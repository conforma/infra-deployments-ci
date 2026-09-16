# infra-deployments-ci

Keep infra-deployments updated with the latest Enterprise Contract components.

## Generate a policy behavior changelog

`hack/generate-changelog.sh` compares the current `:konflux` Conforma CLI and
release policy with the candidate digests resolved from the candidate `:latest`
images. It validates the Golden container and Golden RPM targets four times in
total, then adds a `Policy Behavior Changes` section to the changelog. Policy
behavior differences are informational; failed image pulls, invalid policy
configuration, command failures, and malformed reports stop generation.

The target images, display names, and policy collections are defined in
[`hack/policy-behavior/targets.json`](hack/policy-behavior/targets.json).

### Prerequisites

The workflow requires:

- Bash, Docker or Podman, and `CONTAINER_ENGINE` when the engine is not Docker;
- `crane` for resolving immutable image digests;
- `jq` for JSON processing;
- Git for resolving the `rhtap-ec-policy` data revision;
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

### Release reference selection

At the start of generation, every candidate `:latest` image listed by the
release configuration is resolved exactly once and recorded in a temporary
`images.json`. All later candidate operations use those digest-pinned
references. On success, that same file is published as the release's
`images.json`; neither it nor `changelog.md` is published after a failed run.

The comparison uses:

- `quay.io/conforma/cli:konflux` and
  `oci::quay.io/conforma/release-policy:konflux` for the current release;
- the exact `quay.io/conforma/cli@sha256:...` and
  `oci::quay.io/conforma/release-policy@sha256:...` references from the
  generated candidate `images.json`;
- digest-pinned Golden container and Golden RPM images resolved during the
  comparison;
- one resolved revision of `rhtap-ec-policy`; and
- one digest-pinned acceptable-bundles data image.

Run the generator from the repository root:

```bash
./hack/generate-changelog.sh
./hack/generate-changelog.sh releases/my-candidate
./hack/generate-changelog.sh -
```

The final form writes the changelog to stdout and does not publish
`images.json`. For a direct behavior comparison, provide the generated
candidate file:

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
