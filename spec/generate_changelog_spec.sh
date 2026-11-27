Describe "generate-changelog.sh"
  SCRIPT="./hack/generate-changelog.sh"
  FIXTURE="spec/fixtures/release.json"

  setup() {
    setup_tmpdir
    export CONTAINER_ENGINE="mock-container"
    export MOCK_CONTAINER_MODE=""
    export MOCK_BIN
    export GO_LOG="${TMPDIR}/go.log"
    export CRANE_LOG="${TMPDIR}/crane.log"

    # The manifest under test. The changelog is written next to it.
    cp "$FIXTURE" "${TMPDIR}/images.json"

    cat > "${MOCK_BIN}/crane" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  digest)
    printf 'crane digest %s\n' "$2" >> "$CRANE_LOG"
    if [[ "$2" =~ ^quay\.io/conforma/.+:latest$ ]]; then
      # Candidate images must come from the manifest, never from :latest.
      echo "mock crane: refused to resolve mutable candidate ref: $2" >&2
      exit 1
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

  It "renders the changelog from the manifest without rewriting it"
    When run script "$SCRIPT" "${TMPDIR}/images.json"
    The status should be success
    The path "${TMPDIR}/changelog.md" should be file
    The contents of file "${TMPDIR}/changelog.md" should include "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    The contents of file "${TMPDIR}/changelog.md" should include "sha256:4444444444444444444444444444444444444444444444444444444444444444"
    The contents of file "${TMPDIR}/changelog.md" should include "sha256:5555555555555555555555555555555555555555555555555555555555555555"
    The contents of file "${TMPDIR}/changelog.md" should include "Policy Behavior Changes"
    The stderr should include "Done."
  End

  It "does not write or modify images.json"
    cp "${TMPDIR}/images.json" "${TMPDIR}/images.json.orig"
    When run script "$SCRIPT" "${TMPDIR}/images.json"
    The status should be success
    The stderr should include "Done."
    diff -u "${TMPDIR}/images.json.orig" "${TMPDIR}/images.json"
  End

  It "never resolves a mutable candidate reference"
    When run script "$SCRIPT" "${TMPDIR}/images.json"
    The status should be success
    The stderr should include "Done."
    The contents of file "${CRANE_LOG}" should not include "quay.io/conforma/cli:latest"
    The contents of file "${CRANE_LOG}" should not include "quay.io/conforma/tekton-task:latest"
    The contents of file "${CRANE_LOG}" should not include "quay.io/conforma/release-policy:latest"
  End

  It "compares rules against the manifest candidate digests"
    When run script "$SCRIPT" "${TMPDIR}/images.json"
    The status should be success
    The stderr should include "Done."
    The contents of file "${GO_LOG}" should include "quay.io/conforma/release-policy:konflux quay.io/conforma/release-policy@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  End

  It "writes the changelog to stdout with an output dir of -"
    When run script "$SCRIPT" "${TMPDIR}/images.json" -
    The status should be success
    The output should include "Policy Behavior Changes"
    The stderr should include "Done."
    The path "${TMPDIR}/changelog.md" should not be file
  End

  It "rejects an invalid manifest"
    jq 'del(.components[1].retentionTag)' "${TMPDIR}/images.json" > "${TMPDIR}/invalid.json"
    When run script "$SCRIPT" "${TMPDIR}/invalid.json"
    The status should be failure
    The stderr should include "invalid release manifest"
  End

  It "keeps the changelog when the behavior comparison fails"
    export MOCK_CONTAINER_MODE="fail"
    When run script "$SCRIPT" "${TMPDIR}/images.json"
    The status should be failure
    The path "${TMPDIR}/changelog.md" should be file
    The contents of file "${TMPDIR}/changelog.md" should include "Policy Rule Changes"
    The stderr should include "Policy behavior comparison failed"
  End
End
