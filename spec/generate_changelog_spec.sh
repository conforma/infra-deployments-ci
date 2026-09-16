Describe "generate-changelog.sh"
  SCRIPT="./hack/generate-changelog.sh"

  setup() {
    setup_tmpdir
    export CONTAINER_ENGINE="mock-container"
    export MOCK_CONTAINER_MODE=""
    export MOCK_BIN
    export POLICY_BEHAVIOR_OLD_IMAGES_FILE="${TMPDIR}/old-images.json"
    export CRANE_COUNT_DIR="${TMPDIR}/crane-counts"
    mkdir -p "$CRANE_COUNT_DIR"

    cat > "$POLICY_BEHAVIOR_OLD_IMAGES_FILE" <<'EOF'
{
  "policy": [{
    "image": "quay.io/conforma/release-policy",
    "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }, {
    "image": "quay.io/conforma/task-policy",
    "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }, {
    "image": "quay.io/conforma/build-task-policy",
    "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }],
  "components": [{
    "image": "quay.io/conforma/cli",
    "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"
  }, {
    "image": "quay.io/conforma/tekton-task",
    "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"
  }]
}
EOF

    cat > "${MOCK_BIN}/crane" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  digest)
    key=$(printf '%s' "$2" | tr '/:@.' '_')
    count_file="${CRANE_COUNT_DIR}/${key}"
    count=0
    [[ -f "$count_file" ]] && count=$(<"$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [[ "$count" -gt 1 && "$2" == *":latest" ]]; then
      echo "candidate tag was resolved more than once: $2" >&2
      exit 23
    fi
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
    The stderr should include "Release written to"
  End

  It "does not publish either output after a failed comparison"
    export MOCK_CONTAINER_MODE="fail"
    When run script "$SCRIPT" "${TMPDIR}/failed-release"
    The status should be failure
    The path "${TMPDIR}/failed-release/images.json" should not be file
    The path "${TMPDIR}/failed-release/changelog.md" should not be file
    The stderr should include "Policy behavior comparison failed"
  End
End
