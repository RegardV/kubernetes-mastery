# Security Hardening

Covers the **insecure workload defaults** and **privilege sprawl** failure modes.
Companion files: `networking-storage.md` (network exposure), `packaging-validation.md`
(policy enforcement in CI). Version floor: **Kubernetes v1.29+** unless noted.

Grounding order when guidance conflicts: official Kubernetes docs → NSA/CISA
Kubernetes Hardening Guide → OWASP Kubernetes Top 10 → Pod Security Standards →
CIS Kubernetes Benchmark.

---

## 1. Pod Security Standards (PSS)

Three cumulative profiles, defined by the Kubernetes project. Each is a *policy*,
not a mechanism — you enforce them with Pod Security Admission (PSA, below) or a
third-party engine (Kyverno/Gatekeeper).

| Profile | Intent | Key constraints |
|---|---|---|
| **privileged** | Unrestricted. Trusted/system workloads only. | No restrictions. Never a default for app namespaces. |
| **baseline** | Minimally restrictive; blocks known privilege escalations. | No `hostNetwork/hostPID/hostIPC`, no privileged containers, no hostPath, restricted `hostPorts`, no adding capabilities beyond a small allowed set, default `seccompProfile` not `Unconfined`. |
| **restricted** | Heavily hardened; current best practice for apps. | Everything in baseline **plus** `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile.type: RuntimeDefault`, volume types limited, `runAsUser != 0`. |

**Default to `restricted` for application namespaces.** Drop to `baseline` only
with a stated reason (e.g. a workload that needs `NET_ADMIN`), and never run app
workloads under `privileged`.

### Enforce via Pod Security Admission (namespace labels)

PSA is a built-in admission controller (stable since v1.25). It reads labels on
the **namespace** and applies one of three modes per profile:

- `enforce` — reject Pods that violate the profile.
- `audit` — allow, but record a violation annotation in the audit log.
- `warn` — allow, but return a user-facing warning on `kubectl apply`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    # Reject anything not meeting "restricted".
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.29
    # Also surface warnings + audit at the same bar (belt and braces).
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.29
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.29
```

Rollout pattern for an existing namespace: set `warn`/`audit` to `restricted`
first, watch for violations, fix workloads, then flip `enforce`. Pin
`*-version` to your cluster minor so a control-plane upgrade cannot silently
tighten the bar under you.

PSA is namespace-scoped and coarse (whole profiles only). When you need
per-workload exceptions or richer rules (e.g. "allow `NET_ADMIN` for this one
Deployment"), layer Kyverno or Gatekeeper — see `packaging-validation.md`.

---

## 2. securityContext — field by field

`securityContext` exists at both **pod** (`spec.securityContext`) and
**container** (`spec.containers[].securityContext`) level. Container-level wins
on overlap. Set the pod level for `runAsNonRoot`/`fsGroup`/`seccompProfile`, and
the container level for `capabilities`/`allowPrivilegeEscalation`/
`readOnlyRootFilesystem`.

A `restricted`-compliant container:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: payments
spec:
  replicas: 3
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      automountServiceAccountToken: false        # see RBAC section
      serviceAccountName: web
      securityContext:                             # pod-level
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001                             # group-owns mounted volumes
        fsGroupChangePolicy: OnRootMismatch        # avoid recursive chown on large volumes
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: registry.example.com/web@sha256:<digest>   # pin by digest, not :latest
          ports:
            - containerPort: 8080
          securityContext:                         # container-level
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
      volumes:
        - name: tmp
          emptyDir: {}
        - name: cache
          emptyDir: {}
```

Field reference:

- **`runAsNonRoot: true`** — kubelet refuses to start the container if the image
  resolves to UID 0. The single highest-value control (CIS 5.2.6, NSA/CISA
  "non-root"). Does not by itself pick a UID; pair with `runAsUser`.
- **`runAsUser` / `runAsGroup`** — explicit non-zero UID/GID. Use a high,
  unprivileged value (e.g. `10001`). Some images set `USER` in the Dockerfile;
  setting it here removes ambiguity and satisfies `restricted`.
- **`fsGroup`** — supplemental GID that owns mounted volumes, so a non-root
  process can write to a PVC/emptyDir. `fsGroupChangePolicy: OnRootMismatch`
  skips the recursive `chown` when the top-level dir already matches — important
  for large volumes (avoids slow pod starts).
