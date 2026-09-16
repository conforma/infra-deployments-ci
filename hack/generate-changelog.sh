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

# Generates a release changelog comparing the new image manifest resolved from
# :latest against the previous release's images.json for all Conforma images.
#
# By default creates a release directory at releases/<YYYY-MM-DDTHH:MM:SS>/
# containing changelog.md and images.json (machine-readable image inputs
# for the release workflow).
#
# Pass a directory argument to write elsewhere, or "-" to write the
# changelog to stdout (images.json is skipped in this mode).
#
# Usage:
#   ./hack/generate-changelog.sh                  # → releases/2026-06-30T14:30:00/
#   ./hack/generate-changelog.sh path/output/     # → path/output/
#   ./hack/generate-changelog.sh -                # → stdout (changelog only)
#
# Dependencies:
#   crane, gh, jq, go, git
#
# Output:
#   <release-dir>/changelog.md  — human-readable release notes
#   <release-dir>/images.json   — machine-readable image list for the workflow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RELEASE_DIR="${1:-${REPO_ROOT}/releases/$(date -u +%Y-%m-%dT%H:%M:%S)}"
RELEASES_DIR="${POLICY_BEHAVIOR_RELEASES_DIR:-${REPO_ROOT}/releases}"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
CANDIDATE_IMAGES_FILE="${TMPDIR_BASE}/images.json"
CHANGELOG_FILE="${TMPDIR_BASE}/changelog.md"
POLICY_BEHAVIOR_FILE="${TMPDIR_BASE}/policy-behavior.md"
OLD_IMAGES_FILE="${POLICY_BEHAVIOR_OLD_IMAGES_FILE:-}"

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

        local repo="${image%@*}"
        repo="${repo%:*}"
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
    local before_ref="$2"
    local after_ref="$3"
    local name="${image##*/}"

    echo "  diffing ${name}..." >&2
    local diff_json
    diff_json=$(cd "${REPO_ROOT}/hack/policy-rule-diff" && go run . \
        -bundle -json \
        -doc-base-url "https://conforma.dev/docs/policy/packages" \
        "${before_ref}" "${after_ref}" 2>/dev/null)

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

candidate_digest_for() {
    local image="$1"
    jq -er --arg image "$image" \
        '.policy[]?, .components[]? | select(.image == $image) | .digest' \
        "$CANDIDATE_IMAGES_FILE"
}

candidate_ref_for() {
    local image="$1"
    local digest
    digest=$(candidate_digest_for "$image")
    printf '%s@%s\n' "$image" "$digest"
}

old_digest_for() {
    local image="$1"
    jq -er --arg image "$image" \
        '.policy[]?, .components[]? | select(.image == $image) | .digest' \
        "$OLD_IMAGES_FILE"
}

old_ref_for() {
    local image="$1"
    local digest
    digest=$(old_digest_for "$image")
    printf '%s@%s\n' "$image" "$digest"
}

