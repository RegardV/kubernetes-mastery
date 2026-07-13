---
name: k8s-authoring
description: >-
  Write, review, refactor, or migrate Kubernetes manifests, Helm charts,
  Kustomize overlays, or RBAC — anything that produces YAML you will apply to a
  cluster. Runs a failure-mode-first workflow (insecure defaults, resource
  starvation, network exposure, privilege sprawl, fragile rollouts, API drift),
  hardens against official standards (NSA/CISA, OWASP K8s Top 10, Pod Security
  Standards, CIS), and validates output before delivering. Use for "create a
  Deployment", "review my manifest for production", "add RBAC/NetworkPolicy",
  "write a Helm chart".
---

# Kubernetes Authoring — failure-mode-first

Produce manifests that survive production. Do **not** dump a template and stop —
diagnose likely failure modes first, then generate, validate, and deliver with an
explicit contract. When unsure of a concept, consult the **k8s-concepts** skill.

## Workflow (follow in order)

1. **Capture context.** Cluster version floor, platform (vanilla / k3s / EKS / GKE
   / AKS / OpenShift), stateless vs stateful, in/out of scope. State assumptions.
2. **Diagnose failure mode(s).** Which of the six below does this touch? Usually
   more than one. See `references/failure-modes.md`.
3. **Load only the relevant references** (Conditional Reference Retrieval — do not
   load everything):
   - workload shape → `references/workload-patterns.md`
   - security / RBAC / PSS → `references/security-hardening.md`
   - Service / Ingress / NetworkPolicy / storage → `references/networking-storage.md`
   - Helm / Kustomize / validation → `references/packaging-validation.md`
   - platform signal detected → `${CLAUDE_PLUGIN_ROOT}/references/conditional/<eks|gke|aks|openshift>.md`
   - want a worked example → `references/examples-good-bad.md`
4. **Propose the fix path with tradeoffs.** Name what you're changing and why;
   call out any tradeoff (e.g. `Recreate` vs `RollingUpdate`, hostPath risk).
5. **Generate the manifest(s).** Apply the guardrails; prefer secure, explicit
   defaults over cluster defaults.
6. **Validate before finalizing:**
   - `kubectl apply --dry-run=server -f <file>` (server-side, catches admission)
   - `kubectl diff -f <file>` against a live cluster when available
   - `kubeconform -strict -summary <file>` (schema)
   - policy scan if used: `kyverno apply` / `conftest` / OPA in audit mode
   - cross-resource consistency: labels ↔ selectors ↔ ports match
7. **Deliver the output contract** (always include):
   - Assumptions and cluster version floor
   - Failure mode(s) addressed
   - Chosen remediation + tradeoffs
   - Validation / test plan
   - Rollback and recovery notes

## The six failure modes

| Mode | Smell | First guardrails |
|---|---|---|
| Insecure workload defaults | runs as root, no securityContext | non-root, drop caps, seccomp, read-only rootfs, PSS `restricted` |
| Resource starvation | no requests/limits | set requests/limits, pick QoS, add PDB |
| Network exposure | everything reachable | default-deny NetworkPolicy, right Service type, TLS at Ingress |
| Privilege sprawl | wildcard RBAC, shared SA | least-privilege Role, dedicated ServiceAccount, no cluster-admin |
| Fragile rollouts | `:latest`, no probes | pinned digests, readiness+liveness+startup, surge/unavailable, preStop |
| API drift | deprecated apiVersion | current GA APIs, schema validation, check deprecations |

Details and remediation snippets: `references/failure-modes.md`.

## Grounding

When guidance conflicts, prefer **official Kubernetes docs**, then the **NSA/CISA
Kubernetes Hardening Guide**, **OWASP Kubernetes Top 10**, **Pod Security
Standards**, and the **CIS Kubernetes Benchmark**. State the cluster version floor
your advice assumes.
