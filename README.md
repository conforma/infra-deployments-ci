# infra-deployments-ci

Keep infra-deployments updated with the latest Enterprise Contract components.

## Generate a policy behavior changelog

`hack/generate-changelog.sh` retains its existing release flow: it compares
the current `:konflux` images with the candidate `:latest` images, writes
`changelog.md` and `images.json` to the requested release directory, and now
also appends a `Policy Behavior Changes` section to the changelog. That section
validates the Golden container and Golden RPM targets four times in total.
Policy behavior differences are informational; failed image pulls, invalid
policy configuration, command failures, and malformed reports return an error.

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
- `yq` for rendering the per-run EnterpriseContractPolicy;
- Git for source revision lookups;
- Go for the policy rule diff helper; and
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

The existing image, source-commit, and policy-rule sections continue comparing
`:konflux` with `:latest`. The generated `images.json` records the candidate
digests exactly as before. The behavior comparison then uses the current
`:konflux` CLI and release policy together with the candidate CLI and policy
digests from that generated file. The release files are created before the
behavior comparison, so they remain available for review if that final step
reports an operational error.

The comparison uses:

- the current `quay.io/conforma/cli:konflux` and
  `oci::quay.io/conforma/release-policy:konflux` references;
- the exact candidate CLI and policy digests from the generated `images.json`;
- digest-pinned Golden container and Golden RPM images resolved during the
  comparison;
- the policy data configured by `hack/policy-behavior/golden-policy.yaml`; and
- a rendered policy file whose `spec.sources[0].policy` matches the release and
  whose `spec.sources[0].config.include` matches the target image.

Run the generator from the repository root:

```bash
./hack/generate-changelog.sh
./hack/generate-changelog.sh releases/my-candidate
./hack/generate-changelog.sh -
```

The final form writes the changelog to stdout and does not publish
`images.json`. For a direct behavior comparison, provide a generated candidate
manifest:

```bash
./hack/policy-behavior/compare-policy-behavior.sh \
  --container-engine podman \
  releases/my-candidate/images.json
```

The comparison report retains uncoded failures by their message and
deduplicates results repeated across multi-architecture components. A warning
that becomes a violation appears in both the removed-warnings and
added-violations rows.

### Verification

Run the shell syntax checks and the ShellSpec suite from the repository root:

```bash
bash -n hack/generate-changelog.sh
bash -n hack/policy-behavior/compare-policy-behavior.sh
shellspec
```
