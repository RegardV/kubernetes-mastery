# Failure Modes — smell → why it bites → remediation

The six failure modes from `SKILL.md`, in the same order. Each section: the
**smell** (what you see in the manifest), **why it bites** (the production
incident it causes), and a **remediation** with copy-pasteable YAML. Grounded in
official Kubernetes docs, the NSA/CISA Kubernetes Hardening Guide, OWASP
Kubernetes Top 10, the Pod Security Standards (PSS), and the CIS Kubernetes
Benchmark. When guidance conflicts, official K8s docs win.

Assumes a modern cluster, **v1.29+**, unless a snippet notes otherwise. Deeper
per-topic material lives in `security-hardening.md`, `networking-storage.md`,
`workload-patterns.md`, and `packaging-validation.md`; worked good/bad pairs are
in `examples-good-bad.md`.

---

## 1. Insecure workload defaults

**Smell.** No `securityContext`. Container runs as UID 0. No `seccompProfile`.
Writable root filesystem. Capabilities left at the container-runtime default set.
Namespace has no Pod Security Admission label.

**Why it bites.** A default pod runs as root inside the container. If the process
is compromised (RCE in your app, a poisoned dependency), the attacker starts with
root in the container and the default capability set (`NET_RAW`, `CHOWN`,
`SETUID`, etc.). A writable rootfs lets them drop tooling and rewrite binaries. No
seccomp means the full syscall surface is reachable, widening every
container-escape CVE (runc, kernel). This is OWASP K8s **K01 Insecure Workload
Configurations** and the core of the NSA/CISA "non-root, immutable, least
capability" guidance.

**Remediation.** Set an explicit pod- and container-level `securityContext` that
satisfies PSS `restricted`, and enforce it at the namespace with Pod Security
Admission so nothing non-conforming can schedule.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: web
spec:
  replicas: 3
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      securityContext:                 # pod-level
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: registry.example.com/web@sha256:<digest>
          securityContext:             # container-level
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 8080
          volumeMounts:                # rootfs is read-only, so give writable scratch
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

Enforce `restricted` at the namespace (v1.25+ GA Pod Security Admission):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: web
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.29
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

Notes: if your app must bind a port < 1024, prefer a high port + Service
remap over `NET_BIND_SERVICE`; only add the single capability back if truly
required. See `security-hardening.md` for the full PSS `restricted` checklist.

---

## 2. Resource starvation

**Smell.** No `resources.requests` or `resources.limits`. Every pod lands in
`BestEffort` QoS. No `PodDisruptionBudget`. A single Deployment with no memory cap.

**Why it bites.** Without requests the scheduler cannot reserve capacity, so it
overpacks nodes; under load the node hits memory pressure and the kubelet starts
evicting — `BestEffort` pods first. Without a memory **limit** one leaking pod
consumes the node and triggers the OOM killer, taking neighbors with it. Without a
CPU **request** your latency-sensitive service gets starved by a batch job on the
same node. Without a PDB, a routine node drain (upgrade, autoscaler scale-down) can
delete every replica at once and cause an outage. This is OWASP K8s **K06 Broken
Resource Limits / DoS**.

**Why QoS matters.** `requests == limits` for both CPU and memory ⇒ **Guaranteed**
(evicted last). Requests set but lower than limits ⇒ **Burstable**. Nothing set ⇒
**BestEffort** (evicted first). Give critical workloads Guaranteed or a firm
Burstable floor.

**Remediation.** Set requests and limits, choose QoS deliberately, and protect
availability with a PDB. For memory, set `requests == limits` (memory is
incompressible — bursting past a request just gets you OOM-killed later).

```yaml
# container spec fragment
resources:
  requests:
    cpu: "250m"
    memory: "256Mi"
  limits:
    cpu: "1"          # CPU is compressible: burst allowed, then throttled
    memory: "256Mi"   # == request → no memory bursting, predictable OOM boundary
```

PodDisruptionBudget so voluntary disruptions never take the service to zero:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
  namespace: web
spec:
  minAvailable: 2          # or maxUnavailable: 1
  selector:
    matchLabels: { app: web }
```

Backstop the whole namespace so a bad manifest can't run unbounded:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: web
spec:
  limits:
    - type: Container
      default:            # applied as limit if omitted
        cpu: "500m"
        memory: "256Mi"
      defaultRequest:     # applied as request if omitted
        cpu: "100m"
        memory: "128Mi"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: hard-caps
  namespace: web
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 16Gi
    limits.cpu: "20"
    limits.memory: 32Gi
```

Tradeoff: CPU limits cause throttling (CFS quota) even when the node is idle. For
latency-critical services many teams set a CPU **request** and omit the CPU limit
(keep the memory limit). Do that only in namespaces with a ResourceQuota so the
workload is still bounded overall.

---

## 3. Network exposure

