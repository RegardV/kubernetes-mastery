# Google GKE — Where Managed Kubernetes Flips Vanilla Intuitions

> Loaded only when a GKE platform signal is detected (e.g. `iam.gke.io/gcp-service-account`
> annotations, `cloud.google.com/neg` annotations, `gke.io/*` labels, a `gke_...` kubeconfig
> context, Autopilot admission-webhook rejections, or `container.googleapis.com` references).

## What flips vs vanilla Kubernetes

| Concern | Vanilla intuition | On GKE |
|---|---|---|
| Who runs the nodes | You do | **Autopilot: Google does** — you don't see or manage nodes at all |
| Pod → cloud API auth | Static SA key JSON in a Secret | **Workload Identity** — KSA federates to a GSA, creds from the metadata server |
| Pod IPs | Overlay CIDR | **VPC-native alias IPs** — real, routable secondary-range IPs |
| kube-proxy / NetworkPolicy | iptables + a policy plugin | **Dataplane V2 (eBPF/Cilium)** — no kube-proxy, NetworkPolicy built in |
| `type: LoadBalancer` / Ingress | NodePort behind a cloud LB | **NEGs** let the GCLB target pod IPs directly (container-native LB) |
| PVs | Schedule anywhere | PD volumes are **zone-pinned**; use regional PDs to survive a zone loss |
| Node upgrades | You patch nodes | **Auto-upgrade on a release channel** — nodes get patched under you |
| etcd | You back it up | **You can't** — control plane is Google-managed |
| Cluster access | Static kubeconfig token | **gke-gcloud-auth-plugin** exec plugin (mandatory since client 1.26) |

---

## 1. Autopilot vs Standard — two different operating models

This is the biggest GKE fork. Pick before anything else.

| | **Standard** | **Autopilot** |
|---|---|---|
| Nodes | You create/size node pools | **None visible** — Google runs, sizes, scales, patches nodes |
| Billing | Per-node (whole VM, idle or not) | **Per-pod** (requested vCPU/mem/storage) |
| DaemonSets | Yes | Limited (allowed but no host access; some are blocked) |
| Privileged / hostPath / hostNetwork | Yes | **No** — hardened, rejected by admission |
| Right-sizing | Your job | Automatic; requests are enforced/adjusted |
| Best for | GPUs, host access, custom kernels, fine node control | Web/API services, teams that don't want node ops |

The operating flip: on **Autopilot you never `kubectl get nodes` to debug capacity** — you reason about pod *requests*. There's no SSH, no DaemonSet for node agents with host mounts, no privileged sidecars. If a pod needs those, it belongs on Standard.

Create:
```bash
gcloud container clusters create-auto my-cluster --region us-central1     # Autopilot
gcloud container clusters create my-cluster --zone us-central1-a          # Standard
```

---

## 2. Identity: GKE Workload Identity

Never mount a static SA key JSON. Bind a **Kubernetes SA (KSA)** to a **Google SA (GSA)**; pods fetch short-lived tokens from the GKE **metadata server**. Enabled by default on Autopilot; enable on Standard with `--workload-pool`.

```bash
# 1. Enable on the cluster + node pool (Standard)
gcloud container clusters update my-cluster \
  --workload-pool=my-project.svc.id.goog
gcloud container node-pools update default-pool --cluster my-cluster \
  --workload-metadata=GKE_METADATA

# 2. Create the GSA and grant it cloud permissions (least privilege)
gcloud iam service-accounts create checkout-gsa
gcloud projects add-iam-policy-binding my-project \
  --member "serviceAccount:checkout-gsa@my-project.iam.gserviceaccount.com" \
  --role roles/storage.objectViewer

# 3. Let the KSA impersonate the GSA
gcloud iam service-accounts add-iam-policy-binding \
  checkout-gsa@my-project.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:my-project.svc.id.goog[payments/checkout-ksa]"
```

Annotate the KSA:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout-ksa
  namespace: payments
  annotations:
    iam.gke.io/gcp-service-account: checkout-gsa@my-project.iam.gserviceaccount.com
