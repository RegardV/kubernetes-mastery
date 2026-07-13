# Mental Models — Kubernetes as a Company

The whole of Kubernetes clicks once you stop thinking like an engineer and start
thinking like a **founder running a company**. Every company has two kinds of
people: **management**, who do no real work but keep the company running, and
**employees**, who do the actual work. Kubernetes is built exactly this way —
the **Control Plane** is management, the **Nodes** are the workforce.

The single most important idea: everything is **declarative**. You never issue
step-by-step commands. You declare the *desired end-state*, write it down, and
management runs **reconciliation loops** forever to make reality match it. That
one property explains almost every design decision below.

---

# Part 1 — The Company

## Head Office (the Control Plane)

Management does zero real work. Its only job is to keep the desired state true.

- **API Server (`kube-apiserver`) — the front desk and gatekeeper.** Every
  request goes through it first: `kubectl`, controllers, service accounts,
  external tools, other clusters. It checks *are you allowed in?*
  (authentication), *are you allowed to do this?* (authorization via RBAC), then
  runs validation and admission controllers/webhooks. It is the **only** thing
  that talks to etcd — everything else talks to the API Server.
- **etcd — the single source of truth and company memory.** A strongly
  consistent, distributed key-value store holding every object, its desired
  state, and its current status. Lose or corrupt etcd and the whole cluster is
  in serious trouble. Back it up religiously (on self-managed clusters).
- **Controllers — the management team running reconciliation loops.** Not one
  person but many managers, each watching etcd (via the API Server) and working
  relentlessly to make reality match desired state: the Deployment controller,
  ReplicaSet controller, StatefulSet, DaemonSet, Job/CronJob, Node controller,
  and any custom Operators you add via CRDs.
- **Scheduler (`kube-scheduler`) — the placement officer.** Once controllers
  decide a Pod must exist, the scheduler picks the best Node using resource
  requests/limits, affinity/anti-affinity, taints and tolerations, topology
  spread, and node scoring.

In production the control plane runs **highly available**: multiple API Server
replicas fronting a 3- or 5-node etcd cluster.

## Reconciliation — the beating heart

A control loop is dead simple and runs forever:

1. Observe current state (from etcd via the API Server).
2. Compare to desired state.
3. Take action to close the gap.
4. Repeat.

It is **level-triggered**, not edge-triggered: it reacts to *what the world looks
like now*, not to individual events. Miss an event and it doesn't matter — the
next loop still sees the discrepancy and fixes it. This is why Kubernetes is
self-healing. It is also the danger: **it will reconcile broken state forever**
if you declare something broken. Guardrails (below) are how you stop that.

## Namespaces & the tagging system

- **Namespaces — departments / tenants** inside the same company. Logical
  isolation for resources, access control (RBAC), quotas, and network policies.
  Almost everything lives in a namespace (exceptions: Nodes, PersistentVolumes,
  and other cluster-scoped objects).
- **Labels, Selectors, and Annotations — the internal tagging system.** Labels
  are key/value tags on objects. Selectors query them. This is how a Deployment
  knows which Pods it owns and how a Service knows which Pods get traffic.
  **Nothing references a Pod by name** — everything couples through labels. That
  loose coupling is one of Kubernetes' greatest strengths. Annotations carry
  non-identifying metadata (for tools and humans), never used for selection.

## The Workforce (the Nodes)

A raw VM or bare-metal box can't just join — it must be **onboarded** with
certificates, sufficient resources, and correct config. Each Node runs:

- **Kubelet — the node agent / floor supervisor.** Talks to the control plane,
  starts and monitors Pods, reports status. If a Node won't join, check the
  kubelet and its certificates first.
- **Container Runtime (usually `containerd`)** — actually runs the containers via
  the Container Runtime Interface (CRI).
- **kube-proxy + CNI plugin — networking.** The CNI plugin (Calico, Cilium,
  Flannel…) wires up Pod networking so every Pod gets an IP and Pods on different
  Nodes can talk. kube-proxy programs the rules that turn a Service's virtual IP
  into a real backend Pod. Without a working CNI, cross-node traffic is dead.

