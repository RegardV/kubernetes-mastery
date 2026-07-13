# Concept Map — how the pieces relate

This file is about **relationships and flow**, not definitions (see
`glossary.md` for those). The recurring theme: Kubernetes couples things
*indirectly* — by desired state and by labels — almost never by name.

---

## 1. The reconciliation control loop

Every controller runs the same loop, forever. It is **level-triggered**: it acts
on the *current state of the world*, not on individual events. Drop an event and
the next pass still notices the gap and closes it. This is why the system
self-heals and why it will also faithfully reconcile broken desired state.

```
        ┌─────────────────────────────────────────┐
        │                                         │
        ▼                                         │
   observe current state ──► compare to desired ──► act to close gap
   (read from etcd via              │                    │
    the API Server)                 │                    │
        ▲                    gap == 0? do nothing        │
        └─────────────────────────────────────────────────┘
```

Desired state = what you declared (the spec). Current state = what actually
exists (the status). A controller's whole job is to drive `status → spec`.

---

## 2. Everything flows through the API Server

The API Server is the **single gateway to etcd**. No controller, kubelet, or
user ever touches etcd directly — only the API Server reads and writes it. That
gives one place for authentication, RBAC authorization, admission control, and
validation.

```
kubectl ─┐
clients ─┤
kubelets ─┼─►  API Server  ──►  etcd   (only the API Server talks to etcd)
control- ─┤   (authn, RBAC,
lers     ─┘    admission,
               validation)
```

Controllers and kubelets don't poll blindly; they **watch** the API Server for
changes to the objects they care about.

---

## 3. Request flow — from `kubectl apply` to a running Pod

A concrete trace of creating a Deployment. Note that no single component does it
all — each does one small thing and writes the result back, and the next
controller reacts to that.

```
1. kubectl apply ──► API Server
2. API Server: authn ► RBAC ► admission ► validate ► WRITE object to etcd
3. Deployment controller (watching) sees new Deployment
       └─► creates a ReplicaSet (writes to etcd via API Server)
4. ReplicaSet controller sees the ReplicaSet
       └─► creates N Pod objects, still UNSCHEDULED (nodeName empty)
5. Scheduler (watching for unscheduled Pods) picks a Node
       └─► writes nodeName onto each Pod (binding)
6. Kubelet on that Node (watching Pods bound to it) sees its new Pod
       └─► tells the container runtime (CRI) to pull images & start containers
       └─► sets up networking via the CNI plugin
       └─► reports status back to the API Server ──► etcd
```

Each hand-off is a separate reconciliation loop. The chain is loosely coupled:
each stage only reads/writes objects, never calls the next stage directly.

---

## 4. Ownership chains

Controllers own the objects one level below them via `ownerReferences`. Deleting
a parent garbage-collects its children.

### Stateless: Deployment → ReplicaSet → Pod

```
Deployment            (desired: 3 replicas, image v2, rollout strategy)
   │ owns
   ▼
ReplicaSet            (one per template/version; guarantees replica count)
   │ owns
   ▼
Pod  Pod  Pod         (ephemeral; recreated on death with new names/IPs)
```

A rolling update creates a **new** ReplicaSet for the new template and scales the
old one down as the new one scales up. Rollback = scale the old ReplicaSet back
up. This is why the intermediate ReplicaSet exists rather than the Deployment
owning Pods directly.

### Stateful: StatefulSet → Pods + PVCs

```
StatefulSet
   │ owns (stable, ordinal identities: web-0, web-1, web-2)
   ▼
Pod web-0 ──► PVC web-0   (each Pod keeps its own PersistentVolumeClaim)
Pod web-1 ──► PVC web-1
Pod web-2 ──► PVC web-2
```

Unlike a Deployment, identities are stable and ordered. `web-0` always rebinds to
*its* PVC (and the underlying PersistentVolume), so state survives Pod
rescheduling. PVCs are intentionally **not** deleted when the StatefulSet scales
down, so data isn't lost by accident.

### Others

```
DaemonSet ──► one Pod per matching Node (scheduled by node, not replica count)
Job       ──► Pods that run to completion (retries on failure)
CronJob   ──► creates a Job on a schedule
```

---

## 5. Labels & selectors — the universal coupling

**Nothing references a Pod by name.** Every "which Pods?" relationship is a
label selector matching labels on Pods. This is the loose coupling that makes
Pods disposable.

```
Pods carry labels:            app=web, tier=frontend
                                  ▲              ▲
                   selects on │              │ selects on
   Deployment.spec.selector ──┘              └── Service.spec.selector
   (which Pods do I manage?)                     (which Pods do I send traffic to?)
```

Because the coupling is by label, a Service and a Deployment don't know about
each other at all — they independently point at the same Pods. Swap the Pods
underneath (new ReplicaSet, new nodes) and both keep working as long as the
labels still match. Change a selector carelessly and you silently orphan Pods or
send traffic nowhere.

---

## 6. How a Service actually gets traffic to a Pod

A Service is a stable virtual IP (ClusterIP) and DNS name. It has no idea which
Pods exist until the selector is resolved into concrete endpoints.

```
Service (selector: app=web, ClusterIP 10.96.0.10, DNS web.ns.svc)
   │
   │ EndpointSlice controller watches Pods matching the selector
   ▼
EndpointSlice   (list of ready Pod IPs:ports — only Pods passing readiness)
   │
   │ consumed on every Node by:
   ▼
kube-proxy  (programs iptables/IPVS)     OR     CNI in eBPF mode (e.g. Cilium)
   │
   ▼
traffic to ClusterIP is DNAT'd / load-balanced to a real Pod IP
```

Key couplings in this path:

- **Selector → EndpointSlice**: the EndpointSlice controller keeps the Pod-IP
  list in sync with the selector *and* with readiness. A Pod failing its
  **readiness probe** is removed from the EndpointSlice, so it stops receiving
  traffic without being killed.
- **EndpointSlice → dataplane**: kube-proxy (or eBPF) on each Node turns that
  list into forwarding rules. This is the layer eBPF/Cilium optimizes by skipping
  kube-proxy.
- **CNI**: provides the flat Pod network that makes the final Pod IP reachable
  from any Node in the first place.

For external traffic the chain extends leftward: `Ingress/Gateway →
Service → EndpointSlice → Pod`, with an ingress/gateway controller terminating
TLS and routing by host/path.

---

## 7. Putting it together

```
DESIRED STATE (you)          MANAGEMENT (control plane)         WORKFORCE (nodes)
──────────────────           ──────────────────────────         ─────────────────
kubectl apply ──────────────► API Server ──► etcd
                                   ▲   │
                                   │   └──► Controllers ──► create children
                                   │            (Deploy→RS→Pod, etc.)
                              watch│   
                                   │        Scheduler ──► bind Pod to Node
                                   │                              │
                                   └───────── Kubelet ◄───────────┘ runs Pod
                                              (runtime + CNI), reports status
```

Read it as: you write desired state; management reconciles it into scheduled
Pods; the workforce runs them and reports back; the loop never stops. Labels
couple Services and workloads to those Pods without ever naming them.
