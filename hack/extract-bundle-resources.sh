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
[[ "${REPO##*/}" != *:* ]] || REPO="${REPO%:*}"
RESOURCE_DIR=$(realpath -m "${OUTPUT_DIR}/${DIRECTORY}")

MANIFEST=$(crane manifest "$BUNDLE")
LAYERS=$(echo "$MANIFEST" | jq -c --arg kind "$KIND" '
    .layers[] | select(.annotations["dev.tekton.image.kind"] == $kind)')

if [ -z "$LAYERS" ]; then
    echo "ERROR: No ${KIND} layers found in bundle ${BUNDLE}"
    exit 1
fi

RESOURCE_FILE=$(mktemp)
trap 'rm -f "$RESOURCE_FILE"' EXIT
COUNT=0
while IFS= read -r layer; do
    [ -z "$layer" ] && continue

    DIGEST=$(echo "$layer" | jq -r '.digest')
    NAME=$(echo "$layer" | jq -r '.annotations["dev.tekton.image.name"]')
    crane blob "${REPO}@${DIGEST}" | gunzip | tar -xO > "$RESOURCE_FILE"
    VERSION=$(yq eval '.metadata.labels["app.kubernetes.io/version"]' "$RESOURCE_FILE")

    if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
        echo "ERROR: ${KIND} $NAME is missing the app.kubernetes.io/version label"
        exit 1
    fi

    OUTPUT=$(realpath -m "${RESOURCE_DIR}/${NAME}/${VERSION}/${NAME}.yaml")
    if [[ "$OUTPUT" != "${RESOURCE_DIR}/"* ]]; then
        echo "ERROR: ${KIND} ${NAME} resolves outside ${RESOURCE_DIR}" >&2
        exit 1
    fi

    [[ "$NAME" =~ ^[a-z0-9][a-z0-9.-]*$ && "$VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo "ERROR: unsafe resource identity" >&2; exit 1; }
    [[ $(yq '.metadata.name' "$RESOURCE_FILE") == "$NAME" ]] || { echo "ERROR: layer/resource name mismatch" >&2; exit 1; }
    [[ $(yq '.kind | downcase' "$RESOURCE_FILE") == "$KIND" ]] || { echo "ERROR: layer/resource kind mismatch" >&2; exit 1; }
    [[ ! -e "$OUTPUT" ]] || { echo "ERROR: duplicate resource $OUTPUT" >&2; exit 1; }
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$RESOURCE_FILE" "$OUTPUT"
    echo "Extracted ${KIND}: $NAME"
    COUNT=$((COUNT + 1))
done <<< "$LAYERS"

echo "Extracted ${COUNT} ${KIND}(s) to ${OUTPUT_DIR}"