## The Actual Work — Pods

Kubernetes never runs a raw container. Everything lives in a **Pod** — the
smallest deployable unit: one or more tightly coupled containers sharing a
network namespace (same IP) and storage. Common shape: one main container plus
optional sidecars and init containers.

**Rule:** never put unrelated apps (frontend and backend) in one Pod. If it
dies you lose both, and you can't scale them independently.

Pods are **designed to die** — that is the design, not a bug. They are
ephemeral and disposable. When one dies, a controller creates a replacement (with
a new name and IP). This is exactly why you never reference Pods by name and why
Services exist.

## Guardrails that keep it stable

These separate stable clusters from ones that constantly fight fires. Missing
them is the single biggest cause of production pain — because reconciliation will
happily keep broken things running.

- **Resource requests & limits.** Requests tell the scheduler what a Pod needs
  (used for placement and QoS); limits cap what it can use. No requests → poor
  scheduling and node instability. No limits → one Pod starves the Node and
  triggers OOMKills everywhere.
- **Probes (startup, readiness, liveness).** Readiness gates whether a Pod
  receives Service traffic; liveness restarts stuck Pods; startup gives
  slow-booting apps (Java, databases, AI workloads) time before the other probes
  apply. Forgetting them causes cascading failures.
- **Pod Disruption Budgets (PDBs).** Protect critical workloads during
  *voluntary* disruptions (node drains, upgrades, scale-down) by capping how many
  replicas can be down at once. Teams usually learn this the hard way during a
  node upgrade.
- **Lifecycle hooks & termination grace period.** `preStop` hooks plus a proper
  grace period let apps drain connections and shut down cleanly (or warm up via
  `postStart`). Missing this is a top cause of lost requests and data corruption
  during rollouts.
- **Init containers.** Run setup to completion, in order, before the main
  container starts: migrations, secret fetching, waiting on a dependency.
- **Security contexts.** `runAsNonRoot`, dropped Linux capabilities,
  seccomp/AppArmor. One of the most important production hardening practices.
- **Scheduling constraints.** Taints/tolerations, affinity/anti-affinity, and
  topology spread give fine control over where Pods may or must run (e.g. keep
  the database off spot instances, spread replicas across zones).
- **QoS classes.** Derived from requests/limits — Guaranteed, Burstable,
  BestEffort — and directly tied to eviction order when a Node is under pressure.

## Workload types (who manages the Pods)

- **Deployment → stateless apps** (the common case). Manages ReplicaSets, which
  manage Pods. Handles rolling updates and rollbacks.
- **StatefulSet → stateful apps** needing stable network identity, ordered
  rollout, and per-Pod persistent storage (databases, queues).
- **DaemonSet → one Pod per Node** (log shippers, metrics agents, CNI).
- **Job / CronJob → run-to-completion or scheduled batch work.**

## Exposure, networking, storage, config

- **Service — the stable endpoint / group chat** in front of a set of Pods.
  Types: ClusterIP (internal), NodePort (port on every Node), LoadBalancer
  (external via cloud LB), ExternalName (DNS alias). Pods come and go; the
  Service's identity is stable.
- **Ingress / Gateway API — proper HTTP(S) routing and TLS**, backed by an
  ingress/gateway controller. Gateway API is the newer, more expressive
  successor to Ingress.
- **NetworkPolicies — firewalls between Pods** for zero-trust segmentation.
- **ConfigMaps & Secrets** — inject configuration and credentials (Secrets are
  base64-encoded, not encrypted by default — enable encryption-at-rest).
- **PersistentVolumes, PVCs & StorageClasses** — storage that survives Pod
  death, provisioned dynamically through CSI drivers. A PVC is a *claim* (a
  request for storage); the StorageClass says *how* to provision it.

## The big picture (Part 1)

You rarely manage Pods directly. You declare desired state, attach the right
guardrails (requests/limits, probes, PDBs, security contexts), and let the
control plane do its job. The beauty is the control loop; the danger is that it
will faithfully reconcile broken things forever if you skip the guardrails.

---

# Part 2 — The Holding Company

