Describe "generate-changelog.sh"
  SCRIPT="./hack/generate-changelog.sh"

  setup() {
    setup_tmpdir
    export CONTAINER_ENGINE="mock-container"
    export MOCK_CONTAINER_MODE=""
    export MOCK_BIN
    export GO_LOG="${TMPDIR}/go.log"

    cat > "${MOCK_BIN}/crane" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  digest)
    printf 'sha256:%064d\n' 9
    ;;
  manifest)
    cat <<'JSON'
{"mediaType":"application/vnd.oci.image.manifest.v1+json","annotations":{"org.opencontainers.image.revision":"1111111111111111111111111111111111111111"}}
JSON
    ;;
  *)
    echo "unexpected crane command: $*" >&2
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

    cat > "${MOCK_BIN}/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" ]]; then
  printf '%s\n' "$*" >> "$GO_LOG"
  echo '{"added":[],"removed":[]}'
else
  echo "unexpected go command: $*" >&2
  exit 1
fi
EOF
    chmod +x "${MOCK_BIN}/go"

    cat > "${MOCK_BIN}/mock-container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_CONTAINER_MODE:-}" == "fail" ]]; then
  echo "simulated image pull failure" >&2
  exit 17
fi
echo '{"components":[{"violations":[],"warnings":[]}]}'
EOF
    chmod +x "${MOCK_BIN}/mock-container"
    export PATH="${MOCK_BIN}:${PATH}"
  }

  cleanup() {
    cleanup_tmpdir
  }

  Before "setup"
  After "cleanup"

  It "publishes candidate images and the behavior section after success"
    When run script "$SCRIPT" "${TMPDIR}/release"
    The status should be success
    The path "${TMPDIR}/release/images.json" should be file
    The path "${TMPDIR}/release/changelog.md" should be file
    The contents of file "${TMPDIR}/release/images.json" should include "sha256:0000000000000000000000000000000000000000000000000000000000000009"
    The contents of file "${TMPDIR}/release/changelog.md" should include "Policy Behavior Changes"
    The contents of file "${GO_LOG}" should include "quay.io/conforma/release-policy:konflux quay.io/conforma/release-policy:latest"
    The stderr should include "Release written to"
  End

  It "keeps the generated release artifacts when policy comparison fails"
    export MOCK_CONTAINER_MODE="fail"
    When run script "$SCRIPT" "${TMPDIR}/failed-release"
    The status should be failure
    The path "${TMPDIR}/failed-release/images.json" should be file
    The path "${TMPDIR}/failed-release/changelog.md" should be file
    The contents of file "${TMPDIR}/failed-release/changelog.md" should include "Policy Rule Changes"
    The stderr should include "Policy behavior comparison failed"
  End
End
