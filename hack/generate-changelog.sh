#!/usr/bin/env bash
# Copyright The Conforma Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

# Render a prepared release manifest. This command never selects new candidates.
# Usage: ./hack/generate-changelog.sh releases/<id>/images.json [output-dir|-]
# Dependencies: crane, gh, jq, yq, go, git, docker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CANDIDATE_IMAGES_FILE="${1:?Usage: generate-changelog.sh <images.json> [output-dir|-]}"
CANDIDATE_IMAGES_FILE="$(cd "$(dirname "$CANDIDATE_IMAGES_FILE")" && pwd)/$(basename "$CANDIDATE_IMAGES_FILE")"
"${SCRIPT_DIR}/check-release-inputs.sh" "$CANDIDATE_IMAGES_FILE"
RELEASE_DIR="${2:-$(dirname "$CANDIDATE_IMAGES_FILE")}"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
CONFIG_DIR="${TMPDIR_BASE}/config"
mkdir -p "$CONFIG_DIR"
config_commit=$(jq -r '.inputs.testInputs.configCommit' "$CANDIDATE_IMAGES_FILE")
git -C "$REPO_ROOT" archive "$config_commit" hack/policy-behavior/targets.json hack/policy-behavior/golden-policy.yaml acceptance/pub.key | tar -x -C "$CONFIG_DIR"
jq --slurpfile manifest "$CANDIDATE_IMAGES_FILE" '.targets |= map(. as $target | .image = ($manifest[0].inputs.testInputs.targets[] | select(.name==$target.name) | .image+"@"+.digest))' \
    "$CONFIG_DIR/hack/policy-behavior/targets.json" > "$CONFIG_DIR/targets.json"
POLICY_DATA=$(jq -c '.inputs.testInputs.policyData' "$CANDIDATE_IMAGES_FILE") \
    yq '.spec.sources[].data = (strenv(POLICY_DATA) | from_json)' "$CONFIG_DIR/hack/policy-behavior/golden-policy.yaml" > "$CONFIG_DIR/policy.yaml"
jq '. as $m | (.policy[], .components[]) |= (. as $item | .digest = ($m.baseline.images[] | select(.reference==($item.image+":konflux")) | .digest))' \
    "$CANDIDATE_IMAGES_FILE" > "$CONFIG_DIR/before.json"
POLICY_BEHAVIOR_FILE="${TMPDIR_BASE}/policy-behavior.md"

# ---------------------------------------------------------------------------
# Images to include in the changelog
# ---------------------------------------------------------------------------

# Policy images and their enterprise-contract mirrors. Each entry is
# "conforma_repo|ec_mirror_repo". The mirror list ends up in images.json
# so the release workflow can tag both namespaces.
POLICY_IMAGE_ENTRIES=(
    "quay.io/conforma/release-policy|quay.io/enterprise-contract/ec-release-policy"
    "quay.io/conforma/task-policy|quay.io/enterprise-contract/ec-task-policy"
    "quay.io/conforma/build-task-policy|quay.io/enterprise-contract/ec-build_task-policy"
)

POLICY_IMAGES=()
for entry in "${POLICY_IMAGE_ENTRIES[@]}"; do
    POLICY_IMAGES+=("${entry%%|*}")
done

COMPONENT_IMAGES=(
    quay.io/conforma/cli
    quay.io/conforma/tekton-task
)

COMMIT_LOG_SOURCES=(
    # image_repo|github_org/repo
    "quay.io/conforma/release-policy|conforma/policy"
    "quay.io/conforma/cli|conforma/cli"
)