At scale, one well-run company becomes a **holding company** with subsidiaries,
sophisticated internal comms, formal governance, and financial controls. The
mental model doesn't change — it just gains layers.

## Advanced networking — eBPF

Modern CNIs, especially **Cilium with eBPF**, replace much of kube-proxy with
programmable hooks compiled straight into the Linux kernel. Think of eBPF as
installing ultra-efficient traffic cops directly in the kernel: kernel-level
visibility, identity-aware policy, and performance the userspace `iptables` path
can't match.

## Service mesh — internal comms & governance

A **service mesh** (Istio, Linkerd, Cilium Service Mesh) adds a layer between
services: mutual TLS everywhere, advanced traffic management (canary, circuit
breaking, retries, timeouts), and deep observability (golden metrics, traces).
Most teams adopt it after their first major incident or a compliance mandate.
The cost is real operational complexity — don't reach for it before you need it.

## Managed cloud — renting a serviced building

**Managed Kubernetes** (EKS, GKE, AKS) is renting a fully serviced building: the
provider runs and backs up the control plane and etcd; you run the workloads.
Several vanilla intuitions flip:

- **You no longer back up etcd yourself** — the provider owns it.
- **Identity is cloud-native** via **Workload Identity** — Pods assume cloud IAM
  roles instead of holding static keys.
- **Networking is the cloud's CNI** — Pods often get real VPC IPs, which
  introduces IP-density limits per node.
- **Load balancers and storage** come from the cloud (cloud LB controllers,
  cloud CSI drivers).

## Multi-cluster — subsidiaries

Running **multiple clusters** (for compliance, geography, blast-radius
isolation, or scale) turns Kubernetes into a true holding company. Tools like
ArgoCD (GitOps across clusters), Karmada, or Cilium Cluster Mesh manage many
clusters as one logical system.

## Advanced scheduling

Run multiple or custom **schedulers**; lean heavily on affinity and topology
constraints for AI/GPU workloads and cost optimization (bin-packing onto spot
instances, keeping stateful work on stable nodes).

## Policy & governance — the compliance department

**Admission control policy engines** (Kyverno, OPA/Gatekeeper) enforce rules at
creation time, before an object is ever persisted: "no privileged containers,"
"images only from approved registries," "every Pod must set resource limits."
This is how a large org enforces standards without trusting every author to
remember them.

## Autoscaling & financial controls

- **HPA** scales replica count on load (CPU/memory/custom metrics).
- **VPA** right-sizes a Pod's requests/limits over time.
- **Cluster Autoscaler / Karpenter** add and remove Nodes to fit pending Pods.
- **ResourceQuotas & LimitRanges** cap what a namespace can consume — the
  budget line per department.

## Operations & the real world

- **GitOps (ArgoCD/Flux)** — cluster state lives as code in Git; the cluster
  continuously reconciles to it, dramatically reducing drift and human error.
- **Helm / Kustomize** — package and template manifests (Helm = templated
  charts; Kustomize = overlay-based patching).
- **Backup & DR (Velero)** — back up cluster objects *and* volume data, and
  **test the restore**; an untested backup is a guess.
- **Observability** — Prometheus + Grafana + Loki + tracing is the standard
  stack. `kubectl get events` and `kubectl describe` remain the fastest path to a
  root cause.
- **Node lifecycle** — `cordon`, `drain`, and taint management during upgrades.

## The complete picture

At a basic level Kubernetes is one well-run company. At scale it's a holding
company: subsidiaries (clusters), sophisticated internal comms (service mesh +
eBPF), strict governance (admission policy + security contexts), professional
risk management (backups, PDBs, multi-cluster), and strong financial controls
(requests, quotas, autoscaling).

You are no longer micromanaging containers. You give high-level instructions to
management (the control plane), who direct the workforce (the Nodes) through team
leads (controllers and workload objects), while the group chat (Services) keeps
everything reachable. The control loops never sleep — they keep making reality
match desired state, even when that state is broken. The founder's job is to set
the right guardrails, give clear direction, and build a system that runs with
minimal day-to-day intervention. That is the real power of Kubernetes.
