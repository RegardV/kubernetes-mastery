# Audit Checklists — read-only cluster posture review

Run these to assess a cluster's RBAC, security, network, workload health, drift, and
cost posture. **Everything here is read-only.** Findings are reported to the user;
remediations are proposed as confirm-gated changes (see `safety-guardrails.md`), never
applied automatically.

External tools referenced (kubent, pluto, Trivy, polaris) are read-only scanners — but
still confirm before installing anything on the user's machine or cluster.

Convention:

```bash
NS=default   # scope where a check supports it; most sweep all namespaces with -A
```

---

## 1. RBAC — who can do what

### Over-broad bindings and cluster-admin

```bash
# Every ClusterRoleBinding to cluster-admin — the highest-privilege grant:
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + ([.subjects[]?|.kind+"/"+.name]|join(","))'

# All ClusterRoleBindings with their role and subjects (scan for surprises):
kubectl get clusterrolebindings -o custom-columns='NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name'

# Bindings that grant to broad groups (anyone authenticated / unauthenticated):
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.subjects[]?.name=="system:authenticated" or .subjects[]?.name=="system:unauthenticated") | .metadata.name'
```

### Wildcards in Roles / ClusterRoles

```bash
# ClusterRoles that grant verbs=* or resources=* or apiGroups=* (over-broad):
kubectl get clusterroles -o json | \
  jq -r '.items[] | select(.rules[]? | (.verbs[]?=="*") or (.resources[]?=="*") or (.apiGroups[]?=="*")) | .metadata.name' | sort -u

# Same for namespaced Roles:
kubectl get roles -A -o json | \
  jq -r '.items[] | select(.rules[]? | (.verbs[]?=="*") or (.resources[]?=="*")) | .metadata.namespace + "/" + .metadata.name' | sort -u
```

### Effective permissions of a subject

```bash
# What a given ServiceAccount can actually do:
kubectl auth can-i --list --as=system:serviceaccount:"$NS":default -n "$NS"
kubectl auth can-i --list --as=system:serviceaccount:"$NS":default --all-namespaces

# Can a workload SA read secrets or escalate?  (both should usually be "no")
kubectl auth can-i get secrets --as=system:serviceaccount:"$NS":default -n "$NS"
kubectl auth can-i create clusterrolebindings --as=system:serviceaccount:"$NS":default
kubectl auth can-i '*' '*' --as=system:serviceaccount:"$NS":default --all-namespaces
```

**Flags to raise:** cluster-admin bound to a ServiceAccount or a human group; any Role
with `verbs: ["*"]`; bindings to `system:authenticated`; workload SAs that can `get
secrets` cluster-wide or create RBAC objects.

---

## 2. Security posture

### Privileged / root containers

```bash
# Privileged containers (full host access):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.securityContext.privileged==true) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"]"'

# Containers running as root (runAsNonRoot not set/true, or runAsUser 0):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select((.securityContext.runAsNonRoot != true) and ((.securityContext.runAsUser // 0)==0)) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"]"' | head -40

# allowPrivilegeEscalation not disabled:
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.securityContext.allowPrivilegeEscalation != false) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"]"' | head -40
```

### Host namespaces, hostPath, capabilities

```bash
# hostNetwork / hostPID / hostIPC:
kubectl get pods -A -o json | \
  jq -r '.items[] | select(.spec.hostNetwork==true or .spec.hostPID==true or .spec.hostIPC==true) | .metadata.namespace+"/"+.metadata.name'

# hostPath volume mounts (host filesystem access):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | (.spec.volumes // [])[] | select(.hostPath) | $p.metadata.namespace+"/"+$p.metadata.name+" -> "+.hostPath.path'

# Added Linux capabilities (esp. NET_ADMIN, SYS_ADMIN):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.securityContext.capabilities.add) | $p.metadata.namespace+"/"+$p.metadata.name+" caps="+(.securityContext.capabilities.add|join(","))'
```

### Missing securityContext / read-only root fs

```bash
# Containers with no securityContext at all:
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.securityContext==null) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"]"' | head -40

# Writable root filesystem (readOnlyRootFilesystem not true):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.securityContext.readOnlyRootFilesystem != true) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"]"' | head -40
```

### Broader scan (read-only tools)

```bash
# Polaris — configuration-quality/security scoring, read-only:
polaris audit --format pretty        # if installed; https://github.com/FairwindsOps/polaris

# kube-bench — CIS benchmark for node/control-plane config (read-only):
# runs as a job that reads config; review before applying the manifest.
```

**Flags to raise:** any privileged container outside known infra (CNI/CSI/monitoring);
hostPath mounts of `/`, `/var/run/docker.sock`, or `/etc`; hostNetwork on app pods;
`SYS_ADMIN` capability; app containers with no securityContext and root fs writable.

---

## 3. NetworkPolicy coverage

Kubernetes is allow-all by default: with no NetworkPolicy, every pod can reach every
other pod. Audit which namespaces lack a default-deny.

```bash
# All NetworkPolicies and the namespaces that have them:
kubectl get networkpolicy -A

# Namespaces WITHOUT any NetworkPolicy (implicitly allow-all):
comm -23 \
  <(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort) \
  <(kubectl get networkpolicy -A -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n' | sort -u)

# Does a namespace have a default-deny (empty podSelector, Ingress in policyTypes)?
kubectl get networkpolicy -n "$NS" -o json | \
  jq -r '.items[] | select((.spec.podSelector=={}) and (.spec.policyTypes[]?=="Ingress")) | .metadata.name'
```

