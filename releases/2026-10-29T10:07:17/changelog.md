# Konflux Policy Release

> Conforma policy update for Red Hat's Konflux deployment.

## Policy-Only Release

This release promotes the three policy images only. The CLI is deliberately held back.

- **CLI stays at the currently promoted digest** `quay.io/conforma/cli@sha256:6c6343486b739836c448277c00b1ec3c291e4ad10fd2b1767ff3984e89a43ad1` (`cli:konflux`). The `conforma/cli` commit list below is informational: those changes are staged at `cli:latest` (`sha256:a0cb6fcce80c6d0775e72802e4da58f050ca32ba32e1ea068d314df4a9536837`) and in `tekton-task:latest` (`sha256:1e6d4b6fdd3886bda044ce063efa79e5f0175c9a720a97308ac5055774352ee6`) but are **not** part of this release.
- **How the CLI is held back:** the acceptance pipeline bundle references are pinned to the current released bundle `quay.io/conforma/tekton-task@sha256:e2ac3444a229ce1688c96692ba2af166656be9313ac5cba750cac1c7daf3371d` instead of `:latest`. The release workflow resolves the promoted CLI from that bundle, so the CLI, the rebuilt task bundle, and the catalog task definitions all keep `sha256:6c634348...`. `hack/resolve-tested-digests.sh` was extended to accept digest-pinned bundle references. These pins must be reverted to `:latest` (or re-pinned) in the release that ships the new CLI.
- **Policy source revisions:** policy content is identical to `conforma/policy` main HEAD `c584f007`. `release-policy` was built from `1b908855` (tree-identical to `c584f007`); `task-policy` and `build-task-policy` were built from `cb839dc5` — the only change since is `policy/release/prefetch_dependencies/prefetch_dependencies_test.rego`, a test file excluded from bundles. No image tagged with `c584f007` exists for the task/build-task bundles because `hack/update-bundles.sh` tags each bundle with the last commit that touched its sources.
- **`images.json` components** record what actually ships (CLI `sha256:6c634348...`, input bundle `sha256:e2ac3444...`) rather than the `:latest` candidates.
- **Policy behavior comparison not included:** `compare-policy-behavior.sh` cannot resolve the Golden RPM target (`quay.io/redhat-user-workloads/.../golden-rpm`) without registry authentication, so the generator exited before writing a report. The Golden container comparisons completed locally. The 2026-09-10 release changelog also shipped without a behavior section.
- **`check-release-lead-time` fails on this manifest:** the new rule `valid_cdx_1_7` (`policy/release/sbom_cyclonedx/sbom_cyclonedx.rego`) has no `effective_on` date, so it becomes active immediately when promoted. Minimum required lead is 56 days (effective_on >= 2026-12-24). This PR ships with that check failing by explicit decision of the release owner; reviewers should confirm that immediate activation of `valid_cdx_1_7` is intended.

## Images

- **release-policy** — `sha256:c5f849046794ca55c52f5d84b88e53858b299b759fa8a4827f6911dead422315`
- **task-policy** — `sha256:4785d7b7346ff5ec00736e85166b4d36ee726040dce8827051b35b71367de946`
- **build-task-policy** — `sha256:c74f8a90e75ec19c32d2d860b2c5c70f0c759ce5c86665b9f9f9c38f2606f0fe`
- **cli** — `sha256:a0cb6fcce80c6d0775e72802e4da58f050ca32ba32e1ea068d314df4a9536837` *(candidate at `:latest`; NOT shipped by this release — see Policy-Only Release)*
- **tekton-task** — `sha256:1e6d4b6fdd3886bda044ce063efa79e5f0175c9a720a97308ac5055774352ee6` *(candidate at `:latest`; NOT used — this release pins the input bundle to `sha256:e2ac3444...`)*

## Changes Since Last Release

### [conforma/policy](https://github.com/conforma/policy)

