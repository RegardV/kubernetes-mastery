# Design: `kubernetes-mastery` — a master Kubernetes skill library

- **Date:** 2026-07-13
- **Status:** Approved design, pending spec review
- **Author:** RegardV + Claude

## 1. Goal

Build one installable Claude skill **plugin** that makes an agent genuinely good at Kubernetes across three layers that no single existing skill combines:

1. **Concepts** — the mental model (why K8s is shaped the way it is)
2. **Authoring** — producing correct, hardened manifests/Helm/RBAC
3. **Operating** — safely troubleshooting and auditing a live cluster

Synthesized fresh, informed by the best existing skills and by our own company/holding-company knowledge base.

## 2. Background — sources researched

| Source | Contribution to this design |
|---|---|
| agentskills.io | The SKILL.md standard: portable folder, `name`+`description` frontmatter, progressive disclosure (discover → activate → execute), optional `scripts/` `references/` `assets/`. |
| LukasNiessen/kubernetes-skill | **Failure-mode-first authoring**: 6 failure modes, a 7-step workflow, output contract, Conditional Reference Retrieval, grounding in NSA/CISA · OWASP K8s Top 10 · PSS · CIS. Basis for `k8s-authoring`. |
| kubetail-org/kstack + metalbear/mirrord | **Safe live-cluster operating**: read-only-by-default, confirm-before-mutate, `disable-model-invocation` on destructive ops, "agents need real cluster context." Basis for `k8s-operating`. |
| wshobson/agents, jeffallan/claude-skills | **Library-scale organization**: plugin with `.claude-plugin/plugin.json`, `skills/*/SKILL.md`, `skills/*/references/`, a `SKILLS_GUIDE`/README, validation tooling. |
| Our `k8s-vault/` (Parts 1 & 2) | **The concepts layer none of the sources have** — the founder/holding-company mental models. Basis for `k8s-concepts`. |

**Key insight:** mature K8s skills split into *authoring* vs *operating* and skip the mental model. Adding a concepts layer grounded in our vault is the differentiator.

## 3. Decisions (settled)

- **Shape:** multi-skill plugin library (3 skills, shared reference library).
- **Coverage:** all three layers (concepts, authoring, operating).
- **Build approach:** synthesize fresh; no forking/vendoring.
- **Name:** plugin `kubernetes-mastery`; skills `k8s-concepts`, `k8s-authoring`, `k8s-operating`.
- **Operating scope:** cluster-agnostic core + a homelab section (k3s/MetalLB/local-path).
- **Cloud scope:** **full EKS and GKE** guidance (dedicated conditional reference files); AKS and OpenShift remain brief notes. Cloud refs load only on detected signals (Conditional Reference Retrieval), so no token cost when not on that platform.
- **Vault dependency:** NONE. The skill is fully self-contained. The concepts layer is synthesized from the two finished story notes; the vault stays an independent human-facing wiki. The vault does **not** need fleshing out before or for this build. Only soft link: consistent mental models + a README pointer to the vault as "companion deep-dive."

## 4. Non-goals (YAGNI)

- No MCP server, no compiled/shell tool binaries, no custom slash-command scripts beyond `validate.sh`.
- Deep per-cloud guidance is limited to **EKS and GKE** (in scope). AKS and OpenShift stay brief notes, not full guides.
- No regeneration of the 50 vault notes; no runtime coupling to the vault.
- Execution stays on the agent's existing `kubectl`/`helm`/`kubeconform`; we ship *guidance*, not tooling.

## 5. Architecture

```
kubernetes-mastery/                     ← in the homelab repo, git-versioned
├── .claude-plugin/plugin.json          ← plugin manifest (schema verified at build)
├── README.md                           ← 3-layer model, install paths, vault pointer
├── scripts/validate.sh                 ← CI check (see §9)
├── references/
│   └── conditional/                    ← SHARED across authoring + operating; loaded only on
│       ├── eks.md                        detected platform signal (Conditional Reference Retrieval)
│       │   FULL: IRSA/Pod Identity, VPC CNI + ENI limits, ALB/NLB controller, EBS/EFS CSI,
│       │   Karpenter/Fargate, aws-auth → access entries
│       ├── gke.md
│       │   FULL: Workload Identity, Autopilot vs Standard, Dataplane V2, NEGs/GCLB Ingress,
│       │   PD/Filestore CSI, release channels
│       ├── aks.md                        brief: Entra Workload ID, Azure CNI, AGIC
│       └── openshift.md                  brief: SCCs, Routes, arbitrary-UID constraints
└── skills/
    ├── k8s-concepts/
    │   ├── SKILL.md
    │   └── references/
    │       ├── mental-models.md         ← founder + holding-company models (condensed from Parts 1 & 2)
    │       ├── concept-map.md           ← components + how they relate (control loop, ownership chains)
    │       └── glossary.md              ← term → one-line real definition
    ├── k8s-authoring/
    │   ├── SKILL.md                     ← 7-step workflow + output contract
    │   └── references/
    │       ├── failure-modes.md         ← the 6 modes (see §7)
    │       ├── workload-patterns.md     ← Deployment/StatefulSet/DaemonSet/Job/CronJob
    │       ├── security-hardening.md    ← PSS, SecurityContext, RBAC; NSA/CISA/OWASP/CIS
    │       ├── networking-storage.md    ← Service/Ingress/Gateway/NetworkPolicy; PV/PVC/StorageClass
    │       ├── packaging-validation.md  ← Helm/Kustomize; dry-run/kubeconform/Kyverno
    │       └── examples-good-bad.md     ← annotated good vs anti-pattern manifests
    │       (SKILL.md also loads ../../references/conditional/<platform>.md on cloud signals)
    └── k8s-operating/
        ├── SKILL.md                     ← safe-by-default triage workflow
        └── references/
            ├── triage-playbooks.md      ← CrashLoopBackOff, ImagePullBackOff, Pending, OOMKilled, 5xx, NotReady
            │                              (cloud branches load ../../references/conditional/<platform>.md)
            ├── kubectl-recipes.md       ← read-only investigation commands
            ├── audit-checklists.md      ← RBAC, security posture, NetworkPolicy coverage, cost/drift
            └── safety-guardrails.md     ← confirm-before-mutate rules; destructive-command list
```

