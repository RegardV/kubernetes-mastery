# Kubernetes Mastery

A Claude Code plugin that makes an agent genuinely good at Kubernetes across the
three layers most skills leave incomplete:

1. **Concepts** — *why* Kubernetes is shaped the way it is, via a
   founder-running-a-company mental model.
2. **Authoring** — producing correct, hardened manifests / Helm / RBAC.
3. **Operating** — safely troubleshooting and auditing a **live** cluster.

Guidance is grounded in official Kubernetes documentation, the NSA/CISA
Kubernetes Hardening Guide, the OWASP Kubernetes Top 10, Pod Security Standards,
and the CIS Kubernetes Benchmark.

> **New to the mental model?** Read [**The Story — Kubernetes explained like a
> company you're running**](docs/STORY.md). It's the founder/holding-company
> narrative the `k8s-concepts` skill is built on.

## Skills

| Skill | Triggers on | What it does |
|---|---|---|
| **k8s-concepts** | explaining, teaching, deciding architecture, "how/why does K8s…" | Teaches the control plane / nodes / workloads / reconciliation model. Grounds the other two. |
| **k8s-authoring** | "create/review/refactor a manifest, Helm, RBAC" | Failure-mode-first workflow → generate → validate (`--dry-run`, `kubeconform`, policy) → deliver an output contract. |
| **k8s-operating** | "why is my pod crashing", "audit my cluster" | Read-only-by-default triage with `kubectl`. Proposes but never auto-runs mutating/destructive commands. |

### Shared cloud references

`references/conditional/` holds platform guides loaded **only when a platform
signal is detected** (Conditional Reference Retrieval), so there is no token cost
on other platforms:

- **Full:** `eks.md`, `gke.md`
- **Brief:** `aks.md`, `openshift.md`

Both `k8s-authoring` and `k8s-operating` reference these via
`${CLAUDE_PLUGIN_ROOT}/references/conditional/`.

## Example prompts

**Authoring**
- "Review my Deployment for production" — adds securityContext, resource
  requests/limits, liveness/readiness/startup probes, least-privilege RBAC, and a
  NetworkPolicy, then validates with `--dry-run` and `kubeconform`.
- "Create a hardened Helm chart for a PostgreSQL StatefulSet with backup CronJobs."
- "Add RBAC and a default-deny NetworkPolicy to this manifest."

**Operating**
- "Why is my pod stuck in CrashLoopBackOff / ImagePullBackOff / Pending?" —
  read-only triage with a fix proposed for your confirmation.
- "Audit my cluster's RBAC and NetworkPolicy coverage for over-broad access."
- "My pod is Pending on EKS" — branches into EKS-specific causes (ENI/IP
  exhaustion, AZ-pinned volumes, IRSA).

**Concepts**
- "Explain how Services route traffic to Pods."
- "Explain the Kubernetes control plane like I'm running a company."

## Install

This repo is its own marketplace:

```
/plugin marketplace add RegardV/kubernetes-mastery
/plugin install kubernetes-mastery@regardv-skills
```

Or point Claude Code at a local checkout:

```
claude --plugin-dir .
/reload-plugins
```

## Validate

```
bash scripts/validate.sh                 # structural: frontmatter + reference links
claude plugin validate . --strict        # official validator
```

## Design

The design spec lives at [`docs/DESIGN.md`](./docs/DESIGN.md).

The **concepts** layer is a self-contained digest of a companion Obsidian
knowledge base (the author's `k8s-vault`) that expands the same
founder/holding-company mental model into a linked wiki. The plugin does **not**
depend on the vault at runtime — the vault is the human-facing deep dive. The
readable narrative version lives at [`docs/STORY.md`](./docs/STORY.md).

## Credits & prior art

Synthesized fresh, but the design is informed by excellent prior work — credit
where it's due:

- **[Agent Skills standard](https://agentskills.io)** — the open `SKILL.md`
  format and progressive-disclosure model (originally by Anthropic).
- **[LukasNiessen/kubernetes-skill](https://github.com/LukasNiessen/kubernetes-skill)**
  — the failure-mode-first authoring approach and Conditional Reference Retrieval.
- **[kubetail-org/kstack](https://github.com/kubetail-org/kstack)** — safe,
  read-only-by-default live-cluster operations.
- **[MetalBear — Claude Code skills for Kubernetes](https://metalbear.com/blog/claude-code-skills-for-kubernetes/)**
  — the lesson that agents need real cluster context, not guesses from logs.
- **[wshobson/agents](https://github.com/wshobson/agents)** and
  **[jeffallan/claude-skills](https://github.com/jeffallan/claude-skills)** —
  patterns for organizing a multi-skill plugin library.

Technical guidance is grounded in the official Kubernetes documentation, the
NSA/CISA Kubernetes Hardening Guide, the OWASP Kubernetes Top 10, Pod Security
Standards, and the CIS Kubernetes Benchmark.

## License

MIT — see [LICENSE](./LICENSE).