ALL_IMAGES=(
    "${POLICY_IMAGES[@]}"
    "${COMPONENT_IMAGES[@]}"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# get_revision extracts org.opencontainers.image.revision from an image tag.
# Handles both single manifests and multi-arch indexes (picks linux/amd64).
get_revision() {
    local image="$1"
    local manifest
    manifest=$(crane manifest "$image" 2>/dev/null)

    local media_type
    media_type=$(echo "$manifest" | jq -r '.mediaType // empty')

    if [[ "$media_type" == *"index"* ]] || [[ "$media_type" == *"list"* ]]; then
        local amd64_digest
        amd64_digest=$(echo "$manifest" | jq -r '
            .manifests[] |
            select(.platform.architecture == "amd64" and .platform.os == "linux") |
            .digest' | head -1)

        if [[ -z "$amd64_digest" ]]; then
            echo "ERROR: No linux/amd64 manifest found in index for $image" >&2
            return 1
        fi

        local repo="${image%:*}"
        repo="${repo%@*}"
        manifest=$(crane manifest "${repo}@${amd64_digest}" 2>/dev/null)
    fi

    local revision
    revision=$(echo "$manifest" | jq -r '.annotations["org.opencontainers.image.revision"] // empty')

    if [[ -z "$revision" ]]; then
        echo "ERROR: No revision annotation found for $image" >&2
        return 1
    fi

    echo "$revision"
}

# get_merge_commits clones a repo and returns merge commits between two SHAs.
# Output: one line per merge commit in format "PR_NUMBER|COMMIT_SHA"
get_merge_commits() {
    local github_repo="$1"
    local from_sha="$2"
    local to_sha="$3"
    local clone_dir="${TMPDIR_BASE}/${github_repo##*/}"

    echo "  cloning ${github_repo}..." >&2
    git clone --bare --filter=blob:none --quiet \
        "https://github.com/${github_repo}.git" "$clone_dir" 2>/dev/null

    git -C "$clone_dir" log --merges --oneline "${from_sha}..${to_sha}" 2>/dev/null | \
        while IFS= read -r line; do
            local pr_num
            pr_num=$(echo "$line" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
            local sha
            sha=$(echo "$line" | awk '{print $1}')
            if [[ -n "$pr_num" ]]; then
                echo "${pr_num}|${sha}"
            fi
        done
}

# render_rule_diff runs policy-rule-diff and renders the result as markdown.
# Outputs nothing if there are no changes.
render_rule_diff() {
    local image="$1"
    local name="${image##*/}"

    echo "  diffing ${name}..." >&2
    local diff_json
    diff_json=$(cd "${REPO_ROOT}/hack/policy-rule-diff" && go run . \
        -bundle -json \
        -doc-base-url "https://conforma.dev/docs/policy/packages" \
        "$(baseline_ref "$image")" "$(candidate_ref "$image")")

    local added removed
    added=$(echo "$diff_json" | jq '.added | length')
    removed=$(echo "$diff_json" | jq '.removed | length')

    echo ""
    echo "### ${name}"
    echo ""

    if [[ "$added" -eq 0 ]] && [[ "$removed" -eq 0 ]]; then
        echo "No rule changes."
        return
    fi

    if [[ "$added" -gt 0 ]]; then
        echo "#### Added (${added} rules)"
        echo ""
        echo "$diff_json" | jq -r '
            .added // [] | group_by(.kind) | .[] as $group |
            "**\($group[0].kind)**",
            "",
            ($group[] |
                (if (.doc_url // "") != "" then "- **[\(.title)](\(.doc_url))** — " else "- **\(.title)** — " end) +
                "\(.description)<br>Effective: \(.effective_on | if . == "" then "now" else .[0:10] end) · Collections: \(.collections | join(", "))"
            )'
    fi

    if [[ "$removed" -gt 0 ]]; then
        echo ""
        echo "#### Removed (${removed} rules)"
        echo ""
        echo "$diff_json" | jq -r '
            .removed // [] | group_by(.kind) | .[] as $group |
            "**\($group[0].kind)**",
            "",
            ($group[] |
                (if (.doc_url // "") != "" then "- **[\(.title)](\(.doc_url))** — " else "- **\(.title)** — " end) +
                "\(.description)<br>Collections: \(.collections | join(", "))"
            )'
    fi
}

candidate_ref() {
    jq -er --arg image "$1" '(.policy + .components)[] | select(.image == $image) | "\(.image)@\(.digest)"' "$CANDIDATE_IMAGES_FILE"
}

baseline_ref() {
    jq -er --arg image "$1" '.baseline.images[] | select(.reference == ($image + ":konflux")) | $image + "@" + .digest' "$CANDIDATE_IMAGES_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "$RELEASE_DIR" != "-" ]]; then
    mkdir -p "$RELEASE_DIR"
    exec 1>"${RELEASE_DIR}/changelog.md"
fi

echo "Generating changelog..." >&2

# --- Section 1: Image digests ---

echo "# Konflux Policy Release"
echo ""
echo "> Conforma policy update for Red Hat's Konflux deployment."
echo ""
echo "## Images"
echo ""

for image in "${ALL_IMAGES[@]}"; do
    echo "  reading recorded ${image}..." >&2
    digest="$(candidate_ref "$image")"
    local_name="${image##*/}"
    echo "- **${local_name}** — \`${digest}\`"
done

# --- Section 2: Commit logs ---

echo ""
echo "## Changes Since Last Release"

for entry in "${COMMIT_LOG_SOURCES[@]}"; do
    IFS='|' read -r image_repo github_repo <<< "$entry"

    echo "" >&2
    echo "Processing ${github_repo}..." >&2

    echo "  fetching revisions..." >&2
    konflux_rev=$(get_revision "$(baseline_ref "$image_repo")")
    latest_rev=$(get_revision "$(candidate_ref "$image_repo")")

    echo "  konflux: ${konflux_rev}" >&2
    echo "  latest:  ${latest_rev}" >&2

    echo ""
    echo "### [${github_repo}](https://github.com/${github_repo})"
    echo ""
    echo "Source commits: [\`${konflux_rev:0:8}..${latest_rev:0:8}\`](https://github.com/${github_repo}/compare/${konflux_rev:0:8}...${latest_rev:0:8})"
    echo ""

    if [[ "$konflux_rev" == "$latest_rev" ]]; then
        echo "No changes."
        continue
    fi

    merge_commits=$(get_merge_commits "$github_repo" "$konflux_rev" "$latest_rev")

    if [[ -z "$merge_commits" ]]; then
        echo "No merge commits."
        continue
    fi

    echo "$merge_commits" | while IFS='|' read -r pr_num sha; do
        title=$(gh pr view "$pr_num" --repo "$github_repo" --json title -q .title 2>/dev/null || echo "(title unavailable)")
        echo "- [#${pr_num}](https://github.com/${github_repo}/pull/${pr_num}) — ${title}"
    done
done

# --- Section 3: Policy rule diff ---

echo "" >&2
echo "Running policy rule diffs..." >&2

echo ""
echo "## Policy Rule Changes"

# Render release-policy first (primary focus)
render_rule_diff "${POLICY_IMAGES[0]}"

# Render remaining policies in a collapsible section
if [[ ${#POLICY_IMAGES[@]} -gt 1 ]]; then
    echo ""
    echo "<details>"
    echo "<summary>Task and build policy changes</summary>"
    echo ""
    for image in "${POLICY_IMAGES[@]:1}"; do
        render_rule_diff "$image"
    done
    echo ""
    echo "</details>"
fi

echo "" >&2

if [[ "$RELEASE_DIR" != "-" && ! "${RELEASE_DIR}/images.json" -ef "$CANDIDATE_IMAGES_FILE" ]]; then
    cp "$CANDIDATE_IMAGES_FILE" "${RELEASE_DIR}/images.json"
fi

echo
echo "## Task and StepAction definitions"
echo
jq -r '.inputs | (.sourceTaskBundle, .stepActionsBundle) | "- Source bundle: `\(.image)@\(.digest)`"' "$CANDIDATE_IMAGES_FILE"
bundle=$(candidate_ref quay.io/conforma/tekton-task)
"${SCRIPT_DIR}/extract-bundle-resources.sh" "$bundle" "$TMPDIR_BASE/catalog" task tasks >&2
"${SCRIPT_DIR}/extract-bundle-resources.sh" "$bundle" "$TMPDIR_BASE/catalog" stepaction stepactions >&2
"${SCRIPT_DIR}/check-release-inputs.sh" "$CANDIDATE_IMAGES_FILE" "$TMPDIR_BASE/catalog"
git init --bare -q "$TMPDIR_BASE/catalog-base"
base=$(jq -r '.catalog.baseCommit' "$CANDIDATE_IMAGES_FILE")
git -C "$TMPDIR_BASE/catalog-base" fetch -q --depth=1 https://github.com/conforma/tekton-catalog.git "$base"
while IFS= read -r file; do
    path=${file#"$TMPDIR_BASE/catalog/"}
    echo; echo "### $path"; echo
    : > "$TMPDIR_BASE/previous.yaml"
    if [[ -n $(git -C "$TMPDIR_BASE/catalog-base" ls-tree "$base" -- "$path") ]]; then
        git -C "$TMPDIR_BASE/catalog-base" show "$base:$path" > "$TMPDIR_BASE/previous.yaml"
    fi
    echo '
```diff'
    diff -u "$TMPDIR_BASE/previous.yaml" "$file" || [[ $? == 1 ]]
    echo '```'
done < <(find "$TMPDIR_BASE/catalog" -name '*.yaml' -type f | sort)

echo "" >&2
echo "Comparing policy behavior..." >&2
if ! "${SCRIPT_DIR}/policy-behavior/compare-policy-behavior.sh" \
    --report "$POLICY_BEHAVIOR_FILE" \
    --targets "$CONFIG_DIR/targets.json" \
    --policy-template "$CONFIG_DIR/policy.yaml" \
    --public-key "${TMPDIR_BASE}/config/acceptance/pub.key" \
    --effective-time "$(jq -r '.inputs.testInputs.comparisonTime' "$CANDIDATE_IMAGES_FILE")" \
    "${TMPDIR_BASE}/config/before.json" "$CANDIDATE_IMAGES_FILE" > /dev/null; then
    echo "ERROR: Policy behavior comparison failed" >&2
    exit 1
fi
cat "$POLICY_BEHAVIOR_FILE"

if [[ "$RELEASE_DIR" != "-" ]]; then
    echo "Release written to ${RELEASE_DIR}/" >&2
fi
echo "Done." >&2
