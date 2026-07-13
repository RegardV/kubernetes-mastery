# Packaging & Validation

How manifests are packaged (Helm vs Kustomize) and how they're validated before
apply — the last line of defence against the **API drift** and cross-resource
consistency failures, and the enforcement point for everything in
`security-hardening.md` and `networking-storage.md`. Version floor: **v1.29+**,
Helm **v3**.

---

## 1. Helm vs Kustomize

Two different philosophies. **Helm** = templated packages with
lifecycle/release management. **Kustomize** = template-free overlays that patch
a plain-YAML base. Both are first-class; `kubectl` ships Kustomize built in
(`-k`), Helm is a separate binary.

### Helm

Package manager: a **chart** renders templates with **values**, installs as a
named **release**, and tracks revisions for upgrade/rollback.

```
mychart/
├── Chart.yaml            # name, version, appVersion, dependencies
├── values.yaml           # default values (the public API of the chart)
├── templates/
│   ├── deployment.yaml   # Go-template over .Values / .Release / .Chart
│   ├── service.yaml
│   ├── _helpers.tpl      # named template helpers (labels, names)
│   └── NOTES.txt         # post-install message
└── charts/               # vendored subchart dependencies
```

```yaml
# templates/deployment.yaml (excerpt)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "mychart.fullname" . }}
  labels: {{- include "mychart.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}@{{ .Values.image.digest }}"
          resources: {{- toYaml .Values.resources | nindent 12 }}
```

**Templating pitfalls:**

- **Whitespace / indentation.** Go templates are string substitution — wrong
  `nindent`/`indent` produces invalid YAML that only fails at apply. Use
  `{{- ... }}`/`{{ ... -}}` to trim, and `toYaml ... | nindent N` for nested
  maps. Always render before trusting.
- **Types.** `{{ .Values.port }}` where port is `8080` may emit an int where a
  string is required (or vice versa). Use `quote` / `| toString` deliberately.
- **Missing values.** A typo'd `.Values.reelicaCount` renders empty, not an
  error, unless you use `required "message" .Values.x` or `--strict`.
- **`.Release.Namespace`** is only correct if you actually pass `-n`; templates
  that hardcode namespaces break multi-env installs.
- **Subchart value plumbing** is a frequent source of "why didn't my override
  apply" — parent values must be nested under the subchart's name.

**Core commands:**

```bash
helm lint ./mychart                       # static chart checks
helm template rel ./mychart -f prod.yaml  # render WITHOUT a cluster -> inspect real YAML
helm install rel ./mychart -n payments -f prod.yaml
helm upgrade rel ./mychart -n payments -f prod.yaml --atomic  # rollback on failure
helm diff upgrade rel ./mychart -f prod.yaml   # (helm-diff plugin) preview changes
helm rollback rel 1 -n payments           # revert to a prior revision
```

`helm template` is the key validation hook: it emits the exact manifests, which
you then feed to `kubeconform`/`kubectl --dry-run` (below).

### Kustomize

Template-free: a **base** of plain manifests + **overlays** that patch per
environment. No logic, no functions — just declarative merges. Easier to read
and grep; less powerful for heavy parameterization.

```
app/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── staging/
    │   └── kustomization.yaml
    └── prod/
        ├── kustomization.yaml
        └── replicas-patch.yaml
```

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
commonLabels:
  app.kubernetes.io/name: web
---
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: payments
resources:
  - ../../base
patches:
  - path: replicas-patch.yaml          # strategic-merge patch
    target: { kind: Deployment, name: web }
images:
  - name: web
    newName: registry.example.com/web
    digest: sha256:abc123...            # pin image without editing base
configMapGenerator:
  - name: web-config
    literals: [LOG_LEVEL=info]          # hashed name -> triggers rollout on change
```

**Patch types:** strategic-merge (default, merges by field/list key),
JSON 6902 (`op: replace/add/remove` at a path — precise, used for lists),
and `patchesStrategicMerge`/`patches` targeting.
**Generators:** `configMapGenerator`/`secretGenerator` append a content hash to
the name, so changing config produces a new name and forces a pod rollout — a
feature Helm lacks natively.

```bash
kustomize build overlays/prod           # render (or: kubectl kustomize)
kubectl apply -k overlays/prod          # build + apply
```

### When to use which

| Prefer **Helm** when | Prefer **Kustomize** when |
|---|---|
| Distributing a chart to third parties / a registry | Managing your own manifests across a few environments |
| Rich parameterization, conditionals, loops | You want plain, greppable YAML with no template logic |
| You need release tracking + `rollback` | GitOps where the rendered output is reviewed in PRs |
| Consuming upstream charts (ingress-nginx, cert-manager) | Small, targeted per-env diffs (replicas, image, ns) |

They compose: `helm template` a chart, then post-render with Kustomize; or use
a chart as a Kustomize `helmCharts` source. Don't over-engineer — pick one as
the primary and only reach for the combo when a real need appears.

---

## 2. Validation pipeline

Layered, cheapest first. Each catches a different class of defect.

### a. Schema validation — `kubeconform`

Validates every resource against the Kubernetes OpenAPI schema **offline** (no
cluster). Catches API drift, wrong field names/types, removed apiVersions.
Replaces the unmaintained `kubeval`.

```bash
# Render then validate (works for Helm and Kustomize output)
helm template rel ./mychart -f prod.yaml | kubeconform -strict -summary -
kustomize build overlays/prod          | kubeconform -strict -summary \
    -kubernetes-version 1.29.0 \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceVersion}}.json' \
    -
