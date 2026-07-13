# OpenShift — Essentials (High-Impact Differences)

> Loaded only when an OpenShift signal is detected (e.g. `oc` in use, `Route`/`DeploymentConfig`/
> `ImageStream` objects, `*.apps.<cluster>` hostnames, SCC-related admission denials, or
> `route.openshift.io` / `apps.openshift.io` API groups).

## What flips vs vanilla Kubernetes

| Concern | Vanilla | On OpenShift |
|---|---|---|
| Pod security | PSA labels, you can run as any UID | **SCCs** — by default pods run as a **random high UID**; `runAsUser` is usually rejected |
| External L7 | Ingress | **Route** (older, richer) *and* Ingress (Routes back it) |
| CLI | `kubectl` | `oc` (superset: adds projects, routes, image streams, `oc new-app`) |
| Namespaces | Plain | **Projects** — namespace + default quotas/SCC/RBAC guardrails |
| Images | Pull external only | **ImageStreams** — internal registry + build/rollout triggers |
| Deployments | `Deployment` | `Deployment` (preferred) *or* legacy `DeploymentConfig` |

## Security Context Constraints (SCCs) — the big one

SCCs are OpenShift's admission-level pod security policy (predates and is stricter than PSA). The default `restricted-v2` SCC assigns each project a **random UID range** and runs your container as an arbitrary high UID (e.g. `1000680000`), **not** the image's declared user.

Consequences for images that "work on vanilla":

```yaml
# WRONG on OpenShift restricted-v2 — hardcoding a UID gets denied or fails
securityContext:
  runAsUser: 1000        # SCC won't allow arbitrary runAsUser under restricted-v2

# RIGHT — leave runAsUser UNSET; let OpenShift inject a UID from the project range
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities: { drop: ["ALL"] }
  seccompProfile: { type: RuntimeDefault }
```

**Build images to be arbitrary-UID-safe:**
- Don't assume UID 0 or a specific UID.
- Make writable dirs group-writable and owned by GID **0** (`chgrp -R 0 /app && chmod -R g=u /app`) — OpenShift always runs with supplementary group 0.
- Don't bind ports < 1024 (non-root can't).

Only grant a looser SCC when genuinely required (e.g. a workload that must run as a fixed UID or needs host access):
```bash
oc adm policy add-scc-to-user anyuid -z my-sa -n my-project   # last resort, least privilege
```
Inspect: `oc get scc`, `oc describe scc restricted-v2`.

## Routes vs Ingress

**Route** is OpenShift's native external-access object, backed by the built-in HAProxy router. Richer TLS handling than plain Ingress (edge / passthrough / re-encrypt):
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata: { name: web }
spec:
  host: web.apps.mycluster.example.com
  to: { kind: Service, name: web }
  tls: { termination: edge }        # or passthrough / reencrypt
```
Standard `Ingress` objects also work — OpenShift auto-creates backing Routes. Use Route when you need passthrough/re-encrypt or router-specific features; Ingress for portability.

## oc vs kubectl

`oc` is a superset of `kubectl` — every `kubectl` verb works, plus OpenShift extras:
```bash
oc login --token=... --server=https://api.mycluster:6443
oc new-project payments                 # creates a Project (namespaced guardrails)
oc new-app python:3.12~https://github.com/org/app.git   # S2I build + deploy
oc get routes
oc adm policy add-role-to-user edit alice -n payments
```

## ImageStreams

An **ImageStream** tracks image tags in the internal registry and can **trigger rebuilds/rollouts** when an upstream tag changes — decoupling deploys from registry pulls. Common with S2I (Source-to-Image) builds. On plain K8s you'd just reference a registry image directly; on OpenShift, ImageStreams give you triggers, promotion, and local caching.

## DeploymentConfig vs Deployment

- **`Deployment`** (standard K8s) — **preferred for new work**.
- **`DeploymentConfig`** (legacy, `apps.openshift.io`) — adds ImageStream-trigger-driven rollouts and lifecycle hooks, but is deprecated. Migrate to `Deployment` unless you specifically need DC triggers.

## Projects = namespaces with guardrails

A **Project** is a namespace plus OpenShift defaults: an assigned SCC, default `ResourceQuota`/`LimitRange`, and RBAC. `oc new-project` (not `kubectl create namespace`) sets these up. Self-service project creation and multi-tenant isolation are stronger than a bare namespace.

## Quick operating notes

- Control plane is managed on ROSA/ARO (AWS/Azure) or self-run on bare OpenShift — either way, follow SCC + Route + Project conventions.
- First failure to check on a "works elsewhere" image: **SCC denial** (`unable to validate against any security context constraint`) → fix the image for arbitrary UID, don't just widen the SCC.
