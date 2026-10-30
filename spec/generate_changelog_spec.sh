Describe "generate-changelog.sh"
  SCRIPT="./hack/generate-changelog.sh"

  setup() {
    setup_tmpdir
    mkdir -p "${TMPDIR}/repo/hack/policy-behavior" "${TMPDIR}/repo/hack/policy-rule-diff" "${TMPDIR}/release"
    cp ./hack/generate-changelog.sh "${TMPDIR}/repo/hack/"
    cp ./hack/policy-behavior/compare-policy-behavior.sh "${TMPDIR}/repo/hack/policy-behavior/"
    export FIXTURE_ROOT="$PWD"
    SCRIPT="${TMPDIR}/repo/hack/generate-changelog.sh"
    cat > "${TMPDIR}/repo/hack/release.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  validate) jq -e '.schemaVersion == 2' "$2" >/dev/null ;;
  config)
    mkdir -p "$3/hack/policy-behavior" "$3/acceptance"
    cp "$FIXTURE_ROOT/acceptance/pub.key" "$3/acceptance/"
    cp "$FIXTURE_ROOT/hack/policy-behavior/golden-policy.yaml" "$3/hack/policy-behavior/"
    jq '.targets |= map(.image = (.image | split(":")[0]) + "@sha256:" + ("9" * 64))' "$FIXTURE_ROOT/hack/policy-behavior/targets.json" > "$3/hack/policy-behavior/targets.json"
    jq '(.policy[], .components[]).digest = "sha256:" + ("8" * 64)' "$2" > "$3/before.json"
    ;;
  catalog-changelog) echo '## Task and StepAction definitions' ;;
  *) exit 1 ;;
esac
EOF
    chmod +x "${TMPDIR}/repo/hack/release.sh"
    jq -n '{schemaVersion:2, policy: ["release-policy", "task-policy", "build-task-policy"] | map({image:("quay.io/conforma/" + .),digest:("sha256:" + ("9" * 64))}), components:["cli","tekton-task"] | map({image:("quay.io/conforma/" + .),digest:("sha256:" + ("9" * 64))}),inputs:{testInputs:{comparisonTime:"2026-10-30T00:00:00Z"}}} | .baseline.images = ((.policy + .components) | map({reference:(.image + ":konflux"),digest:("sha256:" + ("8" * 64))}))' > "${TMPDIR}/release/images.json"
    export CONTAINER_ENGINE="mock-container"
    export MOCK_CONTAINER_MODE=""
    export MOCK_BIN
    export GO_LOG="${TMPDIR}/go.log"

    cat > "${MOCK_BIN}/crane" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${2:-}" == *@sha256:* ]] || { echo 'mutable source reference' >&2; exit 1; }
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
    When run script "$SCRIPT" "${TMPDIR}/release/images.json"
    The status should be success
    The path "${TMPDIR}/release/images.json" should be file
    The path "${TMPDIR}/release/changelog.md" should be file
    The contents of file "${TMPDIR}/release/images.json" should include "sha256:9999999999999999999999999999999999999999999999999999999999999999"
    The contents of file "${TMPDIR}/release/changelog.md" should include "Policy Behavior Changes"
    The contents of file "${GO_LOG}" should include "quay.io/conforma/release-policy@sha256:8888888888888888888888888888888888888888888888888888888888888888 quay.io/conforma/release-policy@sha256:9999999999999999999999999999999999999999999999999999999999999999"
    The stderr should include "Release written to"
  End

  It "keeps the generated release artifacts when policy comparison fails"
    export MOCK_CONTAINER_MODE="fail"
    When run script "$SCRIPT" "${TMPDIR}/release/images.json" "${TMPDIR}/failed-release"
    The status should be failure
    The path "${TMPDIR}/failed-release/images.json" should be file
    The path "${TMPDIR}/failed-release/changelog.md" should be file
    The contents of file "${TMPDIR}/failed-release/changelog.md" should include "Policy Rule Changes"
    The stderr should include "Policy behavior comparison failed"
  End
End
