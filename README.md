# infra-deployments-ci

Keep infra-deployments updated with the latest Enterprise Contract components.

## Generate a policy behavior changelog

`hack/generate-changelog.sh` compares the CLI and release policy digests in the
previous release's `images.json` with the candidate digests resolved from the
new `:latest` images. It validates the Golden container and Golden RPM targets
four times in total, then adds a `Policy Behavior Changes` section to the
changelog. Policy behavior differences are informational; failed image pulls,
invalid policy configuration, command failures, and malformed reports stop
generation.

The target images, display names, and policy collections are defined in
[`hack/policy-behavior/targets.json`](hack/policy-behavior/targets.json).
Each validation mounts [`golden-policy.yaml`](golden-policy.yaml) and injects
the release-policy reference for that run and the collection for that target.

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

### Release reference selection

At the start of generation, every candidate `:latest` image listed by the
release configuration is resolved exactly once and recorded in a temporary
`images.json`. The previous release's `images.json` is selected from the latest
timestamped release directory; non-final directories such as `my-candidate`
are ignored. Set `POLICY_BEHAVIOR_OLD_IMAGES_FILE` to override that selection.
All later operations use digest-pinned references from the old and new
manifests. On success, the new file is published as the release's `images.json`;
neither it nor `changelog.md` is published after a failed run.

The comparison uses:

- the exact digest-pinned CLI and policy references from the old
  `images.json`;
- the exact digest-pinned CLI and policy references from the new
  `images.json`;
- digest-pinned Golden container and Golden RPM images resolved during the
  comparison;
- the policy data configured by `golden-policy.yaml`; and
- a rendered policy file whose `spec.sources[0].policy` matches the release and
  whose `spec.sources[0].config.include` matches the target image.

Run the generator from the repository root:

```bash
./hack/generate-changelog.sh
./hack/generate-changelog.sh releases/my-candidate
./hack/generate-changelog.sh -
```

The final form writes the changelog to stdout and does not publish
`images.json`. For a direct behavior comparison, provide the old and new
manifests:

```bash
./hack/policy-behavior/compare-policy-behavior.sh \
  --container-engine podman \
  releases/2026-08-11T17:36:11/images.json \
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