**Smell.** No NetworkPolicy anywhere (all pod-to-pod traffic allowed by default).
`Service` of `type: LoadBalancer` or `NodePort` where `ClusterIP` would do.
Ingress serving plain HTTP. Databases reachable from every namespace.

**Why it bites.** Kubernetes networking is **allow-all by default** — any pod can
reach any other pod and every Service on the cluster. One compromised frontend can
then talk straight to your database, your metadata service, or another team's
namespace (lateral movement). An accidental `type: LoadBalancer` provisions a
public cloud IP and puts an internal service on the internet. Plain-HTTP Ingress
leaks credentials and session tokens. This is OWASP K8s **K07 Missing Network
Segmentation Controls** and central to the NSA/CISA guidance.

**Remediation.** Start every namespace with a **default-deny** policy, then add
explicit allows. Use the narrowest Service type. Terminate TLS at the Ingress.

Default-deny all ingress and egress in the namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: web
spec:
  podSelector: {}                 # all pods in namespace
  policyTypes: [Ingress, Egress]
  # no ingress/egress rules ⇒ deny everything
```

Then allow only what's needed — here, ingress from the app namespace on 8080, DNS
egress, and egress to the database namespace on 5432:

```yaml
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
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
      ports:
        - { protocol: TCP, port: 8080 }
  egress:
    - to:                          # DNS — required or everything breaks
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: db }
          podSelector:
            matchLabels: { app: postgres }
      ports:
        - { protocol: TCP, port: 5432 }
```

Right-size the Service (internal traffic stays `ClusterIP`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: web
spec:
  type: ClusterIP           # NOT LoadBalancer/NodePort unless it must be external
  selector: { app: web }
  ports:
    - { name: http, port: 80, targetPort: 8080 }
```

TLS at the edge (Ingress + cert-manager or a pre-provisioned secret):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  namespace: web
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: [web.example.com]
      secretName: web-tls
  rules:
    - host: web.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port: { number: 80 }
```

NetworkPolicy is enforced by the CNI — Calico, Cilium, and others enforce it;
flannel does not. Confirm your CNI enforces policy, or the default-deny is a
no-op. More in `networking-storage.md`.

---

## 4. Privilege sprawl

**Smell.** Roles with `verbs: ["*"]` or `resources: ["*"]`. A `ClusterRoleBinding`
to `cluster-admin`. Every workload using the namespace `default` ServiceAccount.
`automountServiceAccountToken` left on when the pod never calls the API.

**Why it bites.** A pod's mounted ServiceAccount token is a cluster credential. If
the pod is compromised and its SA has broad rights, the attacker inherits them —
they can read every Secret, create pods, or escalate to admin. Sharing the
`default` SA means one leak affects every workload in the namespace. Wildcard
verbs grant `escalate`/`bind`/`impersonate` even when you didn't mean to. This is
OWASP K8s **K03 Overly Permissive RBAC** and NSA/CISA least-privilege.

**Remediation.** One dedicated ServiceAccount per workload, a Role scoped to the
exact resources/verbs, a RoleBinding (namespaced, not cluster-wide), and token
automount **off** unless the pod actually calls the API.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: web
  namespace: web
automountServiceAccountToken: false   # default off; opt in per-pod if needed
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role                             # Role, not ClusterRole — namespaced
metadata:
  name: web-read-config
  namespace: web
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["web-config"]      # scope to the exact object when you can
    verbs: ["get", "watch", "list"]    # no wildcards
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: web-read-config
  namespace: web
subjects:
  - kind: ServiceAccount
    name: web
    namespace: web
roleRef:
  kind: Role
  name: web-read-config
  apiGroup: rbac.authorization.k8s.io
```

Wire the SA into the pod, and mount a token only for the pod that needs it:

```yaml
spec:
  template:
    spec:
      serviceAccountName: web
      automountServiceAccountToken: true   # only if this pod calls the API server
```

Never grant `cluster-admin` to a workload. Avoid the verbs `escalate`, `bind`,
`impersonate`, and `*` on `roles`/`clusterroles`/`rolebindings` — they let a
subject grant itself more than it has. Full RBAC patterns in
`security-hardening.md`.

---

## 5. Fragile rollouts

**Smell.** `image: myapp:latest` (or any moving tag). No `readinessProbe` — traffic
hits pods before they're ready. No `livenessProbe`, or a liveness probe that's
really a readiness check. No `startupProbe` on a slow starter, so liveness kills it
during boot. No `preStop` / short `terminationGracePeriodSeconds` — in-flight
requests dropped on every deploy. Default `strategy` with no surge/unavailable
tuning.

**Why it bites.** A mutable tag means two nodes can pull different images for the
"same" version, and a rollback isn't reproducible. No readiness probe sends traffic
to a pod that isn't listening → 502s during every deploy and scale-up. A liveness
probe that fires during a slow startup enters a crash-loop that never recovers. No
graceful shutdown drops live connections each rollout. This is OWASP K8s **K01/K08**
territory (supply-chain + config) and pure operational reliability.

