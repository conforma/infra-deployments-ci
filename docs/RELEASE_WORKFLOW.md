# Acceptance Tests + Release Workflow for Tekton Catalog

## Goal

Test the latest Conforma task definitions and CLI image together, then release tested tasks to the `conforma/tekton-catalog` repository on a scheduled cadence.

## How It Works

### The Bundle Is the Source of Truth

The Tekton task bundle (`quay.io/conforma/tekton-task:latest`) already contains the latest task definitions built with the latest CLI image. This single artifact is used for both testing and release — ensuring what we test is exactly what we ship.

### Workflow Overview

A single GitHub Actions workflow (`konflux-policy.yaml`) runs on a schedule and performs three jobs:

```
                    ┌──────────────────────┐
                    │  Acceptance Tests    │
                    │  (make acceptance)   │
                    └──────────┬───────────┘
                               │
                    ┌──────────┴───────────┐
                    │    tests pass        │
                    ├──────────┬───────────┤
                    ▼                      ▼
        ┌───────────────────┐  ┌───────────────────────┐
        │   Tag Policies    │  │  Tekton Catalog        │
        │   & Bundle        │  │  Release               │
        │   :latest →       │  │  Extract tasks from    │
        │   :konflux        │  │  bundle → PR to        │
        │                   │  │  tekton-catalog         │
        └───────────────────┘  └───────────────────────┘
```

**Job 1 — Acceptance Tests:** Spins up a KinD cluster, installs Tekton and a local OCI registry, then runs all test scenarios against the latest bundle. Both `verify-enterprise-contract` and `verify-conforma-konflux-ta` tasks are tested.

**Job 2 — Tag (runs after tests pass):** Tags `:latest` policy bundles and the tekton-task bundle to `:konflux`, promoting them for use in Konflux.

**Job 3 — Tekton Catalog Release (runs after tests pass):** Extracts the tested task definitions from the bundle, formats them as YAML, and creates a PR to the `konflux` branch of `conforma/tekton-catalog`.

### Adding a New Task to the Release

No configuration changes needed. Just:

1. Add a feature file with a test scenario for the new task
2. Add a pipeline definition in `acceptance/` that references the task from the bundle

The release script automatically discovers which tasks are tested by parsing the pipeline definitions for bundle references. If tests pass, those tasks are extracted and included in the PR.

## What Was Implemented

### Acceptance Test for `verify-conforma-konflux-ta`

The `verify-conforma-konflux-ta` task uses Trusted Artifacts — it expects its input snapshot to be delivered as an OCI artifact rather than as a direct parameter. To test this end-to-end:

- A **local OCI registry** (`registry:2`) runs in the KinD cluster
- A **prepare-snapshot** task writes the snapshot JSON and pushes it to the local registry as a Trusted Artifact
- The **verify-conforma-konflux-ta** task (from the bundle) fetches the artifact and validates the snapshot

This exercises the real Trusted Artifacts flow with no shortcuts.

### Task Extraction from Bundle

The script `hack/extract-tested-tasks.sh`:

1. Parses the acceptance pipeline YAMLs to find which task names are referenced via bundle resolver
2. Pulls the bundle manifest and extracts matching task layers using `crane`
3. Formats the YAML and writes to the catalog layout: `tasks/<task-name>/<version>/<task-name>.yaml`

## Files

| File | Purpose |
|------|---------|
| `features/validate_golden.feature` | Tests `verify-enterprise-contract` task |
| `features/validate_golden_ta.feature` | Tests `verify-conforma-konflux-ta` task |
| `acceptance/conforma.yaml` | Pipeline definition for non-TA test |
| `acceptance/conforma-ta.yaml` | Pipeline definition for TA test (prepare + verify) |
| `acceptance/prepare-snapshot.yaml` | Task that creates a Trusted Artifact from snapshot JSON |
| `hack/registry/` | Local OCI registry deployment for KinD |
| `hack/extract-tested-tasks.sh` | Extracts tested tasks from bundle in catalog layout |
| `.github/workflows/konflux-policy.yaml` | Single workflow: test → tag + release |
