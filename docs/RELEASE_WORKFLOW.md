# Conforma release workflow

Prepare once, test the completed candidate, then publish it unchanged.
`images.json` identifies the exact policies, CLI and final Task/StepAction bundle
consumed by both acceptance and publication. The [annotated JSONC reference](RELEASE_WORKFLOW_V2_DESIGN.md#release-manifest)
explains every field; generated manifests use standard JSON.

## Prepare and review

Dispatch [Prepare release](../.github/workflows/prepare-release.yaml) on `main`
in `conforma/infra-deployments-ci`. The assembly job captures candidate digests,
source bundles, test inputs and publication baselines. It pins execution images
and Git StepAction commits, then builds the final bundle under a unique
`candidate-*` retention tag. External StepActions must already pin their runtime
images. Retain candidate tags for the lifetime of the release records.

A separate job generates the changelog without publication credentials.
Download its `release-pr-files` artifact and submit the timestamped directory
under `releases/` in a PR. It contains `images.json` and `changelog.md`.

Review image/source changes, policy rule changes, Golden image behavior, and
Task/StepAction catalog diffs. The PR check validates the manifest, prepared
execution references and retention tag. Newly introduced policy rules must have
at least 56 days of lead time, measured against the recorded baseline. Require
that check in branch protection.

Local preparation needs Bash 4+, Git, jq, Mike Farah yq, crane and tkn. Changelog
generation also needs gh, Go and a container engine:

```bash
./hack/prepare-release.sh /tmp/prepared-release
./hack/generate-changelog.sh /tmp/prepared-release/images.json releases/<id>

# Reproduce the changelog without selecting newer candidates:
./hack/generate-changelog.sh releases/<id>/images.json
./hack/check-release-inputs.sh releases/<id>/images.json
bash hack/check-release-lead-time.sh releases/<id>/images.json
```

Preparation requires Conforma registry write access. `configCommit` must be
available locally and configuration changes must be committed. Changelog
comparison uses the captured targets, OCI policy data, configuration and one
recorded evaluation time for both baseline and candidate. Behavior differences
are informational; operational failures fail generation.

## Acceptance

Merging the PR triggers [konflux-policy](../.github/workflows/konflux-policy.yaml).
A push must contain exactly one added or modified release manifest. Manual
dispatch on `main` can select a release directory explicitly.

The job checks out `configCommit` and runs the existing Go acceptance suite with
`RELEASE_IMAGES` pointing to the committed manifest and `RELEASE_CATALOG` to
files extracted from its final bundle. No test source files are rewritten.
It uses no publication credentials and covers:

- Golden container and RPM through both verification Tasks, using manifest pins.
- Valid, populated `TEST_OUTPUT`, plus the Trusted Artifacts VSA archival path.
- Missing, disabled and enabled keyless configuration in the auxiliary Task.
- Successful and failed registry operations in the attestation StepAction.
- Positive and negative inputs for task-policy and build-task-policy rules.

Auxiliary script tests use the actual runtime images and stub external commands.
Adding a released resource requires an explicit test case. Acceptance captures
one fresh evaluation time per run and uploads reports and logs. `STRICT=false`
keeps policy findings reviewable; operational failures still fail acceptance.

For local reproduction, check out the recorded configuration, extract the final
bundle with `extract-bundle-resources.sh` (both `task tasks` and
`stepaction stepactions`), then run `make acceptance` with absolute paths in
`RELEASE_IMAGES` and `RELEASE_CATALOG`. Install Kind and Kustomize as well as the
tools above. With Podman on macOS, set `KIND_EXPERIMENTAL_PROVIDER=podman`.

Private test inputs need the `REGISTRY_READ_AUTH_JSON` secret: a Docker config
JSON containing read-only credentials. Acceptance mounts it through a dedicated
test service account. The configured Golden RPM repository requires access.
Locally, set `REGISTRY_AUTH_FILE` to a read-only Docker config and `DOCKER_CONFIG`
to its directory (the file must be named `config.json`).

## Publication and retries

Publication depends on successful acceptance and reads the same committed
manifest. The workflow is serialized and cannot cancel an active publication.
It promotes eight `:konflux` tags: three Conforma policies, their three
enterprise-contract mirrors, the CLI, and the final Task bundle. It also copies
exact bundle files to `conforma/tekton-catalog` branch `konflux`.

Before any write, it checks every destination against the candidate and recorded
baseline. Candidate content is skipped; baseline content is updated; anything
else or a read failure stops publication. Image copies preserve digests. Catalog
updates preserve unrelated files and older versions and never force push.
Final verification and the publication log show the resulting digests and
catalog commit.

Registry and Git updates are not atomic. Rerun a failed workflow or manually
dispatch the same release to finish partial publication. Already-applied content
is skipped, including after a lost Git push acknowledgement. A conflict requires
inspection and a new reviewed manifest; do not edit a historical release record.
A deliberate rollback also needs a new manifest with current baselines and
retained historical candidates, followed by normal acceptance.

Preparation uses `BUNDLE_PUSH_USER_CONFORMA` / `BUNDLE_PUSH_PASS_CONFORMA`.
Publication additionally uses the corresponding `_EC` pair and
`EC_AUTOMATION_APP_ID` / `EC_AUTOMATION_KEY` for catalog writes. Other automation
must not independently write these release destinations.

The separate [infra-deployments PR workflow](../.github/workflows/create-pr.yaml)
is unchanged. This release ends at registry tags and catalog updates.
