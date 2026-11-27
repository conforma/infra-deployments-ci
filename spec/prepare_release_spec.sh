Describe "prepare-release.sh"
  SCRIPT="./hack/prepare-release.sh"

  POLICY_DIGEST="sha256:$(printf '%064d' 1)"
  TASK_POLICY_DIGEST="sha256:$(printf '%064d' 2)"
  BUILD_POLICY_DIGEST="sha256:$(printf '%064d' 3)"
  CLI_DIGEST="sha256:$(printf '%064d' 4)"
  BUNDLE_DIGEST="sha256:$(printf '%064d' 5)"
  SOURCE_DIGEST="sha256:$(printf '%064d' 6)"
  STEPS_DIGEST="sha256:$(printf '%064d' 7)"
  OTHER_IMAGE="quay.io/konflux-ci/task-runner:v3@sha256:$(printf '%064d' 8)"
  ACTION_SHA="abcdef1234567890abcdef1234567890abcdef12"

  setup() {
    setup_tmpdir
    export MOCK_BIN
    export TKN_LOG="${TMPDIR}/tkn.log"
    export TKN_CAPTURE="${TMPDIR}/pushed"
    mkdir -p "$TKN_CAPTURE" "${TMPDIR}/crane/blobs"

    cat > "${MOCK_BIN}/crane" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  manifest)
    cat "${TMPDIR}/crane/manifest.json"
    ;;
  blob)
    digest="\${2#*@}"
    cat "${TMPDIR}/crane/blobs/\${digest}.tar.gz"
    ;;
  digest)
    case "\$2" in
      quay.io/conforma/tekton-task:candidate-*) echo "$BUNDLE_DIGEST" ;;
      quay.io/conforma/release-policy:latest|quay.io/conforma/release-policy@*) echo "$POLICY_DIGEST" ;;
      quay.io/conforma/task-policy:latest) echo "$TASK_POLICY_DIGEST" ;;
      quay.io/conforma/build-task-policy:latest) echo "$BUILD_POLICY_DIGEST" ;;
      quay.io/conforma/cli:latest)
        if [[ "\${MOCK_FAIL_REF:-}" == "cli" ]]; then
          echo "mock crane: refused to resolve \$2" >&2
          exit 1
        fi
        echo "$CLI_DIGEST"
        ;;
      quay.io/conforma/tekton-task:latest|quay.io/conforma/tekton-task@*) echo "$SOURCE_DIGEST" ;;
      quay.io/conforma/step-actions:snapshot) echo "$STEPS_DIGEST" ;;
      *)
        echo "mock crane: unexpected digest ref: \$2" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "mock crane: unknown subcommand: \$1" >&2
    exit 1
    ;;
esac
EOF
    chmod +x "${MOCK_BIN}/crane"

    cat > "${MOCK_BIN}/tkn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "tkn $*" >> "$TKN_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-f" ]]; then
    cp "$2" "$TKN_CAPTURE/"
  fi
  shift
done
EOF
    chmod +x "${MOCK_BIN}/tkn"

    cat > "${MOCK_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ls-remote" ]]; then
  printf '%s\t%s\n' "abcdef1234567890abcdef1234567890abcdef12" "${3:-}"
  exit 0
fi
echo "unexpected git command: $*" >&2
exit 1
EOF
    chmod +x "${MOCK_BIN}/git"

    export PATH="${MOCK_BIN}:${PATH}"

    cat > "${TMPDIR}/crane/manifest.json" <<EOF
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
        "dev.tekton.image.kind": "stepaction",
        "dev.tekton.image.name": "create-test-result-attestation"
      }
    }
  ]
}
EOF

    create_blob() {
      local digest="$1"
      local yaml="$2"
      local staging="${TMPDIR}/blob-staging"
      mkdir -p "$staging"
      printf '%s' "$yaml" > "${staging}/resource.yaml"
      tar -cf - -C "$staging" resource.yaml | gzip > "${TMPDIR}/crane/blobs/${digest}.tar.gz"
      rm -rf "$staging"
    }

    create_blob "sha256:aaa111" "apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: verify-enterprise-contract
  labels:
    app.kubernetes.io/version: \"0.1\"
spec:
  params:
    - name: POLICY_BUNDLE_DIGEST
      default: \"\"
  steps:
    - name: verify
      image: quay.io/conforma/cli:some-tag
    - name: collect
      image: quay.io/conforma/cli@sha256:$(printf '%064d' 9)
    - name: setup
      image: $OTHER_IMAGE
      ref:
        resolver: git
        params:
          - name: url
            value: https://github.com/konflux-ci/release-service-catalog
          - name: revision
            value: development
          - name: pathInRepo
            value: stepactions/create-trusted-artifact/create-trusted-artifact.yaml
