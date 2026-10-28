Describe "extract-bundle-resources.sh"
  SCRIPT="./hack/extract-bundle-resources.sh"

  setup() {
    setup_tmpdir
    create_mock_crane
    export CRANE_DATA="${TMPDIR}/crane"
    export PATH="${MOCK_BIN}:${PATH}"
  }

  cleanup() {
    cleanup_tmpdir
  }

  Before "setup"
  After "cleanup"

  Describe "extracts tasks from a bundle"
    setup_bundle() {
      cat > "${TMPDIR}/crane/manifest.json" <<'EOF'
{
  "layers": [
    {
      "digest": "sha256:aaa111",
      "annotations": {
        "dev.tekton.image.kind": "task",
        "dev.tekton.image.name": "verify-enterprise-contract"
      }
    },
    {
      "digest": "sha256:bbb222",
      "annotations": {
        "dev.tekton.image.kind": "task",
        "dev.tekton.image.name": "collect-keyless-params"
      }
    }
  ]
}
EOF

      create_blob "sha256:aaa111" "apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: verify-enterprise-contract
  labels:
    app.kubernetes.io/version: \"0.1\"
spec:
  params:
  - name: POLICY_BUNDLE_DIGEST
    default: \"sha256:olddigest\"
"

      create_blob "sha256:bbb222" "apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: collect-keyless-params
  labels:
    app.kubernetes.io/version: \"0.2\"
spec:
  params:
  - name: SOME_PARAM
    default: value
"
    }

    Before "setup_bundle"

    It "creates catalog directory layout"
      When run script "$SCRIPT" "quay.io/conforma/tekton-task:latest" "${TMPDIR}/output" task tasks
      The status should be success
      The output should include "Extracted 2 task(s)"
      The path "${TMPDIR}/output/tasks/verify-enterprise-contract/0.1/verify-enterprise-contract.yaml" should be file
      The path "${TMPDIR}/output/tasks/collect-keyless-params/0.2/collect-keyless-params.yaml" should be file
    End

    It "writes valid YAML content"
      When run script "$SCRIPT" "quay.io/conforma/tekton-task:latest" "${TMPDIR}/output" task tasks
      The status should be success
      The output should include "Extracted 2 task(s)"
      The contents of file "${TMPDIR}/output/tasks/verify-enterprise-contract/0.1/verify-enterprise-contract.yaml" should include "verify-enterprise-contract"
      The contents of file "${TMPDIR}/output/tasks/collect-keyless-params/0.2/collect-keyless-params.yaml" should include "collect-keyless-params"
    End
  End

  Describe "handles digest references"
    setup_digest_ref() {
      cat > "${TMPDIR}/crane/manifest.json" <<'EOF'
{
  "layers": [
    {
      "digest": "sha256:ccc333",
      "annotations": {
        "dev.tekton.image.kind": "task",
        "dev.tekton.image.name": "my-task"
      }
    }
  ]
}
EOF

      create_blob "sha256:ccc333" "apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: my-task
  labels:
    app.kubernetes.io/version: \"1.0\"
spec: {}
"
    }

    Before "setup_digest_ref"

    It "strips digest from repo for blob fetch"
      When run script "$SCRIPT" "quay.io/conforma/tekton-task@sha256:abc123" "${TMPDIR}/output" task tasks
      The status should be success
      The output should include "Extracted 1 task(s)"
    End
  End

  Describe "error cases"
    It "fails when no arguments provided"
      When run script "$SCRIPT"
      The status should be failure
      The stderr should include "Usage"
    End

    It "fails when output-dir argument is missing"
      When run script "$SCRIPT" "quay.io/conforma/tekton-task:latest"
      The status should be failure
      The stderr should include "Usage"
    End

    It "fails when bundle contains no task layers"
      cat > "${TMPDIR}/crane/manifest.json" <<'EOF'
{
  "layers": [
    {
      "digest": "sha256:notask",
      "annotations": {
        "dev.tekton.image.kind": "pipeline",
        "dev.tekton.image.name": "some-pipeline"
      }
    }
  ]
}
EOF
      When run script "$SCRIPT" "quay.io/conforma/tekton-task:latest" "${TMPDIR}/output" task tasks
      The status should be failure
      The output should include "No task layers found"
    End

    It "fails when task is missing version label"
      cat > "${TMPDIR}/crane/manifest.json" <<'EOF'
{
  "layers": [
    {
      "digest": "sha256:nover",
      "annotations": {
        "dev.tekton.image.kind": "task",
        "dev.tekton.image.name": "bad-task"
      }
    }
  ]
}
EOF

      create_blob "sha256:nover" "apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: bad-task
spec: {}
"

      When run script "$SCRIPT" "quay.io/conforma/tekton-task:latest" "${TMPDIR}/output" task tasks
      The status should be failure
      The output should include "missing the app.kubernetes.io/version label"
    End
  End

  Describe "StepActions"
    It "writes StepActions to the requested directory"
      cat > "${TMPDIR}/crane/manifest.json" <<'EOF'
{
  "layers": [
    {
      "digest": "sha256:stepaction",
      "annotations": {
        "dev.tekton.image.kind": "stepaction",
        "dev.tekton.image.name": "create-test-result-attestation"
      }
    }
  ]
}
EOF

      create_blob "sha256:stepaction" "apiVersion: tekton.dev/v1
kind: StepAction
metadata:
  name: create-test-result-attestation
  labels:
    app.kubernetes.io/version: \"0.1\"
spec: {}
"

      When run script "$SCRIPT" "quay.io/conforma/step-actions:snapshot" "${TMPDIR}/output" stepaction stepactions
      The status should be success
      The output should include "Extracted 1 stepaction(s)"
      The path "${TMPDIR}/output/stepactions/create-test-result-attestation/0.1/create-test-result-attestation.yaml" should be file
    End

    It "rejects a version that escapes the StepAction directory"
      cat > "${TMPDIR}/crane/manifest.json" <<'EOF'
{
  "layers": [
    {
      "digest": "sha256:malicious-stepaction",
      "annotations": {
        "dev.tekton.image.kind": "stepaction",
        "dev.tekton.image.name": "verify-enterprise-contract"
      }
    }
  ]
}
EOF

      create_blob "sha256:malicious-stepaction" "apiVersion: tekton.dev/v1
kind: StepAction
metadata:
  name: verify-enterprise-contract
  labels:
    app.kubernetes.io/version: \"../../tasks/verify-enterprise-contract/0.1\"
spec: {}
"

      When run script "$SCRIPT" "quay.io/conforma/step-actions:snapshot" "${TMPDIR}/output" stepaction stepactions
      The status should be failure
      The stderr should include "resolves outside"
      The path "${TMPDIR}/output/tasks/verify-enterprise-contract/0.1/verify-enterprise-contract.yaml" should not be file
    End

    It "rejects a name that escapes the StepAction directory"
      cat > "${TMPDIR}/crane/manifest.json" <<'EOF'
{
  "layers": [
    {
      "digest": "sha256:malicious-name",
      "annotations": {
        "dev.tekton.image.kind": "stepaction",
        "dev.tekton.image.name": "../../tasks/verify-enterprise-contract"
      }
    }
  ]
}
EOF

      create_blob "sha256:malicious-name" "apiVersion: tekton.dev/v1
kind: StepAction
metadata:
  name: verify-enterprise-contract
  labels:
    app.kubernetes.io/version: \"0.1\"
spec: {}
"

      When run script "$SCRIPT" "quay.io/conforma/step-actions:snapshot" "${TMPDIR}/output" stepaction stepactions
      The status should be failure
      The stderr should include "resolves outside"
    End
  End
End
