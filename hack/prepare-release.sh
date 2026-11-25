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

# Pins every release input once and assembles the final Tekton task bundle
# before anything is tested or published. Writes a v2 images.json that the
# acceptance suite and the publication workflow both consume as the single
# source of truth.
#
# Usage:
#   prepare-release.sh <new-release-directory>
#
# The output directory must not exist yet; only images.json is written.
# Generate the changelog afterwards with:
#   generate-changelog.sh <new-release-directory>/images.json
#
# Requires push credentials for quay.io/conforma (tkn bundle push).
#
# Dependencies:
#   crane, git, jq, tkn, yq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="${1:?Usage: prepare-release.sh <new-release-directory>}"
if [ -e "$OUTPUT_DIR" ]; then
    echo "ERROR: release directory already exists: ${OUTPUT_DIR}" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Policy images and their enterprise-contract mirrors, "image|mirror".
POLICY_IMAGE_ENTRIES=(
    "quay.io/conforma/release-policy|quay.io/enterprise-contract/ec-release-policy"
    "quay.io/conforma/task-policy|quay.io/enterprise-contract/ec-task-policy"
    "quay.io/conforma/build-task-policy|quay.io/enterprise-contract/ec-build_task-policy"
)

# resolve_ref resolves an image reference to a digest, once.
resolve_ref() {
    local ref="$1" digest
    echo "  resolving ${ref}..." >&2
    if ! digest=$(crane digest "$ref"); then
        echo "ERROR: failed to resolve ${ref}" >&2
        exit 1
    fi
    if [[ ! "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        echo "ERROR: invalid digest for ${ref}: ${digest}" >&2
        exit 1
    fi
    printf '%s\n' "$digest"
}

# pin_cli_images rewrites every quay.io/conforma/cli reference (tagged or
# digest-pinned) in the extracted definitions to the candidate CLI digest.
pin_cli_images() {
    local dir="$1" cli_ref="$2" file image
    while IFS= read -r file; do
        while IFS= read -r image; do
            [ -z "$image" ] && continue
            [[ "$image" =~ ^quay\.io/conforma/cli([:@]|$) ]] || continue
            if [ "$image" != "$cli_ref" ]; then
                yq -i "(.. | select(has(\"image\")) | select(.image == \"${image}\") | .image) = \"${cli_ref}\"" "$file"
                echo "  pinned CLI image in ${file##*/}: ${image} → ${cli_ref}" >&2
            fi
        done < <(yq -r '.. | select(has("image")) | .image' "$file")
    done < <(find "$dir" -name '*.yaml' -type f | sort)
}

# pin_step_actions resolves mutable Git-resolver StepAction revisions
# (branches or tags) to full commit SHAs.
pin_step_actions() {
    local dir="$1" file ref url revision sha
    while IFS= read -r file; do
        while IFS= read -r ref; do
            [ -z "$ref" ] && continue
            url=$(jq -r '.params[] | select(.name == "url") | .value' <<< "$ref")
            revision=$(jq -r '.params[] | select(.name == "revision") | .value' <<< "$ref")
            [[ "$revision" =~ ^[a-f0-9]{40}$ ]] && continue
            sha=$(git ls-remote "$url" "refs/heads/${revision}" | cut -f1)
            if [ -z "$sha" ]; then
                sha=$(git ls-remote "$url" "refs/tags/${revision}" | cut -f1)
            fi
            if [[ ! "$sha" =~ ^[a-f0-9]{40}$ ]]; then
                echo "ERROR: could not resolve ${url} revision ${revision} to a commit SHA" >&2
                exit 1
            fi
            yq -i "(.spec.steps[] | select(.ref.resolver == \"git\") |
                .ref.params[] | select(.name == \"revision\") | .value) = \"${sha}\"" "$file"
            echo "  pinned StepAction in ${file##*/}: ${url} ${revision} → ${sha}" >&2
        done < <(yq -o=json -I=0 '.spec.steps[]? | select(has("ref")) | select(.ref.resolver == "git") | .ref' "$file")
    done < <(find "$dir" -name '*.yaml' -type f | sort)
}

# ---------------------------------------------------------------------------
# 1. Resolve every release input once
# ---------------------------------------------------------------------------

echo "Resolving release inputs..." >&2

POLICIES='[]'
for entry in "${POLICY_IMAGE_ENTRIES[@]}"; do
    IFS='|' read -r image mirror <<< "$entry"
    digest=$(resolve_ref "${image}:latest")
    POLICIES=$(jq -n --arg image "$image" --arg digest "$digest" --arg mirror "$mirror" \
        '$policies + [{image: $image, digest: $digest, mirrors: [$mirror]}]' \
        --argjson policies "$POLICIES")
done

CLI_DIGEST=$(resolve_ref quay.io/conforma/cli:latest)
CLI_REF="quay.io/conforma/cli@${CLI_DIGEST}"
SOURCE_TASK_DIGEST=$(resolve_ref quay.io/conforma/tekton-task:latest)
STEP_ACTIONS_DIGEST=$(resolve_ref quay.io/conforma/step-actions:snapshot)
POLICY_REF=$(jq -r '.[0] | .image + "@" + .digest' <<< "$POLICIES")

# ---------------------------------------------------------------------------
# 2. Extract the definitions from the pinned source bundles
# ---------------------------------------------------------------------------

echo "Extracting bundle resources..." >&2
"${SCRIPT_DIR}/extract-bundle-resources.sh" \
    "quay.io/conforma/tekton-task@${SOURCE_TASK_DIGEST}" "$WORK/catalog" task tasks
"${SCRIPT_DIR}/extract-bundle-resources.sh" \
    "quay.io/conforma/step-actions@${STEP_ACTIONS_DIGEST}" "$WORK/catalog" stepaction stepactions

# ---------------------------------------------------------------------------
# 3. Bake the pinned policy and CLI into the task definitions
# ---------------------------------------------------------------------------

"${SCRIPT_DIR}/update-policy-digest.sh" "$WORK/catalog/tasks" "$POLICY_REF"
pin_cli_images "$WORK/catalog" "$CLI_REF"
pin_step_actions "$WORK/catalog"

# ---------------------------------------------------------------------------
# 4. Assemble the candidate bundle
# ---------------------------------------------------------------------------

RETENTION_TAG="candidate-$(date -u +%Y%m%d%H%M%S)"
BUNDLE_REF="quay.io/conforma/tekton-task:${RETENTION_TAG}"

TASK_FILES=()
while IFS= read -r file; do
    TASK_FILES+=("-f" "$file")
done < <(find "$WORK/catalog" -name '*.yaml' -type f | sort)

echo "Pushing candidate bundle ${BUNDLE_REF}..." >&2
tkn bundle push "$BUNDLE_REF" "${TASK_FILES[@]}"

# The tag is unique to this run, so the digest read back cannot race with
# another push moving it.
BUNDLE_DIGEST=$(resolve_ref "$BUNDLE_REF")

# ---------------------------------------------------------------------------
# 5. Write and validate the manifest
# ---------------------------------------------------------------------------

jq -n \
    --argjson policies "$POLICIES" \
    --arg cli_ref "$CLI_REF" \
    --arg bundle_digest "$BUNDLE_DIGEST" \
    --arg retention_tag "$RETENTION_TAG" \
    --arg source_task_digest "$SOURCE_TASK_DIGEST" \
    --arg step_actions_digest "$STEP_ACTIONS_DIGEST" \
    '{
        schemaVersion: 2,
        policy: $policies,
        components: [
            ($cli_ref | split("@") as [$image, $digest] | {image: $image, digest: $digest}),
            {
                image: "quay.io/conforma/tekton-task",
                digest: $bundle_digest,
                retentionTag: $retention_tag
            }
        ],
        inputs: {
            sourceTaskBundle: {
                image: "quay.io/conforma/tekton-task",
                digest: $source_task_digest
            },
            stepActionsBundle: {
                image: "quay.io/conforma/step-actions",
                digest: $step_actions_digest
            }
        }
    }' > "$WORK/images.json"

"${SCRIPT_DIR}/check-release-inputs.sh" "$WORK/images.json" "$WORK/catalog" >&2

mkdir -p "$OUTPUT_DIR"
cp "$WORK/images.json" "${OUTPUT_DIR}/images.json"
echo "Release manifest written to ${OUTPUT_DIR}/images.json" >&2
