# Triage Playbooks

One playbook per symptom. Every command here is **read-only** unless it is under a
heading that says **FIX (requires confirmation)** — those must be shown to the user
with their effect and rollback, then run only after an explicit yes. See
`safety-guardrails.md` for the confirmation protocol.

Before any playbook: confirm where you are.

```bash
kubectl config current-context
kubectl config view --minify -o jsonpath='{..namespace}'; echo
```

Set a shell variable for the target namespace so commands stay copy-pasteable:

```bash
NS=default   # replace with the namespace under investigation
```

---

## CrashLoopBackOff

The container starts, exits, and the kubelet backs off before restarting it. The
pod is scheduled and the image pulled — the failure is at or after process start.

### Likely causes (ranked)

1. **Application error on startup** — bad config, missing env var, unreachable
   dependency (DB/queue), failed migration. Most common.
2. **Failing liveness probe** killing a container that is actually still booting
   (probe too aggressive / `initialDelaySeconds` too low).
3. **Bad command/args or entrypoint** — container exits 0 immediately or errors 127.
4. **Missing/incorrect mounted secret or configmap** the app reads at boot.
5. **OOMKilled on startup** — see the OOMKilled playbook; check exit code 137.
6. **Read-only filesystem or permissions** — app can't write a pidfile/cache.

### Confirm each (read-only)

```bash
# Restart count, current state, and last-terminated reason/exit code:
kubectl get pod <pod> -n "$NS" -o wide
kubectl describe pod <pod> -n "$NS"

# The single most useful read — logs from the PREVIOUS crashed container:
kubectl logs <pod> -n "$NS" --previous
kubectl logs <pod> -n "$NS" --previous -c <container>   # multi-container pod

# Exit code + reason as structured data (137=OOM/SIGKILL, 143=SIGTERM, 1/2=app err):
kubectl get pod <pod> -n "$NS" -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.lastState.terminated.exitCode}{"\t"}{.lastState.terminated.reason}{"\n"}{end}'

# Events for this pod, newest last:
kubectl get events -n "$NS" --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp

# Probe definitions and command/args — verify probe timing and entrypoint:
kubectl get pod <pod> -n "$NS" -o yaml | grep -A15 -iE 'livenessProbe|readinessProbe|command|args'

# Env, and whether referenced secrets/configmaps exist:
kubectl describe pod <pod> -n "$NS" | grep -A20 -iE 'Environment|Mounts'
kubectl get configmap,secret -n "$NS"
```

If the probe is the suspect, compare `initialDelaySeconds` against how long the
app takes to log "ready" in `--previous` logs.

### FIX (requires confirmation)

The fix depends on the confirmed cause. Typical patterns — propose the exact one,
never guess:

```bash
# Cause: liveness probe too aggressive. Effect: relaxes probe timing.
# Rollback: kubectl rollout undo deployment/<deploy> -n "$NS"
kubectl edit deployment/<deploy> -n "$NS"   # raise initialDelaySeconds/failureThreshold

# Cause: missing/wrong env value. Effect: patches the container env.
# Rollback: kubectl rollout undo deployment/<deploy> -n "$NS"
kubectl set env deployment/<deploy> -n "$NS" KEY=value

# Cause: a stuck rollout of a bad image/config. Effect: reverts to prior ReplicaSet.
# Rollback: kubectl rollout undo deployment/<deploy> -n "$NS" --to-revision=<prev>
kubectl rollout undo deployment/<deploy> -n "$NS"
```

---

## ImagePullBackOff / ErrImagePull

The kubelet cannot pull the image. The pod is scheduled but the container never
starts. `ErrImagePull` is the first failure; `ImagePullBackOff` is the backoff after
repeated failures.

### Likely causes (ranked)

1. **Wrong image name or tag** — typo, tag that doesn't exist, or `:latest` that was
   deleted/retagged in the registry.
2. **Private registry without credentials** — missing/incorrect `imagePullSecrets`.
3. **Registry auth expired** — token/pull secret rotated out from under the pod.
4. **Rate limiting** — Docker Hub anonymous pull limit (`toomanyrequests`).
5. **Network/DNS** — node can't reach the registry (air-gapped homelab, wrong proxy,
   private registry not resolvable).
6. **Architecture mismatch** — image has no matching arch (e.g. amd64-only image on
   an arm64 Raspberry Pi node — common in homelabs).

### Confirm each (read-only)