Install unit: **the plugin** (ships as one folder). `k8s-concepts` is fully self-contained and can be copied alone into `~/.claude/skills/`; `k8s-authoring` and `k8s-operating` share the plugin-level `references/conditional/` cloud guides, so keep the whole plugin to retain EKS/GKE depth.

## 6. Skill descriptions (frontmatter — drives activation)

- **k8s-concepts** — "Use when explaining, teaching, or reasoning about how Kubernetes fits together — the control plane, nodes, workloads, reconciliation. Load before architecture decisions or when asked how/why K8s behaves as it does. Grounds k8s-authoring and k8s-operating."
- **k8s-authoring** — "Use when writing, reviewing, refactoring, or migrating Kubernetes manifests, Helm charts, Kustomize overlays, or RBAC — anything producing YAML to apply to a cluster. Runs a failure-mode-first workflow and validates output before delivering."
- **k8s-operating** — "Use when troubleshooting or auditing a live Kubernetes cluster with kubectl — crashes (CrashLoopBackOff, OOMKilled, Pending, ImagePullBackOff), events/logs, or RBAC/security/network posture. Read-only by default; asks before any change."

## 7. `k8s-authoring` core

**7-step workflow (SKILL.md body):** capture context (cluster version floor, platform) → diagnose likely failure mode(s) → load only the matching reference(s) → propose fix path with tradeoffs → generate manifest → validate (`kubectl --dry-run=server`, `kubeconform`, optional Kyverno) → deliver **output contract**.

**Output contract:** assumptions · cluster version floor · failure mode(s) addressed · remediation + tradeoffs · validation/test plan · rollback/recovery notes.

**6 failure modes:** insecure workload defaults · resource starvation · network exposure · privilege sprawl · fragile rollouts · API drift. Each maps to concrete guardrails already catalogued in the vault (SecurityContext, requests/limits/QoS, NetworkPolicy, RBAC, probes/PDB/lifecycle, apiVersion/deprecations).

## 8. `k8s-operating` safety model

- **Read-only by default.** Investigation uses `get`/`describe`/`logs`/`events`/`top` only.
- **Confirm before mutate.** Any `apply`/`edit`/`scale`/`delete`/`drain`/`cordon`/`rollout` requires explicit user confirmation; these commands are listed in `safety-guardrails.md` and must never be auto-run.
- **Respect context.** Never switch kubeconfig context silently; state the active context before acting.
- **Homelab section.** k3s specifics (embedded etcd/sqlite, local-path storage, MetalLB/servicelb, Traefik ingress) called out alongside the agnostic core.

## 9. Verification

`scripts/validate.sh` — the one runnable check:
1. every `SKILL.md` has `name` + `description` frontmatter; `name` is lowercase-hyphen; `description` within length limit;
2. every relative link into `references/` resolves to an existing file (no dead links);
3. `plugin.json` parses as valid JSON.

Run in CI (`.github/workflows/` optional) and locally before commit.

## 10. Success criteria

- Installing the plugin exposes three independently-triggering skills.
- Asking "review this deployment for production" activates `k8s-authoring` and returns the output contract.
- Asking "why is my pod crashlooping" activates `k8s-operating` and stays read-only until told otherwise.
- Asking "explain how services find pods" activates `k8s-concepts`.
- `validate.sh` passes; no reference to any path outside the plugin folder.

## 11. To confirm at build time

- Exact `.claude-plugin/plugin.json` (and, if published as a marketplace, `marketplace.json`) schema — verify against current Claude Code plugin docs before finalizing.
