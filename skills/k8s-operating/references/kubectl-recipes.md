# kubectl Recipes — safe read-only investigation

Every command in this file is **read-only** (`get`, `describe`, `logs`, `events`,
`top`, `auth can-i`, `api-resources`, `explain`). None mutates cluster state. Grouped
by task. Replace `<...>` placeholders; `-A` means all namespaces, `-n <ns>` scopes.

Conventions used below:

```bash
NS=default
POD=<pod-name>
```

---

## Orient — where am I

```bash
kubectl config current-context                                   # active cluster
kubectl config get-contexts                                      # all contexts, * = current
kubectl config view --minify -o jsonpath='{..namespace}'; echo   # default namespace of context
kubectl cluster-info                                             # API server + core addon URLs
kubectl version --output=yaml                                    # client/server versions
kubectl get nodes -o wide                                        # nodes, roles, versions, IPs
kubectl api-resources                                            # every resource kind + shortname
kubectl api-versions                                             # served API groups/versions
```

---

## Health snapshots

```bash
# Everything unhealthy across the cluster, fastest first look:
kubectl get pods -A -o wide | grep -vE 'Running|Completed'
kubectl get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded

# Broad workload snapshot in one namespace:
kubectl get pods,deploy,rs,sts,ds,svc,ingress -n "$NS" -o wide

# Deployments not fully rolled out (ready != desired):
kubectl get deploy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas'

# High restart counts anywhere (leak/crash signal):
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,PHASE:.status.phase' | tail -20

# Pods pending / not-ready right now:
kubectl get pods -A --field-selector status.phase=Pending
kubectl get pods -A -o json | kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'

# Cluster-wide component health (older clusters):
kubectl get componentstatuses 2>/dev/null
```

---

## Events (sorted by time — the highest-signal read)

```bash
# Namespace events, oldest→newest (default sort is unhelpful):
kubectl get events -n "$NS" --sort-by=.lastTimestamp

# Only Warnings (skip the Normal noise):
kubectl get events -n "$NS" --field-selector type=Warning --sort-by=.lastTimestamp

# Events for one specific object:
kubectl get events -n "$NS" --field-selector involvedObject.name="$POD" --sort-by=.lastTimestamp

# Cluster-wide warnings, newest last:
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp

# Wide format with the count of repeated events:
kubectl get events -n "$NS" --sort-by=.lastTimestamp \
  -o custom-columns='LAST:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MSG:.message'
```

---

## Ownership chain — Pod → ReplicaSet → Deployment

Walk `ownerReferences` upward to find the real object to act on. Each step is one read.

```bash
# 1. Who owns the pod? (usually a ReplicaSet):
kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{"\n"}{end}'

# 2. Who owns that ReplicaSet? (the Deployment):
RS=<replicaset-from-step-1>
kubectl get rs "$RS" -n "$NS" -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{"\n"}{end}'

# One-liner: pod → its top owner kind/name in a table:
kubectl get pods -n "$NS" -o custom-columns='POD:.metadata.name,OWNER_KIND:.metadata.ownerReferences[0].kind,OWNER:.metadata.ownerReferences[0].name'

# Downward: which pods does a Deployment own (via its selector)?
SEL=$(kubectl get deploy <deploy> -n "$NS" -o jsonpath='{.spec.selector.matchLabels}' | tr -d '{}"' | tr ',' ',')
kubectl get pods -n "$NS" -l "$(kubectl get deploy <deploy> -n "$NS" -o jsonpath='{range .spec.selector.matchLabels}{@}{end}')" 2>/dev/null
# Simpler and reliable — read the deployment's pod-template label and reuse it:
kubectl get deploy <deploy> -n "$NS" -o jsonpath='{.spec.selector.matchLabels}'; echo
kubectl get pods -n "$NS" -l app=<value>

# Rollout history and current revision of a Deployment (read-only):
kubectl rollout history deployment/<deploy> -n "$NS"
kubectl rollout status deployment/<deploy> -n "$NS" --timeout=5s   # reports, does not change
```

---

## Logs

```bash
# Current logs:
kubectl logs "$POD" -n "$NS"

# Previous (crashed) container — essential for CrashLoopBackOff:
kubectl logs "$POD" -n "$NS" --previous

# A specific container in a multi-container pod:
kubectl logs "$POD" -n "$NS" -c <container>
kubectl logs "$POD" -n "$NS" --all-containers=true --prefix

# Time-bounded / tail-bounded (avoid dumping gigabytes):
kubectl logs "$POD" -n "$NS" --since=15m
kubectl logs "$POD" -n "$NS" --since-time=2026-07-13T10:00:00Z
kubectl logs "$POD" -n "$NS" --tail=200

# Follow live (read-only stream) — Ctrl-C to stop:
kubectl logs "$POD" -n "$NS" -f --tail=50

# Aggregate logs across all pods of a workload by label:
kubectl logs -n "$NS" -l app=<value> --all-containers --prefix --tail=100 --max-log-requests=10

# Logs from every pod of a Deployment (kubectl resolves the pods):
kubectl logs deployment/<deploy> -n "$NS" --all-containers --tail=100
```

---

## describe (across pods, nodes, namespaces)

