# Examples — GOOD vs BAD, annotated

Side-by-side manifests for the objects you write most: a Deployment, a Service,
RBAC, and a NetworkPolicy. Each pair shows the **bad** version first, calls out
every problem and which of the six failure modes it maps to, then the **hardened
good** version. Failure-mode vocabulary matches `failure-modes.md`: *insecure
workload defaults, resource starvation, network exposure, privilege sprawl, fragile
rollouts, API drift*. Assumes **v1.29+**.

For full remediation detail see `failure-modes.md`; for whole-workload templates see
`workload-patterns.md`.

---

## 1. Deployment

### BAD

```yaml
apiVersion: extensions/v1beta1       # (1)
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1                        # (2)
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
        - name: web
          image: web:latest          # (3)
          ports: [{ containerPort: 8080 }]
          # (4) no resources
          # (5) no securityContext
          # (6) no probes
```

What's wrong:

1. **API drift** — `extensions/v1beta1` Deployment was removed in v1.16. This won't
   apply to any current cluster. Also missing the required `selector`.
2. **Fragile rollouts** — `replicas: 1` is a single point of failure; one node drain
   or crash = full outage. No rollout strategy tuning.
3. **Fragile rollouts / insecure defaults** — `web:latest` is a moving tag: not
   reproducible, no reliable rollback, and nodes can pull different bits for the
   "same" version.
4. **Resource starvation** — no requests/limits → BestEffort QoS, first to be OOM-
   evicted, can starve neighbors, no scheduler capacity reservation.
5. **Insecure workload defaults** — runs as root, full capability set, writable
   rootfs, no seccomp. Fails PSS `restricted`.
6. **Fragile rollouts** — no readiness probe means traffic hits the pod before it
   can serve (502s on every deploy); no liveness/startup probes.

### GOOD

```yaml
apiVersion: apps/v1                  # (1) current GA
kind: Deployment
metadata:
  name: web
  namespace: web
  labels: { app: web }
spec:
  replicas: 3                        # (2) survive a node loss
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }   # (6) zero-downtime
  minReadySeconds: 10
  selector:
    matchLabels: { app: web }        # (1) required selector, matches template labels
  template:
    metadata:
      labels: { app: web }
    spec:
      serviceAccountName: web        # (privilege sprawl) dedicated SA, not default
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      securityContext:               # (5) pod-level hardening
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: web
          image: registry.example.com/web@sha256:<digest>   # (3) pinned by digest
          ports: [{ containerPort: 8080 }]
          resources:                 # (4) requests+limits, Guaranteed-ish
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "256Mi" }
          securityContext:           # (5) container-level hardening
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          startupProbe:              # (6) guard slow boot
            httpGet: { path: /healthz, port: 8080 }
            failureThreshold: 30
            periodSeconds: 5
          readinessProbe:            # (6) gate traffic
            httpGet: { path: /readyz, port: 8080 }
            periodSeconds: 5
          livenessProbe:             # (6) restart if wedged
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 10
          lifecycle:
            preStop: { exec: { command: ["/bin/sh","-c","sleep 15"] } }  # (6) drain
          volumeMounts:
            - { name: tmp, mountPath: /tmp }   # (5) writable scratch for RO rootfs
      volumes:
        - name: tmp
          emptyDir: {}
```

Pair it with a `PodDisruptionBudget` (`minAvailable: 2`) to close the resource-
starvation gap on voluntary disruptions — see `failure-modes.md` §2.

---

## 2. Service

### BAD

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: LoadBalancer          # (1)
  selector: { app: web }
  ports:
    - port: 80
      targetPort: 80          # (2)
```

What's wrong:

1. **Network exposure** — `type: LoadBalancer` provisions a public cloud IP and puts
   an internal service on the internet. Most Services should be `ClusterIP`.
2. **Fragile rollouts / network exposure** — `targetPort: 80` doesn't match the
   container's `8080`; traffic black-holes. `port`/`targetPort` mismatch is a
   classic silent outage. No named port either, so the contract is easy to break.

### GOOD

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: web
  labels: { app: web }
spec:
  type: ClusterIP             # (1) internal only; expose via Ingress + TLS if public
  selector: { app: web }      # matches the Deployment's pod labels exactly
  ports:
    - name: http
      port: 80
      targetPort: 8080        # (2) matches containerPort
      protocol: TCP
```

If it genuinely must be reached from outside, keep the Service `ClusterIP` and put an
`Ingress` with TLS in front of it (see `failure-modes.md` §3), rather than exposing
the Service directly. Consistency check: Service `selector` ↔ pod `labels`, and
Service `targetPort` ↔ container `containerPort`.