```
Google client libraries auto-discover creds via the metadata server (`169.254.169.254`) — no code changes. One KSA↔GSA binding per workload keeps blast radius small.

---

## 3. Networking: VPC-native + Dataplane V2

### VPC-native (alias IPs)

GKE clusters are VPC-native by default: pods get **real IPs from a secondary range** (alias IPs) on the subnet — routable inside the VPC, no overlay encapsulation. You size the pod and service ranges at creation:
```bash
gcloud container clusters create my-cluster \
  --enable-ip-alias \
  --cluster-ipv4-cidr=/17 --services-ipv4-cidr=/22
```
Plan CIDRs carefully — pod density and cluster max-size are bounded by the secondary range you pick.

### Dataplane V2 (eBPF / Cilium)

Replaces kube-proxy iptables with **eBPF (Cilium-based)**. Benefits: NetworkPolicy is built in (no separate plugin), scalable service routing, and network policy **logging**:
```bash
gcloud container clusters create my-cluster --enable-dataplane-v2
```
Standard `NetworkPolicy` just works; GKE also adds `CiliumNetworkPolicy`-style features and flow visibility. Default on Autopilot.

---

## 4. Ingress / Load balancing: NEGs, GCLB, Gateway

### Container-native LB via NEGs

A **Network Endpoint Group (NEG)** is a set of `pod-IP:port` endpoints. Because pods have VPC-native IPs, the Google Cloud Load Balancer (GCLB) targets **pods directly** — no NodePort double-hop, better health checks, cleaner source IP. Opt in on a Service:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
spec:
  type: ClusterIP
  ports: [ { port: 80, targetPort: 8080 } ]
  selector: { app: web }
```

### GKE Ingress → external GCLB

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    kubernetes.io/ingress.class: "gce"                       # or "gce-internal"
    networking.gke.io/managed-certificates: "web-cert"       # Google-managed TLS
    kubernetes.io/ingress.global-static-ip-name: "web-ip"
spec:
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: web, port: { number: 80 } } }
```
`ManagedCertificate` provisions and renews TLS certs for you:
```yaml
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata: { name: web-cert }
spec:
  domains: [ app.example.com ]
```

### Gateway API (the current direction)

GKE ships first-class Gateway controllers (`gke-l7-global-external-managed`, regional, internal). Prefer Gateway for new multi-team L7 setups:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: web-gw }
spec:
  gatewayClassName: gke-l7-global-external-managed
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls: { mode: Terminate, certificateRefs: [ { name: web-tls } ] }
```

---

## 5. Storage: PD CSI, regional PDs, Filestore

### PD CSI (block, RWO)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: pd-balanced }
provisioner: pd.csi.storage.gke.io
volumeBindingMode: WaitForFirstConsumer     # avoid zone/affinity conflicts
parameters:
  type: pd-balanced                          # pd-ssd for higher IOPS
  disk-encryption-kms-key: ""                # optional CMEK
```
**Zone pinning is the flip:** a standard PD lives in one zone; the pod is bound to that zone. `WaitForFirstConsumer` binds the disk in whatever zone the pod schedules to.

### Regional PDs — survive a zone loss

Synchronously replicate a PD across two zones so a stateful pod can fail over:
```yaml
parameters:
  type: pd-balanced
  replication-type: regional-pd
# plus allowedTopologies pinning two zones
```

### Filestore (shared, RWX)

For `ReadWriteMany`, PDs can't — use Filestore (managed NFS):
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: filestore-rwx }
provisioner: filestore.csi.storage.gke.io
parameters:
  tier: standard
  network: default
```

---

## 6. Autoscaling

- **Cluster Autoscaler (Standard):** scales node pools within `--min-nodes/--max-nodes`.
- **Node auto-provisioning (NAP):** creates *new node pools* with right-sized machine types on demand — closer to Karpenter's behavior:
  ```bash
  gcloud container clusters update my-cluster --enable-autoprovisioning \
    --min-cpu 1 --max-cpu 100 --min-memory 1 --max-memory 400
  ```
