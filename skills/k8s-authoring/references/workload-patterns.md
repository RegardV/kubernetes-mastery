# Workload Patterns — pick the right kind, then harden it

Choosing the wrong workload type is the most expensive mistake to unwind later.
This file is the decision guide plus a production-ready template for each type.
Every template already carries the guardrails from `failure-modes.md` (non-root
`securityContext`, requests/limits, probes, dedicated ServiceAccount) — copy the
whole thing, don't reassemble from memory. Assumes **v1.29+**.

Deeper security detail lives in `security-hardening.md`; Services, storage classes,
and NetworkPolicy in `networking-storage.md`; good/bad diffs in
`examples-good-bad.md`.

## Decision guide

| Need | Use | Not this |
|---|---|---|
| Stateless replicas, any pod interchangeable | **Deployment** | StatefulSet (no stable identity needed) |
| Stable network ID + per-pod persistent storage + ordered start | **StatefulSet** | Deployment (loses identity/ordering) |
| Exactly one pod per node (log/metrics/CNI agent) | **DaemonSet** | Deployment with node anti-affinity (fragile) |
| Run to completion once | **Job** | Deployment (restarts forever) |
| Run to completion on a schedule | **CronJob** | Job + external cron (reinvents it) |

Rule of thumb: **default to Deployment.** Only escalate to StatefulSet when you
genuinely need stable identity or per-pod volumes — it is strictly harder to
operate (ordered rollouts, manual PVC cleanup, careful scaling).

---

## Deployment — stateless services

Use for: web servers, APIs, workers behind a queue — anything where replicas are
interchangeable and can be created/destroyed in any order.

Do NOT use when: pods need stable hostnames or their own persistent volume (→
StatefulSet), or must run one-per-node (→ DaemonSet).

Rollout strategy: `RollingUpdate` with `maxUnavailable: 0` / `maxSurge: 1` for
zero-downtime; switch to `Recreate` only when two versions can't coexist (e.g. an
exclusive lock or incompatible schema during migration) — Recreate causes a brief
full outage, which is the tradeoff.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: app
  labels: { app: api }
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  minReadySeconds: 10
  selector:
    matchLabels: { app: api }
  template:
    metadata:
      labels: { app: api }
    spec:
      serviceAccountName: api
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:            # spread replicas across nodes/zones
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: api }
      containers:
        - name: api
          image: registry.example.com/api@sha256:<digest>
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "256Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          startupProbe:
            httpGet: { path: /healthz, port: 8080 }
            failureThreshold: 30
            periodSeconds: 5
          readinessProbe:
            httpGet: { path: /readyz, port: 8080 }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 10
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: tmp
          emptyDir: {}
```

Pair every Deployment with a PodDisruptionBudget (see `failure-modes.md` §2) and,
where load varies, an `autoscaling/v2` HorizontalPodAutoscaler.

---

## StatefulSet — stable identity + per-pod storage

Use for: databases, Kafka/Zookeeper, anything where pod `foo-0` must always be
`foo-0`, reach the same volume, and start/stop in order.

What you get that a Deployment can't give: stable pod names (`web-0`, `web-1`),
stable DNS via a **headless Service**, ordered rolling updates, and a dedicated PVC
per pod from `volumeClaimTemplates`.

Do NOT use when: the app is stateless or stores state externally (managed RDS,
object storage) — a Deployment is simpler and safer. StatefulSets do **not**
auto-delete their PVCs on scale-down by default; you clean them up (or set
`persistentVolumeClaimRetentionPolicy`).

Rollout strategy: `RollingUpdate` updates pods **in reverse ordinal order**, one at
a time, waiting for each to be Ready. Use `partition` for staged/canary rollouts.
`podManagementPolicy: Parallel` speeds up initial scale-out but drops ordering
guarantees — only for peers that don't need ordered bring-up.

```yaml
apiVersion: v1
kind: Service                    # headless Service is REQUIRED for stable DNS
metadata:
  name: pg
  namespace: data
