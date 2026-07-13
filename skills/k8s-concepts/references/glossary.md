# Glossary

Term → one-line real definition. Analogy tag in parentheses where it helps.
Alphabetical. See `mental-models.md` for the narrative and `concept-map.md` for
how these relate.

## A

- **Admission controller** — API Server plugin/webhook that validates or mutates
  objects *after* authn/authz but *before* they persist to etcd (the compliance
  check at the door).
- **Affinity / anti-affinity** — scheduling rules pulling Pods toward
  (affinity) or away from (anti-affinity) certain Nodes or other Pods.
- **Annotation** — non-identifying key/value metadata on an object, for tools and
  humans; never used for selection (unlike labels).
- **API Server (`kube-apiserver`)** — the single front door to the cluster and
  the only component that talks to etcd; handles authn, RBAC, admission,
  validation (the front desk / gatekeeper).

## C

- **Cluster Autoscaler** — adds/removes Nodes so pending Pods can be scheduled and
  idle Nodes are reclaimed.
- **CNI (Container Network Interface) plugin** — provides Pod networking so every
  Pod gets an IP and Pods across Nodes can talk (Calico, Cilium, Flannel).
- **ConfigMap** — non-secret configuration data injected into Pods as env vars,
  files, or args.
- **Container runtime** — software that actually runs containers on a Node via the
  CRI, usually `containerd`.
- **Controller** — a loop that watches desired vs current state and drives them
  together (a manager running a reconciliation loop).
- **CRD (CustomResourceDefinition)** — extends the Kubernetes API with your own
  object kinds, reconciled by a custom controller/Operator.
- **CronJob** — creates a Job on a cron schedule (scheduled batch work).
- **CSI (Container Storage Interface)** — plugin standard letting storage vendors
  provision and attach volumes to Pods.
- **Cluster Autoscaler vs Karpenter** — both add Nodes for pending Pods; Karpenter
  provisions right-sized nodes just-in-time rather than scaling fixed node groups.

## D

- **DaemonSet** — runs exactly one Pod per (matching) Node; for agents like log
  shippers, metrics, and CNI.
- **Deployment** — manages stateless apps via ReplicaSets, handling rolling
  updates and rollbacks (the standard workload object).

## E

- **eBPF** — programmable hooks compiled into the Linux kernel; used by CNIs like
  Cilium for fast, identity-aware networking and observability (traffic cops in
  the kernel).
- **EndpointSlice** — the controller-maintained list of ready Pod IPs/ports behind
  a Service; how a selector becomes real backends.
- **etcd** — strongly consistent distributed key-value store holding all cluster
  state (the single source of truth / company memory).
- **Events** — timestamped records of what happened to objects; `kubectl get
  events` / `describe` is often the fastest path to a root cause.

## G

- **Gateway API** — the newer, more expressive successor to Ingress for L4/L7
  routing, with role-oriented resources (GatewayClass, Gateway, HTTPRoute).
- **GitOps** — treat cluster state as code in Git; a controller (ArgoCD, Flux)
  continuously reconciles the cluster to the repo, reducing drift.

## H

- **Helm** — package manager for Kubernetes using templated "charts."
- **HPA (Horizontal Pod Autoscaler)** — scales the number of Pod replicas based on
  CPU/memory/custom metrics.

## I

- **Ingress** — HTTP(S) routing and TLS termination into the cluster, realized by
  an ingress controller.
- **Init container** — a container that runs to completion, in order, before the
  main containers start (setup: migrations, secret fetch, waiting on deps).

## J

- **Job** — runs one or more Pods to successful completion, with retries.

## K

- **Karpenter** — just-in-time Node provisioner that launches right-sized nodes
  for pending Pods; a flexible alternative to Cluster Autoscaler.
- **Kubelet** — the per-Node agent that talks to the control plane, starts/monitors
  Pods, and reports status (the floor supervisor).
- **kube-proxy** — programs iptables/IPVS rules on each Node to route Service
  virtual IPs to backend Pods; can be replaced by eBPF dataplanes.
- **Kustomize** — template-free manifest customization via overlays/patches
  (built into `kubectl`).

## L

- **Label** — key/value tag on an object; the basis of all selection.
- **Lifecycle hook** — `postStart` / `preStop` container hooks; `preStop` plus a
  termination grace period enables graceful shutdown.
