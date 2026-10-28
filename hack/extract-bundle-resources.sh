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

set -euo pipefail

BUNDLE="${1:?Usage: extract-bundle-resources.sh <bundle-ref> <output-dir> <kind> <directory>}"
OUTPUT_DIR="${2:?Usage: extract-bundle-resources.sh <bundle-ref> <output-dir> <kind> <directory>}"
KIND="${3:?Usage: extract-bundle-resources.sh <bundle-ref> <output-dir> <kind> <directory>}"
DIRECTORY="${4:?Usage: extract-bundle-resources.sh <bundle-ref> <output-dir> <kind> <directory>}"
REPO="${BUNDLE%@*}"
REPO="${REPO%:*}"
RESOURCE_DIR=$(realpath -m "${OUTPUT_DIR}/${DIRECTORY}")

MANIFEST=$(crane manifest "$BUNDLE")
LAYERS=$(echo "$MANIFEST" | jq -c --arg kind "$KIND" '
    .layers[] | select(.annotations["dev.tekton.image.kind"] == $kind)')

if [ -z "$LAYERS" ]; then
    echo "ERROR: No ${KIND} layers found in bundle ${BUNDLE}"
    exit 1
fi

COUNT=0
while IFS= read -r layer; do
    [ -z "$layer" ] && continue

    DIGEST=$(echo "$layer" | jq -r '.digest')
    NAME=$(echo "$layer" | jq -r '.annotations["dev.tekton.image.name"]')
    YAML=$(crane blob "${REPO}@${DIGEST}" | gunzip | tar -xO)
    VERSION=$(echo "$YAML" | yq eval '.metadata.labels["app.kubernetes.io/version"]' -)

    if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
        echo "ERROR: ${KIND} $NAME is missing the app.kubernetes.io/version label"
        exit 1
    fi

    OUTPUT=$(realpath -m "${RESOURCE_DIR}/${NAME}/${VERSION}/${NAME}.yaml")
    if [[ "$OUTPUT" != "${RESOURCE_DIR}/"* ]]; then
        echo "ERROR: ${KIND} ${NAME} resolves outside ${RESOURCE_DIR}" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$OUTPUT")"
    echo "$YAML" | yq eval '.' -P - > "$OUTPUT"
    echo "Extracted ${KIND}: $NAME"
    COUNT=$((COUNT + 1))
done <<< "$LAYERS"

echo "Extracted ${COUNT} ${KIND}(s) to ${OUTPUT_DIR}"