```bash
# The exact pull error is in the events / describe output:
kubectl describe pod <pod> -n "$NS" | grep -A5 -iE 'Failed|Events'
kubectl get events -n "$NS" --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp

# The image reference actually requested:
kubectl get pod <pod> -n "$NS" -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'

# Whether a pull secret is attached and exists:
kubectl get pod <pod> -n "$NS" -o jsonpath='{.spec.imagePullSecrets[*].name}'; echo
kubectl get secret -n "$NS" --field-selector type=kubernetes.io/dockerconfigjson

# Node architecture vs image (arm64/amd64 mismatch):
kubectl get nodes -o custom-columns=NODE:.metadata.name,ARCH:.status.nodeInfo.architecture
```

Distinguish the message: `not found`/`manifest unknown` = wrong name/tag;
`unauthorized`/`authentication required` = credentials; `toomanyrequests` = rate
limit; `no matching manifest for linux/arm64` = arch mismatch.

### FIX (requires confirmation)

```bash
# Cause: wrong tag. Effect: updates the deployment image, triggers a new rollout.
# Rollback: kubectl rollout undo deployment/<deploy> -n "$NS"
kubectl set image deployment/<deploy> -n "$NS" <container>=<repo>:<correct-tag>

# Cause: missing pull secret. Effect: creates a dockerconfigjson secret.
# Rollback: kubectl delete secret regcred -n "$NS"
kubectl create secret docker-registry regcred -n "$NS" \
  --docker-server=<registry> --docker-username=<user> --docker-password=<pass>
# then reference it on the serviceaccount or podspec (kubectl patch — also confirm).
```

**Homelab note:** for a local private registry (`registry:2`, Harbor, or k3s's
embedded registry mirror), verify the node trusts it — k3s reads
`/etc/rancher/k3s/registries.yaml`. If that file is wrong the pull fails identically;
that's a node-config fix, not a kubectl fix.

---

## Pending (unschedulable)

The pod exists but no node has been assigned. The scheduler cannot place it.

### Likely causes (ranked)

1. **Insufficient resources** — no node has enough allocatable CPU/memory for the
   pod's requests.
2. **Unsatisfiable node affinity / nodeSelector / required topology.**
3. **Taints without matching tolerations** — e.g. control-plane taint, or a
   `NotReady`/`disk-pressure` taint.
4. **Unbound PVC** — pod waits on a PersistentVolumeClaim that isn't bound (see the
   Pending PVC playbook).
5. **Pod anti-affinity / topology spread** can't be satisfied (common with
   single-node clusters wanting replicas on distinct nodes).
6. **All nodes cordoned / `NotReady`.**

### Confirm each (read-only)

```bash
# The scheduler writes the exact reason into events — read it first:
kubectl describe pod <pod> -n "$NS" | grep -A10 Events
# Typical: "0/1 nodes are available: 1 Insufficient cpu", "... had untolerated taint",
#          "... didn't match Pod's node affinity/selector", "... pod has unbound PVCs".

# What the pod is asking for:
kubectl get pod <pod> -n "$NS" -o jsonpath='{range .spec.containers[*]}{.name}{" req="}{.resources.requests}{"\n"}{end}'
kubectl get pod <pod> -n "$NS" -o jsonpath='{.spec.nodeSelector}{"\n"}{.spec.tolerations}{"\n"}'

# What the nodes can offer, and their taints:
kubectl get nodes -o wide
kubectl describe nodes | grep -A6 -iE 'Allocatable|Taints|Allocated resources'
kubectl top nodes   # requires metrics-server
```

### FIX (requires confirmation)

```bash
# Cause: requests too high for the node. Effect: lowers requests, reschedules.
# Rollback: kubectl rollout undo deployment/<deploy> -n "$NS"
kubectl edit deployment/<deploy> -n "$NS"   # reduce resources.requests

# Cause: a node is cordoned and you want it schedulable again.
# Effect: marks node schedulable. Rollback: kubectl cordon <node>
kubectl uncordon <node>

# Cause: replica count exceeds capacity on a single-node homelab.
# Effect: scales down. Rollback: kubectl scale deployment/<deploy> -n "$NS" --replicas=<orig>
kubectl scale deployment/<deploy> -n "$NS" --replicas=1
```

**Homelab note:** on a single-node k3s cluster, `podAntiAffinity` with
`requiredDuringScheduling` and `topologyKey: kubernetes.io/hostname` will pin a
second replica in `Pending` forever — there is only one host. Prefer a single
replica or relax to `preferredDuringScheduling`.

---

## OOMKilled

A container exceeded its memory limit and the kernel OOM-killer terminated it.
Exit code **137**, reason `OOMKilled`. Often masquerades as CrashLoopBackOff.

