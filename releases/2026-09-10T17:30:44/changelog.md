# Konflux Policy Release

> Conforma policy update for Red Hat's Konflux deployment.

## Images

- **release-policy** — `sha256:0d3ab4efb94bd8ee361bda3146cae0c509c41d597431af658ce2570112efe469`
- **task-policy** — `sha256:8c617e360d17bada4e738b84d00529a221509d91810b4c547b26471bb62e7e0c`
- **build-task-policy** — `sha256:d1fd53bcbe3ac1c6f1b4104ac707be4054774dcba6aa888e30f77d8c2a3a591d`
- **cli** — `sha256:6c6343486b739836c448277c00b1ec3c291e4ad10fd2b1767ff3984e89a43ad1`
- **tekton-task** — `sha256:ca5c984f49b74ce5fb199566696eb71361b74d6d488dc76313c4e9fd98d9c115`

## Changes Since Last Release

### [conforma/policy](https://github.com/conforma/policy)

Source commits: [`7c9b0e0f..fb1d3a6b`](https://github.com/conforma/policy/compare/7c9b0e0f...fb1d3a6b)

- [#1845](https://github.com/conforma/policy/pull/1845) — Push back effective_on dates
- [#1831](https://github.com/conforma/policy/pull/1831) — chore(EC-2174): bump conforma/cli and fix transitive dependency conflicts
- [#1773](https://github.com/conforma/policy/pull/1773) — docs(#1772): document dual test-result architecture and trust chain
- [#1823](https://github.com/conforma/policy/pull/1823) — EC-2160: Enforce required test tasks from build and ITS attestations
- [#1663](https://github.com/conforma/policy/pull/1663) — Update go toolchain directive to v1.27.0 (main)
- [#1817](https://github.com/conforma/policy/pull/1817) — Deduplicate test-result attestations by test name
- [#1787](https://github.com/conforma/policy/pull/1787) — Verify SBOM signatures from OCI referrers and tag refs
- [#1813](https://github.com/conforma/policy/pull/1813) — Fix test mock _type to match stepaction output
- [#1785](https://github.com/conforma/policy/pull/1785) — docs(#1784): correct collection-registration guidance in AGENTS.md
- [#1815](https://github.com/conforma/policy/pull/1815) — docs(EC-1999): document testing expectations for collection changes
- [#1806](https://github.com/conforma/policy/pull/1806) — feat(EC-2031): remove data.trusted_task_rules in favor of rule_data only
- [#1781](https://github.com/conforma/policy/pull/1781) — Warn when regex patterns in rule data lack anchoring
- [#1793](https://github.com/conforma/policy/pull/1793) — [EC-1864] Add AI skills for ec-policies

### [conforma/cli](https://github.com/conforma/cli)

Source commits: [`905b0796..f46a8040`](https://github.com/conforma/cli/compare/905b0796...f46a8040)

- [#3551](https://github.com/conforma/cli/pull/3551) — chore(deps): Update golang module CVE fixes (main)
- [#3553](https://github.com/conforma/cli/pull/3553) — Update github/codeql-action action to v4.37.9 (main)
- [#3552](https://github.com/conforma/cli/pull/3552) — Update github actions (main)
- [#3520](https://github.com/conforma/cli/pull/3520) — feat(KONFLUX-15176): add SECURITY.md for CRA
- [#3547](https://github.com/conforma/cli/pull/3547) — chore(deps): advance .fullsend dispatch pin to pinned main
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
- **[All required test tasks were included in a pipeline](https://conforma.dev/docs/policy/packages/release_tasks.html#tasks__required_test_tasks_found)** — Ensure that every currently required test task is included in either the build PipelineRun or a trusted ITS PipelineRun associated with the image.<br>Effective: 2027-01-15 · Collections: redhat, redhat_security
**warn**

- **[SBOM signature verification failed](https://conforma.dev/docs/policy/packages/release_sbom.html#sbom__signature_verification)** — Report when signature verification fails for SBOMs discovered via OCI referrers or image-tag refs. The SBOM is excluded (fail-closed), but the user should know why.<br>Effective: now · Collections: redhat, redhat_security
- **[Future required test tasks were found](https://conforma.dev/docs/policy/packages/release_tasks.html#tasks__future_required_test_tasks_found)** — Produce a warning when a test task that will be required in the future was not included in either the build or ITS PipelineRun attestations.<br>Effective: 2027-01-16 · Collections: redhat, redhat_security

<details>
<summary>Task and build policy changes</summary>


### task-policy

No rule changes.

### build-task-policy

No rule changes.

</details>