**Flags to raise:** any namespace running workloads with zero NetworkPolicies;
namespaces with per-app policies but no default-deny baseline.

**Homelab note:** k3s ships with flannel, which historically did **not** enforce
NetworkPolicy — the objects exist but nothing enforces them. Verify the CNI actually
enforces (`kubectl get pods -n kube-system | grep -iE 'calico|cilium'`); on stock k3s
+ flannel, treat NetworkPolicy as documentation, not enforcement, unless a policy CNI
was added.

---

## 4. Workload health

### Missing resource requests / limits

```bash
# Containers with no CPU or memory requests (scheduler can't place them well):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select((.resources.requests.cpu==null) or (.resources.requests.memory==null)) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"] missing requests"' | head -40

# Containers with no limits (can starve neighbours / never OOM-cap):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.resources.limits==null) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"] no limits"' | head -40
```

### Missing probes

```bash
# Containers lacking a readiness probe (may receive traffic before ready):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.readinessProbe==null) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"] no readinessProbe"' | head -40

# Containers lacking a liveness probe:
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.livenessProbe==null) | $p.metadata.namespace+"/"+$p.metadata.name+" ["+.name+"] no livenessProbe"' | head -40
```

### PodDisruptionBudgets and replica counts

```bash
# Deployments running a single replica (no HA — a restart = downtime):
kubectl get deploy -A -o json | \
  jq -r '.items[] | select((.spec.replicas // 1) < 2) | .metadata.namespace+"/"+.metadata.name+" replicas="+((.spec.replicas//1)|tostring)'

# PDBs present, and which workloads have none:
kubectl get pdb -A
```

**Flags to raise:** app workloads with no requests (breaks scheduling & autoscaling);
no limits (noisy-neighbour risk); no readiness probe on a Service-backed pod; critical
Deployments at replica 1 with no PDB.

**Homelab note:** single-replica and no-PDB are *expected* on a single-node k3s box —
HA is impossible with one node. Report these as "by design for single-node" rather than
defects, unless the user intends multi-node.

---

## 5. Image & API drift

### `:latest` and mutable tags

```bash
# Every container image using :latest or no explicit tag:
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' | \
  awk '/:latest| [^:]+$/' | grep -E ':latest|[[:space:]][^:/[:space:]]+$'

# imagePullPolicy: Always paired with :latest (non-reproducible deploys):
kubectl get pods -A -o json | \
  jq -r '.items[] | . as $p | .spec.containers[] | select(.image|test(":latest$")) | $p.metadata.namespace+"/"+$p.metadata.name+" "+.image'
```

### Deprecated / removed APIs

```bash
# pluto — detect deprecated/removed apiVersions in live objects (read-only):
pluto detect-all-in-cluster -o wide            # https://github.com/FairwindsOps/pluto

# kubent (kube-no-trouble) — same purpose, checks against your server version:
kubent                                          # https://github.com/doitintl/kube-no-trouble

# Server version to interpret which APIs are already removed:
kubectl version -o json | jq -r '.serverVersion.gitVersion'
```

### Image CVE scanning

```bash
# Trivy — scan a running image for CVEs (read-only; pulls & inspects the image):
trivy image <repo>:<tag> --severity HIGH,CRITICAL      # https://aquasecurity.github.io/trivy

# Enumerate distinct images in use, then feed them to trivy:
kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' | sort -u
```

**Flags to raise:** `:latest` on anything you can't reproduce; objects on
deprecated/removed API versions ahead of a cluster upgrade; HIGH/CRITICAL CVEs in
running images with no patch plan.

---

## 6. Cost signals

### Requests vs. actual usage (over-provisioning)

```bash
# Actual usage now (needs metrics-server), heaviest first:
kubectl top pods -A --sort-by=memory
kubectl top pods -A --sort-by=cpu

# Requested (reserved) CPU/mem per pod — compare against top output above:
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory'

# Node-level: allocated (reserved) vs capacity — headroom or overcommit:
kubectl describe nodes | grep -A6 'Allocated resources'
```

Where usage sits far below requests, the workload is reserving capacity it never uses —
you're paying for idle headroom. Where usage repeatedly nears limits, it's a scaling or
OOM risk. Report both directions.

### Idle LoadBalancers and unused resources

```bash
# LoadBalancer Services (each often = a paid cloud LB):
kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide

# LoadBalancers with NO endpoints (paying for nothing):
for s in $(kubectl get svc -A --field-selector spec.type=LoadBalancer -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  ns=${s%/*}; nm=${s#*/};
  ep=$(kubectl get endpoints "$nm" -n "$ns" -o jsonpath='{.subsets[*].addresses[*].ip}');
  [ -z "$ep" ] && echo "IDLE LB: $s (no endpoints)";
done

# Released/available PVs still provisioned (orphaned storage):
kubectl get pv --field-selector status.phase=Available
kubectl get pv -o json | jq -r '.items[] | select(.status.phase=="Released") | .metadata.name+" "+.spec.capacity.storage'

# Completed/Failed pods lingering (clutter, minor cost):
kubectl get pods -A --field-selector status.phase=Succeeded
```

**Flags to raise:** requests set 5–10x above observed usage; LoadBalancer Services with
no endpoints; `Available`/`Released` PVs no longer needed.

**Homelab note:** with servicelb/MetalLB there is no per-LB cloud bill, so "idle
LoadBalancer" is a tidiness finding, not a cost one. Over-provisioned requests still
matter — on a small node they can make otherwise-fine pods unschedulable.
