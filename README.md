# infra-deployments-ci

Keep infra-deployments updated with the latest Enterprise Contract components.

For the complete release process from changelog generation through image and
Tekton task publication, see [the release workflow guide](docs/RELEASE_WORKFLOW.md).

## Prepare a release and generate its changelog

Release preparation and changelog generation are separate steps.
`hack/prepare-release.sh <new-release-directory>` pins every release input
once: the three policies, the CLI, the source task bundle and the StepAction
bundle are resolved to digests, the task definitions are extracted and pinned
(CLI image, `POLICY_BUNDLE_DIGEST`, Git-resolver StepAction revisions), and
the assembled candidate task bundle is pushed under a unique `candidate-*`
retention tag. The result is a v2 `images.json` that acceptance testing and
publication both consume as the single source of truth.

`hack/generate-changelog.sh <images.json> [output-dir|-]` renders the
changelog from that manifest. It never re-resolves a candidate: every digest
it prints comes from `images.json`, and it appends a `Policy Behavior
Changes` section to the changelog. That section validates the Golden container
and Golden RPM targets four times in total. Policy behavior differences are
informational; failed image pulls, invalid policy configuration, command
failures, and malformed reports return an error.

The target images, display names, and policy collections are defined in
[`hack/policy-behavior/targets.json`](hack/policy-behavior/targets.json).
Each validation mounts
[`hack/policy-behavior/golden-policy.yaml`](hack/policy-behavior/golden-policy.yaml)
and injects the release-policy reference for that run and the collection for
that target.

### Prerequisites

The workflow requires:

- Bash, Docker or Podman, and `CONTAINER_ENGINE` when the engine is not Docker;
- `crane` for resolving immutable image digests;
- `jq` for JSON processing;
- `yq` for rendering the per-run EnterpriseContractPolicy and pinning task
  definitions;
- Git for source revision lookups;
- Go for the policy rule diff helper;
- `tkn` and push credentials for `quay.io/conforma` to push the candidate
  task bundle during preparation; and
- GitHub CLI (`gh`) for changelog pull-request titles.

The container engine must be running and able to pull from Quay. Anonymous
pulls are normally sufficient. If registry authentication is required, set
`REGISTRY_AUTH_FILE` to a Docker-compatible auth file; it is mounted read-only
inside the validation container. Set `REGISTRY_AUTH_DEST` if the container
engine expects the auth file at a different path.

Examples:

```bash
# Docker (the default)
docker info
unset CONTAINER_ENGINE

# Podman
podman info
export CONTAINER_ENGINE=podman

# Optional authenticated pulls
export REGISTRY_AUTH_FILE="$HOME/.docker/config.json"
```

### Release output and comparison inputs

The changelog's image, source-commit, and policy-rule sections compare the
current `:konflux` images with the candidate digests recorded in the
manifest. `images.json` is written by `prepare-release.sh`; the changelog
generator only reads it. The behavior comparison then uses the current
`:konflux` CLI and release policy together with the candidate CLI and policy
digests from that manifest. The changelog is written before the behavior
comparison, so it remains available for review if that final step reports an
operational error.

The comparison uses:

- the current `quay.io/conforma/cli:konflux` and
  `oci::quay.io/conforma/release-policy:konflux` references;
- the exact candidate CLI and policy digests from the prepared `images.json`;
- digest-pinned Golden container and Golden RPM images resolved during the
  comparison;
- the policy data configured by `hack/policy-behavior/golden-policy.yaml`; and
- a rendered policy file whose `spec.sources[0].policy` matches the release and
  whose `spec.sources[0].config.include` matches the target image.

Run both steps from the repository root:

```bash
./hack/prepare-release.sh releases/my-candidate
./hack/generate-changelog.sh releases/my-candidate/images.json
```

The changelog can also be written to stdout or to another directory:

```bash
./hack/generate-changelog.sh releases/my-candidate/images.json -
./hack/generate-changelog.sh releases/my-candidate/images.json path/output/
```

For a direct behavior comparison, provide a prepared candidate
manifest:

```bash
./hack/policy-behavior/compare-policy-behavior.sh \
  --container-engine podman \
  releases/my-candidate/images.json
```

To compare two generated releases directly, provide both manifests:

```bash
./hack/policy-behavior/compare-policy-behavior.sh \
  --container-engine podman \
  releases/2026-08-11T17:36:11/images.json \
  releases/2026-09-10T17:30:44/images.json
```

The comparison report retains uncoded failures by their message and
deduplicates results repeated across multi-architecture components. A warning
that becomes a violation appears in both the removed-warnings and
added-violations rows.

### Verification

Run the shell syntax checks and the ShellSpec suite from the repository root:

```bash
bash -n hack/generate-changelog.sh
bash -n hack/prepare-release.sh
bash -n hack/policy-behavior/compare-policy-behavior.sh
shellspec
```
