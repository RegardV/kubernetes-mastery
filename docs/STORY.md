# Kubernetes, explained like a company you're running

> The mental model behind the `k8s-concepts` skill. Read it top to bottom and the
> architecture stops feeling like magic and starts feeling like an organization.
> **Part 1** builds the company; **Part 2** scales it into a holding company.

Kubernetes makes much more sense if you stop thinking like an engineer and start
thinking like a **founder running a company**.

Every company has two types of people:

- **Management** — they don't do the real work, they make sure the company runs smoothly.
- **Employees** — they do the actual work.

Kubernetes is built exactly like this: the **Control Plane** (head office) and the
**Nodes** (the workforce). Everything runs on **declarative state** — you declare
what you want, and the system works relentlessly through its **control loop** to
make it reality.

---

# Part 1 — The Company

## The Control Plane (Head Office)

- **API Server** — the single front desk and gatekeeper. Every request passes
  through it. It handles authentication, **RBAC**, validation, and admission
  controllers/webhooks.
- **etcd** — the single source of truth. All cluster state lives here — back it
  up religiously.
- **Controllers** — a team running **reconciliation loops** (Deployments,
  StatefulSets, DaemonSets, Jobs, CronJobs, and your own Operators via CRDs).
- **Scheduler** — the resource allocator that considers requests, limits,
  affinity rules, taints, and more.

## Namespaces & Organization

**Namespaces** are like separate departments or tenants inside the same company.
They give you resource isolation, access control, and network policies. Almost
everything lives in one (except nodes and some cluster-wide objects).

**Labels, Selectors, and Annotations** are the company's internal tagging system.
They're how Deployments know which pods they own, how Services route traffic, and
how you organize everything.

## The Nodes (Workforce)

- **Kubelet**, **Container Runtime**, **Kube-proxy** + **CNI plugin** for networking.
- Nodes must be properly **onboarded** with certificates, sufficient resources,
  and correct configuration.

## The Actual Work

Everything runs in a **Pod** (one or more tightly coupled containers). Pods are
disposable.

**High-impact but often overlooked:**

- **Init containers** — run setup tasks before your main container starts
  (database migrations, secret fetching, waiting on a dependency), in order and to
  completion.
- **Resource requests & limits** — tell the scheduler how much CPU/memory each pod
  needs. No requests = poor scheduling and node instability. No limits = one pod
  can starve the entire node (OOMKills everywhere). One of the biggest causes of
  production pain.
- **Probes (Startup, Readiness, Liveness)** — health checks. Readiness tells the
  Service not to send traffic to unhealthy pods. Liveness restarts dead ones.
  Forgetting these (especially on slow-starting apps) causes cascading failures.
- **Lifecycle hooks (preStop/postStart) + termination grace period** — give apps
  time to shut down cleanly or warm up. Missing this is a top cause of data
  corruption or lost requests during deployments.
- **Pod Disruption Budgets (PDBs)** — protect important workloads during voluntary
  disruptions (drains, upgrades, scaling). Many teams learn this the hard way
  during a node upgrade.

## Workload Types

- **Deployment** → stateless apps (with a ReplicaSet under the hood).
- **StatefulSet** → stateful apps (stable identity + storage).
- **DaemonSet** → one agent per node.
- **Job / CronJob** → batch/scheduled work.

## Exposure & Networking

- **Service** → stable endpoint in front of pods.
- **Ingress / Gateway API** → proper HTTP routing and TLS.
- **NetworkPolicies** → firewall rules between pods (zero-trust).

## Storage & Configuration

- **ConfigMaps and Secrets** for configuration and credentials.
- **PersistentVolumes, PVCs, and StorageClasses** so data survives pod death.

## What Separates Intermediate from Advanced

- **Taints & tolerations + affinity/anti-affinity** — control exactly where pods
  can/should run (e.g., keep your database off spot instances).
- **Quality of Service (QoS) classes** — Guaranteed, Burstable, BestEffort —
  directly tied to how the kubelet evicts pods under pressure.
- **Security contexts** — run pods as non-root, drop capabilities, use
  seccomp/AppArmor.
- **imagePullSecrets and private registries** — easily overlooked until your
  cluster can't pull images.
- **Observability & cost** — proper metrics, logging, tracing, and cluster
  autoscaling (Karpenter is excellent) to avoid surprise bills and blind spots.
- **Backup & disaster recovery** — beyond etcd snapshots, back up PV data and
  manifests (Velero) and **test the restore** — an untested backup is a guess.
- **Events** — `kubectl get events` is your cluster's log of what actually went
  wrong; usually the fastest path to a root cause.
- **Node operations** — `kubectl drain` / `cordon` and handling taints safely
  during maintenance.
- **GitOps (ArgoCD/Flux) + Helm/Kustomize** — treat your cluster configuration as
  code. Dramatically reduces drift and human error.

## The Big Picture (Part 1)

You rarely manage pods directly. You declare the desired state, set proper
requests/limits/probes/PDBs, and let the control plane do its job.

