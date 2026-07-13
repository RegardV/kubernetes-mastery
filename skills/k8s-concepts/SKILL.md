---
name: k8s-concepts
description: >-
  Explain, teach, or reason about how Kubernetes fits together — the control
  plane, nodes, workloads, networking, and the reconciliation loop — using a
  founder-running-a-company mental model. Use before making an architecture
  decision, when someone asks "how does X work" or "why does Kubernetes do Y",
  or when another Kubernetes task needs conceptual grounding. Grounds the
  k8s-authoring and k8s-operating skills.
---

# Kubernetes Concepts — think like a founder running a company

Use this skill to build or explain the **mental model** behind Kubernetes. When
the user is deciding architecture, learning, or asking "why," reason from this
model first, then point them at authoring or operating for the "how."

## The one-line model

Kubernetes is a company. **Management** (the Control Plane) does no real work —
it makes sure the company runs smoothly. **Employees** (the Nodes) do the actual
work. Everything is **declarative**: you state the desired end-state, and
management runs **reconciliation loops** forever to make reality match it.

## The layers (teach in this order)

1. **Head office (Control Plane)** — API Server (front desk / gatekeeper: authn,
   RBAC, admission), etcd (single source of truth), Controllers (managers running
   reconciliation loops), Scheduler (placement).
2. **The workforce (Nodes)** — Kubelet (node agent), container runtime, kube-proxy
   + CNI (networking). Onboarded with certs, resources, config.
3. **Organization** — Namespaces (departments/tenants), Labels/Selectors/Annotations
   (the tagging system that couples Deployments→Pods and Services→Pods).
4. **The work** — Pods (the atomic unit; ephemeral by design), managed by
   Deployments / StatefulSets / DaemonSets / Jobs.
5. **Guardrails that keep it stable** — requests/limits, probes, PDBs, lifecycle
   hooks, init containers, security contexts. Missing these is why clusters fight
   fires.
6. **Holding company (advanced)** — service mesh, eBPF, multi-cluster, managed
   cloud (EKS/GKE), policy governance.

## How to use the references

Load only what the question needs:

- **`references/mental-models.md`** — the full founder + holding-company narrative
  (Part 1 and Part 2). Read when explaining the big picture or onboarding someone.
- **`references/concept-map.md`** — how the pieces relate: ownership chains
  (Deployment→ReplicaSet→Pod), the control loop, what talks to what. Read when the
  question is about relationships or data flow.
- **`references/glossary.md`** — term → one-line real definition. Read to answer a
  quick "what is X" without loading the whole narrative.

## Hand-off

- Producing YAML? → **k8s-authoring**.
- Troubleshooting a live cluster? → **k8s-operating**.

Keep explanations anchored to the company analogy; it is what makes the
architecture click. When precision matters, give the real component name
alongside the analogy (e.g. "the front desk — the `kube-apiserver`").