### Likely causes (ranked)

1. **Memory limit set too low** for the app's real working set.
2. **Memory leak / unbounded growth** — usage climbs until it hits the limit.
3. **Load spike** — a batch job or traffic burst temporarily exceeds the limit.
4. **JVM/runtime not limit-aware** — heap sized to node RAM, not the cgroup limit
   (older JVMs, `-Xmx` unset).
5. **Node-level memory pressure** evicting/killing even under-limit pods (check node
   conditions).

### Confirm each (read-only)

```bash
# Confirm it was OOM, not a plain crash:
kubectl get pod <pod> -n "$NS" -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\treason="}{.lastState.terminated.reason}{"\texit="}{.lastState.terminated.exitCode}{"\n"}{end}'
kubectl describe pod <pod> -n "$NS" | grep -iE 'OOMKilled|Last State|Exit Code|Reason'

# Current limit vs current usage:
kubectl get pod <pod> -n "$NS" -o jsonpath='{range .spec.containers[*]}{.name}{" limit="}{.resources.limits.memory}{" request="}{.resources.requests.memory}{"\n"}{end}'
kubectl top pod <pod> -n "$NS" --containers   # requires metrics-server

# Node memory pressure (rules out an under-limit eviction):
kubectl describe node <node> | grep -A5 Conditions
kubectl get events -n "$NS" --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp | grep -i oom
```

### FIX (requires confirmation)

```bash
# Cause: limit genuinely too low. Effect: raises the memory limit, rolls the pods.
# Rollback: kubectl rollout undo deployment/<deploy> -n "$NS"
kubectl set resources deployment/<deploy> -n "$NS" --limits=memory=512Mi --requests=memory=256Mi
```

If usage grows without bound (leak), raising the limit only delays the kill — flag
that to the user; the real fix is in the application, not the manifest.

---

## Service returns 5xx / no endpoints

Requests through a Service fail (502/503) or time out. Usually the Service has no
healthy backends, not an application bug.

### Likely causes (ranked)

1. **Selector mismatch** — the Service `selector` doesn't match any pod labels, so the
   endpoint list is empty.
2. **Pods not Ready** — readiness probe failing, so pods are excluded from Endpoints.
3. **Wrong `targetPort`** — Service points at a port the container isn't listening on.
4. **All backends crashing** — see CrashLoopBackOff; no Ready pods to serve.
5. **NetworkPolicy** blocking traffic from the Service/ingress to the pods.
6. **Ingress/LoadBalancer misroute** — Traefik/servicelb route exists but points at the
   wrong Service or port (homelab).

### Confirm each (read-only)

```bash
# The decisive check — does the Service have endpoints?  Empty = selector/readiness problem.
kubectl get endpoints <svc> -n "$NS"
kubectl get endpointslices -n "$NS" -l kubernetes.io/service-name=<svc>

# Compare Service selector against actual pod labels:
kubectl get svc <svc> -n "$NS" -o jsonpath='{.spec.selector}'; echo
kubectl get pods -n "$NS" --show-labels

# Service ports vs container ports:
kubectl get svc <svc> -n "$NS" -o jsonpath='{range .spec.ports[*]}{.name}{" port="}{.port}{" targetPort="}{.targetPort}{"\n"}{end}'
kubectl get pods -n "$NS" -l <selector> -o jsonpath='{range .items[*].spec.containers[*]}{.name}{" ports="}{.ports}{"\n"}{end}'

# Are the backing pods Ready?
kubectl get pods -n "$NS" -l <selector> -o wide

# NetworkPolicies that might block it:
kubectl get networkpolicy -n "$NS"
```

### FIX (requires confirmation)

```bash
# Cause: selector/targetPort wrong in the Service. Effect: edits the Service.
# Rollback: re-apply the prior Service manifest, or kubectl edit back.
kubectl edit svc <svc> -n "$NS"
```

**Homelab note:** with servicelb (klipper-lb) a `LoadBalancer` Service can sit in
`<pending>` for its external IP if host ports 80/443 are already taken. Traefik is
the default ingress in k3s — check `kubectl get ingress -A` and
`kubectl -n kube-system logs deploy/traefik` (read-only) when the 5xx comes from
the edge rather than the Service.

---

## Node NotReady

A node reports `NotReady`; its pods may be getting evicted or stuck `Terminating`.

### Likely causes (ranked)