spec:
  clusterIP: None                # headless
  selector: { app: pg }
  ports: [{ name: pg, port: 5432, targetPort: 5432 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg
  namespace: data
spec:
  serviceName: pg                # must match the headless Service above
  replicas: 3
  podManagementPolicy: OrderedReady
  updateStrategy:
    type: RollingUpdate
    rollingUpdate: { partition: 0 }
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain          # keep data if the StatefulSet is deleted
    whenScaled: Retain
  selector:
    matchLabels: { app: pg }
  template:
    metadata:
      labels: { app: pg }
    spec:
      serviceAccountName: pg
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 999           # postgres uid
        fsGroup: 999             # so the mounted volume is group-writable
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: pg
          image: registry.example.com/postgres@sha256:<digest>
          ports: [{ containerPort: 5432, name: pg }]
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
            limits:   { cpu: "2",    memory: "1Gi" }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
            # readOnlyRootFilesystem often false for DBs; the data dir is a PVC,
            # give the process any other writable paths it needs via emptyDir.
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            periodSeconds: 10
          livenessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            periodSeconds: 15
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
  volumeClaimTemplates:          # one PVC per pod, named data-pg-0, data-pg-1, ...
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-ssd
        resources:
          requests: { storage: 20Gi }
```

Operational note: scaling a StatefulSet down does not delete PVCs (data is
retained on purpose). Track and reclaim orphaned PVCs deliberately. See
`networking-storage.md` for storage classes and access modes.

---

## DaemonSet — one pod per node

Use for: node-level agents — log shippers (Fluent Bit), metrics
(node-exporter), CNI/CSI plugins, security agents. The scheduler places exactly
one pod on every matching node and automatically adds one when a node joins.

Do NOT use when: you just want N replicas (→ Deployment). A DaemonSet's replica
count is "number of nodes," not something you set.

Rollout strategy: `RollingUpdate` with `maxUnavailable` (default 1) so upgrades
roll node-by-node. Set `maxUnavailable` higher to speed fleet-wide upgrades if the
agent can tolerate gaps. Node agents usually need **tolerations** to run on tainted
nodes (control-plane, GPU) and often a small **priorityClass** so they aren't
evicted first.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels: { app: node-exporter }
  updateStrategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 1 }
  template:
    metadata:
      labels: { app: node-exporter }
    spec:
      serviceAccountName: node-exporter
      automountServiceAccountToken: false
      priorityClassName: system-node-critical
      hostNetwork: false                 # only true if the agent truly needs it
      tolerations:                        # run everywhere, including control plane
        - operator: Exists
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534                  # nobody
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: node-exporter
          image: registry.example.com/node-exporter@sha256:<digest>
          args: ["--path.rootfs=/host/root"]
          ports: [{ containerPort: 9100, name: metrics }]
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "200m", memory: "128Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: root, mountPath: /host/root, readOnly: true }   # read-only host mount
      volumes:
        - name: root
          hostPath: { path: / }
```

Danger note: DaemonSets often mount the host filesystem or use `hostNetwork`. Every
such privilege breaks PSS `restricted`. Mount host paths **read-only**, keep the
scope minimal, and justify each escalation — a compromised privileged DaemonSet is a
node takeover. See `security-hardening.md`.

---

## Job — run once to completion

Use for: one-off tasks — a database migration, a batch import, a backfill. The Job
runs pods until `completions` succeed, then stops (unlike a Deployment, which
restarts forever).

Do NOT use for: long-running services (→ Deployment). Don't hand-roll retries — set
`backoffLimit` and let the Job controller handle them.

Patterns:
- Single task: omit `completions`/`parallelism` (defaults to 1/1).
- Fixed count: set `completions: N`, `parallelism: M`.
- Work queue: `parallelism: M`, no `completions`, pods exit 0 when the queue drains.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  namespace: app
spec:
  backoffLimit: 4                 # retry the pod up to 4 times, then fail the Job
  activeDeadlineSeconds: 600      # hard wall-clock cap
  ttlSecondsAfterFinished: 3600   # auto-clean finished Job + pods after 1h
  completions: 1
  parallelism: 1
  template:
    metadata:
      labels: { app: db-migrate }
    spec:
      serviceAccountName: db-migrate
      automountServiceAccountToken: false
      restartPolicy: Never        # Never or OnFailure — NOT Always (invalid for Jobs)
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: migrate
          image: registry.example.com/migrate@sha256:<digest>
          command: ["/app/migrate", "up"]
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

Note: `ttlSecondsAfterFinished` (GA) garbage-collects finished Jobs so they don't
pile up. `activeDeadlineSeconds` stops a wedged Job. Probes are usually pointless
for short Jobs — omit them.

---

## CronJob — scheduled Jobs

Use for: recurring batch — nightly backups, hourly report generation, periodic
cleanup. A CronJob creates a Job on a cron schedule.

Do NOT use for: sub-minute intervals (cron granularity is one minute; use a
long-running worker instead), or work that must not overlap without setting
`concurrencyPolicy`.

Key knobs:
- `concurrencyPolicy: Forbid` — skip a run if the previous is still going (default
  `Allow` can pile up overlapping runs and starve the node).
- `startingDeadlineSeconds` — if the controller was down, don't fire missed runs
  after this many seconds late.
- `successful/failedJobsHistoryLimit` — cap retained Job history.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-backup
  namespace: app
spec:
  schedule: "0 2 * * *"            # 02:00 daily
  timeZone: "Etc/UTC"             # explicit TZ (GA in 1.27+); default is controller TZ
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 3600
      ttlSecondsAfterFinished: 86400
      template:
        metadata:
          labels: { app: nightly-backup }
        spec:
          serviceAccountName: nightly-backup
          automountServiceAccountToken: false
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 10001
            seccompProfile: { type: RuntimeDefault }
          containers:
            - name: backup
              image: registry.example.com/backup@sha256:<digest>
              command: ["/app/backup.sh"]
              resources:
                requests: { cpu: "100m", memory: "128Mi" }
                limits:   { cpu: "500m", memory: "256Mi" }
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: { drop: ["ALL"] }
```

---

## Init containers and sidecars

**Init containers** run to completion, in order, **before** app containers start.
Use for setup that must finish first: waiting on a dependency, running a migration,
fetching config, fixing volume permissions. If an init container fails, the pod
restarts it (per `restartPolicy`) — the app never starts on a broken precondition.

```yaml
spec:
  initContainers:
    - name: wait-for-db
      image: registry.example.com/busybox@sha256:<digest>
      command: ["sh", "-c", "until nc -z pg.data 5432; do sleep 2; done"]
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
```

**Sidecars** run alongside the app for its whole life — proxies (Envoy), log
tailers, secret refreshers. On **v1.29+** use the native sidecar: an
`initContainers` entry with `restartPolicy: Always`. It starts before app
containers, stays running, and — critically — is torn down **after** the app
containers on shutdown, which the old "just add another container" approach never
guaranteed.

```yaml
spec:
  initContainers:
    - name: log-shipper           # native sidecar (v1.29+)
      image: registry.example.com/fluent-bit@sha256:<digest>
      restartPolicy: Always       # <-- this is what makes it a sidecar
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      volumeMounts:
        - { name: varlog, mountPath: /var/log, readOnly: true }
  containers:
    - name: app
      image: registry.example.com/app@sha256:<digest>
      volumeMounts:
        - { name: varlog, mountPath: /var/log }
  volumes:
    - name: varlog
      emptyDir: {}
```

On clusters older than v1.29, sidecars are plain extra `containers` — but then you
own the shutdown-ordering problem yourself. Prefer the native sidecar whenever the
cluster floor allows it.

---

## Cross-check

- Right type chosen (defaulted to Deployment unless identity/storage/per-node
  demanded otherwise)?
- Guardrails from `failure-modes.md` present on every template?
- StatefulSet has a headless Service + `serviceName`, and you've a plan for orphaned
  PVCs?
- DaemonSet host mounts are read-only and each privilege is justified?
- Job/CronJob use `restartPolicy: Never`/`OnFailure`, `backoffLimit`,
  `ttlSecondsAfterFinished`, and (CronJob) `concurrencyPolicy: Forbid`?
- Sidecars use native `restartPolicy: Always` on v1.29+?
