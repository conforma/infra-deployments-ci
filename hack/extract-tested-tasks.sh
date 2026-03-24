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

# Extracts tested task definitions from Tekton bundles and arranges them
# in the tekton-catalog directory layout: tasks/<task-name>/<version>/<task-name>.yaml
#
# Bundle URLs and task names are determined by parsing the acceptance pipeline
# YAML files for bundle resolver taskRefs. Only tasks that are referenced in
# acceptance pipelines (and therefore tested) are extracted.
#
# When the BUNDLE_DIGESTS environment variable is set (JSON object mapping
# bundle URL to pinned "repo@sha256:..." reference), the script uses those
# exact digests instead of the tag from the pipeline YAML. This ensures the
# extracted tasks come from the exact image that was tested.
#
# Usage:
#   extract-tested-tasks.sh <output-dir>
#
# Environment:
#   BUNDLE_DIGESTS - Optional JSON object mapping bundle URLs to digest-pinned
#                    references (e.g. from resolve-tested-digests.sh)

set -euo pipefail

OUTPUT_DIR="${1:?Usage: extract-tested-tasks.sh <output-dir>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse acceptance pipeline YAML files to find bundle URLs and task names
# Each entry is "bundle|task_name"
BUNDLE_TASKS=()
for pipeline_file in "${REPO_ROOT}"/acceptance/conforma*.yaml; do
    [ -f "$pipeline_file" ] || continue
    # Extract bundle URL and task name pairs from bundle resolver taskRefs
    entries=$(yq eval '
        .spec.tasks[] |
        select(.taskRef.resolver == "bundles") |
        (.taskRef.params[] | select(.name == "bundle") | .value) as $bundle |
        (.taskRef.params[] | select(.name == "name") | .value) as $name |
        $bundle + "|" + $name
    ' "$pipeline_file")
    for entry in $entries; do
        BUNDLE_TASKS+=("$entry")
    done
done

# Deduplicate
mapfile -t BUNDLE_TASKS < <(printf '%s\n' "${BUNDLE_TASKS[@]}" | sort -u)

if [ ${#BUNDLE_TASKS[@]} -eq 0 ]; then
    echo "ERROR: No bundle task references found in acceptance pipeline files"
    exit 1
fi

# Group tasks by bundle for efficient extraction
declare -A BUNDLE_MAP
for entry in "${BUNDLE_TASKS[@]}"; do
    bundle="${entry%%|*}"
    task_name="${entry##*|}"
    # If BUNDLE_DIGESTS is set, resolve to the pinned digest reference
    if [ -n "${BUNDLE_DIGESTS:-}" ]; then
        pinned=$(echo "$BUNDLE_DIGESTS" | jq -r --arg url "$bundle" '.[$url] // empty')
        if [ -n "$pinned" ]; then
            bundle="$pinned"
        else
            echo "ERROR: No digest found for bundle ${bundle} in BUNDLE_DIGESTS"
            exit 1
        fi
    fi
    BUNDLE_MAP["$bundle"]+="${task_name} "
    echo "Found: bundle=${bundle} task=${task_name}"
done

# Extract tasks from each bundle
for bundle in "${!BUNDLE_MAP[@]}"; do
    read -ra task_names <<< "${BUNDLE_MAP[$bundle]}"
    echo ""
    echo "Processing bundle: $bundle"
    echo "  Tasks: ${task_names[*]}"

    MANIFEST=$(crane manifest "$bundle")

    for task_name in "${task_names[@]}"; do
        echo "  Extracting task: $task_name"

        # Find the layer with matching name and kind annotations
        DIGEST=$(echo "$MANIFEST" | jq -r --arg name "$task_name" \
            '.layers[] | select(.annotations["dev.tekton.image.name"] == $name and .annotations["dev.tekton.image.kind"] == "task") | .digest')

        if [ -z "$DIGEST" ]; then
            echo "ERROR: Task $task_name not found in bundle $bundle"
            exit 1
        fi

        # Extract the task YAML (layers are tar+gzip encoded)
        # Strip any existing tag or digest from the bundle reference to get the repo
        REPO="${bundle%@*}"
        REPO="${REPO%:*}"
        TASK_YAML=$(crane blob "${REPO}@${DIGEST}" | gunzip | tar -xO)

        # Get version from task labels
        VERSION=$(echo "$TASK_YAML" | yq eval '.metadata.labels["app.kubernetes.io/version"]' -)
        if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
            echo "ERROR: Task $task_name is missing the app.kubernetes.io/version label"
            exit 1
        fi

        # Create catalog directory structure
        TASK_DIR="${OUTPUT_DIR}/tasks/${task_name}/${VERSION}"
        mkdir -p "$TASK_DIR"
        echo "$TASK_YAML" | yq eval '.' -P - > "${TASK_DIR}/${task_name}.yaml"

        echo "  Written to ${TASK_DIR}/${task_name}.yaml"
    done
done

echo ""
echo "Done. Extracted ${#BUNDLE_TASKS[@]} task(s) to ${OUTPUT_DIR}"
