# Konflux Policy Release

> Conforma policy update for Red Hat's Konflux deployment.

## Images

- **release-policy** — `sha256:14c117a834d2ce3310d633b7d70bee8aba83f8d590a120b835c7e3731eaf183f`
- **task-policy** — `sha256:00444a90a1679351e96f0fb07c83ee51061f5247caf6186efe997bdd91cef7f5`
- **build-task-policy** — `sha256:0cfe667dbb641996b08a1f154c7497fe82bc44094e3a6ccb906804b32d91d33f`
- **cli** — `sha256:41c5359d57538974800cdffa48cd0ca6e654325e8a8cf2f7c4ad57487bb8f035`
- **tekton-task** — `sha256:432950381863d5953bf8e0634515a1cfbc347cca314348abca1a51122e017da8`

## Changes Since Last Release

### [conforma/policy](https://github.com/conforma/policy)

Source commits: [`2fed4e7e..e1d2b116`](https://github.com/conforma/policy/compare/2fed4e7e...e1d2b116)

- [#1975](https://github.com/conforma/policy/pull/1975) — fix(fullsend): match GitHub App author logins
- [#1970](https://github.com/conforma/policy/pull/1970) — fix(fullsend): skip reviews for Renovate and Konflux bots
- [#1959](https://github.com/conforma/policy/pull/1959) — Add new release-time CVEs check with grace periods
- [#1950](https://github.com/conforma/policy/pull/1950) — fix(sbom): revert Hermeto attribution requirement
- [#1928](https://github.com/conforma/policy/pull/1928) — 🚨 Update dependency ubuntu to v26 (main)
- [#1962](https://github.com/conforma/policy/pull/1962) — chore(EC-2322): group OpenTelemetry modules and vulnerability alerts in Renovate
- [#1957](https://github.com/conforma/policy/pull/1957) — ci(#1925): add static check for go directive drift across modules
- [#1940](https://github.com/conforma/policy/pull/1940) — Bring back local handling of coverage output
- [#1958](https://github.com/conforma/policy/pull/1958) — chore(EC-2345): skip fullsend review for Renovate bot PRs
- [#1953](https://github.com/conforma/policy/pull/1953) — ci: generate release notes with pinned Gemini CLI
- [#1952](https://github.com/conforma/policy/pull/1952) — Set effective_on for valid_cdx_1_7

### [conforma/cli](https://github.com/conforma/cli)

Source commits: [`0556e84a..0ff104c4`](https://github.com/conforma/cli/compare/0556e84a...0ff104c4)

- [#3740](https://github.com/conforma/cli/pull/3740) — fix(fullsend): skip reviews for Renovate and Konflux bots
- [#3727](https://github.com/conforma/cli/pull/3727) — Handle the mirror release-policy reference
- [#3748](https://github.com/conforma/cli/pull/3748) — chore(deps): Update ubi, golang & containerd/v2 (main)
- [#3664](https://github.com/conforma/cli/pull/3664) — Add optional runtime policy data to Konflux trusted-artifact validation
- [#3714](https://github.com/conforma/cli/pull/3714) — chore(deps): Update ubi-minimal base image (main)
- [#3670](https://github.com/conforma/cli/pull/3670) — Update Konflux references (main) (patch)
- [#3659](https://github.com/conforma/cli/pull/3659) — Update github actions (main)
- [#3600](https://github.com/conforma/cli/pull/3600) — chore: sync deprecated ITS pipeline copy

## Policy Rule Changes

### release-policy

#### Added (3 rules)

**deny**

- **[CVEs past their release-time grace period](https://conforma.dev/docs/policy/packages/release_release_time_cve.html#release_time_cve__advisory_grace_period_expired)** — Block releases containing CVEs in RHSA advisories after the severity-specific grace period. Without configuration the defaults are 30 days for CRITICAL and 60 for IMPORTANT. If `release_time_cve_leeway` is configured, omitted severities have no grace period (0 days). Advisory data is expected in the `collector_data` runtime data key under `rhsa`. Only advisories listing input.component_name in their components apply.<br>Effective: 2027-07-01 · Collections: redhat, redhat_security
- **[Release-time CVE leeway rule data provided](https://conforma.dev/docs/policy/packages/release_release_time_cve.html#release_time_cve__rule_data_provided)** — Confirm that release_time_cve_leeway specifies non-negative integer day counts for the supported advisory severity levels.<br>Effective: 2027-07-01 · Collections: redhat, redhat_security, policy_data
- **[Release-time CVE data format](https://conforma.dev/docs/policy/packages/release_release_time_cve.html#release_time_cve__runtime_data_format)** — Require runtime collector data with `rhsa` CRITICAL and IMPORTANT arrays and validate advisory IDs, release timestamps, CVE entries, and affected component names. Require input.component_name to associate advisories with the evaluated component. Empty severity arrays represent a successful collection with no advisories.<br>Effective: 2027-07-01 · Collections: redhat, redhat_security

#### Removed (2 rules)

**deny**

- **[Hermeto attribution required](https://conforma.dev/docs/policy/packages/release_sbom_cyclonedx.html#sbom_cyclonedx__hermeto_attribution_required)** — Registry dependencies with a PURL type listed in vendored_purl_types must be processed by Hermeto. When a hermetic build omits prefetch-input for a vendored ecosystem, Hermeto never runs and the SBOM contains only Syft-reported module-level data, which is insufficient for CVE analysis.<br>Collections: redhat, policy_data, redhat_security
- **[Hermeto attribution required](https://conforma.dev/docs/policy/packages/release_sbom_spdx.html#sbom_spdx__hermeto_attribution_required)** — Registry dependencies with a PURL type listed in vendored_purl_types must be processed by Hermeto. When a hermetic build omits prefetch-input for a vendored ecosystem, Hermeto never runs and the SBOM contains only Syft-reported module-level data, which is insufficient for CVE analysis.<br>Collections: redhat, policy_data, redhat_security

<details>
<summary>Task and build policy changes</summary>


### task-policy

No rule changes.

### build-task-policy

No rule changes.

</details>

## Policy Behavior Changes

- Current CLI: `quay.io/conforma/cli:konflux`
- Candidate CLI: `quay.io/conforma/cli@sha256:41c5359d57538974800cdffa48cd0ca6e654325e8a8cf2f7c4ad57487bb8f035`
- Current policy: `oci::quay.io/conforma/release-policy:konflux`
- Candidate policy: `oci::quay.io/conforma/release-policy@sha256:14c117a834d2ce3310d633b7d70bee8aba83f8d590a120b835c7e3731eaf183f`
- Effective time: `2026-11-23T18:17:42Z`
- Policy template: `hack/policy-behavior/golden-policy.yaml`
- Policy data: `["oci::quay.io/redhat-konflux/policy-data:latest"]`

### Golden container

- Target image: `quay.io/konflux-ci/ec-golden-image@sha256:d77b83349cb8e24f835a52d08887dde5c32128c16425b3cb528aeda9dc6703e0`
- Policy collection: `@redhat`

No behavior changes.

### Golden RPM

- Target image: `quay.io/redhat-user-workloads/rhtap-contract-tenant/golden-rpm/golden-rpm@sha256:cd54bf6d8ab45b5a7a2323cdb16e188cbf1f209b027a225a31e2004af3143772`
- Policy collection: `@redhat_rpms`

No behavior changes.