1. **kubelet down or unhealthy** on the node (service crashed, cert expired).
2. **Resource pressure** — `MemoryPressure`, `DiskPressure`, `PIDPressure` conditions.
3. **Network/CNI failure** — node can't reach the API server, or CNI pod (flannel/
   calico) is down.
4. **Container runtime down** — containerd/dockerd not responding.
5. **Node genuinely offline** — powered off, network cable, VM paused (homelab).
6. **Clock skew / expired certs** — kubelet client cert lapsed.

### Confirm each (read-only)

```bash
kubectl get nodes -o wide
kubectl describe node <node> | grep -A8 Conditions      # which condition flipped
kubectl describe node <node> | grep -A5 -iE 'Taints|Pressure'

# System pods for that node (CNI, kube-proxy) — are they healthy?
kubectl get pods -n kube-system -o wide --field-selector spec.nodeName=<node>

# Cluster-level events around the node:
kubectl get events -A --field-selector involvedObject.name=<node> --sort-by=.lastTimestamp

# What's stranded on it:
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>
```

On-node diagnosis (SSH, not kubectl — still read-only): `systemctl status kubelet`,
`journalctl -u kubelet --no-pager | tail`, `df -h`, `free -m`. For k3s the unit is
`k3s` (server) or `k3s-agent`.

### FIX (requires confirmation)

Recovery is usually on the node itself (restart kubelet/k3s, free disk). Cluster-side
actions that mutate:

```bash
# Cause: node is unhealthy and you must move workloads off safely.
# Effect: evicts pods, marks node unschedulable. THIS IS DISRUPTIVE.
# Rollback: kubectl uncordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# Effect: stop scheduling new pods here without evicting existing ones.
# Rollback: kubectl uncordon <node>
kubectl cordon <node>
```

Never drain the only node of a single-node homelab — it evicts everything and leaves
you nowhere to schedule. Fix the kubelet/k3s service instead.

---

## Pending PVC (unbound PersistentVolumeClaim)

A PVC stays `Pending`; pods that mount it stay `Pending` too.

### Likely causes (ranked)

1. **No matching PersistentVolume** and no dynamic provisioner for the requested
   StorageClass.
2. **StorageClass name wrong or missing** — PVC references a class that doesn't exist,
   or none and there's no default class.
3. **`WaitForFirstConsumer`** binding mode — PVC intentionally stays Pending until a
   pod that uses it is scheduled (this is normal, not a fault).
4. **Provisioner pod down** — CSI driver / local-path-provisioner not running.
5. **Access mode / size unsatisfiable** — e.g. `ReadWriteMany` on a provisioner that
   only supports `ReadWriteOnce`.
6. **Node affinity on a local PV** doesn't match any schedulable node.

### Confirm each (read-only)

```bash
kubectl get pvc -n "$NS"
kubectl describe pvc <pvc> -n "$NS" | grep -A10 Events   # the provisioner writes the reason here

# The requested class, and whether it exists / is default:
kubectl get pvc <pvc> -n "$NS" -o jsonpath='{.spec.storageClassName}'; echo
kubectl get storageclass                                  # look for (default) marker
kubectl get storageclass <class> -o jsonpath='{.volumeBindingMode}'; echo

# Available PVs (for static provisioning):
kubectl get pv

# Is the provisioner running?
kubectl get pods -n kube-system | grep -iE 'provisioner|csi'
```

`WaitForFirstConsumer` + a Pending PVC + a Pending pod is expected — schedule the
consuming pod and both bind. Only treat it as a fault if the pod is schedulable but
the PVC still won't bind.

### FIX (requires confirmation)

```bash
# Cause: PVC references a nonexistent class and you must recreate it correctly.
# PVCs are largely immutable — the fix is usually delete + recreate.
# Effect: DELETES the claim (and, per reclaim policy, possibly the data). CONFIRM CAREFULLY.
# Rollback: none for the delete — the old claim is gone. Re-create from a saved manifest.
kubectl get pvc <pvc> -n "$NS" -o yaml > /tmp/<pvc>-backup.yaml   # read-only backup first
kubectl delete pvc <pvc> -n "$NS"                                 # confirm required
kubectl apply -f <corrected-pvc>.yaml                            # confirm required
```

**Homelab note:** k3s ships `local-path` as the default StorageClass with
`volumeBindingMode: WaitForFirstConsumer` and `ReadWriteOnce` only. A PVC requesting
`ReadWriteMany` will never bind on stock k3s — you'd need NFS or Longhorn. A
`local-path` PV is pinned to the node that first scheduled the pod, so a pod that
later lands on a different node can't reach its data on a multi-node k3s cluster.
