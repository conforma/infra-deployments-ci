Describe "compare-policy-behavior.sh"
  SCRIPT="./hack/policy-behavior/compare-policy-behavior.sh"

  setup() {
    setup_tmpdir
    export CONTAINER_ENGINE="mock-container"
    export POLICY_BEHAVIOR_EFFECTIVE_TIME="2026-09-16T15:00:00Z"
    export VALIDATION_LOG="${TMPDIR}/validation.log"
    export VALIDATION_COUNT_FILE="${TMPDIR}/validation-count"
    export CRANE_LOG="${TMPDIR}/crane.log"
    export POLICY_LOG="${TMPDIR}/policy.log"
    export CRANE_COUNT_DIR="${TMPDIR}/crane-counts"
    mkdir -p "$CRANE_COUNT_DIR"

    cat > "${MOCK_BIN}/crane" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ref="$2"
printf '%s\n' "$ref" >> "$CRANE_LOG"
if [[ "${MOCK_CRANE_MODE:-}" == "fail" ]]; then
  echo "simulated pull failure" >&2
  exit 19
fi
key=$(printf '%s' "$ref" | tr '/:@.' '_')
count_file="${CRANE_COUNT_DIR}/${key}"
count=0
[[ -f "$count_file" ]] && count=$(<"$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
case "$ref" in
  quay.io/konflux-ci/ec-golden-image:latest)
    printf 'sha256:%064d\n' 1
    ;;
  quay.io/redhat-user-workloads/rhtap-contract-tenant/golden-rpm/golden-rpm:on-pr-10ea4af075719a4626bd8e8487fd76dbe456a862.calculation-x86_64)
    printf 'sha256:%064d\n' 2
    ;;
  quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest)
    printf 'sha256:%064d\n' 3
    ;;
  *)
    echo "unexpected crane ref: $ref" >&2
    exit 1
    ;;
esac
EOF
    chmod +x "${MOCK_BIN}/crane"

    cat > "${MOCK_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ls-remote" ]]; then
  printf '%040d refs/heads/main\n' 4
else
  echo "unexpected git command: $*" >&2
  exit 1
fi
EOF
    chmod +x "${MOCK_BIN}/git"

    cat > "${MOCK_BIN}/mock-container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf '%s\n' "$args" >> "$VALIDATION_LOG"
policy_file=""
for arg in "$@"; do
  case "$arg" in
    *:/workspace/golden-policy.yaml:ro)
      policy_file="${arg%:/workspace/golden-policy.yaml:ro}"
      ;;
  esac
done
[[ -n "$policy_file" && -f "$policy_file" ]] || {
  echo "mounted policy file not found" >&2
  exit 98
}
{
  printf '%s\n' '--- validation policy ---'
  cat "$policy_file"
} >> "$POLICY_LOG"

if [[ "$args" == *"quay.io/conforma/cli:konflux"* ]]; then
  expected_policy="oci::quay.io/conforma/release-policy:konflux"
else
  expected_policy="oci::quay.io/conforma/release-policy@sha256:3333333333333333333333333333333333333333333333333333333333333333"
fi
grep -Fq -- "- ${expected_policy}" "$policy_file" || {
  echo "policy file does not match CLI release" >&2
  exit 97
}

if [[ "$args" == *"ec-golden-image@sha256:"* ]]; then
  expected_collection="@redhat"
else
  expected_collection="@redhat_rpms"
fi
grep -Fq -- "- '${expected_collection}'" "$policy_file" || {
  echo "policy collection does not match target" >&2
  exit 96
}

count=$(wc -l < "$VALIDATION_LOG" | tr -d ' ')
if [[ "$count" -gt 4 ]]; then
  echo "more than four validation commands" >&2
  exit 99
fi
printf '%s\n' "$count" > "$VALIDATION_COUNT_FILE"
if [[ "${MOCK_CONTAINER_MODE:-}" == "fail" ]]; then
  echo "image pull failed" >&2
  exit 17
fi
if [[ "${MOCK_CONTAINER_MODE:-}" == "malformed" ]]; then
  echo '{}'
  exit 0
fi
if [[ "${MOCK_CONTAINER_MODE:-}" == "no-change" ]]; then
  echo '{"components":[{"violations":[],"warnings":[]}]}'
  exit 0
fi

new=0
[[ "$args" == *"cli@sha256:4444444444444444444444444444444444444444444444444444444444444444"* ]] && new=1
if [[ "$args" == *"ec-golden-image@sha256:"* ]]; then
  if [[ "$new" -eq 1 ]]; then
    cat <<'JSON'
{"components":[{"violations":[{"metadata":{"code":"new.container"}},{"metadata":{"code":"transition.rule"}}],"warnings":[{"msg":"new uncoded warning"}]},{"violations":[{"metadata":{"code":"new.container"}},{"metadata":{"code":"transition.rule"}}],"warnings":[{"msg":"new uncoded warning"}]}]}
JSON
  else
    cat <<'JSON'
{"components":[{"violations":[{"metadata":{"code":"old.container"}}],"warnings":[{"metadata":{"code":"transition.rule"}}]},{"violations":[{"metadata":{"code":"old.container"}}],"warnings":[{"msg":"duplicate architecture warning"}]}]}
JSON
  fi
else
  echo '{"components":[{"violations":[],"warnings":[]}]}'