- **Autopilot:** scaling is automatic and pod-driven — you never touch node pools; capacity appears to fit your pods' requests.
- **Spot Pods / Spot VMs:** cheap, preemptible capacity. On Autopilot request via nodeSelector; on Standard via a spot node pool:
  ```yaml
  spec:
    nodeSelector:
      cloud.google.com/gke-spot: "true"
  ```
- Pair cluster/node scaling with **HPA/VPA** for pod-level scaling.

---

## 7. Ops: release channels, upgrades, no etcd

The control plane (API server + etcd) is Google-run. You **cannot** snapshot etcd or reach the API server host. DR = workload/PV backup (Velero with the GCP plugin, or **Backup for GKE**).

**Release channels** control version cadence and auto-upgrade risk:

| Channel | Freshness | Use for |
|---|---|---|
| `rapid` | newest, earliest features | test/dev, early adoption |
| `regular` | ~2–3 months behind rapid (default) | most production |
| `stable` | most soak time, conservative | risk-averse prod |

```bash
gcloud container clusters update my-cluster --release-channel regular
```
Nodes **auto-upgrade** to stay within the channel; control node-disruption with **maintenance windows** and **PodDisruptionBudgets**. You can pin/blue-green node-pool upgrades on Standard. There's no "never upgrade" — channels enforce version currency.

---

## 8. Access: the gcloud auth plugin

Since kubectl/client-go 1.26, exec credential plugins are external — you **must** install `gke-gcloud-auth-plugin` or auth fails with `no Auth Provider found`:
```bash
gcloud components install gke-gcloud-auth-plugin
# or: apt-get install google-cloud-cli-gke-gcloud-auth-plugin

gcloud container clusters get-credentials my-cluster --region us-central1
# kubeconfig now runs the plugin to mint tokens from your gcloud identity
```
Verify: `USE_GKE_GCLOUD_AUTH_PLUGIN=True kubectl get ns`.

---

## 9. Common failures branch (for operating)

### Autopilot rejects a pod (constraint violation)
Symptom: pod never schedules; the admission webhook returns a clear message, e.g.
`hostPath volumes are not allowed`, `privileged is not allowed`, `resource requests must be set`,
or the request was auto-bumped to Autopilot minimums.
- Autopilot forbids: privileged, hostPath/hostNetwork/hostPID, host ports, most NodePorts, unsupported `DaemonSet` host mounts, and pods with no resource requests.
- Fixes: remove host access; set explicit CPU/mem requests within Autopilot's allowed ranges/ratios; if you genuinely need host-level access or a GPU config Autopilot won't allow, move the workload to a **Standard** cluster.

### Workload Identity 403 (`PERMISSION_DENIED` / metadata errors)
Symptom: app gets `403` from a GCP API or `could not fetch identity from metadata server`.
- Checklist: Workload Identity enabled on cluster **and** node pool (`--workload-metadata=GKE_METADATA`)? KSA annotated with the right `iam.gke.io/gcp-service-account`? The `roles/iam.workloadIdentityUser` binding names the exact `PROJECT.svc.id.goog[NAMESPACE/KSA]`? The GSA actually has the target API role? Pod using that KSA (`serviceAccountName:`)?
- On Autopilot the metadata server is always GKE_METADATA — the usual culprit is a wrong namespace/KSA in the binding member string.

### NEG / Ingress not programming
Symptom: Ingress has no IP, backends show `UNHEALTHY`, or `404` from the LB.
- Standalone NEG missing the `cloud.google.com/neg` annotation → GCLB has nothing to target.
- Health checks failing: GCLB probes the pod's `readinessProbe` path/port; a missing or mismatched readiness probe marks backends unhealthy. Ensure firewall rules allow Google's health-check ranges (`130.211.0.0/22`, `35.191.0.0/16`).
- Managed certificate stuck `Provisioning`: DNS for the domain must already point at the Ingress IP before the cert can validate.
- Give it time — global GCLB programming can take several minutes; check `kubectl describe ingress` events and the backend-service health in the Cloud console.
