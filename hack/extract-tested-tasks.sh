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

# Extracts tested task definitions from a Tekton bundle and arranges them
# in the tekton-catalog directory layout: tasks/<task-name>/<version>/<task-name>.yaml
#
# Task names are determined by parsing the acceptance pipeline YAML files
# for bundle resolver taskRefs. Only tasks that are referenced in acceptance
# pipelines (and therefore tested) are extracted.
#
# Usage:
#   extract-tested-tasks.sh <bundle> <output-dir>

set -euo pipefail

BUNDLE="${1:?Usage: extract-tested-tasks.sh <bundle> <output-dir>}"
OUTPUT_DIR="${2:?Usage: extract-tested-tasks.sh <bundle> <output-dir>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse acceptance pipeline YAML files to find task names referenced via bundle resolver
TASK_NAMES=()
for pipeline_file in "${REPO_ROOT}"/acceptance/conforma*.yaml; do
    [ -f "$pipeline_file" ] || continue
    names=$(yq eval '.spec.tasks[] | select(.taskRef.resolver == "bundles") | .taskRef.params[] | select(.name == "name") | .value' "$pipeline_file")
    for name in $names; do
        TASK_NAMES+=("$name")
    done
done

# Deduplicate
mapfile -t TASK_NAMES < <(printf '%s\n' "${TASK_NAMES[@]}" | sort -u)

if [ ${#TASK_NAMES[@]} -eq 0 ]; then
    echo "ERROR: No task names found in acceptance pipeline files"
    exit 1
fi

echo "Tasks to extract: ${TASK_NAMES[*]}"

# Get bundle manifest
MANIFEST=$(crane manifest "$BUNDLE")

# Extract each task
for task_name in "${TASK_NAMES[@]}"; do
    echo "Extracting task: $task_name"

    # Find the layer with matching name and kind annotations
    DIGEST=$(echo "$MANIFEST" | jq -r --arg name "$task_name" \
        '.layers[] | select(.annotations["dev.tekton.image.name"] == $name and .annotations["dev.tekton.image.kind"] == "task") | .digest')

    if [ -z "$DIGEST" ]; then
        echo "ERROR: Task $task_name not found in bundle $BUNDLE"
        exit 1
    fi

    # Extract the task YAML (layers are tar+gzip encoded)
    TASK_YAML=$(crane blob "${BUNDLE}@${DIGEST}" | gunzip | tar -xO)

    # Get version from task labels
    VERSION=$(echo "$TASK_YAML" | yq eval '.metadata.labels["app.kubernetes.io/version"]' -)
    if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
        VERSION="0.1"
    fi

    # Create catalog directory structure
    TASK_DIR="${OUTPUT_DIR}/tasks/${task_name}/${VERSION}"
    mkdir -p "$TASK_DIR"
    echo "$TASK_YAML" | yq eval '.' -P - > "${TASK_DIR}/${task_name}.yaml"

    echo "Written to ${TASK_DIR}/${task_name}.yaml"
done

echo "Done. Extracted ${#TASK_NAMES[@]} task(s) to ${OUTPUT_DIR}"