find_previous_images_file() {
    local release_dir="$1"
    local excluded_path=""
    local candidate
    local release_name

    if [[ "$release_dir" != "-" ]]; then
        if [[ "$release_dir" == /* ]]; then
            excluded_path="${release_dir%/}/images.json"
        else
            excluded_path="${REPO_ROOT}/${release_dir%/}/images.json"
        fi
    fi

    [[ -d "$RELEASES_DIR" ]] || return 1
    while IFS= read -r candidate; do
        release_name=$(basename "$(dirname "$candidate")")
        [[ "$release_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || continue
        [[ -n "$excluded_path" && "$candidate" == "$excluded_path" ]] && continue
        printf '%s\n' "$candidate"
        return 0
    done < <(find "$RELEASES_DIR" -mindepth 2 -maxdepth 2 -type f -name images.json | sort -r)
    return 1
}

resolve_candidate_images() {
    local images_json='{"policy":[],"components":[]}'
    local entry image mirror digest

    for entry in "${POLICY_IMAGE_ENTRIES[@]}"; do
        IFS='|' read -r image mirror <<< "$entry"
        echo "  resolving ${image}:latest..." >&2
        if ! digest=$(crane digest "${image}:latest" 2>/dev/null); then
            echo "ERROR: Failed to resolve ${image}:latest" >&2
            return 1
        fi
        if [[ ! "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
            echo "ERROR: crane returned an invalid digest for ${image}:latest: ${digest}" >&2
            return 1
        fi
        images_json=$(jq --arg img "$image" --arg dig "$digest" --arg mir "$mirror" \
            '.policy += [{"image": $img, "digest": $dig, "mirrors": [$mir]}]' <<< "$images_json")
    done

    for image in "${COMPONENT_IMAGES[@]}"; do
        echo "  resolving ${image}:latest..." >&2
        if ! digest=$(crane digest "${image}:latest" 2>/dev/null); then
            echo "ERROR: Failed to resolve ${image}:latest" >&2
            return 1
        fi
        if [[ ! "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
            echo "ERROR: crane returned an invalid digest for ${image}:latest: ${digest}" >&2
            return 1
        fi
        images_json=$(jq --arg img "$image" --arg dig "$digest" \
            '.components += [{"image": $img, "digest": $dig}]' <<< "$images_json")
    done

    echo "$images_json" | jq . > "$CANDIDATE_IMAGES_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ -z "$OLD_IMAGES_FILE" ]]; then
    if ! OLD_IMAGES_FILE=$(find_previous_images_file "$RELEASE_DIR"); then
        echo "ERROR: Could not find a finalized release images.json under ${RELEASES_DIR}" >&2
        exit 1
    fi
elif [[ "$OLD_IMAGES_FILE" != /* ]]; then
    OLD_IMAGES_FILE="${REPO_ROOT}/${OLD_IMAGES_FILE}"
fi

[[ -f "$OLD_IMAGES_FILE" ]] || {
    echo "ERROR: Previous release images.json does not exist: ${OLD_IMAGES_FILE}" >&2
    exit 1
}

if ! jq -e 'type == "object" and (.policy | type == "array") and (.components | type == "array")' \
    "$OLD_IMAGES_FILE" >/dev/null 2>&1; then
    echo "ERROR: Previous release images.json is invalid or is missing policy/components arrays: ${OLD_IMAGES_FILE}" >&2
    exit 1
fi

resolve_candidate_images

# Keep all changelog output in a temporary file. The final files are copied to
# the release directory only after every section, including policy behavior,
# has completed successfully.
exec 3>&1
exec 1>"$CHANGELOG_FILE"

echo "Generating changelog..." >&2

# --- Section 1: Image digests ---

echo "# Konflux Policy Release"
echo ""
echo "> Conforma policy update for Red Hat's Konflux deployment."
echo ""
echo "## Images"
echo ""

for image in "${ALL_IMAGES[@]}"; do
    digest=$(candidate_digest_for "$image")
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
    old_ref=$(old_ref_for "$image_repo")
    candidate_ref=$(candidate_ref_for "$image_repo")
    old_rev=$(get_revision "$old_ref")
    new_rev=$(get_revision "$candidate_ref")

    echo "  old: ${old_rev}" >&2
    echo "  new: ${new_rev}" >&2

    echo ""
    echo "### [${github_repo}](https://github.com/${github_repo})"
    echo ""
    echo "Source commits: [\`${old_rev:0:8}..${new_rev:0:8}\`](https://github.com/${github_repo}/compare/${old_rev:0:8}...${new_rev:0:8})"
    echo ""

    if [[ "$old_rev" == "$new_rev" ]]; then
        echo "No changes."
        continue
    fi

    merge_commits=$(get_merge_commits "$github_repo" "$old_rev" "$new_rev")

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
render_rule_diff "${POLICY_IMAGES[0]}" \
    "$(old_ref_for "${POLICY_IMAGES[0]}")" "$(candidate_ref_for "${POLICY_IMAGES[0]}")"

# Render remaining policies in a collapsible section
if [[ ${#POLICY_IMAGES[@]} -gt 1 ]]; then
    echo ""
    echo "<details>"
    echo "<summary>Task and build policy changes</summary>"
    echo ""
    for image in "${POLICY_IMAGES[@]:1}"; do
        render_rule_diff "$image" "$(old_ref_for "$image")" "$(candidate_ref_for "$image")"
    done
    echo ""
    echo "</details>"
fi

echo "" >&2

echo "" >&2
echo "Comparing policy behavior..." >&2
if ! "${SCRIPT_DIR}/policy-behavior/compare-policy-behavior.sh" \
    --report "$POLICY_BEHAVIOR_FILE" \
    "$OLD_IMAGES_FILE" "$CANDIDATE_IMAGES_FILE" > /dev/null; then
    echo "ERROR: Policy behavior comparison failed" >&2
    exit 1
fi
cat "$POLICY_BEHAVIOR_FILE"

if [[ "$RELEASE_DIR" != "-" ]]; then
    mkdir -p "$RELEASE_DIR"
    cp "$CHANGELOG_FILE" "${RELEASE_DIR}/changelog.md"
    cp "$CANDIDATE_IMAGES_FILE" "${RELEASE_DIR}/images.json"
    echo "Release written to ${RELEASE_DIR}/" >&2
else
    cat "$CHANGELOG_FILE" >&3
fi
echo "Done." >&2
