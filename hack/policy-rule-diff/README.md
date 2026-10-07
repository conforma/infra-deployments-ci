# policy-rule-diff

Compares two OCI policy bundle images and reports which Rego policy rules
(deny/warn) were added or removed. Used by the release changelog to show
approvers exactly which policy behavior is changing.

Originally developed in [conforma/policy](https://github.com/conforma/policy)
(`hack/policy-rule-diff/`), where the git-ref comparison mode is still
useful for local development.

## Usage

```bash
# Compare two bundle tags (primary use case)
go run ./hack/policy-rule-diff -bundle -json \
  quay.io/conforma/release-policy:konflux \
  quay.io/conforma/release-policy:latest

# Human-readable output (colored, for terminal use)
go run ./hack/policy-rule-diff -bundle \
  quay.io/conforma/release-policy:konflux \
  quay.io/conforma/release-policy:latest

# Compare two local Rego files
go run ./hack/policy-rule-diff -before old.rego -after new.rego
```

## JSON Output

With `-json`, the tool writes structured JSON to stdout (progress messages go
to stderr):

```json
{
  "before": "quay.io/conforma/release-policy:konflux",
  "after": "quay.io/conforma/release-policy:latest",
  "added": [
    {
      "short_name": "experimental_hermeto_backend",
      "kind": "deny",
      "package": "sbom_cyclonedx",
      "title": "Experimental Hermeto backend",
      "description": "...",
      "effective_on": "2026-08-01T00:00:00Z",
      "collections": ["minimal", "redhat", "redhat_rpms"],
      "file": "policy/release/sbom_cyclonedx/hermeto.rego",
      "source": "deny contains result if { ... }"
    }
  ],
  "removed": [],
  "files": {
    "policy/release/sbom_cyclonedx/hermeto.rego": {
      "before": "",
      "after": "... full file content ..."
    }
  }
}
```

Key fields for changelog generation:

| Field | Description |
|-------|-------------|
| `short_name` | Stable rule identifier |
| `kind` | `deny` or `warn` |
| `title` | Human-readable rule name |
| `effective_on` | ISO 8601 date when the rule activates (empty = immediately) |
| `collections` | Policy collections the rule belongs to |

The `files` map contains full before/after Rego source for changed files,
useful for detailed analysis but not needed for changelog summaries.

## Flags

| Flag | Description |
|------|-------------|
| `-bundle` | Compare two OCI bundle image references (positional args) |
| `-json` | Output structured JSON instead of colored terminal output |
| `-before` / `-after` | Compare two local files directly |
| `-no-color` | Disable colored terminal output |
| `-min-effective-lead-days N` | Fail if an added rule has no valid RFC3339 `effective_on` at least N days away (default: disabled). The release pull request check uses 56 days. |

The [release pull request workflow](../../.github/workflows/check-release-lead-time.yaml)
runs when files under `releases/` change. It checks each policy image pinned in
the submitted `releases/<date>/images.json` against its current `:konflux`
image, and fails if any new rule has less than 56 days of lead time.
Changelog generation does not run this validation.

The [checker test workflow](../../.github/workflows/test-release-lead-time.yaml)
runs when the lead-time implementation changes. It runs the rule-diff unit
tests and a mocked release-helper test before the code is merged.