fi
EOF
    chmod +x "${MOCK_BIN}/mock-container"
    export PATH="${MOCK_BIN}:${PATH}"

    cat > "${TMPDIR}/candidate-images.json" <<'EOF'
{
  "policy": [{
    "image": "quay.io/conforma/release-policy",
    "digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333"
  }],
  "components": [{
    "image": "quay.io/conforma/cli",
    "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444"
  }]
}
EOF
  }

  cleanup() {
    cleanup_tmpdir
  }

  Before "setup"
  After "cleanup"

  It "runs four current and candidate validations with shared inputs and renders changes"
    When run script "$SCRIPT" --report "${TMPDIR}/report.md" "${TMPDIR}/candidate-images.json"
    The status should be success
    The contents of file "${VALIDATION_COUNT_FILE}" should equal 4
    The output should include "Policy Behavior Changes"
    The stderr should include "Running Golden container"
    The contents of file "${VALIDATION_LOG}" should include "validate image"
    The contents of file "${VALIDATION_LOG}" should include "quay.io/conforma/cli:konflux"
    The contents of file "${VALIDATION_LOG}" should include "quay.io/conforma/cli@sha256:4444444444444444444444444444444444444444444444444444444444444444"
    The contents of file "${VALIDATION_LOG}" should include "--policy /workspace/golden-policy.yaml"
    The contents of file "${POLICY_LOG}" should include "kind: EnterpriseContractPolicy"
    The contents of file "${POLICY_LOG}" should include "oci::quay.io/conforma/release-policy:konflux"
    The contents of file "${POLICY_LOG}" should include "oci::quay.io/conforma/release-policy@sha256:3333333333333333333333333333333333333333333333333333333333333333"
    The contents of file "${POLICY_LOG}" should include "oci::quay.io/redhat-konflux/policy-data:latest"
    The contents of file "${VALIDATION_LOG}" should include "--allow-past-effective-time"
    The contents of file "${POLICY_LOG}" should include "'@redhat'"
    The contents of file "${POLICY_LOG}" should include "'@redhat_rpms'"
    The contents of file "${TMPDIR}/report.md" should include "Added violations"
    The contents of file "${TMPDIR}/report.md" should include "Removed warnings"
    The contents of file "${TMPDIR}/report.md" should include "new.container"
    The contents of file "${TMPDIR}/report.md" should include "No behavior changes."
    The contents of file "${TMPDIR}/report.md" should include "2026-09-16T15:00:00Z"
  End

  It "preserves warning-to-violation changes and deduplicates architectures"
    When run script "$SCRIPT" --report "${TMPDIR}/report.md" "${TMPDIR}/candidate-images.json"
    The status should be success
    The output should include "Policy Behavior Changes"
    The stderr should include "Running Golden RPM"
    The contents of file "${TMPDIR}/report.md" should include "transition.rule"
    The contents of file "${TMPDIR}/report.md" should include "new uncoded warning"
  End

  It "fails for a missing candidate CLI entry"
    jq 'del(.components)' "${TMPDIR}/candidate-images.json" > "${TMPDIR}/missing-cli.json"
    When run script "$SCRIPT" "${TMPDIR}/missing-cli.json"
    The status should be failure
    The stderr should include "missing policy/components arrays"
  End

  It "fails for a missing candidate policy entry"
    jq 'del(.policy)' "${TMPDIR}/candidate-images.json" > "${TMPDIR}/missing-policy.json"
    When run script "$SCRIPT" "${TMPDIR}/missing-policy.json"
    The status should be failure
    The stderr should include "missing policy/components arrays"
  End

  It "fails for invalid candidate JSON"
    printf '%s\n' 'not-json' > "${TMPDIR}/invalid.json"
    When run script "$SCRIPT" "${TMPDIR}/invalid.json"
    The status should be failure
    The stderr should include "invalid or is missing policy/components arrays"
  End

  It "fails for a malformed validation report"
    export MOCK_CONTAINER_MODE="malformed"
    When run script "$SCRIPT" "${TMPDIR}/candidate-images.json"
    The status should be failure
    The stderr should include "malformed JSON report"
  End

  It "fails for an operational validation error"
    export MOCK_CONTAINER_MODE="fail"
    When run script "$SCRIPT" "${TMPDIR}/candidate-images.json"
    The status should be failure
    The stderr should include "validation command failed"
    The stderr should include "image pull failed"
  End

  It "fails before validation for an invalid policy template"
    printf '%s\n' 'kind: ConfigMap' > "${TMPDIR}/invalid-policy.yaml"
    When run script "$SCRIPT" --policy-template "${TMPDIR}/invalid-policy.yaml" "${TMPDIR}/candidate-images.json"
    The status should be failure
    The stderr should include "Policy template is not a valid EnterpriseContractPolicy"
    The path "${VALIDATION_LOG}" should not be file
  End

  It "fails when a target digest cannot be resolved"
    export MOCK_CRANE_MODE="fail"
    When run script "$SCRIPT" "${TMPDIR}/candidate-images.json"
    The status should be failure
    The stderr should include "Failed to resolve image digest"
  End

  It "renders no-change output when both releases match"
    export MOCK_CONTAINER_MODE="no-change"
    When run script "$SCRIPT" "${TMPDIR}/candidate-images.json"
    The status should be success
    The output should include "No behavior changes."
    The stderr should include "Running Golden RPM"
  End
End
