# Draft: Konflux policy update

Advance the three policy bundles to the sources at
[`conforma/policy` main, `c584f00711d7760c46171bc833b41e8fe8177ea0`](https://github.com/conforma/policy/commit/c584f00711d7760c46171bc833b41e8fe8177ea0).
The manifest records the released CLI and task-bundle digests captured on
2026-10-29. This proposal changes release files only and remains blocked.

## Images

| Image | Selected digest | Role |
|---|---|---|
| `quay.io/conforma/release-policy` | `sha256:c5f849046794ca55c52f5d84b88e53858b299b759fa8a4827f6911dead422315` | Promote policy and configured mirror |
| `quay.io/conforma/task-policy` | `sha256:4785d7b7346ff5ec00736e85166b4d36ee726040dce8827051b35b71367de946` | Promote policy and configured mirror |
| `quay.io/conforma/build-task-policy` | `sha256:c74f8a90e75ec19c32d2d860b2c5c70f0c759ce5c86665b9f9f9c38f2606f0fe` | Promote policy and configured mirror |
| `quay.io/conforma/cli` | `sha256:6c6343486b739836c448277c00b1ec3c291e4ad10fd2b1767ff3984e89a43ad1` | Recorded released component |
| `quay.io/conforma/tekton-task` | `sha256:e2ac3444a229ce1688c96692ba2af166656be9313ac5cba750cac1c7daf3371d` | Recorded released component |

The unchanged workflow selects the task bundle and CLI from
`tekton-task:latest`, independently of the manifest's `components` entries.
Merging this release directory would run that workflow and could change the
CLI. These pins do not make automated publication policy-only. Do not merge
until the publication scope is resolved without changing the current CI.

The policy revision annotations are `1b908855` for release-policy and `cb839dc5`
for task-policy and build-task-policy. These match the last commits affecting
`policy/lib` and each bundle's source directory at the recorded main HEAD, as
selected by `hack/update-bundles.sh`. That script excludes test Rego files and
`artifacthub-pkg.yml`; its revision annotation need not equal the merge commit.

## Source changes

[Full policy source comparison: `fb1d3a6b...c584f007`](https://github.com/conforma/policy/compare/fb1d3a6b...c584f00711d7760c46171bc833b41e8fe8177ea0).
Selected policy changes in that range:

- [#1945](https://github.com/conforma/policy/pull/1945): Decide SLSA v1 task format from `predicateType`.
- [#1871](https://github.com/conforma/policy/pull/1871): Reject malformed Pipeline and Task values.
- [#1943](https://github.com/conforma/policy/pull/1943): Add CycloneDX 1.7 SBOM validation.
- [#1941](https://github.com/conforma/policy/pull/1941): Check signing identities for trusted task bundles.
- [#1866](https://github.com/conforma/policy/pull/1866): Support flexible disallowed date formats.
- [#1829](https://github.com/conforma/policy/pull/1829): Verify integration-test PipelineRuns use trusted tasks.
- [#1832](https://github.com/conforma/policy/pull/1832): Verify SBOM attestations with signing identities.
- [#1826](https://github.com/conforma/policy/pull/1826): Allow the PNC SLSA build type for PipelineRun attestations.
- [#1844](https://github.com/conforma/policy/pull/1844): Use the `ec.oci.parsed_blob` builtin.

No CLI update is requested. Compatibility with the released CLI still needs
validation, including policy use of custom builtins.

## Policy rule changes

The rule comparison found nine additions and no removals across the three
bundles. These are rule-metadata changes, not a runtime behavior comparison.

| Bundle | Added rule | Effective time (UTC) |
|---|---|---|
| release-policy | `malformed_parameter` | `2027-01-11T00:00:00Z` |
| release-policy | `mode_not_permissive_v2` | `2027-01-11T00:00:00Z` |
| release-policy | `valid_cdx_1_7` | Missing: blocks the release check |
| release-policy | `required_untrusted_test_task_found` | `2027-01-15T00:00:00Z` |
| release-policy | `test_identity_found` | `2027-01-15T00:00:00Z` |
| release-policy | `test_timestamp_found` | `2027-01-15T00:00:00Z` |
| task-policy | `required_v2` | `2027-01-11T00:00:00Z` |
| task-policy | `workspaces_format` | `2027-01-11T00:00:00Z` |
| build-task-policy | `build_type_label_set_v2` | `2027-01-11T00:00:00Z` |

## Validation and merge blockers

JSON validation and a diff-scope check passed. Only this changelog and
`images.json` differ from the PR base; the workflows, scripts, tests, and release
documentation are unchanged.

`hack/check-release-lead-time.sh` fails because `valid_cdx_1_7` has no
`effective_on` date. The minimum at the check was `2026-12-24T09:57:57Z`.
Separate task-policy and build-task-policy lead-time checks passed. Fix the
policy rule through the policy repository's review process, then refresh the
candidate digests and rerun the check; this proposal does not waive it.

The container-based Golden image behavior comparison and Kind acceptance suite
have not run because the preparation environment has no Docker daemon. Run both
against the retained CLI and candidate policy before treating this as a release
candidate. Compatibility with the released CLI has not been demonstrated.