```bash
kubectl describe pod "$POD" -n "$NS"
kubectl describe node <node>
kubectl describe deploy <deploy> -n "$NS"

# Describe every pod matching a label:
kubectl describe pods -n "$NS" -l app=<value>

# Just the Events section of a describe (fast triage):
kubectl describe pod "$POD" -n "$NS" | sed -n '/Events:/,$p'

# Describe the same kind in every namespace:
kubectl describe ingress -A
```

---

## Resource usage — top

Requires `metrics-server` (bundled in k3s; may need install elsewhere).

```bash
kubectl top nodes
kubectl top pods -n "$NS"
kubectl top pods -A --sort-by=memory        # heaviest memory consumers cluster-wide
kubectl top pods -A --sort-by=cpu
kubectl top pod "$POD" -n "$NS" --containers # per-container breakdown

# Compare requests (what's reserved) against reality — usage vs. spec:
kubectl get pods -n "$NS" -o custom-columns='POD:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory'
```

---

## Permissions — auth can-i

```bash
# Can I (as current user) do X?
kubectl auth can-i get pods -n "$NS"
kubectl auth can-i delete deployments -n "$NS"
kubectl auth can-i '*' '*' --all-namespaces            # am I effectively cluster-admin?

# Everything the current identity can do here (audit an account):
kubectl auth can-i --list -n "$NS"

# Impersonate to check another subject's rights (read-only evaluation):
kubectl auth can-i list secrets -n "$NS" --as=system:serviceaccount:"$NS":default
kubectl auth can-i --list --as=system:serviceaccount:"$NS":default -n "$NS"
kubectl auth can-i get nodes --as=jane --as-group=devs

# Who am I right now:
kubectl auth whoami 2>/dev/null    # k8s 1.26+
```

---

## Selectors — jsonpath and custom-columns

```bash
# All images running in a namespace (dedup for a drift audit):
kubectl get pods -n "$NS" -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' | sort -u

# Pod → node placement:
kubectl get pods -n "$NS" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP'

# Containers using :latest (a drift smell):
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' | grep ':latest'

# Every container's resource requests/limits at a glance:
kubectl get pods -n "$NS" -o custom-columns='POD:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_LIM:.spec.containers[*].resources.limits.memory'

# Pods not Ready (jsonpath over the Ready condition):
kubectl get pods -n "$NS" -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}'

# Nodes with their allocatable CPU/mem:
kubectl get nodes -o custom-columns='NODE:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,ARCH:.status.nodeInfo.architecture'

# Sort by any field:
kubectl get pods -n "$NS" --sort-by=.metadata.creationTimestamp
kubectl get pv --sort-by=.spec.capacity.storage
```

---

## Finding pods (and other objects) by label

```bash
kubectl get pods -A --show-labels                       # discover what labels exist
kubectl get pods -n "$NS" -l app=nginx                  # exact match
kubectl get pods -n "$NS" -l 'app in (web,api)'         # set-based
kubectl get pods -n "$NS" -l 'tier!=frontend'           # negation
kubectl get pods -n "$NS" -l app=web,env=prod           # AND of two labels
kubectl get all -n "$NS" -l app=web                      # all common kinds for a label

# Field selectors (server-side filter on non-label fields):
kubectl get pods -A --field-selector spec.nodeName=<node>
kubectl get pods -A --field-selector status.phase=Failed
kubectl get events -A --field-selector reason=BackOff
```

---

## Quick checks — probes, resources, images, config

```bash
# Probes defined on a pod:
kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .spec.containers[*]}{.name}{": live="}{.livenessProbe}{" ready="}{.readinessProbe}{"\n"}{end}'

# Image + imagePullPolicy per container:
kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\t"}{.imagePullPolicy}{"\n"}{end}'

# securityContext (privileged/root check):
kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.securityContext}{"\n"}{range .spec.containers[*]}{.name}{": "}{.securityContext}{"\n"}{end}'

# Env vars and their sources:
kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .spec.containers[*].env[*]}{.name}{"="}{.value}{.valueFrom}{"\n"}{end}'

# Volumes and mounts:
kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.volumes}' | tr ',' '\n'
kubectl describe pod "$POD" -n "$NS" | sed -n '/Mounts:/,/Conditions:/p'

# What a Service points at:
kubectl get svc <svc> -n "$NS" -o jsonpath='{.spec.selector}{"\n"}'
kubectl get endpoints <svc> -n "$NS"

# Explain any field without touching the cluster:
kubectl explain deployment.spec.strategy
kubectl explain pod.spec.containers.resources --recursive
```

---

## Diff and dry-run WITHOUT changing anything

`--dry-run=client` and `kubectl diff` are read-only previews — safe to run when you
want to see what a change *would* do before proposing the real (confirm-gated) apply.

```bash
# Show what apply would change against the live cluster (reads only):
kubectl diff -f <manifest>.yaml

# Render an object as it would be created, without sending it:
kubectl create deployment demo --image=nginx --dry-run=client -o yaml
```

Note: `--dry-run=server` sends the object to the API server for validation. It does
not persist, but it is a write-path call — prefer `--dry-run=client` and `diff` for
pure investigation, and treat server dry-run as confirm-worthy on locked-down clusters.
