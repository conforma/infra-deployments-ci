Describe "check-release-inputs.sh"
  SCRIPT="./hack/check-release-inputs.sh"
  FIXTURE="spec/fixtures/release.json"

  setup() {
    setup_tmpdir
    export PATH="${MOCK_BIN}:${PATH}"
  }

  cleanup() {
    cleanup_tmpdir
  }

  Before "setup"
  After "cleanup"

  It "accepts a valid v2 manifest"
    When run script "$SCRIPT" "$FIXTURE"
    The status should be success
    The output should include "Release manifest OK"
  End

  It "rejects a manifest without schemaVersion"
    jq 'del(.schemaVersion)' "$FIXTURE" > "${TMPDIR}/v1.json"
    When run script "$SCRIPT" "${TMPDIR}/v1.json"
    The status should be failure
    The stderr should include "invalid release manifest"
  End

  It "rejects a v1 manifest"
    jq 'del(.schemaVersion, .inputs, .components[1].retentionTag)' "$FIXTURE" > "${TMPDIR}/old.json"
    When run script "$SCRIPT" "${TMPDIR}/old.json"
    The status should be failure
    The stderr should include "invalid release manifest"
  End

  It "rejects a manifest with a missing policy entry"
    jq 'del(.policy[2])' "$FIXTURE" > "${TMPDIR}/missing-policy.json"
    When run script "$SCRIPT" "${TMPDIR}/missing-policy.json"
    The status should be failure
    The stderr should include "ERROR"
  End

  It "rejects a manifest with a missing component"
    jq 'del(.components[0])' "$FIXTURE" > "${TMPDIR}/missing-cli.json"
    When run script "$SCRIPT" "${TMPDIR}/missing-cli.json"
    The status should be failure
    The stderr should include "ERROR"
  End

  It "rejects a manifest with a malformed digest"
    jq '.components[0].digest = "sha256:short"' "$FIXTURE" > "${TMPDIR}/bad-digest.json"
    When run script "$SCRIPT" "${TMPDIR}/bad-digest.json"
    The status should be failure
    The stderr should include "ERROR"
  End

  It "rejects a manifest without a retention tag"
    jq 'del(.components[1].retentionTag)' "$FIXTURE" > "${TMPDIR}/no-retention.json"
    When run script "$SCRIPT" "${TMPDIR}/no-retention.json"
    The status should be failure
    The stderr should include "ERROR"
  End

  It "rejects a manifest with a bad retention tag"
    jq '.components[1].retentionTag = "konflux"' "$FIXTURE" > "${TMPDIR}/bad-retention.json"
    When run script "$SCRIPT" "${TMPDIR}/bad-retention.json"
    The status should be failure
    The stderr should include "ERROR"
  End

  It "rejects a manifest with missing source bundle inputs"
    jq 'del(.inputs.sourceTaskBundle)' "$FIXTURE" > "${TMPDIR}/no-inputs.json"
    When run script "$SCRIPT" "${TMPDIR}/no-inputs.json"
    The status should be failure
    The stderr should include "ERROR"
  End

  Describe "catalog immutability checks"
    write_catalog_task() {
      local catalog="${TMPDIR}/catalog"
      mkdir -p "${catalog}/tasks/verify-enterprise-contract/0.1"
      cat > "${catalog}/tasks/verify-enterprise-contract/0.1/verify-enterprise-contract.yaml" <<<"$1"
    }

    VALID_TASK="apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: verify-enterprise-contract
  labels:
    app.kubernetes.io/version: \"0.1\"
spec:
  params:
    - name: POLICY_BUNDLE_DIGEST
      default: \"sha256:1111111111111111111111111111111111111111111111111111111111111111\"
  steps:
    - name: verify
      image: quay.io/conforma/cli@sha256:4444444444444444444444444444444444444444444444444444444444444444
    - name: setup
      ref:
        resolver: git
        params:
          - name: url
            value: https://github.com/konflux-ci/release-service-catalog
          - name: revision
            value: abcdef1234567890abcdef1234567890abcdef12
          - name: pathInRepo
            value: stepactions/create-trusted-artifact/create-trusted-artifact.yaml
"

    It "accepts a catalog matching the manifest"
      write_catalog_task "$VALID_TASK"
      When run script "$SCRIPT" "$FIXTURE" "${TMPDIR}/catalog"
      The status should be success
      The output should include "Release inputs OK"
    End

    It "rejects a CLI image that does not match the manifest"
      write_catalog_task "${VALID_TASK/cli@sha256:4444/cli@sha256:9999}"
      When run script "$SCRIPT" "$FIXTURE" "${TMPDIR}/catalog"
      The status should be failure
      The stderr should include "does not match the manifest"
    End

    It "rejects a mutable CLI image tag"
      write_catalog_task "${VALID_TASK/cli@sha256:4444444444444444444444444444444444444444444444444444444444444444/cli:latest}"
      When run script "$SCRIPT" "$FIXTURE" "${TMPDIR}/catalog"
      The status should be failure
      The stderr should include "mutable image reference"
    End

    It "rejects a wrong policy bundle digest default"
      write_catalog_task "${VALID_TASK/sha256:1111111111111111111111111111111111111111111111111111111111111111/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
      When run script "$SCRIPT" "$FIXTURE" "${TMPDIR}/catalog"
      The status should be failure
      The stderr should include "POLICY_BUNDLE_DIGEST"
    End

    It "rejects a POLICY_BUNDLE_DIGEST param with an empty default"
      write_catalog_task "${VALID_TASK/sha256:1111111111111111111111111111111111111111111111111111111111111111/}"
      When run script "$SCRIPT" "$FIXTURE" "${TMPDIR}/catalog"
      The status should be failure
      The stderr should include "POLICY_BUNDLE_DIGEST"
    End

    It "rejects a mutable StepAction revision"
      write_catalog_task "${VALID_TASK/value: abcdef1234567890abcdef1234567890abcdef12/value: development}"
      When run script "$SCRIPT" "$FIXTURE" "${TMPDIR}/catalog"
      The status should be failure
      The stderr should include "StepAction revision"
    End
  End
End
