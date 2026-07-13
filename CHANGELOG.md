# Changelog

All notable changes to the `kubernetes-mastery` plugin are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and this
project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-13

### Added
- Initial release with three skills:
  - **k8s-concepts** — the founder/company mental model for reasoning about
    Kubernetes architecture, with `mental-models`, `concept-map`, and `glossary`
    references.
  - **k8s-authoring** — failure-mode-first manifest design and review (7-step
    workflow, six failure modes, output contract), with references for workload
    patterns, security hardening, networking/storage, packaging/validation, and
    annotated good/bad examples.
  - **k8s-operating** — read-only-by-default live-cluster triage, with playbooks,
    kubectl recipes, audit checklists, and safety guardrails.
- Shared conditional cloud references (`references/conditional/`): full **EKS**
  and **GKE** guides, brief **AKS** and **OpenShift** notes, loaded only when a
  platform signal is detected.
- `scripts/validate.sh` — structural check for frontmatter and reference links.
