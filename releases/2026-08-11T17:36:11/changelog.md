# Konflux Policy Release

> Conforma policy update for Red Hat's Konflux deployment.

## Images

- **release-policy** — `sha256:ee5c3a020c9545eca738ed87198af0b235463069b2d72c5dba609364a83321d2`
- **task-policy** — `sha256:39bbb84f9137bd270b61979b3284e3c7886e06fe4347594614bc6f45188179ce`
- **build-task-policy** — `sha256:932e9371203115b883a000eba0b350d25ef8fd9d6e6751f6f999889c0e3db32d`
- **cli** — `sha256:871fbcc2e4dc7f0edeb6c7c9f60536e0dc580948cb6c7de719142b6e7685bad9`
- **tekton-task** — `sha256:e097724eb48295d640d245591576273dc33e2d3e70248f2cc241684f35d47dbf`

## Changes Since Last Release

### [conforma/policy](https://github.com/conforma/policy)

Source commits: [`38d2e311..7c9b0e0f`](https://github.com/conforma/policy/compare/38d2e311...7c9b0e0f)

- [#1796](https://github.com/conforma/policy/pull/1796) — EC-2016: require Hermeto attribution for vendored dependency ecosystems
- [#1775](https://github.com/conforma/policy/pull/1775) — fix(#1774): update stale registry ref to conforma
- [#1786](https://github.com/conforma/policy/pull/1786) — Merge pipeline-required-tasks from ruleData config
- [#1795](https://github.com/conforma/policy/pull/1795) — feat(EC-2060): extend CVE policy to accept ROXCTL scan reports
- [#1794](https://github.com/conforma/policy/pull/1794) — Add threat model for the policy repo
- [#1780](https://github.com/conforma/policy/pull/1780) — feat(EC-1957): verify base image release signatures
- [#1783](https://github.com/conforma/policy/pull/1783) — docs(#1782): fix make ci description in AGENTS.md
- [#1769](https://github.com/conforma/policy/pull/1769) — fix(#1768): remove stale .adoc files before doc generation
- [#1790](https://github.com/conforma/policy/pull/1790) — docs(EC-1932): add Rego evaluation model guidance to AGENTS.md
- [#1789](https://github.com/conforma/policy/pull/1789) — docs(EC-1954): add effective_on review checklist to AGENTS.md
- [#1791](https://github.com/conforma/policy/pull/1791) — Add 18 rules to the redhat_security collection
- [#1779](https://github.com/conforma/policy/pull/1779) — chore: add AgentReady scaffolding for AI-assisted development
- [#1766](https://github.com/conforma/policy/pull/1766) — Add redhat_security policy collection
- [#1771](https://github.com/conforma/policy/pull/1771) — Update quay.io references from enterprise-contract to conforma
- [#1770](https://github.com/conforma/policy/pull/1770) — feat(EC-1950,EC-1982): test attestation parity and trust verification fixes
- [#1763](https://github.com/conforma/policy/pull/1763) — fix(EC-1971): set GEMINI_CLI_TRUST_WORKSPACE in release workflow
- [#1736](https://github.com/conforma/policy/pull/1736) — feat: deny releases using experimental Hermeto backends
- [#1741](https://github.com/conforma/policy/pull/1741) — feat(EC-1797): support version constraints for git resolver task references

### [conforma/cli](https://github.com/conforma/cli)

Source commits: [`15814bf9..0250ec50`](https://github.com/conforma/cli/compare/15814bf9...0250ec50)

- [#3465](https://github.com/conforma/cli/pull/3465) — Fix case-insensitive HTTP scheme bypass in isSecure()
- [#3412](https://github.com/conforma/cli/pull/3412) — Include enforcement date in warnings for future effective_on violations
- [#3469](https://github.com/conforma/cli/pull/3469) — chore(deps): Update ubi-minimal base image (main)
- [#3471](https://github.com/conforma/cli/pull/3471) — Update github/codeql-action action to v4.37.5 (main)
- [#3472](https://github.com/conforma/cli/pull/3472) — Add imagePullPolicy: IfNotPresent to task and pipeline steps
- [#3463](https://github.com/conforma/cli/pull/3463) — Pin third-party action to immutable ref in release workflow
- [#3466](https://github.com/conforma/cli/pull/3466) — Add threat model for the CLI
- [#3457](https://github.com/conforma/cli/pull/3457) — docs(EC-1980): add product naming guidance to AGENTS.md
- [#3292](https://github.com/conforma/cli/pull/3292) — Update module github.com/in-toto/in-toto-golang to v0.11.0 [SECURITY] (main)
- [#3270](https://github.com/conforma/cli/pull/3270) — Update registry.access.redhat.com/ubi9/ubi-minimal:latest Docker digest to 48fa5d8 (main)
- [#3224](https://github.com/conforma/cli/pull/3224) — Update module helm.sh/helm/v3 to v3.20.2 [SECURITY] (main)
- [#3455](https://github.com/conforma/cli/pull/3455) — Update registry.access.redhat.com/ubi9/ubi-minimal:latest Docker digest to 48fa5d8 (main) - autoclosed
- [#3454](https://github.com/conforma/cli/pull/3454) — chore(deps): Update ubi-minimal base image (main)
- [#3399](https://github.com/conforma/cli/pull/3399) — Update module github.com/sigstore/sigstore-go to v1.2.1 [SECURITY] (main)
- [#3450](https://github.com/conforma/cli/pull/3450) — Update Konflux references (main)
- [#3434](https://github.com/conforma/cli/pull/3434) — feat(EC-1862): add AI skills for ec-cli
- [#3384](https://github.com/conforma/cli/pull/3384) — Bump conforma/go-containerregistry
- [#3448](https://github.com/conforma/cli/pull/3448) — Update github actions (main) (patch)
- [#3438](https://github.com/conforma/cli/pull/3438) — fix(#3437): use distinct digest in VEC pin-policy-bundle test
- [#3282](https://github.com/conforma/cli/pull/3282) — Update github actions (main) (minor)
- [#3447](https://github.com/conforma/cli/pull/3447) — chore(deps): UBI bump & update oras.land/oras-go/v2 (main)
- [#3424](https://github.com/conforma/cli/pull/3424) — fix(EC-1993): reject past --effective-time values by default
- [#3440](https://github.com/conforma/cli/pull/3440) — fix: disable global timeout for --server mode
- [#3254](https://github.com/conforma/cli/pull/3254) — Update Konflux references (main) (minor)
- [#3442](https://github.com/conforma/cli/pull/3442) — chore(deps): Update github.com/sigstore/fulcio (main)
- [#3435](https://github.com/conforma/cli/pull/3435) — Add enterprise-contract pipeline definition to cli/pipelines
- [#3439](https://github.com/conforma/cli/pull/3439) — chore(deps): Remove Renovate annotations from .tekton files
- [#3431](https://github.com/conforma/cli/pull/3431) — Fix pinned ref cache miss to avoid policy refetch
- [#3324](https://github.com/conforma/cli/pull/3324) — Add pin-policy-bundle acceptance tests for TA task
- [#3433](https://github.com/conforma/cli/pull/3433) — [EC-1776] docs: Document Cicada content stream update in release process
- [#3429](https://github.com/conforma/cli/pull/3429) — chore(deps): Update ubi-minimal base image (main)
- [#3417](https://github.com/conforma/cli/pull/3417) — Run e2e tests on push to main instead of on every PR
- [#3418](https://github.com/conforma/cli/pull/3418) — fix(EC-1912): validate in-toto statement type in bundle attestation path
- [#3423](https://github.com/conforma/cli/pull/3423) — chore(deps): Pin Go builder image by digest
- [#3415](https://github.com/conforma/cli/pull/3415) — chore: add AgentReady scaffolding for AI-assisted development
- [#3408](https://github.com/conforma/cli/pull/3408) — Update https://github.com/conforma/e2e-tests digest to 2f3c802 (main)
- [#3298](https://github.com/conforma/cli/pull/3298) — [troubleshooting] Add ryuk troubleshooting section to README
- [#3406](https://github.com/conforma/cli/pull/3406) — deps: Update github.com/sigstore/rekor (main)
- [#3385](https://github.com/conforma/cli/pull/3385) — fix(EC-1977): migrate tenant-release SA to konflux-bot-0
- [#3386](https://github.com/conforma/cli/pull/3386) — Add validate input --server flag for persistent HTTP/REST
- [#3393](https://github.com/conforma/cli/pull/3393) — Update quay.io references from enterprise-contract to conforma
- [#3403](https://github.com/conforma/cli/pull/3403) — Build output fix for kubectl version plus deps updates
- [#3391](https://github.com/conforma/cli/pull/3391) — chore(deps): Update oras.land/oras-go/v2
- [#3378](https://github.com/conforma/cli/pull/3378) — Update module oras.land/oras-go/v2 to v2.6.1 [SECURITY] (main)
- [#3383](https://github.com/conforma/cli/pull/3383) — feat(#1512): remove abandoned generated documentation files
- [#3381](https://github.com/conforma/cli/pull/3381) — feat(#3345): improve error messages for Rego compilation failures
- [#3382](https://github.com/conforma/cli/pull/3382) — feat(#1313): accept positional args for validate input
- [#3136](https://github.com/conforma/cli/pull/3136) — sigstore: Cache verify_image results across policy evaluations
- [#3331](https://github.com/conforma/cli/pull/3331) — feat(EC-1816): add multi-component stress benchmark
- [#3329](https://github.com/conforma/cli/pull/3329) — style(#3160): use explicit 0o octal notation for file permissions
- [#3376](https://github.com/conforma/cli/pull/3376) — feat:  pass custom cli params to e2e pipeline for pull requests
- [#3374](https://github.com/conforma/cli/pull/3374) — Update https://github.com/conforma/e2e-tests digest to f49f4a2 (main)
- [#3357](https://github.com/conforma/cli/pull/3357) — Konflux task refs and other dependency updates (main)
- [#3334](https://github.com/conforma/cli/pull/3334) — Trigger conforma e2e tests on cli pull requests

## Policy Rule Changes

### release-policy

#### Added (9 rules)

**deny**

- **[Experimental Hermeto backend](https://conforma.dev/docs/policy/packages/release_sbom_cyclonedx.html#sbom_cyclonedx__experimental_hermeto_backend)** — Verify that no components in the CycloneDX SBOM were fetched using an experimental Hermeto backend. Experimental backends are identified by<br>Effective: 2026-08-01 · Collections: minimal, redhat, redhat_rpms
- **[Hermeto attribution required](https://conforma.dev/docs/policy/packages/release_sbom_cyclonedx.html#sbom_cyclonedx__hermeto_attribution_required)** — Registry dependencies with a PURL type listed in vendored_purl_types must be processed by Hermeto. When a hermetic build omits prefetch-input for a vendored ecosystem, Hermeto never runs and the SBOM contains only Syft-reported module-level data, which is insufficient for CVE analysis.<br>Effective: 2026-10-01 · Collections: redhat, policy_data, redhat_security
- **[Experimental Hermeto backend](https://conforma.dev/docs/policy/packages/release_sbom_spdx.html#sbom_spdx__experimental_hermeto_backend)** — Verify that no packages in the SPDX SBOM were fetched using an experimental Hermeto backend. Experimental backends are identified by annotations with<br>Effective: 2026-08-01 · Collections: minimal, redhat, redhat_rpms
- **[Hermeto attribution required](https://conforma.dev/docs/policy/packages/release_sbom_spdx.html#sbom_spdx__hermeto_attribution_required)** — Registry dependencies with a PURL type listed in vendored_purl_types must be processed by Hermeto. When a hermetic build omits prefetch-input for a vendored ecosystem, Hermeto never runs and the SBOM contains only Syft-reported module-level data, which is insufficient for CVE analysis.<br>Effective: 2026-10-01 · Collections: redhat, policy_data, redhat_security
- **[No erred test attestations](https://conforma.dev/docs/policy/packages/release_test_attestation.html#test_attestation__no_erred_test_attestations)** — Produce a violation if any test result attestation has an erred result. The result type is configurable by the "erred_test_attestation_results" key in the rule data.<br>Effective: now · Collections: redhat
- **[No skipped test attestations](https://conforma.dev/docs/policy/packages/release_test_attestation.html#test_attestation__no_skipped_test_attestations)** — Produce a violation if any test result attestation has a skipped result. A skipped result means a pre-requirement for executing the test was not met. The result type is configurable by the "skipped_test_attestation_results" key in the rule data.<br>Effective: now · Collections: redhat
- **[Rule data provided](https://conforma.dev/docs/policy/packages/release_test_attestation.html#test_attestation__rule_data_provided)** — Confirm the expected rule data keys have been provided in the expected format. The keys are "supported_test_attestation_results", "failed_test_attestation_results", "erred_test_attestation_results", "skipped_test_attestation_results", "warned_test_attestation_results", and "informative_test_attestations".<br>Effective: now · Collections: redhat, policy_data
- **[Test attestation subject matches image](https://conforma.dev/docs/policy/packages/release_test_attestation.html#test_attestation__subject_mismatch)** — Verify that each test-result attestation's subject includes the digest of the image being evaluated. An attestation produced for a different image should not satisfy this image's test requirements.<br>Effective: now · Collections: redhat
**warn**

- **[No failed informative test attestations](https://conforma.dev/docs/policy/packages/release_test_attestation.html#test_attestation__no_failed_informative_test_attestations)** — Produce a warning if any informative test attestation has a failed result. Informative tests produce warnings instead of violations, allowing teams to roll out new tests without blocking releases. The list of informative tests is configurable by the "informative_test_attestations" key, and the result type by the "failed_test_attestation_results" key in the rule data.<br>Effective: now · Collections: redhat

<details>
<summary>Task and build policy changes</summary>


### task-policy

No rule changes.

### build-task-policy

No rule changes.

</details>
