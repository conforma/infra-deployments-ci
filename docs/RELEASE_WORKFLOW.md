# Release Conforma to Konflux

## The Big Picture

A Conforma release updates the tools Konflux uses to verify application images. An [integration pipeline][integration-verify] can check a team's images after a build, and a [managed release pipeline][managed-pipeline] can check the same images again before they ship. In both cases, a Tekton task runs the Conforma command-line tool (CLI) against the policy configured for that workload.

**The default integration test follows a bundle tag. Managed releases pin a Git commit.** The [publication workflow][publish-code] publishes CLI and policy images to Quay and delivers the task definitions as both a Quay bundle and YAML files in Git. As soon as the workflow [moves the bundle's `:konflux` tag][example-bundle-step], a new integration run can use the release. The digest identifies the exact bundle that ran. Managed releases adopt the new task commit separately, so the two pipelines can check the same snapshot with different Conforma versions.

## Lifecycle Flow

Merging the proposal starts publication. The two consumer paths are independent:

```text
Release PR merges to main in conforma/infra-deployments-ci
  -> konflux-policy: run acceptance tests, tag CLI and policies, prepare tasks
      |
      +-- Quay: tag the rebuilt task bundle :konflux
      |   -> new integration run loads the pipeline from conforma/tekton-catalog on main
      |   -> compare the bundle digest its tasks resolved with the published digest
      |
      `-- Git: commit on the konflux branch of conforma/tekton-catalog
          -> update the task commit in release-service-catalog on development
          -> promote to staging, validate, then promote to production
          -> verify a new managed release run
```

**Follow one release:** [release proposal #261][proposal] contains the November 2 changelog and image manifest. Its [publication run][example-run] produced [task-catalog commit `ffb55a3`][example-commit]. [Release Service PR #2722][managed-pr] then pinned that commit in the managed pipelines on `development`. This is where the PR handoff ends: `staging` and `production` each need a separate branch promotion. A new workload run shows when that workload adopted the release.

## Key Roles & Ownership

| Owner | Decision or handoff |
| --- | --- |
| Conforma release engineer | Prepares the proposal, verifies publication and records the bundle digest, image digests and task-catalog commit. Shares that record with workload owners and prepares the managed catalog update. |
| Conforma reviewers | Review the rule changes and decide whether new warnings or violations are expected. The [lead-time check on #261][lead-example] illustrates the automated part: CI checks effective dates for new rules. |
| Conforma catalog maintainers | Review sync PRs from `conforma/cli`, including changes to the integration pipeline on catalog `main`. |
| Release Service maintainers | Review the task-commit update on `development`. They decide when to run [Promote branch][promote] for staging or production, and whether an urgent change needs a hotfix. |
| Tenant or workload owner | Identifies a new integration or release run. With Conforma, checks the task, CLI, effective policy and validation result for that workload. |

## Step-by-Step Execution

### 1. Prepare and merge one release proposal

1. **Generate the proposal.** From the root of `conforma/infra-deployments-ci`, with the [generator tools and registry access][setup] in place, run:

   ```bash
   ./hack/generate-changelog.sh
   ```

2. **Review `changelog.md`** in the new `releases/<UTC-timestamp>/` directory. Check the source PRs, added and removed rules, affected collections and effective dates. Read the behavior report: it compares the current CLI and policy with the candidate pair using the same Golden container and RPM image digests and evaluation time. Account for any change in warnings or violations in the proposal.
3. **Review `images.json`.** Match its candidate digests to the changelog and check each policy's mirror destinations. The `policy` entries select the images to promote. The `components` entries record the CLI and bundle candidates seen during generation.
4. **Open and merge the release PR.** Include both files in **one new release directory** in a PR to `main`, as in [#261][proposal]. Confirm the [lead-time check][lead-time] and required reviews pass, then merge one release directory per push.

   **Note:** Each newly added rule needs an RFC 3339 `effective_on` [at least 56 days][lead-time-window] after the lead-time check runs. Existing rules are exempt.

### 2. Verify publication and record what shipped

**Do this for every full release.** Record two values the proposal cannot supply: the digest of the **rebuilt task bundle** for integration, and the **task-catalog commit** for managed releases. Capture them while the tags and branch still identify this run. Record the CLI and policy digests alongside them so a workload owner can later check what ran, or recover a known-good version.

For example, the manifest in #261 listed [`a0cb6fc…`][manifest-cli] as the candidate CLI digest. The task published by that run uses [`975ec70…`][task-cli] for its CLI image. The workflow takes the CLI from the input task bundle; copying the candidate digest into the handoff would have sent reviewers looking for the wrong image.

1. **Confirm the full release completed.** Open the [`konflux-policy` run][publish] for the merge, as in [run 41855742425][example-run]. In `acceptance-tests`, check the `Using releases/.../images.json` line and that `make acceptance` passed. Confirm all four publication jobs below also succeeded.

   **Stop if the full release is incomplete.** Publication writes to Quay and Git separately. Once the bundle tag moves, new integration runs can use the bundle even if the catalog push fails. Hold the handoff and [check which destinations changed](#partial-publication-or-rollback) before retrying. If you deliberately ran acceptance only, record the test result and end here.

2. **Collect the versions from this run.** Use `crane digest <image-reference>` to compare each registry destination with its job output.

   | What to collect | Where to find it and what to compare |
   | --- | --- |
   | **Rebuilt task bundle** | In `tekton-task-bundle`, find the `run-<UTC-date>-<run-id>-<attempt>` tag printed by the [bundle publication step][example-bundle-step]. Record that tag and its digest; `quay.io/conforma/tekton-task:konflux` must resolve to the same digest for this release. |
   | **Task-catalog commit** | In `tekton-catalog`, find the commit pushed to `conforma/tekton-catalog` on `konflux`. Record its full SHA, or the existing revision if the job reported no file changes. The [example commit `ffb55a3`][example-commit] shows the updated tasks, the added StepAction and a link back to the run. |
   | **CLI image** | In `acceptance-tests` → **Resolve tested image digests**, find the CLI read from the input bundle. In `tag` → **Tag tested images by digest**, check that `quay.io/conforma/cli:konflux` resolves to that digest. |
   | **Policy images and mirrors** | Match each destination in `tag` → **Tag policy images** to its `policy` entry in `images.json`. In the `task-definitions` artifact from `update-task-definitions`, check that `POLICY_BUNDLE_DIGEST` defaults to the promoted release-policy digest and that the StepActions from `quay.io/conforma/step-actions:snapshot` are present. In #261, `507e458…` appears in both the [release-policy entry][manifest-policy] and the [published task default][task-policy-default]. |

3. **Hand off the record.** Once all destinations agree, share the release PR, release directory, run URL and full values above with workload owners and Release Service maintainers. For example, [Release Service PR #2722][managed-pr] pinned the [full SHA of `ffb55a3`][pipeline-revision] in its pipeline files. Confirmation that a workload actually ran those versions comes in step 5.

   **Caution:** If a destination disagrees with the run, pause even if every job is green. Another publication may already have moved the tag or branch.

### 3. Follow the two consumer paths independently

**Integration tests (`conforma/tekton-catalog`)**

1. **Check the workload's `IntegrationTestScenario` (ITS).** Its `spec.resolverRef` tells Konflux which integration pipeline to run. The [Konflux UI default][its-default] uses the Git resolver to load `pipelines/enterprise-contract/0.1/enterprise-contract.yaml` from `conforma/tekton-catalog` on `main`.
2. **If you're reviewing a catalog sync to `main`, check which files changed.**
   - **Only files under `tasks/`:** [Catalog PR #309][catalog-task-sync] set the CLI image in three tasks to [`975ec70…`][task-cli], the digest release #261 later published. Merging #309 did not roll out those tasks: the default ITS loads them from Quay.
   - **The selected pipeline YAML:** The earlier [catalog PR #286][catalog-sync-pr] changed the pipeline's [`WORKERS` default][pipeline-workers] from `1` to `2`. A new run following `main` can pick up that change without a Conforma release.
3. **Ask the workload owner for the next integration run after publication.** The pipeline resolves both [`collect-keyless-params`][integration-collect] and [`verify-enterprise-contract`][integration-verify] from `quay.io/conforma/tekton-task:konflux`. Once [publication moves the tag][example-bundle-step], a production ITS using this default can pick up the new bundle without a catalog PR or separate staging promotion. [Compare the run's resolved digests with the published bundle digest](#5-confirm-adoption-per-consumer).

   **Note (legacy):** [Renovate PR #3379][build-pr] updated bundle pins in the [deprecated `build-definitions` pipeline][legacy-pipeline] alongside a CLI pin for that repository's own CI.

**Managed release pipelines (`konflux-ci/release-service-catalog`)**

1. **Generate the task-commit update.** From a checkout based on `development`, run the [revision helper][bump] and inspect its changes. The helper requires GNU `sed` (`gsed` on macOS).

   ```bash
   ./scripts/bump-conforma-revision.sh
   git diff -- pipelines/
   ```

2. **Compare the printed SHA with the handoff.** Check each affected pipeline's Git resolver for the intended `conforma/tekton-catalog` revision. Include pipelines starting from older pins.

   **Caution:** The helper follows the current head of the task catalog's `konflux` branch. Stop if that branch has advanced beyond the release you intend to roll out.

3. **Open a PR against `development`.** Include the changelog, publication run and old/new revisions. Ask the Release Service maintainers to review and merge. [PR #2722][managed-pr] is a worked example: its pipeline changes point to the same commit as the publication record.

### 4. Promote the managed release catalog

1. **Request staging promotion.** Ask Release Service maintainers to run [Promote branch][promote] with `development-to-staging`. Record the run URL.

   **Caution:** Normal promotion force-pushes the **whole source branch** to the target. Coordinate all pending catalog changes with the maintainers. For a blocked or urgent promotion, see [promotion troubleshooting](#a-promotion-is-blocked-or-urgent).

2. **Validate staging.** Check that all affected pipelines on `staging` pin the intended task-catalog SHA. Use the checks in step 5 on a new staging run before requesting production promotion.
3. **Request production promotion.** When maintainers approve, ask them to dispatch `staging-to-production`. Record the run and verify the pins in the affected pipelines on `production`.

### 5. Confirm adoption per consumer

1. **Select a new `PipelineRun` with the workload owner.** For integration, choose one that started after the bundle tag moved. For a managed release, choose one after the relevant environment promotion and check the pipeline repository, path and revision selected by `ReleasePlanAdmission.spec.pipeline.pipelineRef`.
2. **Record the resolved pipeline Git commit.** Then check the tasks against the publication record:
   - **Integration:** Check the `TaskRun` provenance for both pipeline tasks, `collect-keyless-params` and `verify`. Each resolved bundle digest should match the rebuilt bundle digest from step 2. The pipeline commit alone cannot identify a bundle fetched by tag.
   - **Managed release:** Compare the verification task's resolved Git commit with the task-catalog SHA from step 2.
3. **Record what the verification task ran.** Check its CLI image digest, effective policy reference and digest, and validation result. Link the run evidence to the publication record and, for managed releases, the catalog PR and promotion run or hotfix PR. Report adoption for the workload and environment you verified.

   **Note:** If the production pin has moved but no workload has run yet, report “production catalog updated” and leave workload adoption pending.

## Edge Cases & Troubleshooting

### Preparing or publishing

#### The generator wrote release files but the behavior report is missing or incomplete

**Why this happens:** `generate-changelog.sh` writes `changelog.md` and `images.json` before it finishes comparing the Golden container and RPM images. Both files can exist after a failed pull or validation command.

**What to do:** Check the generator's exit status and first error. For a pull error, confirm the container engine can read both Golden images; set `REGISTRY_AUTH_FILE` to a Docker-compatible auth file if needed. Fix the reported error, regenerate the proposal and check that both Golden comparisons completed before opening the PR.

#### The changelog and `images.json` give different digests for the same candidate

**Why this happens:** The generator looks up `:latest` more than once. If the tag moves during generation, the changelog can describe a different image from the one in the manifest.

**What to do:** Compare the full digests for the same repository in both files. Regenerate them together and review the new behavior report. Editing one digest by hand leaves the comparison tied to the old inputs.

#### CI rejects a new rule's effective date

**Why this happens:** The lead-time check measures the interval from the time CI runs. A newly added rule fails if its `effective_on` is absent, malformed or less than 56 days away.

**What to do:** Identify the rule in the check output and inspect its RFC 3339 date. To reproduce, set `RELEASE_DIR` to the proposal directory and run `bash ./hack/check-release-lead-time.sh "$RELEASE_DIR/images.json"`. Resolve the rule or candidate selection with the policy reviewer before merging.

#### A push starts publication but the run reports `No images.json found`

**Why this happens:** Any change under `releases/**` on `main` can trigger the workflow. On a push it selects the first *newly added* manifest; editing an existing changelog or manifest gives it no new one to select.

**What to do:** For a new proposal, check that the PR adds `releases/<directory>/images.json`. To use an existing directory, dispatch [`konflux-policy`][publish] manually with that `release_dir`, with or without the `releases/` prefix. Choose the publication switches before starting the run.

#### You need to run acceptance without moving release tags

**Why this needs care:** Manual dispatch uses an existing proposal, but all three publication switches default to `true`. Leaving them enabled publishes images and catalog files after acceptance.

**What to do:** Select the intended `release_dir`. Set `run_tag`, `run_tekton_task_bundle` and `run_tekton_catalog` **all to `false`** for acceptance only. For a deliberately partial run, enable only the outputs you intend to publish. If you publish tasks with `run_tag=false`, their policy default comes from the **existing** `release-policy:konflux` tag.

#### Acceptance passed but the Golden reports contain violations

**Why this happens:** The scenarios use `STRICT=false`: success means the pipelines completed. They resolve `:latest` references, and the workflow rebuilds the final bundle after acceptance.

**What to do:** Use the proposal's behavior report to review changes in policy findings. For questions about which versions shipped, use the publication record; for what a workload evaluated, inspect its Conforma `TaskRun` in step 5.

### A consumer has not picked up the release

#### A new integration run used an unexpected task bundle

**Why this happens:** The workload may select a different pipeline, or the `:konflux` tag may have moved again before the tasks resolved it.

**What to do:** Check the ITS repository and path, then inspect the task references at the pipeline commit recorded by the `PipelineRun`. Match the digest from each `TaskRun` to the release records from step 2 to identify which bundle ran. If the run records only a tag, leave adoption unconfirmed. Looking up `:konflux` now cannot tell you what an earlier run used.

#### A run uses the expected task commit but evaluates a different policy digest

**Why this happens:** The commit supplies a *default* for `POLICY_BUNDLE_DIGEST`. The run also supplies a policy configuration, which may already pin another digest or may use a floating tag that the task leaves unchanged.

**What to do:**

1. Compare the run's actual `POLICY_BUNDLE_DIGEST` with the published task default. An empty value skips the override.
2. Inspect the `pin-policy-bundle` step log and the policy configuration used by `validate`. The [pin helper][policy-pin] rewrites `oci::quay.io/conforma/release-policy:konflux`. It preserves an existing digest pin and leaves the legacy `oci::quay.io/enterprise-contract/ec-release-policy:konflux` URL unchanged.
3. Confirm the intended policy with the workload owner. If the reference or override needs correcting, verify the resulting policy digest in a **new** run. Record an intentional override separately from adoption of the release policy.

### A promotion is blocked or urgent

| Problem | Why it happens | What to do |
| --- | --- | --- |
| The bump merged to `development`, but promotion to `staging` is blocked. | Staging and production still have different file contents. A green **Konflux Staging** PR check tested the PR revision; the `staging` branch stays in place until promotion. | Compare the branches with Release Service maintainers. Coordinate the outstanding staging changes before another promotion. Maintainers decide whether to use `force-to-staging`. |
| Promotion to `production` is blocked by the age check. | The [promotion script][guards] found a commit newer than its six-day cutoff. It checks Git commit timestamps; an old commit can qualify even if it just reached staging. | Inspect the commits identified by the check. Agree on validation and timing with the maintainers; they own the `override` decision. |
| The promotion would discard a hotfix. | A change on the target branch is missing from the source. A whole-branch promotion would overwrite it. | Ask maintainers to reconcile the hotfix before retrying. `override-hotfix-check` bypasses that protection. |
| One urgent change needs to ship ahead of the batch. | Normal promotion carries every pending change on the source branch. | Ask maintainers about a selective hotfix. An exact `/hotfix` comment on the **merged `development` PR** requests cherry-pick PRs for both branches; [manual dispatch][hotfix] can select either or both. Check which PRs were created, resolve conflicts with maintainers, then follow each target's review and merge process. |
| You need to preview a catalog promotion without changing other systems. | `dry-run` suppresses the catalog push, but the optional controller and email actions can still run. | Leave controller-promotion and email options off for a catalog-only preview. |

### Partial publication or rollback

**Problem:** A run failed after moving some release tags, or the bundle and catalog point to different releases. The two final jobs finish independently. A later failure does not undo earlier writes, and another run may already have published newer outputs.

**What to do:**

1. **Inventory first.** Pause downstream pin updates and coordinate with other release operators. Compare completed jobs, destination tags, the catalog SHA and any consumer pins already changed. Pausing pin updates does not stop integration runs from using `:konflux`. If the bundle tag moved, ask workload owners to check which runs resolved the new digest.

   If the bundle reached Quay and only `tekton-catalog` failed, check that the original run still has the `task-definitions` artifact used to build that bundle and that no newer release has superseded this one. If either check fails, keep downstream pins on hold and coordinate a new full publication or rollback. Otherwise, rerun **only [`tekton-catalog`][catalog-artifact] in the original run**. Before handing off, compare the tasks and StepActions it publishes with those in the bundle at its recorded digest.

   **Caution:** Do not start a new catalog-only dispatch to finish an earlier release. Even with the same `release_dir`, a new run resolves the task bundle, policy and StepActions again. The catalog can then differ from the bundle already on Quay.

2. **For rollback, select a known-good release.** Use its full handoff or recover the policy digests from its manifest, the published CLI digest from its successful tag-job log, and the rebuilt bundle from its bundle-job log and run tag. **Do not dispatch an old `release_dir` as a rollback**; it resolves current bundle inputs again.
3. **Restore registry tags with approved access.** For each policy, set `IMAGE` and `DIGEST` from the known-good manifest. Run the copy once with `DEST` set to the primary repository and once for each listed mirror. For the CLI, use its repository and its actual published digest.

   ```bash
   skopeo copy --all "docker://${IMAGE}@${DIGEST}" "docker://${DEST}:konflux"
   ```

   For the rebuilt task bundle, set `BUNDLE_DIGEST` to the verified previous `sha256:...` digest. The old run tag is not required:

   ```bash
   crane tag "quay.io/conforma/tekton-task@${BUNDLE_DIGEST}" konflux
   ```

   If the registry no longer has that digest, restore a retained copy first; do not substitute `:latest`. Verify every restored destination with `crane digest`.
4. **Restore Git pins separately.** Restore the known-good tasks and StepActions on `conforma/tekton-catalog`'s `konflux` branch as needed. With consumer owners, restore any affected bundle or CLI digest pins and managed pipeline task SHAs to their known-good values. Keep `development` consistent so the next promotion does not reintroduce the bad revision. Verify recovery in new runs, including consumers of floating policy tags.

[setup]: https://github.com/conforma/infra-deployments-ci/blob/main/README.md#prerequisites
[lead-time]: https://github.com/conforma/infra-deployments-ci/blob/f22b8608f4e15649c249e9dfa4362e2dc18a894f/.github/workflows/check-release-lead-time.yaml#L39-L41
[lead-time-window]: https://github.com/conforma/infra-deployments-ci/blob/f22b8608f4e15649c249e9dfa4362e2dc18a894f/hack/check-release-lead-time.sh#L47-L49
[publish]: https://github.com/conforma/infra-deployments-ci/actions/workflows/konflux-policy.yaml
[publish-code]: https://github.com/conforma/infra-deployments-ci/blob/main/.github/workflows/konflux-policy.yaml
[proposal]: https://github.com/conforma/infra-deployments-ci/pull/261
[lead-example]: https://github.com/conforma/infra-deployments-ci/actions/runs/41435124397/job/125242896912
[example-run]: https://github.com/conforma/infra-deployments-ci/actions/runs/41855742425
[example-commit]: https://github.com/conforma/tekton-catalog/commit/ffb55a37e4963fc6d051239aca35841342098689
[managed-pr]: https://github.com/konflux-ci/release-service-catalog/pull/2722
[its-default]: https://github.com/konflux-ci/konflux-ui/blob/81fbbd6ff61d5ea621f6553b0126a8baa2c14dd9/src/components/IntegrationTests/IntegrationTestForm/const.ts#L1-L3
[integration-collect]: https://github.com/conforma/tekton-catalog/blob/cda80addb3a687c52fe5d08fba67061db20933bd/pipelines/enterprise-contract/0.1/enterprise-contract.yaml#L109-L115
[integration-verify]: https://github.com/conforma/tekton-catalog/blob/cda80addb3a687c52fe5d08fba67061db20933bd/pipelines/enterprise-contract/0.1/enterprise-contract.yaml#L163-L169
[catalog-task-sync]: https://github.com/conforma/tekton-catalog/pull/309/files
[catalog-sync-pr]: https://github.com/conforma/tekton-catalog/pull/286/files
[pipeline-workers]: https://github.com/conforma/tekton-catalog/blob/2bb8884d1be8426f790f3b03014c6ee9f0e67461/pipelines/enterprise-contract/0.1/enterprise-contract.yaml#L66-L69
[managed-pipeline]: https://github.com/konflux-ci/release-service-catalog/blob/b895c71e57258f2870674a105a1f2c0b6ad1e564/pipelines/managed/calunga-push-npm-to-pulp/calunga-push-npm-to-pulp.yaml#L257-L267
[manifest-cli]: https://github.com/conforma/infra-deployments-ci/blob/f22b8608f4e15649c249e9dfa4362e2dc18a894f/releases/2026-11-02T10%3A22%3A39/images.json#L27-L28
[task-cli]: https://github.com/conforma/tekton-catalog/blob/ffb55a37e4963fc6d051239aca35841342098689/tasks/verify-enterprise-contract/0.1/verify-enterprise-contract.yaml#L280-L282
[manifest-policy]: https://github.com/conforma/infra-deployments-ci/blob/f22b8608f4e15649c249e9dfa4362e2dc18a894f/releases/2026-11-02T10%3A22%3A39/images.json#L5
[task-policy-default]: https://github.com/conforma/tekton-catalog/blob/ffb55a37e4963fc6d051239aca35841342098689/tasks/verify-enterprise-contract/0.1/verify-enterprise-contract.yaml#L114
[example-bundle-step]: https://github.com/conforma/infra-deployments-ci/blob/f22b8608f4e15649c249e9dfa4362e2dc18a894f/.github/workflows/konflux-policy.yaml#L268-L271
[catalog-artifact]: https://github.com/conforma/infra-deployments-ci/blob/e2e4a9ac553cf94e96c6a624ad6b45c5f4dfdc28/.github/workflows/konflux-policy.yaml#L279-L283
[pipeline-revision]: https://github.com/konflux-ci/release-service-catalog/blob/b895c71e57258f2870674a105a1f2c0b6ad1e564/pipelines/managed/calunga-push-npm-to-pulp/calunga-push-npm-to-pulp.yaml#L263-L264
[legacy-pipeline]: https://github.com/konflux-ci/build-definitions/blob/88d1231f6c10873132600522a27893837b7a0632/pipelines/enterprise-contract.yaml#L1-L5
[build-pr]: https://github.com/konflux-ci/build-definitions/pull/3379/files
[bump]: https://github.com/konflux-ci/release-service-catalog/blob/development/scripts/bump-conforma-revision.sh
[promote]: https://github.com/konflux-ci/release-service-catalog/actions/workflows/promote_branch.yaml
[guards]: https://github.com/konflux-ci/release-service-catalog/blob/b895c71e57258f2870674a105a1f2c0b6ad1e564/.github/scripts/promote_branch.sh#L105-L113
[hotfix]: https://github.com/konflux-ci/release-service-catalog/actions/workflows/hot_fix_pr.yaml
[policy-pin]: https://github.com/conforma/cli/blob/6ac4587f007efd1fa69ada2244fbf0c4390cea1f/hack/pin-konflux-policy-bundle.sh#L78-L93
