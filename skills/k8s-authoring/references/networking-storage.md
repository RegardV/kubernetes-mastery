# Networking & Storage

Covers the **network exposure** failure mode and the storage half of stateful
workloads. Companion files: `security-hardening.md` (PSS/RBAC/Secrets),
`workload-patterns.md` (Deployment/StatefulSet shape), `packaging-validation.md`
(validating cross-resource consistency). Version floor: **Kubernetes v1.29+**.

Grounding: official Kubernetes docs → NSA/CISA Hardening Guide (network
separation) → OWASP K8s Top 10 (K08 missing network segmentation) → CIS 5.3.

---

## 1. Services

A Service gives a stable virtual IP / DNS name in front of a set of Pods
selected by label. DNS: `<svc>.<namespace>.svc.cluster.local`.

| Type | Reachable from | Use when | Watch out |
|---|---|---|---|
| **ClusterIP** (default) | Inside the cluster only | Internal service-to-service | None; safest default. |
| **NodePort** | `<anyNodeIP>:<30000-32767>` | Bare-metal without a LB, dev, or behind an external LB you manage | Opens a port on **every** node — network exposure. Avoid for prod ingress. |
| **LoadBalancer** | External via cloud LB | Cloud L4 entry point | Provisions (and bills for) a cloud LB per Service. Use an Ingress/Gateway to share one. |
| **ExternalName** | CNAME to external DNS | Alias an out-of-cluster host (`db.rds.aws`) | No proxying/selector; just DNS. No TLS handling. |

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: payments
spec:
  type: ClusterIP
  selector:
    app: web                 # MUST match pod template labels (see consistency note)
  ports:
    - name: http
      port: 80               # Service port
      targetPort: 8080       # containerPort on the pod
```

**Headless Service** (`clusterIP: None`) — no virtual IP; DNS returns the Pod
IPs directly. Required for **StatefulSets** so each pod gets a stable DNS name
`<pod>.<svc>.<ns>.svc.cluster.local`, and for client-side load balancing.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db                   # referenced as StatefulSet.spec.serviceName
  namespace: payments
spec:
  clusterIP: None            # headless
  selector:
    app: db
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
```

---

## 2. Ingress vs Gateway API

Both terminate external L7 traffic and route by host/path; both need a
**controller** installed (nginx, Traefik, HAProxy, cloud, Istio, Contour…).
The API object alone does nothing without a controller.

### Ingress (stable, `networking.k8s.io/v1`)

Mature, ubiquitous, but limited: HTTP(S) only, and advanced features live in
controller-specific annotations (not portable). Good default for simple
host/path routing + TLS.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  namespace: payments
  annotations:
    # Controller-specific. Redirect http→https on nginx:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx          # which controller handles this (replaces the old annotation)
  tls:
    - hosts:
        - app.example.com
      secretName: app-tls          # kubernetes.io/tls Secret: tls.crt + tls.key
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
```

TLS termination: the referenced `secretName` is a `kubernetes.io/tls` Secret
holding `tls.crt`/`tls.key`. Typically issued and rotated by **cert-manager**
(ACME/Let's Encrypt or an internal CA) — don't hand-manage certs.

### Gateway API (`gateway.networking.k8s.io`, GA v1 since v1.1)

The successor: role-oriented (infra team owns `Gateway`, app team owns
`HTTPRoute`), protocol-aware (HTTP, TLS, TCP, gRPC), and portable — features
are typed fields, not annotations. Prefer for new multi-team platforms; keep
Ingress for simple single-team setups until your controller's Gateway support
is solid.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared
  namespace: gateway-system
spec:
  gatewayClassName: nginx
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-tls        # kubernetes.io/tls Secret
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels: { gateway-access: "true" }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web
  namespace: payments
spec:
  parentRefs:
    - name: shared
      namespace: gateway-system
  hostnames: ["app.example.com"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: web
          port: 80
```

---

## 3. NetworkPolicies — zero trust

By default **all Pods can talk to all Pods** (flat network). A NetworkPolicy is
a namespaced, label-selected firewall enforced by the CNI — **your CNI must
support it** (Calico, Cilium, Antrea, Weave do; flannel alone does not). Applying
a policy under a non-enforcing CNI silently does nothing.

Policies are **additive and allow-only**: once *any* policy selects a pod for a
direction (ingress/egress), everything not explicitly allowed for that direction
is denied. The zero-trust pattern is: **default-deny, then allow narrowly.**

### Default-deny all ingress and egress (per namespace)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}                 # empty = every pod in the namespace
  policyTypes:
    - Ingress
    - Egress
  # No ingress/egress rules => deny both directions for all selected pods.
