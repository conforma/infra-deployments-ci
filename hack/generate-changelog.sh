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

# Generates a release changelog comparing :latest (to be promoted) against
# :konflux (current production) for all Conforma images.
#
# By default writes to releases/<YYYY-MM-DDTHH:MM:SS>.md in the repo root.
# Pass a path argument to write elsewhere, or "-" to write to stdout.
#
# Usage:
#   ./hack/generate-changelog.sh                  # → releases/2026-06-30T14:30:00.md
#   ./hack/generate-changelog.sh path/output.md   # → path/output.md
#   ./hack/generate-changelog.sh -                # → stdout
#
# Dependencies:
#   crane, gh, jq, go, git
#
# Output (markdown):
#   - Image digest table
#   - Merge commit logs for conforma/policy and conforma/cli
#   - Policy rule diff for release-policy, task-policy, build-task-policy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_FILE="${1:-${REPO_ROOT}/releases/$(date -u +%Y-%m-%dT%H:%M:%S).md}"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Images to include in the changelog
# ---------------------------------------------------------------------------

POLICY_IMAGES=(
    quay.io/conforma/release-policy
    quay.io/conforma/task-policy
    quay.io/conforma/build-task-policy
)

COMMIT_LOG_SOURCES=(
    # image_repo|github_org/repo
    "quay.io/conforma/release-policy|conforma/policy"
    "quay.io/conforma/cli|conforma/cli"
)

ALL_IMAGES=(
    "${POLICY_IMAGES[@]}"
    quay.io/conforma/cli
    quay.io/conforma/tekton-task
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
        -bundle -json "${image}:konflux" "${image}:latest" 2>/dev/null)

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
                "- **\(.title)** — \(.description)<br>Effective: \(.effective_on | if . == "" then "now" else .[0:10] end) · Collections: \(.collections | join(", "))"
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
                "- **\(.title)** — \(.description)<br>Collections: \(.collections | join(", "))"
            )'
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "$OUTPUT_FILE" != "-" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    exec 1>"$OUTPUT_FILE"
fi

echo "Generating changelog..." >&2

# --- Section 1: Image digests ---

echo "# Conforma Release"
echo ""
echo "## Images"
echo ""

for image in "${ALL_IMAGES[@]}"; do
    echo "  resolving ${image}:latest..." >&2
    digest=$(crane digest "${image}:latest" 2>/dev/null)
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
    konflux_rev=$(get_revision "${image_repo}:konflux")
    latest_rev=$(get_revision "${image_repo}:latest")

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

for image in "${POLICY_IMAGES[@]}"; do
    render_rule_diff "$image"
done

echo "" >&2
if [[ "$OUTPUT_FILE" != "-" ]]; then
    echo "Changelog written to ${OUTPUT_FILE}" >&2
fi
echo "Done." >&2