"

    create_blob "sha256:bbb222" "apiVersion: tekton.dev/v1beta1
kind: StepAction
metadata:
  name: create-test-result-attestation
  labels:
    app.kubernetes.io/version: \"0.1\"
spec:
  image: $OTHER_IMAGE
"
  }

  cleanup() {
    cleanup_tmpdir
  }

  Before "setup"
  After "cleanup"

  It "writes a valid v2 manifest for the assembled candidate bundle"
    When run script "$SCRIPT" "${TMPDIR}/release"
    The status should be success
    The output should include "Extracted 1 task(s)"
    The stderr should include "Release manifest written to"
    The path "${TMPDIR}/release/images.json" should be file
    The contents of file "${TMPDIR}/release/images.json" should include "\"schemaVersion\": 2"
    The contents of file "${TMPDIR}/release/images.json" should include "$BUNDLE_DIGEST"
    The contents of file "${TMPDIR}/release/images.json" should include "$CLI_DIGEST"
    The contents of file "${TMPDIR}/release/images.json" should include "$POLICY_DIGEST"
    The contents of file "${TMPDIR}/release/images.json" should include "$SOURCE_DIGEST"
    The contents of file "${TMPDIR}/release/images.json" should include "$STEPS_DIGEST"
    The contents of file "${TMPDIR}/release/images.json" should include "candidate-"
  End

  It "pushes the candidate bundle under a unique retention tag"
    When run script "$SCRIPT" "${TMPDIR}/release"
    The status should be success
    The output should include "Extracted 1 task(s)"
    The stderr should include "Pushing candidate bundle"
    The contents of file "${TKN_LOG}" should include "bundle push quay.io/conforma/tekton-task:candidate-"
    The contents of file "${TKN_LOG}" should include "-f"
  End

  It "assembles a bundle whose definitions are fully pinned"
    When run script "$SCRIPT" "${TMPDIR}/release"
    The status should be success
    The output should include "Extracted 1 task(s)"
    The stderr should include "pinned StepAction"
    The path "${TKN_CAPTURE}/verify-enterprise-contract.yaml" should be file
    The contents of file "${TKN_CAPTURE}/verify-enterprise-contract.yaml" should include "quay.io/conforma/cli@$CLI_DIGEST"
    The contents of file "${TKN_CAPTURE}/verify-enterprise-contract.yaml" should not include "cli:some-tag"
    The contents of file "${TKN_CAPTURE}/verify-enterprise-contract.yaml" should not include "sha256:$(printf '%064d' 9)"
    The contents of file "${TKN_CAPTURE}/verify-enterprise-contract.yaml" should include "default: \"$POLICY_DIGEST\""
    The contents of file "${TKN_CAPTURE}/verify-enterprise-contract.yaml" should include "value: $ACTION_SHA"
    The contents of file "${TKN_CAPTURE}/verify-enterprise-contract.yaml" should not include "value: development"
    The contents of file "${TKN_CAPTURE}/verify-enterprise-contract.yaml" should include "$OTHER_IMAGE"
    The path "${TKN_CAPTURE}/create-test-result-attestation.yaml" should be file
    The contents of file "${TKN_CAPTURE}/create-test-result-attestation.yaml" should include "$OTHER_IMAGE"
  End

  It "is deterministic across runs with the same inputs"
    When run script "$SCRIPT" "${TMPDIR}/first"
    The status should be success
    The output should include "Extracted 1 task(s)"
    The stderr should include "Release manifest written to"
    "$SCRIPT" "${TMPDIR}/second" > /dev/null 2>&1
    jq -S 'del(.components[] | select(.image == "quay.io/conforma/tekton-task") | .retentionTag)' \
      "${TMPDIR}/first/images.json" > "${TMPDIR}/first.norm"
    jq -S 'del(.components[] | select(.image == "quay.io/conforma/tekton-task") | .retentionTag)' \
      "${TMPDIR}/second/images.json" > "${TMPDIR}/second.norm"
    diff -u "${TMPDIR}/first.norm" "${TMPDIR}/second.norm"
  End

  It "fails when a release input cannot be resolved"
    export MOCK_FAIL_REF="cli"
    When run script "$SCRIPT" "${TMPDIR}/release"
    The status should be failure
    The stderr should include "failed to resolve quay.io/conforma/cli:latest"
    The path "${TMPDIR}/release/images.json" should not be file
  End

  It "refuses to overwrite an existing release directory"
    mkdir -p "${TMPDIR}/existing"
    When run script "$SCRIPT" "${TMPDIR}/existing"
    The status should be failure
    The stderr should include "already exists"
    The output should be blank
  End
End
