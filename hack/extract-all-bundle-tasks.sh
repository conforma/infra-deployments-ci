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

# Extracts all task definitions from a Tekton bundle and arranges them in
# the catalog directory layout: tasks/<task-name>/<version>/<task-name>.yaml
#
# Unlike extract-tested-tasks.sh, this script extracts every task in the
# bundle, not just those referenced in acceptance pipelines.
#
# Usage:
#   extract-all-bundle-tasks.sh <bundle-ref> <output-dir>
#
# Arguments:
#   bundle-ref  - OCI reference for the Tekton bundle (tag or digest)
#   output-dir  - Directory to write extracted tasks into

set -euo pipefail

BUNDLE="${1:?Usage: extract-all-bundle-tasks.sh <bundle-ref> <output-dir>}"
OUTPUT_DIR="${2:?Usage: extract-all-bundle-tasks.sh <bundle-ref> <output-dir>}"

REPO="${BUNDLE%@*}"
REPO="${REPO%:*}"

MANIFEST=$(crane manifest "$BUNDLE")

TASK_LAYERS=$(echo "$MANIFEST" | jq -c '
    .layers[] | select(.annotations["dev.tekton.image.kind"] == "task")')

if [ -z "$TASK_LAYERS" ]; then
    echo "ERROR: No task layers found in bundle ${BUNDLE}"
    exit 1
fi

COUNT=0
while IFS= read -r layer; do
    [ -z "$layer" ] && continue

    DIGEST=$(echo "$layer" | jq -r '.digest')
    NAME=$(echo "$layer" | jq -r '.annotations["dev.tekton.image.name"]')

    echo "Extracting task: $NAME"

    TASK_YAML=$(crane blob "${REPO}@${DIGEST}" | gunzip | tar -xO)

    VERSION=$(echo "$TASK_YAML" | yq eval '.metadata.labels["app.kubernetes.io/version"]' -)
    if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
        echo "ERROR: Task $NAME is missing the app.kubernetes.io/version label"
        exit 1
    fi

    TASK_DIR="${OUTPUT_DIR}/tasks/${NAME}/${VERSION}"
    mkdir -p "$TASK_DIR"
    echo "$TASK_YAML" | yq eval '.' -P - > "${TASK_DIR}/${NAME}.yaml"

    echo "  Written to ${TASK_DIR}/${NAME}.yaml"
    COUNT=$((COUNT + 1))
done <<< "$TASK_LAYERS"

echo ""
echo "Done. Extracted ${COUNT} task(s) to ${OUTPUT_DIR}"