- **`allowPrivilegeEscalation: false`** — sets the `no_new_privs` bit; blocks a
  process from gaining more privileges than its parent (e.g. via setuid
  binaries). Required by `restricted`.
- **`capabilities.drop: ["ALL"]`** — start from zero Linux capabilities, then
  `add:` back only what is proven necessary (e.g. `["NET_BIND_SERVICE"]` to bind
  <1024). Dropping ALL is required by `restricted`; adding anything beyond the
  baseline allow-list breaks `baseline`.
- **`seccompProfile.type: RuntimeDefault`** — applies the container runtime's
  default seccomp filter, blocking dangerous syscalls. `restricted` forbids
  `Unconfined`. Use `Localhost` + `localhostProfile` only for a custom profile.
- **`readOnlyRootFilesystem: true`** — immutable container filesystem; defeats a
  large class of in-container tampering and persistence. Mount `emptyDir` (or a
  PVC) for the specific writable paths the app needs (`/tmp`, cache, run dirs).
- **`privileged: true`** — never for app workloads. Grants all capabilities and
  host device access; equals host root. Only CNI/CSI/system agents.
- **`hostNetwork` / `hostPID` / `hostIPC: true`** — share host namespaces;
  forbidden by `baseline`. Avoid unless the workload is an infra agent.

---

## 3. RBAC — least privilege

Model: **Subjects** (User, Group, ServiceAccount) are granted **verbs** on
**resources** via a **Role** (namespaced) or **ClusterRole** (cluster-wide),
bound by a **RoleBinding** or **ClusterRoleBinding**.

### Role vs ClusterRole

- **Role** — permissions within **one namespace**. Default choice for app
  ServiceAccounts.
- **ClusterRole** — cluster-scoped resources (nodes, PVs, namespaces,
  CRDs at cluster scope) *or* a reusable permission set. A ClusterRole bound
  with a **RoleBinding** grants its verbs **only in that binding's namespace** —
  a common way to reuse a definition without going cluster-wide.
- **ClusterRoleBinding** — grants a ClusterRole across **all** namespaces. Rare
  for apps; audit every one.

### Dedicated ServiceAccount + minimal Role

Never let workloads use the namespace `default` ServiceAccount (it accumulates
grants and is shared). Give each workload its own SA.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: web
  namespace: payments
automountServiceAccountToken: false   # opt in per-pod only if the app calls the API
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: web-config-reader
  namespace: payments
rules:
  - apiGroups: [""]                    # core group
    resources: ["configmaps"]
    resourceNames: ["web-config"]      # scope to a single object where possible
    verbs: ["get", "list", "watch"]    # read-only; no create/update/delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: web-config-reader
  namespace: payments
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: web-config-reader
subjects:
  - kind: ServiceAccount
    name: web
    namespace: payments
