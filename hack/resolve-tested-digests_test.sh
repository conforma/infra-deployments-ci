#!/usr/bin/env bash
# Copyright The Conforma Contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR
export MOCK_BUNDLE_DIGEST="sha256:$(printf 'a%.0s' {1..64})"
export MOCK_CLI="quay.io/conforma/cli@sha256:$(printf 'b%.0s' {1..64})"
export MOCK_POLICY_DIGEST="sha256:$(printf 'c%.0s' {1..64})"
export MOCK_BUNDLE="quay.io/conforma/tekton-task@${MOCK_BUNDLE_DIGEST}"

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/repo/"{hack,acceptance,features}
cp "$SCRIPT_DIR/resolve-tested-digests.sh" "$TEST_DIR/repo/hack/"
cp "$SCRIPT_DIR/../acceptance/conforma"*.yaml "$TEST_DIR/repo/acceptance/"
cp "$SCRIPT_DIR/../features/validate_golden"*.feature "$TEST_DIR/repo/features/"

jq -n --arg bundle "$MOCK_BUNDLE_DIGEST" --arg cli "${MOCK_CLI##*@}" \
    --arg policy "$MOCK_POLICY_DIGEST" '{policy_only: true,
    policy: [{image: "quay.io/conforma/release-policy", digest: $policy}],
    components: [{image: "quay.io/conforma/tekton-task", digest: $bundle},
                 {image: "quay.io/conforma/cli", digest: $cli}]}' > "$TEST_DIR/images.json"

cat > "$TEST_DIR/manifest.json" <<'EOF'
{"layers":[
  {"digest":"sha256:first","annotations":{"dev.tekton.image.name":"verify-enterprise-contract","dev.tekton.image.kind":"task"}},
  {"digest":"sha256:second","annotations":{"dev.tekton.image.name":"another-task","dev.tekton.image.kind":"task"}}
]}
EOF
jq -n --arg image "$MOCK_CLI" '{spec: {steps: [{image: $image}]}}' > "$TEST_DIR/task.json"
tar -czf "$TEST_DIR/first.tar.gz" -C "$TEST_DIR" task.json
cp "$TEST_DIR/first.tar.gz" "$TEST_DIR/second.tar.gz"
cat > "$TEST_DIR/bin/crane" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_DIR/crane.log"
case "$1" in
    digest) printf '%s\n' "$MOCK_BUNDLE_DIGEST" ;;
    manifest)
        [[ "$2" == "$MOCK_BUNDLE" ]] || { echo "Unexpected bundle: $2" >&2; exit 1; }
        cat "$TEST_DIR/manifest.json" ;;
    blob) cat "$TEST_DIR/${2##*:}.tar.gz" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/crane"
export PATH="$TEST_DIR/bin:$PATH"

resolve() {
    bash "$TEST_DIR/repo/hack/resolve-tested-digests.sh" "$@"
}

resolve "$TEST_DIR/images.json" > "$TEST_DIR/digests.json"
jq -e --arg bundle "$MOCK_BUNDLE" --arg cli "$MOCK_CLI" \
    '.[$bundle] == $bundle and .["quay.io/conforma/cli"] == $cli' \
    "$TEST_DIR/digests.json" >/dev/null || {
    echo "ERROR: Release component pins were ignored" >&2
    exit 1
}
if grep -q ':latest' "$TEST_DIR/crane.log"; then
    echo "ERROR: Pinned release resolved a mutable latest tag" >&2
    exit 1
fi

resolve > "$TEST_DIR/default-digests.json"
jq -e --arg bundle "$MOCK_BUNDLE" \
    '.["quay.io/conforma/tekton-task:latest"] == $bundle' \
    "$TEST_DIR/default-digests.json" >/dev/null

jq '.components[1].digest = "sha256:invalid"' "$TEST_DIR/images.json" > "$TEST_DIR/invalid.json"
if resolve "$TEST_DIR/invalid.json" >/dev/null 2>&1; then
    echo "ERROR: Invalid component digest accepted" >&2
    exit 1
fi
jq '.components += [.components[0]]' "$TEST_DIR/images.json" > "$TEST_DIR/duplicate.json"
if resolve "$TEST_DIR/duplicate.json" >/dev/null 2>&1; then
    echo "ERROR: Duplicate component accepted" >&2
    exit 1
