# Konflux Policy Release

> Conforma policy update for Red Hat's Konflux deployment.

## Images

- **release-policy** — `sha256:10de4ff888f9d054baeaa15c528ff74118bfd3c99ed0e5fc0ac24e72e83e01dc`
- **task-policy** — `sha256:d023b6fd037357659d233df7e085b2e7a1159d80746050c964fc33e3c67e9826`
- **build-task-policy** — `sha256:76d49ad45557eef03581b15994d30bb09d005db6c9aaaf8aef5e44532cfe23cb`
- **cli** — `sha256:f19ee80ccf91370136ad865ee8c79a9adee944b998183a6a2db5049fc0f448c2`
- **tekton-task** — `sha256:37b57db5fd7706509011ea031b564a50c468a76de85d327d37869a7bf8a115cf`

## Changes Since Last Release

### [conforma/policy](https://github.com/conforma/policy)

Source commits: [`7c9b0e0f..2161b032`](https://github.com/conforma/policy/compare/7c9b0e0f...2161b032)

- [#1817](https://github.com/conforma/policy/pull/1817) — Deduplicate test-result attestations by test name
- [#1787](https://github.com/conforma/policy/pull/1787) — Verify SBOM signatures from OCI referrers and tag refs
- [#1813](https://github.com/conforma/policy/pull/1813) — Fix test mock _type to match stepaction output
- [#1785](https://github.com/conforma/policy/pull/1785) — docs(#1784): correct collection-registration guidance in AGENTS.md
- [#1815](https://github.com/conforma/policy/pull/1815) — docs(EC-1999): document testing expectations for collection changes
- [#1806](https://github.com/conforma/policy/pull/1806) — feat(EC-2031): remove data.trusted_task_rules in favor of rule_data only
- [#1781](https://github.com/conforma/policy/pull/1781) — Warn when regex patterns in rule data lack anchoring
- [#1793](https://github.com/conforma/policy/pull/1793) — [EC-1864] Add AI skills for ec-policies

### [conforma/cli](https://github.com/conforma/cli)

Source commits: [`905b0796..fd0921d9`](https://github.com/conforma/cli/compare/905b0796...fd0921d9)

- [#3537](https://github.com/conforma/cli/pull/3537) — fix: Remove reference to deleted quick-build-args.conf
- [#3516](https://github.com/conforma/cli/pull/3516) — Remove local helpers:pinGitHubActionDigests override
- [#3527](https://github.com/conforma/cli/pull/3527) — chore: add CODEOWNERS designating the devs team as code owners
- [#3538](https://github.com/conforma/cli/pull/3538) — Upgrade go version to 1.26.7
- [#3513](https://github.com/conforma/cli/pull/3513) — Update Konflux references (main)
- [#3521](https://github.com/conforma/cli/pull/3521) — Bump minor version to 0.10
- [#3519](https://github.com/conforma/cli/pull/3519) — chore(deps): Update google.golang.org/grpc and ubi base image (main)
- [#3473](https://github.com/conforma/cli/pull/3473) — Update module github.com/go-git/go-git/v5 to v5.19.2 [SECURITY] (main)
- [#3511](https://github.com/conforma/cli/pull/3511) — docs(#3510): add AGENTS.md guidance for review conventions
- [#3489](https://github.com/conforma/cli/pull/3489) — Use ValidateVSAAndComparePolicy for ec validate image VSA skip
- [#3505](https://github.com/conforma/cli/pull/3505) — Restore commented out acceptance test scenario
- [#3430](https://github.com/conforma/cli/pull/3430) — Add attended scripts for multi-branch UBI bump and module update PRs
- [#3478](https://github.com/conforma/cli/pull/3478) — Update github actions (main) (patch)
- [#3477](https://github.com/conforma/cli/pull/3477) — Pin dependencies (main)
- [#3497](https://github.com/conforma/cli/pull/3497) — Update Konflux references (main)
- [#3500](https://github.com/conforma/cli/pull/3500) — chore(deps): Update ubi-minimal base image (main)
- [#3493](https://github.com/conforma/cli/pull/3493) — chore(deps): Update ubi-minimal base image
- [#3496](https://github.com/conforma/cli/pull/3496) — Update Konflux references
- [#3486](https://github.com/conforma/cli/pull/3486) — Skip volatile config items when timestamp parsing fails

## Policy Rule Changes

### release-policy

#### Added (5 rules)

**deny**

- **[allowed_target_branch_patterns format](https://conforma.dev/docs/policy/packages/release_git_branch.html#git_branch__allowed_target_branch_patterns_format)** — Confirm the `allowed_target_branch_patterns` rule data uses anchored regex patterns.<br>Effective: now · Collections: redhat_rpms, policy_data
- **[allowed_rpm_build_dependency_sources format](https://conforma.dev/docs/policy/packages/release_rpm_build_deps.html#rpm_build_deps__allowed_rpm_build_dependency_sources_format)** — Confirm the `allowed_rpm_build_dependency_sources` rule data uses anchored regex patterns.<br>Effective: now · Collections: redhat_rpms, policy_data
- **[All required test tasks were included in a pipeline](https://conforma.dev/docs/policy/packages/release_tasks.html#tasks__required_test_tasks_found)** — Ensure that every currently required test task is included in either the build PipelineRun or a trusted ITS PipelineRun associated with the image.<br>Effective: 2026-10-01 · Collections: redhat, redhat_security
**warn**

- **[SBOM signature verification failed](https://conforma.dev/docs/policy/packages/release_sbom.html#sbom__signature_verification)** — Report when signature verification fails for SBOMs discovered via OCI referrers or image-tag refs. The SBOM is excluded (fail-closed), but the user should know why.<br>Effective: now · Collections: redhat, redhat_security
- **[Future required test tasks were found](https://conforma.dev/docs/policy/packages/release_tasks.html#tasks__future_required_test_tasks_found)** — Produce a warning when a test task that will be required in the future was not included in either the build or ITS PipelineRun attestations.<br>Effective: 2026-10-01 · Collections: redhat, redhat_security

<details>
<summary>Task and build policy changes</summary>


### task-policy

No rule changes.

### build-task-policy

No rule changes.

</details>