The beauty of Kubernetes is the **control loop**. The danger is that it will
happily reconcile broken things forever if you don't set the right guardrails
(resources, probes, policies, budgets).

Get the fundamentals plus these often-overlooked high-impact items right, and your
cluster becomes stable, scalable, and manageable. Miss them, and you'll spend
nights debugging why everything is crashing or costing a fortune.

---

# Part 2 — The Holding Company

Kubernetes is built the same way at scale. The Control Plane is your management —
it does zero actual work itself. The Nodes are your employee floor, where the real
work happens. This single mental model explains almost everything: the
architecture stops feeling like magic and starts feeling like a well-designed (if
sometimes bureaucratic) organization. Part 2 scales that company into a **holding
company** — with subsidiaries, internal comms, governance, and financial controls.

## The Control Plane, revisited

- **API Server** — the front desk. Every request (kubectl, controllers, service
  accounts, external tools, other clusters) goes through it first. It checks *are
  you allowed in?* (authentication) and *are you allowed to do this?* (authorization
  via RBAC), plus admission webhooks and validation. In production, most teams put
  an auth proxy or service mesh in front of it.
- **etcd** — the company's single source of truth and memory. Every object,
  desired state, and current status lives here, strongly consistent and
  distributed. Lose or corrupt it and the whole cluster is in serious trouble —
  backups are non-negotiable.
- **Controllers** — not one person, but a whole management team running
  reconciliation loops, watching etcd to make reality match desired state.
  Deployment controller → ReplicaSet → Pods; plus StatefulSet, DaemonSet,
  Job/CronJob, and Node controllers.
- **Scheduler** — once controllers decide work must happen, it finds the best node
  using requests/limits and taints, tolerations, affinity, topology spread, and
  node scoring.

The control plane usually runs **highly available** (multiple API server replicas
+ a 3- or 5-node etcd cluster).

## Pods — the fundamental unit

Kubernetes never runs a raw container. Everything lives in a **Pod** — the
smallest deployable unit; one or more containers sharing network and storage.
Common pattern: one main container + optional sidecars/init containers.

> **Important rule:** never put unrelated apps (frontend and backend) in the same
> Pod. If it dies you lose both, and you lose independent scaling.

Pods are **designed to die** — that's the design, not a bug. When one dies,
something else must create a replacement.

## Advanced Layers — When One Company Is No Longer Enough

**Advanced networking.** Modern CNI plugins — especially **Cilium with eBPF** —
deliver kernel-level visibility and performance kube-proxy can't match. eBPF is
like installing ultra-efficient traffic cops directly in the kernel.

**Service mesh.** Istio, Linkerd, or Cilium Service Mesh add mutual TLS, advanced
traffic management (canary, circuit breaking, retries), and deep observability.
Many teams adopt it after their first major incident or a compliance requirement.

**Managed cloud (EKS, GKE, AKS).** Managed Kubernetes is renting a fully-serviced
building: the provider runs the control plane and etcd, but you must use their
integrations — cloud identity via **Workload Identity** (no static keys), cloud CNI
(real VPC IPs, pod-density limits), cloud load balancers, and cloud CSI storage.
Several vanilla intuitions flip here — most notably, you **no longer back up etcd
yourself**.

**Multi-cluster.** Running multiple clusters (compliance, geography, blast radius,
scale) turns Kubernetes into a holding company. ArgoCD (GitOps), Karmada, or Cilium
Cluster Mesh manage them as one logical system.

**Advanced scheduling.** Run multiple or custom schedulers; heavy affinity/topology
use for AI/GPU workloads and cost optimization (spot instances).

**Policy & governance.** Admission control engines (Kyverno, OPA/Gatekeeper)
enforce rules at creation time ("no privileged containers", "images from approved
registries only").

## Operations & The Real World

- **GitOps (ArgoCD/Flux)** — cluster state as code in Git; dramatically reduces drift.
- **Backup & disaster recovery** — Velero for cluster + volume backups. Test your restores.
- **Observability** — Prometheus + Grafana + Loki + tracing is the standard stack.
- **Node lifecycle** — proper draining, cordoning, taint management during upgrades.
- **Troubleshooting** — `kubectl get events`, `kubectl describe`, and logs remain
  your best friends.

## The Complete Picture

At a basic level, Kubernetes is one well-run company. At scale it becomes a
**holding company** with subsidiaries (clusters), sophisticated internal comms
(service mesh + eBPF), strict governance (policies & security contexts),
professional risk management (backups, PDBs, multi-cluster), and strong financial
controls (requests, quotas, autoscaling).

You're no longer micromanaging containers. You give high-level instructions to
management (the control plane), who direct the workforce (nodes) through team leads
(controllers and workload objects) while the group chat (Services) keeps everything
reachable.

The control loops never sleep — they'll keep trying to make reality match desired
state, even if that state is broken. Your job as founder is to set the right
guardrails, give clear direction, and build systems that run with minimal
day-to-day intervention. That's the real power of Kubernetes.