fi
jq --arg digest "$MOCK_POLICY_DIGEST" '.components[1].digest = $digest' \
    "$TEST_DIR/images.json" > "$TEST_DIR/mismatch.json"
if resolve "$TEST_DIR/mismatch.json" >/dev/null 2>&1; then
    echo "ERROR: CLI component mismatch accepted" >&2
    exit 1
fi
jq --arg image "quay.io/conforma/cli@$MOCK_POLICY_DIGEST" \
    '.spec.steps[0].image = $image' "$TEST_DIR/task.json" > "$TEST_DIR/other-task.json"
tar -czf "$TEST_DIR/second.tar.gz" -C "$TEST_DIR" other-task.json
if resolve "$TEST_DIR/images.json" >/dev/null 2>&1; then
    echo "ERROR: A different CLI in another task was accepted" >&2
    exit 1
fi
jq '.layers[1].annotations["dev.tekton.image.kind"] = "stepaction"' \
    "$TEST_DIR/manifest.json" > "$TEST_DIR/stepactions.json"
mv "$TEST_DIR/stepactions.json" "$TEST_DIR/manifest.json"
jq -n --arg image "quay.io/conforma/cli@$MOCK_POLICY_DIGEST" \
    '{spec: {image: $image}}' > "$TEST_DIR/other-task.json"
tar -czf "$TEST_DIR/second.tar.gz" -C "$TEST_DIR" other-task.json
if resolve "$TEST_DIR/images.json" >/dev/null 2>&1; then
    echo "ERROR: A different CLI in a preserved step action was accepted" >&2
    exit 1
fi
jq -n --arg image "$MOCK_CLI" '{spec: {image: $image}}' > "$TEST_DIR/other-task.json"
tar -czf "$TEST_DIR/second.tar.gz" -C "$TEST_DIR" other-task.json
resolve "$TEST_DIR/images.json" >/dev/null
jq '.layers[1].annotations["dev.tekton.image.kind"] = "task"' \
    "$TEST_DIR/manifest.json" > "$TEST_DIR/tasks.json"
mv "$TEST_DIR/tasks.json" "$TEST_DIR/manifest.json"
cp "$TEST_DIR/first.tar.gz" "$TEST_DIR/second.tar.gz"

export RELEASE_IMAGES
RELEASE_IMAGES=$(cat "$TEST_DIR/images.json")
export BUNDLE_DIGESTS
BUNDLE_DIGESTS=$(cat "$TEST_DIR/digests.json")
yq -r '.jobs.acceptance-tests.steps[] | select(.name == "Pin policy-only acceptance inputs") | .run' \
    "$SCRIPT_DIR/../.github/workflows/konflux-policy.yaml" > "$TEST_DIR/pin.sh"
[[ -s "$TEST_DIR/pin.sh" ]] || { echo "ERROR: Missing acceptance pinning step" >&2; exit 1; }
(cd "$TEST_DIR/repo" && bash "$TEST_DIR/pin.sh")
for pipeline in "$TEST_DIR/repo/acceptance/"conforma*.yaml; do
    yq -e '.spec.tasks[] | select(.taskRef.resolver == "bundles") |
        .taskRef.params[] | select(.name == "bundle") | .value == strenv(MOCK_BUNDLE)' "$pipeline" >/dev/null
    yq -e '.spec.tasks[] | select(.taskRef.resolver == "bundles") |
        .params[] | select(.name == "POLICY_BUNDLE_DIGEST") | .value == strenv(MOCK_POLICY_DIGEST)' "$pipeline" >/dev/null
done
if grep -Eq 'conforma/(tekton-task|release-policy):latest' "$TEST_DIR/repo/features/"*.feature; then
    echo "ERROR: Acceptance features still select mutable release inputs" >&2
    exit 1
fi

: > "$TEST_DIR/crane.log"
yq -r '.jobs.update-task-definitions.steps[] | select(.name == "Extract step actions from selected bundle") | .run' \
    "$SCRIPT_DIR/../.github/workflows/konflux-policy.yaml" > "$TEST_DIR/step-actions.sh"
bash "$TEST_DIR/step-actions.sh"
if [[ "$(cat "$TEST_DIR/crane.log")" != "manifest $MOCK_BUNDLE" ]]; then
    echo "ERROR: Policy-only release fetched unrelated step actions" >&2
    exit 1
fi

echo "Pinned release input tests passed"