```

This also blocks DNS. Immediately add an egress allowance for DNS or nothing
resolves:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system   # auto-set label on every ns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### Allow a specific flow (web → db, and ingress to web)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-to-db
  namespace: payments
spec:
  podSelector:
    matchLabels: { app: db }      # this policy governs db pods
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { app: web }   # only web pods, same namespace
      ports:
        - protocol: TCP
          port: 5432
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-web
  namespace: payments
spec:
  podSelector:
    matchLabels: { app: web }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { name: ingress-nginx }   # traffic from the ingress controller ns
      ports:
        - protocol: TCP
          port: 8080
```

Selector semantics that trip people up:

- `podSelector` alone → pods **in the policy's own namespace**.
- `namespaceSelector` alone → all pods in the matched namespaces.
- `podSelector` **and** `namespaceSelector` in the *same* `from` element (no `-`
  between them) → pods matching **both** (AND). Two separate list items → OR.
- `ipBlock` → CIDR-based allow (with optional `except`), for egress to external
  IPs or on-prem ranges.

Roll out default-deny per namespace, verify app flows still work with a probe,
then keep it as the baseline. NSA/CISA and CIS 5.3.2 both call for network
segmentation; default-deny is the enforcement.

---

## 4. Storage

### The chain: StorageClass → PVC → PV → Volume

- **PersistentVolume (PV)** — a piece of storage in the cluster (cluster-scoped).
- **PersistentVolumeClaim (PVC)** — a namespaced *request* for storage (size +
  access mode + class). Pods mount PVCs, never PVs directly.
- **StorageClass (SC)** — describes a *provisioner* + parameters for **dynamic**
  provisioning: a PVC referencing an SC auto-creates a matching PV. Without an
  SC you must pre-create PVs (static provisioning).

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com          # a CSI driver
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete                  # Delete | Retain
volumeBindingMode: WaitForFirstConsumer  # bind after pod scheduled -> AZ-correct
allowVolumeExpansion: true
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: payments
spec:
  storageClassName: fast-ssd
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 20Gi
```

### Access modes

| Mode | Short | Meaning | Typical backend |
|---|---|---|---|
| ReadWriteOnce | RWO | Mounted read-write by a single **node** (multiple pods on that node OK) | Block storage (EBS, PD, Azure Disk) |
| ReadOnlyMany | ROX | Read-only by many nodes | Object-backed, NFS, some CSI |
| ReadWriteMany | RWX | Read-write by many nodes | NFS, CephFS, EFS, Azure Files |
| ReadWriteOncePod | RWOP | Read-write by a single **pod** (strict, v1.29 stable) | CSI drivers supporting it |

Most cloud block volumes are **RWO only** — you cannot share one across pods on
different nodes. Need shared read-write → a filesystem backend (RWX) or
rearchitect. Requesting RWX from a block-only class fails to bind.

### Reclaim policy

- **Delete** — deleting the PVC deletes the PV and underlying storage. Convenient
  for scratch/replaceable data; **data loss** if used for a database.
- **Retain** — PV (and data) survive PVC deletion; an admin must reclaim/clean it
  manually. Use for anything you can't lose. Set it on the StorageClass for
  production stateful data.

### CSI

The **Container Storage Interface** is the standard plugin model (in-tree drivers
are removed). Vendors ship a CSI driver (`ebs.csi.aws.com`, `pd.csi.storage.gke.io`,
`disk.csi.azure.com`, Ceph, Portworx…) referenced by the StorageClass
`provisioner`. CSI enables snapshots, cloning, resize, and topology awareness.

### StatefulSet `volumeClaimTemplates`

A StatefulSet mints a **dedicated PVC per replica** from a template — each pod
gets its own persistent, stable-named volume (`data-db-0`, `data-db-1`, …) that
survives rescheduling. Pair with the headless Service above.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
  namespace: payments
spec:
  serviceName: db               # the headless Service
  replicas: 3
  selector:
    matchLabels: { app: db }
  template:
    metadata:
      labels: { app: db }
    spec:
      containers:
        - name: db
          image: postgres@sha256:<digest>
          ports:
            - { name: postgres, containerPort: 5432 }
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        storageClassName: fast-ssd
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi
```

Note: `volumeClaimTemplates` PVCs are **not** garbage-collected when the
StatefulSet is deleted (protects data) — clean them up explicitly if intended.

### AZ / topology pinning

A zonal block volume (EBS/PD/Azure Disk) lives in **one** availability zone; a
pod bound to it can only schedule in that zone. Use
`volumeBindingMode: WaitForFirstConsumer` (above) so the PV is created **after**
the scheduler places the pod — the volume lands in the pod's zone instead of a
random one the pod then can't reach. For HA, spread replicas across zones with
pod `topologySpreadConstraints`; each replica's PVC pins that replica to its
zone. Regional/replicated volumes or an RWX filesystem remove the single-zone
constraint at higher cost.