```

Rules of thumb:

- **No wildcards.** `apiGroups: ["*"]`, `resources: ["*"]`, or `verbs: ["*"]`
  is a red flag (CIS 5.1.3). Enumerate exactly what's needed.
- **Never bind `cluster-admin`** to a workload SA (CIS 5.1.1). If you think you
  need it, you need a narrower ClusterRole.
- **Scope with `resourceNames`** to specific objects when the verb set allows
  (note: `list`/`watch`/`create`/`deletecollection` cannot be name-restricted).
- **Separate read from write.** Split roles so a component that only reads never
  holds `update`/`delete`/`patch`.
- **Avoid escalation-enabling verbs** unless required: `bind`, `escalate`,
  `impersonate`, and `create` on `pods/exec`, `secrets`, `serviceaccounts/token`,
  and RBAC objects are privilege-escalation vectors.

### `automountServiceAccountToken: false`

By default every pod gets a mounted SA token at
`/var/run/secrets/kubernetes.io/serviceaccount/token`. A stolen token = the SA's
API access. Most app pods never call the API — turn it off. Set it on the
**ServiceAccount** (default for all its pods) and/or the **Pod spec** (per-pod
override). Opt back in only for controllers/operators that genuinely call the
API server (CIS 5.1.5, NSA/CISA). Modern tokens are short-lived, audience-bound
projected tokens — still, don't mount what you don't use.

---

## 4. Secrets handling

Kubernetes `Secret` objects are **base64-encoded, not encrypted**. Anyone with
`get secrets` in the namespace, or read access to etcd, sees plaintext.

- **Encryption at rest (etcd).** Configure `EncryptionConfiguration` on the API
  server so Secrets are encrypted in etcd. Prefer a KMS provider (envelope
  encryption via an external KMS) over `aescbc`/`secretbox` static keys, which
  only move the key onto the control-plane host. CIS 3.1.1 / NSA/CISA.

  ```yaml
  # /etc/kubernetes/enc/encryption-config.yaml (referenced by --encryption-provider-config)
  apiVersion: apiserver.config.k8s.io/v1
  kind: EncryptionConfiguration
  resources:
    - resources: ["secrets"]
      providers:
        - kms:                       # envelope encryption via external KMS
            apiVersion: v2
            name: cluster-kms
            endpoint: unix:///var/run/kmsplugin/socket.sock
        - identity: {}               # fallback for reads of pre-existing data
  ```

  After enabling, rewrite existing secrets so they get encrypted:
  `kubectl get secrets --all-namespaces -o json | kubectl replace -f -`.

- **External secret managers.** Prefer keeping secret *material* out of the
  cluster entirely: External Secrets Operator, Vault Agent/CSI, or the
  Secrets Store CSI Driver sync from AWS Secrets Manager / GCP Secret Manager /
  Azure Key Vault / Vault. The manifest references the manager; the value never
  lives in git. This also gives rotation and audit for free.

- **RBAC on secrets.** Grant `get`/`list` on Secrets narrowly, scoped by
  `resourceNames`. `list secrets` at namespace scope exposes every secret.

- **`imagePullSecrets`.** For private registries, create a
  `kubernetes.io/dockerconfigjson` Secret and reference it — attach to the
  **ServiceAccount** so all its pods inherit it, rather than repeating per-pod:

  ```yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: web
    namespace: payments
  imagePullSecrets:
    - name: registry-creds        # kubectl create secret docker-registry registry-creds ...
  automountServiceAccountToken: false
  ```

  Even better where supported: image-pull credentials via a cloud IAM identity
  (IRSA / Workload Identity) so no long-lived registry password is stored.

- **Never** commit secrets to git, bake them into images, or pass them as plain
  `env` from literals. Mount as files (volume) over env vars where possible —
  env is visible in `/proc`, crash dumps, and child processes.

---

## 5. Standards mapping

| Control here | NSA/CISA Hardening | OWASP K8s Top 10 | CIS Benchmark |
|---|---|---|---|
| `runAsNonRoot`, non-root UID | Kubernetes Pod Security → non-root | K01 Insecure Workload Config | 5.2.6 |
| `allowPrivilegeEscalation: false` | Immutable / least-priv containers | K01 | 5.2.5 |
| `capabilities.drop: ["ALL"]` | Least-privilege containers | K01 | 5.2.7–5.2.9 |
| `privileged: false`, no host namespaces | Non-privileged, host isolation | K01 | 5.2.1–5.2.4 |
| `seccompProfile: RuntimeDefault` | Seccomp/AppArmor enforcement | K01 | 5.7.2 |
| `readOnlyRootFilesystem: true` | Immutable filesystems | K01 | 5.2.x (hardening) |
| PSS `restricted` via PSA labels | Pod Security enforcement | K01 / K08 Missing Segmentation (policy) | 5.2 (Pod Security Standards) |
| Dedicated SA, no wildcards, no cluster-admin | RBAC least privilege | K03 Overly Permissive RBAC | 5.1.1–5.1.3 |
| `automountServiceAccountToken: false` | Limit token exposure | K03 / K08 | 5.1.5–5.1.6 |
| etcd encryption at rest / KMS | Encrypt Secrets at rest | K07 Missing Logging & Secrets Mgmt | 3.1.1 (encryption provider) |
| External secret managers, file mounts | Protect secret material | K07 | 5.4.1 |
| NetworkPolicy default-deny (see `networking-storage.md`) | Network separation | K08 Missing Network Segmentation | 5.3.2 |

When you cannot meet a control, say so explicitly in the output contract's
"tradeoffs" section and name the compensating control.