---

## 3. RBAC

### BAD

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole                 # (1)
metadata:
  name: web
rules:
  - apiGroups: ["*"]              # (2)
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding          # (3)
metadata:
  name: web
subjects:
  - kind: ServiceAccount
    name: default                 # (4)
    namespace: web
roleRef:
  kind: ClusterRole
  name: cluster-admin             # (5)
  apiGroup: rbac.authorization.k8s.io
```

What's wrong (all **privilege sprawl**):

1. **ClusterRole** grants rights cluster-wide when the workload only acts in one
   namespace — should be a namespaced `Role`.
2. Wildcard `*` on apiGroups/resources/verbs grants everything, including dangerous
   verbs (`escalate`, `bind`, `impersonate`) that let the subject grant itself more.
3. **ClusterRoleBinding** widens the blast radius to the whole cluster.
4. Binds the shared `default` ServiceAccount — every pod in the namespace inherits
   these rights, so one compromise affects all of them.
5. Binding to `cluster-admin` gives a workload full control of the cluster. Never do
   this for a workload.

### GOOD

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: web                       # dedicated SA, one per workload
  namespace: web
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role                        # (1) namespaced
metadata:
  name: web-read-config
  namespace: web
rules:
  - apiGroups: [""]               # (2) explicit group/resource/verbs, no wildcards
    resources: ["configmaps"]
    resourceNames: ["web-config"] # scoped to the exact object
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding                 # (3) namespaced binding
metadata:
  name: web-read-config
  namespace: web
subjects:
  - kind: ServiceAccount
    name: web                     # (4) the dedicated SA, not default
    namespace: web
roleRef:
  kind: Role                      # (5) least-privilege Role, never cluster-admin
  name: web-read-config
  apiGroup: rbac.authorization.k8s.io
```

The pod that uses this SA sets `serviceAccountName: web` and only turns on
`automountServiceAccountToken` if it actually calls the API server. Full RBAC
guidance in `security-hardening.md`.

---

## 4. NetworkPolicy

### BAD

There is no bad NetworkPolicy here — the bad case is the **absence** of one. With no
policy, Kubernetes is **allow-all**: every pod can reach every other pod and Service
across all namespaces.

```yaml
# (nothing) — no NetworkPolicy in the namespace
# Result: a compromised frontend can talk straight to the database,
# the metadata service, and other teams' namespaces. Unrestricted lateral movement.
```

What's wrong (**network exposure**): no segmentation. This is OWASP K8s K07. Even a
correctly hardened pod is one RCE away from reaching everything.

A second common mistake is a partial policy that forgets DNS:

```yaml
# default-deny egress with NO allow for kube-dns → every name lookup fails,
# and the app looks "broken" for reasons unrelated to its own code.
```

### GOOD

Default-deny the namespace, then allow exactly what's needed (including DNS):

```yaml
apiVersion: networking.k8s.io/v1     # current GA
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: web
spec:
  podSelector: {}                    # every pod in the namespace
  policyTypes: [Ingress, Egress]     # no rules below ⇒ deny all in both directions
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow
  namespace: web
spec:
  podSelector:
    matchLabels: { app: web }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:                          # only the ingress controller reaches web:8080
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
      ports: [{ protocol: TCP, port: 8080 }]
  egress:
    - to:                            # DNS — REQUIRED, or all lookups fail
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:                            # only the postgres pods in the db namespace
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: db }
          podSelector:
            matchLabels: { app: postgres }
      ports: [{ protocol: TCP, port: 5432 }]
```

Why it's right: default-deny establishes least-privilege networking; each allow is
explicit and narrow; DNS egress is included so the app actually works. Remember
NetworkPolicy is enforced by the **CNI** — Calico/Cilium enforce it, flannel does
not, so verify your CNI or the default-deny is a no-op. See `networking-storage.md`.

---

## The through-line

Every "good" manifest above is the same move: replace implicit cluster defaults with
**explicit, least-privilege, validated** configuration. Map each object back to the
six failure modes before you apply it —

- Deployment → *insecure defaults*, *resource starvation*, *fragile rollouts*, *API
  drift*
- Service → *network exposure*, *fragile rollouts* (port mismatch)
- RBAC → *privilege sprawl*
- NetworkPolicy → *network exposure*

Then validate: `kubectl apply --dry-run=server`, `kubeconform -strict`, and a policy
scan — as in the `SKILL.md` workflow and `packaging-validation.md`.
