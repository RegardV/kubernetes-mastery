---
name: k8s-operating
description: >-
  Troubleshoot or audit a live Kubernetes cluster with kubectl — investigate
  crashes (CrashLoopBackOff, OOMKilled, Pending, ImagePullBackOff), read events
  and logs, trace ownership chains, and check RBAC/security/network posture.
  Read-only by default; proposes but never runs mutating or destructive commands
  without explicit user confirmation. Use for "why is my pod crashing", "what's
  wrong with this deployment", "audit my cluster", "debug this service".
---

# Kubernetes Operating — safe live-cluster triage

Diagnose and audit a running cluster. Investigation is **read-only**; any change
is proposed and gated on the user's explicit yes.

## Safety contract (non-negotiable)

1. **Read-only by default.** Investigate with `get`, `describe`, `logs`, `events`,
   `top`, `api-resources`, `auth can-i` — never mutate to diagnose.
2. **Confirm before mutate.** These require the user's explicit confirmation and
   must **never** be auto-run: `apply`, `create`, `edit`, `patch`, `replace`,
   `scale`, `delete`, `rollout restart/undo`, `cordon`, `drain`, `uncordon`,
   `label`/`annotate --overwrite`, `exec` that writes, `port-forward`. Show the
   exact command and what it will do first. Full list: `references/safety-guardrails.md`.
3. **Respect context.** State the active context and namespace before acting
   (`kubectl config current-context`). Never switch context silently.
4. **Least surprise.** Prefer `-o yaml`/`describe` reads over interactive `exec`;
   scope by namespace and label selector.

## Triage workflow

1. **Orient.** Confirm context/namespace; get a health snapshot
   (`kubectl get pods,deploy,svc -A` or scoped).
2. **Localize.** Identify the failing object and walk the **ownership chain**
   (Pod → ReplicaSet → Deployment) to the real owner.
3. **Read the evidence.** `kubectl describe` the object, then
   `kubectl get events --sort-by=.lastTimestamp`, then `logs` (add `--previous`
   for crashed containers).
4. **Match a playbook.** Map the symptom to `references/triage-playbooks.md`
   (CrashLoopBackOff, ImagePullBackOff, Pending, OOMKilled, 5xx, Node NotReady).
5. **Branch by platform** when the cause is cloud-specific (no IP, can't pull,
   can't assume role) → `${CLAUDE_PLUGIN_ROOT}/references/conditional/<eks|gke|aks|openshift>.md`.
6. **Propose the fix** with the exact command(s), the expected effect, and a
   rollback. Wait for confirmation before anything mutating.

## References

- `references/triage-playbooks.md` — symptom → likely causes → read-only checks → fix.
- `references/kubectl-recipes.md` — safe investigation commands and one-liners.
- `references/audit-checklists.md` — RBAC, security posture, NetworkPolicy coverage,
  image/version drift, cost signals.
- `references/safety-guardrails.md` — the destructive-command list and confirmation rules.

## Homelab note

For single-node / k3s homelabs: control plane is often co-located (embedded etcd
or SQLite), storage is `local-path`, LoadBalancer is servicelb/MetalLB, ingress is
Traefik by default. Adjust expectations (e.g. `Pending` PVCs, single-replica
constraints) accordingly — details in the playbooks.

When the user asks *why* rather than *what to run*, lean on **k8s-concepts**.