- **Limit** — hard ceiling on a container's CPU/memory; exceeding memory → OOMKill,
  CPU → throttling.
- **Liveness probe** — health check; failing it restarts the container.

## M

- **Managed Kubernetes** — provider-run control plane and etcd (EKS, GKE, AKS);
  you run workloads and use cloud-native identity/CNI/LB/storage (renting a
  serviced building).

## N

- **Namespace** — logical partition for isolation, access control, and quotas (a
  department/tenant).
- **NetworkPolicy** — firewall rules governing which Pods may talk to which (for
  zero-trust segmentation); requires a CNI that enforces them.
- **Node** — a worker machine (VM or bare metal) running kubelet, a runtime, and
  networking; where Pods actually run (an employee).

## O

- **Operator** — a custom controller (usually paired with CRDs) that encodes
  operational knowledge to manage an app (e.g. a database) automatically.

## P

- **PDB (Pod Disruption Budget)** — caps how many replicas may be down during
  *voluntary* disruptions (drains, upgrades), protecting availability.
- **Pod** — smallest deployable unit; one or more containers sharing network and
  storage; ephemeral by design (the atomic unit of work).
- **PodSecurity Standards** — built-in policy levels (Privileged / Baseline /
  Restricted) enforced per namespace by the Pod Security admission controller.
- **Probe** — health check run by the kubelet: **startup** (grace for slow boot),
  **readiness** (gate Service traffic), **liveness** (restart if stuck).
- **PV (PersistentVolume)** — a cluster-level piece of provisioned storage.
- **PVC (PersistentVolumeClaim)** — a Pod's *request* for storage, bound to a PV.

## Q

- **QoS class** — Guaranteed / Burstable / BestEffort, derived from
  requests/limits; determines eviction order under Node pressure.

## R

- **RBAC (Role-Based Access Control)** — authorization model binding subjects to
  Roles/ClusterRoles that grant verbs on resources.
- **Reconciliation loop** — the level-triggered observe→compare→act cycle that
  drives current state toward desired state (the engine of self-healing).
- **ReplicaSet** — ensures a set number of identical Pods exist; owned by a
  Deployment (one per template version).
- **Request** — the amount of CPU/memory a container is guaranteed; used by the
  scheduler for placement and by QoS.

## S

- **Scheduler (`kube-scheduler`)** — assigns unscheduled Pods to Nodes using
  requests, taints/tolerations, affinity, and topology (the placement officer).
- **Secret** — object for sensitive data (base64-encoded, not encrypted by default
  — enable encryption-at-rest).
- **Security context** — per-Pod/container hardening: `runAsNonRoot`, dropped
  capabilities, seccomp/AppArmor, read-only root FS.
- **Selector** — a label query identifying which objects (usually Pods) something
  applies to.
- **Service** — stable virtual IP + DNS name load-balancing across a selected set
  of Pods (the group chat / stable endpoint). Types:
  - **ClusterIP** — internal-only virtual IP (default).
  - **NodePort** — exposes the Service on a static port on every Node.
  - **LoadBalancer** — provisions an external cloud load balancer.
  - **ExternalName** — a DNS CNAME alias to an external name (no proxying).
- **Service mesh** — sidecar/eBPF layer adding mTLS, traffic management (canary,
  retries, circuit breaking), and observability (Istio, Linkerd, Cilium).
- **ServiceAccount** — identity for processes in Pods to authenticate to the API
  Server (and, via Workload Identity, to cloud APIs).
- **StatefulSet** — manages stateful Pods with stable identities, ordered rollout,
  and per-Pod persistent storage.
- **StorageClass** — defines *how* PVs are dynamically provisioned (backend, type,
  reclaim policy) for PVCs.

## T

- **Taint / toleration** — a taint repels Pods from a Node unless the Pod carries a
  matching toleration (keeps workloads off unsuitable nodes).
- **Topology spread constraints** — rules to spread Pods evenly across zones/nodes
  for resilience.

## V

- **VPA (Vertical Pod Autoscaler)** — recommends/sets Pod resource requests and
  limits based on observed usage.

## W

- **Workload Identity** — cloud-native mechanism letting Pods assume cloud IAM
  roles via their ServiceAccount, removing static credentials (managed clouds).
