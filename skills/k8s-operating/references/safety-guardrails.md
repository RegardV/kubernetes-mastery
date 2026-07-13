# Safety Guardrails

This is the enforceable version of the SKILL's safety contract. When operating a live
cluster you are **read-only by default**. Anything that can change cluster state, evict
workloads, or open an interactive/writable channel into a pod is **mutating** and must
be confirmed by the user before you run it — no exceptions, no "small" edits.

---

## Why read-only by default

You are pointed at a **live** cluster that may be running someone's production or their
home services. A read never breaks anything; a mutation can delete data, cause an
outage, or evict a stateful workload with no undo. Diagnosis almost never requires a
write — `get`, `describe`, `logs`, `events`, `top`, `auth can-i`, and `explain` reveal
the cause. So the default is: investigate freely, change nothing until the user says so.
The cost of asking is one sentence; the cost of a wrong auto-mutation is an incident.

---

## Allowed without confirmation (read-only)

These never change state. Run them freely during triage and audit.

| Command | Purpose |
|---|---|
| `kubectl get` | List/read objects (`-o yaml`/`-o json`/`-o jsonpath`/`-o custom-columns`) |
| `kubectl describe` | Human-readable object + events |
| `kubectl logs` (incl. `--previous`, `-f`, `--since`, `-c`) | Container logs |
| `kubectl get events` / `events` | Cluster events |
| `kubectl top` | Live CPU/memory usage |
| `kubectl auth can-i` (incl. `--list`, `--as`) | Permission checks (impersonation is evaluation-only) |
| `kubectl auth whoami` | Current identity |
| `kubectl api-resources` / `api-versions` | Discover kinds/versions |
| `kubectl explain` | Schema docs |
| `kubectl cluster-info` (without `dump` to a shared path) | Endpoints overview |
| `kubectl config current-context` / `get-contexts` / `view` | Inspect config (read) |
| `kubectl diff -f` | Preview a change vs. live — reads only, sends nothing |
| `kubectl rollout status` / `rollout history` | Report rollout state (no change) |
| `kubectl create ... --dry-run=client -o yaml` | Render locally, never sent |

---

## Requires explicit confirmation (mutating / destructive)

Never auto-run any of these. Each either changes state, disrupts workloads, or opens a
writable/interactive channel.

| Command | Effect if run |
|---|---|
| `kubectl apply` | Creates/updates objects from a manifest |
| `kubectl create` | Creates a new object |
| `kubectl edit` | Opens an editor and applies the saved result |
| `kubectl patch` | Mutates specific fields in place |
| `kubectl replace` | Overwrites an object wholesale |
| `kubectl scale` | Changes replica count (up or down) |
| `kubectl delete` | **Destroys** objects — often irreversible |
| `kubectl rollout restart` | Recreates all pods of a workload |
| `kubectl rollout undo` | Reverts to a previous revision (still a state change) |
| `kubectl cordon` | Marks a node unschedulable |
| `kubectl drain` | **Evicts** all pods off a node — highly disruptive |
| `kubectl uncordon` | Re-enables scheduling on a node |
| `kubectl label --overwrite` / `annotate --overwrite` | Mutates existing metadata (may change selectors/behavior) |
| `kubectl set image` / `set env` / `set resources` | Mutates a workload's spec |
| `kubectl exec` **that writes** (or any interactive `-it` shell) | Runs commands inside a container; can change container state |
| `kubectl cp` **into** a pod | Writes files into a running container |
| `kubectl port-forward` | Opens a network tunnel to a pod/service |
| `kubectl proxy` | Opens a local proxy to the API server |
| `kubectl attach` | Attaches to a running process (can send input) |
| `kubectl apply -k` / `kustomize ... apply` | Same as apply, from kustomize |
| `kubectl config use-context` / `set-context` / `set` | Changes which cluster/ns you act on |
| `kubectl taint` | Changes node scheduling rules |
| `kubectl certificate approve/deny` | Approves/denies CSRs |
| `helm install` / `upgrade` / `rollback` / `uninstall` | Mutating package operations |

Notes on edge cases:

- **`kubectl exec` read-only** (e.g. `exec <pod> -- cat /etc/config`, `ls`, `env`) does
  not change state, but it runs a process inside a live container and can have side
  effects depending on the command. Prefer `-o yaml`/`describe`/`logs`. If a read-only
  exec is genuinely the only way, show the exact command and confirm anyway.
- **`--dry-run=server`** does not persist, but it is a write-path API call. On
  locked-down clusters treat it as confirm-worthy; prefer `--dry-run=client` and
  `kubectl diff` for pure investigation.
- **`port-forward`/`proxy`** don't mutate objects but open access channels — confirm.

---

## Confirmation protocol

Before running anything from the confirm-required list, present all three of these and
then **stop and wait** for the user's explicit yes:

1. **The exact command** you propose to run — fully resolved, no placeholders, the real
   namespace/context/object names.
2. **The effect** — what changes, which objects/pods are affected, and whether it is
   disruptive (restart, eviction, data loss) or reversible.
3. **The rollback** — the exact command or manifest to undo it, or an explicit statement
   that there is **no rollback** (e.g. `delete` of a PVC with a `Delete` reclaim policy).

Template:

```
Proposed change (requires your confirmation):
  Command : kubectl rollout undo deployment/api -n prod
  Context : prod-cluster   Namespace: prod
  Effect  : reverts 'api' to the previous ReplicaSet; recreates all api pods (brief
            disruption if single-replica). Reversible.
  Rollback: kubectl rollout undo deployment/api -n prod --to-revision=<current-rev>

Run it? (yes / no)
```

Rules:

- One confirmation = one command (or one tightly-coupled set you named explicitly). A
  yes to command A is **not** a yes to a follow-up B.
- If the effect changed since you last described it (different object, different
  namespace), re-confirm.
- Take a **read-only backup first** where it helps recovery, e.g.
  `kubectl get <obj> -n <ns> -o yaml > backup.yaml` before a `delete` — the backup
  command itself is read-only and needs no confirmation.
- Never chain a mutation behind a read in a single shell line to "save a round trip".

---

## Context and namespace safety

- **State before you act.** Announce the active context and namespace
  (`kubectl config current-context`; `kubectl config view --minify -o jsonpath='{..namespace}'`)
  before proposing anything mutating, and whenever they might have changed.
- **Never switch context or namespace silently.** `kubectl config use-context`,
  `set-context`, and `--context`/`--namespace` overrides that redirect a mutation to a
  different cluster/namespace are themselves confirm-required — changing *where* a change
  lands is as dangerous as the change.
- **Prefer explicit `-n <ns>`** over relying on the current namespace, so the target is
  visible in the command the user is confirming.
- **Assume the most dangerous interpretation** of ambiguous scope. If the user says
  "restart the deployment" and two namespaces have one, ask which — do not pick.
- **Protect production.** If the context name suggests prod, be extra explicit about
  effect and rollback; consider proposing the change against a non-prod context first if
  one exists.

---

## When the user says "just fix it"

A blanket "just fix it" does **not** waive the protocol for destructive actions. You may
proceed with a clearly-reversible, low-blast-radius change after showing the command and
effect once, but for `delete`, `drain`, or anything without a rollback, still show the
exact command + effect + (missing) rollback and get a specific yes for that action.
Read-only-by-default protects the user from a confident-but-wrong mutation — that risk
doesn't disappear because they're in a hurry.