Source commits: [`fb1d3a6b..1b908855`](https://github.com/conforma/policy/compare/fb1d3a6b...1b908855)

- [#1945](https://github.com/conforma/policy/pull/1945) — Decide slsav1 task format from predicateType
- [#1871](https://github.com/conforma/policy/pull/1871) — fix(EC-2235): reject malformed Pipeline and Task values
- [#1943](https://github.com/conforma/policy/pull/1943) — Add CycloneDX 1.7 SBOM validation support
- [#1941](https://github.com/conforma/policy/pull/1941) — Signing identity checks for trusted task bundles
- [#1881](https://github.com/conforma/policy/pull/1881) — Update module github.com/sigstore/timestamp-authority/v2 to v2.1.0 [SECURITY] (main)
- [#1884](https://github.com/conforma/policy/pull/1884) — Update module go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp to v1.45.0 [SECURITY] (main)
- [#1878](https://github.com/conforma/policy/pull/1878) — Update module github.com/in-toto/go-witness to v0.9.1 [SECURITY] (main)
- [#1923](https://github.com/conforma/policy/pull/1923) — Update FullSend workflow pins
- [#1868](https://github.com/conforma/policy/pull/1868) — Set Codecov coverage targets to 100%
- [#1866](https://github.com/conforma/policy/pull/1866) — Support flexible disallowed date formats
- [#1867](https://github.com/conforma/policy/pull/1867) — Pin Fullsend references to upstream commits
- [#1679](https://github.com/conforma/policy/pull/1679) — 🚨 Update github actions (main) (major)
- [#1821](https://github.com/conforma/policy/pull/1821) — docs(#1820): document test attestation input contract in AGENTS.md
- [#1798](https://github.com/conforma/policy/pull/1798) — docs(#1797): add product and tool name casing conventions
- [#1819](https://github.com/conforma/policy/pull/1819) — docs(#1818): add opt-in/fail-closed exception to effective_on guidance
- [#1859](https://github.com/conforma/policy/pull/1859) — chore: update fullsend per-repo installation
- [#1858](https://github.com/conforma/policy/pull/1858) — chore: initialize fullsend per-repo installation
- [#1842](https://github.com/conforma/policy/pull/1842) — docs: require direct unit tests for new helper functions
- [#1851](https://github.com/conforma/policy/pull/1851) — docs(EC-2104): add THREAT_MODEL.md to change checklist for trust-boundary modifications
- [#1829](https://github.com/conforma/policy/pull/1829) — EC-2162: Verify ITS PipelineRuns use trusted tasks
- [#1832](https://github.com/conforma/policy/pull/1832) — EC-2026: Verify SBOM attestations with signing identities
- [#1848](https://github.com/conforma/policy/pull/1848) — docs(policy): document signing identity configuration
- [#1847](https://github.com/conforma/policy/pull/1847) — docs(EC-2103): fix stale trusted_task_rules architecture in THREAT_MODEL.md
- [#1826](https://github.com/conforma/policy/pull/1826) — Allow PNC SLSA build type for PipelineRun attestations
- [#1844](https://github.com/conforma/policy/pull/1844) — feat(EC-2081): use ec.oci.parsed_blob builtin in parsed_blob wrapper

### [conforma/cli](https://github.com/conforma/cli)

Source commits: [`f46a8040..5f59d023`](https://github.com/conforma/cli/compare/f46a8040...5f59d023)

- [#3632](https://github.com/conforma/cli/pull/3632) — chore(deps): Update ubi-minimal base image (main)
- [#3629](https://github.com/conforma/cli/pull/3629) — feat(validate): warn on deprecated VSA usage
- [#3628](https://github.com/conforma/cli/pull/3628) — Update FullSend workflow pins
- [#3602](https://github.com/conforma/cli/pull/3602) — fix(EC-2188): limit release PR builds to linux amd64
- [#3574](https://github.com/conforma/cli/pull/3574) — test: run ITS pipeline e2e checks on pull requests
- [#3606](https://github.com/conforma/cli/pull/3606) — Update module go.mongodb.org/mongo-driver to v1.17.7 [SECURITY] (main)
- [#3604](https://github.com/conforma/cli/pull/3604) — Update module github.com/containerd/containerd to v1.7.36 [SECURITY] (main)
- [#3598](https://github.com/conforma/cli/pull/3598) — docs(EC-2071): deprecate the ec track bundle command
- [#3603](https://github.com/conforma/cli/pull/3603) — ci: guard release workflow against forks
- [#3621](https://github.com/conforma/cli/pull/3621) — chore(deps): Update ubi-minimal base image (main)
- [#3591](https://github.com/conforma/cli/pull/3591) — test: add acceptance coverage for the ITS pipeline
- [#3573](https://github.com/conforma/cli/pull/3573) — chore(EC-2153): remove RH-specific policy digest defaults
- [#3599](https://github.com/conforma/cli/pull/3599) — Pin Fullsend references to upstream commits
- [#3485](https://github.com/conforma/cli/pull/3485) — fix(#3482): exclude vulnerability PRs from grouped patch updates
- [#3596](https://github.com/conforma/cli/pull/3596) — Fix shell interpolation in task reports
- [#3576](https://github.com/conforma/cli/pull/3576) — test(#3515): increase unit test timeout to 30s
- [#3595](https://github.com/conforma/cli/pull/3595) — fix: pin Fullsend with OpenShell 0.1.2
- [#3530](https://github.com/conforma/cli/pull/3530) — Find roxctl reports also using benchmark offliner
- [#3425](https://github.com/conforma/cli/pull/3425) — fix(EC-1994): correct off-by-one in validate image worker loop
- [#3592](https://github.com/conforma/cli/pull/3592) — fix: pin compatible Fullsend workflows
- [#3572](https://github.com/conforma/cli/pull/3572) — Pin dependencies (main)
- [#3586](https://github.com/conforma/cli/pull/3586) — chore: update fullsend per-repo installation
- [#3587](https://github.com/conforma/cli/pull/3587) — chore(deps): Update ubi-minimal base image (main)
- [#3582](https://github.com/conforma/cli/pull/3582) — chore: initialize fullsend per-repo installation
- [#3577](https://github.com/conforma/cli/pull/3577) — Remove unnecessary secrets: inherit from auto-merge caller
- [#3578](https://github.com/conforma/cli/pull/3578) — chore(deps): Update ubi-minimal base image (main)
- [#3441](https://github.com/conforma/cli/pull/3441) — Establish performance baselines and regression detection
- [#3570](https://github.com/conforma/cli/pull/3570) — chore(deps): Update ubi-minimal base image (main)
- [#3566](https://github.com/conforma/cli/pull/3566) — Update registry.access.redhat.com/ubi9/go-toolset:1.26.7 Docker digest to 685ccca (main)
- [#3539](https://github.com/conforma/cli/pull/3539) — docs(EC-2061): document dependency management strategy in AGENTS.md
- [#3540](https://github.com/conforma/cli/pull/3540) — docs(EC-2039): document expected skill format in AGENTS.md
- [#3557](https://github.com/conforma/cli/pull/3557) — EC-2028: consolidate sync primitives in PolicyUrl (source.go)
- [#3558](https://github.com/conforma/cli/pull/3558) — chore(deps): Update testcontainers-go and moby/go-archive (main)

## Policy Rule Changes

### release-policy

#### Added (6 rules)

**deny**

- **[Build task parameters are well-formed](https://conforma.dev/docs/policy/packages/release_buildah_build_task.html#buildah_build_task__malformed_parameter)** — Verify that the DOCKERFILE, ADD_CAPABILITIES, PLATFORM and PRIVILEGED_NESTED parameters of a builder Task, when present, are provided as strings. A non-string value (null, number, object or array), or a malformed parameter container that hides the parameters entirely, would otherwise be silently ignored by the parameter checks, allowing a malformed value to look like a pass.<br>Effective: 2027-01-11 · Collections: redhat, redhat_security
- **[Prefetch dependencies mode parameter check (v2)](https://conforma.dev/docs/policy/packages/release_prefetch_dependencies.html#prefetch_dependencies__mode_not_permissive_v2)** — Verify the prefetch-dependencies task in the PipelineRun attestation was not invoked with the "permissive" mode parameter, which could compromise security.<br>Effective: 2027-01-11 · Collections: redhat, redhat_security
- **[Valid 1.7](https://conforma.dev/docs/policy/packages/release_sbom_cyclonedx.html#sbom_cyclonedx__valid_cdx_1_7)** — Check the CycloneDX SBOM has the expected format. It verifies the CycloneDX SBOM matches the 1.7 version of the schema.<br>Effective: now · Collections: minimal, redhat, redhat_rpms, redhat_security
- **[All required test tasks are from trusted tasks](https://conforma.dev/docs/policy/packages/release_tasks.html#tasks__required_untrusted_test_task_found)** — Ensure that every required test task found in a build or latest applicable ITS PipelineRun has a trusted execution path. For an ITS PipelineRun, every applicable Task represented in its SLSA provenance must be trusted.<br>Effective: 2027-01-15 · Collections: redhat, redhat_security
- **[Test attestation includes an identity](https://conforma.dev/docs/policy/packages/release_test_attestation.html#test_attestation__test_identity_found)** — Ensure every test-result attestation provides a non-empty string in predicate.configuration[0].name. The name identifies repeated executions of the same integration test when selecting its latest result.<br>Effective: 2027-01-15 · Collections: redhat, redhat_security
- **[Test attestation includes a valid timestamp](https://conforma.dev/docs/policy/packages/release_test_attestation.html#test_attestation__test_timestamp_found)** — Ensure every signature-verified test-result attestation provides a valid RFC 3339 timestamp. The timestamp is required to select the latest retry deterministically.<br>Effective: 2027-01-15 · Collections: redhat, redhat_security

<details>
<summary>Task and build policy changes</summary>


### task-policy

#### Added (2 rules)

**deny**

- **[Required result defined (v2)](https://conforma.dev/docs/policy/packages/task_results.html#results__required_v2)** — Verify if Task defines the required result. This is controlled by the `required_task_results` rule data key. By default this is empty making this rule a no-op.<br>Effective: 2027-01-11 · Collections:
- **[Workspaces format](https://conforma.dev/docs/policy/packages/task_trusted_artifacts.html#trusted_artifacts__workspaces_format)** — Confirm that a Task implementing the Trusted Artifacts pattern declares its workspaces as a list. A present but malformed `spec.workspaces` (for example an object, a scalar or null) would otherwise silently skip the general purpose workspace check.<br>Effective: 2027-01-11 · Collections: redhat_security

### build-task-policy

#### Added (1 rules)

**deny**

- **[Build task has build type label (v2)](https://conforma.dev/docs/policy/packages/build_task_build_labels.html#build_labels__build_type_label_set_v2)** — Confirm the build task definition has the required build type label.<br>Effective: 2027-01-11 · Collections: redhat_security

</details>