**Remediation.** Pin the image by **digest**, add all three probes appropriately,
tune the rolling update, and shut down gracefully.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: web
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1            # one extra pod during rollout
      maxUnavailable: 0      # never drop below desired during rollout
  minReadySeconds: 10
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      terminationGracePeriodSeconds: 45
      containers:
        - name: web
          image: registry.example.com/web@sha256:2c8...pin-the-digest
          ports:
            - containerPort: 8080
          startupProbe:            # guards slow boot; liveness/readiness wait for it
            httpGet: { path: /healthz, port: 8080 }
            failureThreshold: 30   # 30 × 5s = up to 150s to start
            periodSeconds: 5
          readinessProbe:          # gates traffic
            httpGet: { path: /readyz, port: 8080 }
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:           # restarts a wedged process
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:               # stop taking new traffic, drain in-flight
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
```

Rules of thumb:
- **readiness** = "can serve now" (fail ⇒ removed from Service endpoints, not
  killed). **liveness** = "is it wedged" (fail ⇒ restarted). Never point liveness
  at a dependency you don't control, or an outage cascades into restart storms.
- Use a **startupProbe** for anything that takes more than a few seconds to boot so
  liveness doesn't kill it mid-startup.
- `preStop sleep` (or a real drain hook) < `terminationGracePeriodSeconds` gives the
  endpoints controller time to deregister the pod before SIGTERM.
- Pin by digest for reproducibility; use a tag + digest comment if humans need
  readability. Rollout/rollback detail in `workload-patterns.md`.

---

## 6. API drift

**Smell.** `apiVersion: extensions/v1beta1` or `apps/v1beta*`,
`networking.k8s.io/v1beta1` Ingress, `policy/v1beta1` PDB,
`batch/v1beta1` CronJob, `autoscaling/v2beta2` HPA,
`rbac.authorization.k8s.io/v1beta1`, or `PodSecurityPolicy` (removed in 1.25).
Manifests that `kubectl apply` accepts today but that the next upgrade rejects.

**Why it bites.** Deprecated APIs are removed on a schedule. A manifest pinned to a
removed version fails to apply after a cluster upgrade — your CI/CD breaks, or
worse, a GitOps controller can't reconcile and drift accumulates silently.
PodSecurityPolicy was removed in v1.25 entirely; charts still shipping it simply
don't work. This is the maintenance tax that turns into an incident during an
otherwise routine upgrade.

**Remediation.** Use current **GA** apiVersions, validate against the target
cluster's schema, and check for deprecations before every upgrade.

Current GA versions to reach for (v1.29+):

```yaml
# Workloads
apps/v1                         # Deployment, StatefulSet, DaemonSet, ReplicaSet
batch/v1                        # Job AND CronJob (batch/v1beta1 CronJob removed 1.25)
# Networking
networking.k8s.io/v1            # Ingress, IngressClass, NetworkPolicy
# Policy / autoscaling
policy/v1                       # PodDisruptionBudget (policy/v1beta1 removed 1.25)
autoscaling/v2                  # HorizontalPodAutoscaler (v2beta* removed)
# RBAC
rbac.authorization.k8s.io/v1    # Role, RoleBinding, ClusterRole, ClusterRoleBinding
# Pod security: use PSS labels on the Namespace, NOT PodSecurityPolicy (removed 1.25)
```

Validate schema and catch deprecations in CI:

```bash
# schema validation against a specific cluster version
kubeconform -strict -summary -kubernetes-version 1.29.0 manifests/

# server-side dry-run catches admission + apiVersion problems the real API rejects
kubectl apply --dry-run=server -f manifests/

# scan a live cluster / manifests for deprecated & removed APIs before upgrading
kubectl deprecations   # (krew plugin), or:
pluto detect-files -d manifests/
```

Keep manifests forward-compatible: prefer GA over beta even when beta still works,
delete `PodSecurityPolicy` and move to PSS labels, and run `pluto` / `kubeconform`
in CI so drift is caught at PR time, not at upgrade time. Validation tooling detail
in `packaging-validation.md`.

---

## Quick cross-check before you ship

- [ ] Non-root, caps dropped, seccomp `RuntimeDefault`, read-only rootfs, PSS
      `restricted` on the namespace — *insecure defaults*
- [ ] requests + limits set, QoS chosen on purpose, PDB present — *resource
      starvation*
- [ ] default-deny NetworkPolicy + explicit allows, narrowest Service type, TLS at
      Ingress — *network exposure*
- [ ] dedicated SA, least-privilege Role, no wildcards/cluster-admin, token
      automount off unless needed — *privilege sprawl*
- [ ] digest-pinned image, readiness+liveness+startup probes, surge/unavailable,
      preStop + grace period — *fragile rollouts*
- [ ] GA apiVersions, no removed APIs, schema-validated in CI — *API drift*