```

- `-strict` — reject unknown/misspelled fields (default is lenient).
- `-kubernetes-version` — validate against your cluster's minor to catch APIs
  removed in that version.
- extra `-schema-location` — resolve CRDs (Gateway API, cert-manager, etc.).

### b. Server-side dry run — `kubectl apply --dry-run=server`

Sends the manifest to the API server, which runs **admission** (including Pod
Security Admission, validating/mutating webhooks, quota) but does **not**
persist. Catches what offline schema checks can't: PSS violations, webhook
rejections, immutable-field conflicts, defaulting.

```bash
kubectl apply --dry-run=server -f rendered.yaml
# or straight from the packager:
kustomize build overlays/prod | kubectl apply --dry-run=server -f -
```

Use `--dry-run=client` only for local syntax sanity — it skips admission and so
misses the PSS/webhook failures that matter most.

### c. Diff against live — `kubectl diff`

Shows exactly what would change vs the running cluster before you apply — the
review gate for GitOps.

```bash
kustomize build overlays/prod | kubectl diff -f -
```

### d. Policy engines — Kyverno / OPA-Gatekeeper / conftest

Schema validation says a manifest is *well-formed*; policy says it's *allowed*
(e.g. "must set `runAsNonRoot`", "no `:latest`", "requests/limits required",
"only approved registries"). This is where the guardrails from
`security-hardening.md` get **enforced**, not just recommended.

- **Kyverno** — Kubernetes-native policies as YAML CRDs; can `validate`,
  `mutate` (inject defaults), and `generate`. Easiest to author.
- **OPA / Gatekeeper** — policies in Rego via `ConstraintTemplate` +
  `Constraint`; powerful, steeper curve.
- **conftest** — runs Rego against YAML/JSON **files in CI**, no cluster needed.

**Audit vs enforce** — always onboard in audit first:

- **Audit** — violations are reported (Gatekeeper `enforcementAction: dryrun`,
  Kyverno `validationFailureAction: Audit`) but resources still admit. Use to
  measure blast radius before turning it on.
- **Enforce** — violations are **rejected** at admission (Kyverno
  `validationFailureAction: Enforce`). Flip only after audit is clean.

```yaml
# Kyverno: require runAsNonRoot on all pods. Start in Audit, then Enforce.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-non-root
spec:
  validationFailureAction: Audit          # -> Enforce once clean
  background: true
  rules:
    - name: check-runasnonroot
      match:
        any:
          - resources: { kinds: [Pod] }
      validate:
        message: "runAsNonRoot must be true"
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): true
            containers:
              - =(securityContext):
                  =(runAsNonRoot): true
```

```bash
# Same policy, offline in CI (no cluster):
kustomize build overlays/prod | kyverno apply require-run-as-non-root.yaml --resource -
conftest test rendered.yaml -p policy/     # Rego policies under policy/
```

### e. Cross-resource consistency

Schema/PSS validate each object in isolation; they will **not** catch a Service
`selector` that matches no Pod, or a `targetPort` that no container exposes.
These pass every dry-run and then silently route nowhere. Check the wiring:

- Service `spec.selector` ⊆ Pod template `labels`.
- Service `targetPort` ↔ a container `ports.containerPort` (or its named port).
- Ingress/HTTPRoute `backend.service.name` + `port` ↔ an existing Service + port.
- StatefulSet `spec.serviceName` ↔ an existing headless Service.
- NetworkPolicy `podSelector` ↔ labels of the pods it's meant to govern.
- ServiceAccount referenced by workloads actually exists in the namespace.

A quick label/selector sanity check:

```bash
# Does the web Service actually select running pods?
kubectl get endpoints web -n payments -o wide   # empty ENDPOINTS = broken selector
```

---

## 3. Minimal CI snippet

Fail the pipeline before anything reaches a cluster. Renders both packagers,
runs schema + policy offline, then a server-side dry run against a throwaway
cluster (kind/k3d) that has PSA labels and any admission webhooks installed.

```yaml
# .github/workflows/manifests.yaml
name: validate-manifests
on: [pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install tools
        run: |
          curl -sL https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz | tar xz
          sudo mv kubeconform /usr/local/bin/
          curl -sL https://github.com/open-policy-agent/conftest/releases/latest/download/conftest_Linux_x86_64.tar.gz | tar xz
          sudo mv conftest /usr/local/bin/

      - name: Render
        run: kubectl kustomize overlays/prod > rendered.yaml

      - name: Schema (kubeconform)
        run: kubeconform -strict -summary -kubernetes-version 1.29.0 rendered.yaml

      - name: Policy (conftest / OPA, audit=fail in CI)
        run: conftest test rendered.yaml -p policy/

      - name: Server-side dry run
        run: |
          kubectl apply --dry-run=server -f rendered.yaml   # needs a kubeconfig (kind/k3d step)
```

Order matters: `kubeconform` (ms, no cluster) → `conftest`/`kyverno apply`
(offline policy) → `--dry-run=server` (needs a cluster, catches admission). Keep
the expensive server step last so cheap checks fail fast. Mirror the *same*
policies here that run in `enforce` mode on the cluster, so a PR can't merge a
manifest the cluster will later reject.
