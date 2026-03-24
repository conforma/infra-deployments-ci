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

# Resolves each unique bundle URL and CLI image referenced in acceptance
# pipeline definitions to their current digests. Outputs a JSON object mapping
# image URL to pinned "repo@digest" for use in downstream CI jobs.
#
# Usage:
#   resolve-tested-digests.sh
#
# Output (JSON):
#   {
#     "quay.io/conforma/tekton-task:latest": "quay.io/conforma/tekton-task@sha256:abc...",
#     "quay.io/conforma/cli": "quay.io/conforma/cli@sha256:def..."
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Get unique bundle URLs from acceptance pipeline definitions
BUNDLE_URLS=$(
    for pipeline_file in "${REPO_ROOT}"/acceptance/conforma*.yaml; do
        [ -f "$pipeline_file" ] || continue
        yq eval '
            .spec.tasks[] |
            select(.taskRef.resolver == "bundles") |
            .taskRef.params[] |
            select(.name == "bundle") |
            .value
        ' "$pipeline_file"
    done | sort -u
)

if [ -z "$BUNDLE_URLS" ]; then
    echo "ERROR: No bundle URLs found in acceptance pipeline files" >&2
    exit 1
fi

# Build JSON map of url → url@digest
RESULT="{}"
FIRST_PINNED=""
for url in $BUNDLE_URLS; do
    digest=$(crane digest "$url")
    pinned="${url%:*}@${digest}"
    RESULT=$(echo "$RESULT" | jq --arg url "$url" --arg pinned "$pinned" '. + {($url): $pinned}')
    echo "Resolved ${url} → ${pinned}" >&2
    [ -z "$FIRST_PINNED" ] && FIRST_PINNED="$pinned"
done

# Extract the CLI image from the first bundle and add it to the map
MANIFEST=$(crane manifest "$FIRST_PINNED")
LAYER_DIGEST=$(echo "$MANIFEST" | jq -r '
    .layers[] |
    select(
        .annotations["dev.tekton.image.name"] == "verify-enterprise-contract" and
        .annotations["dev.tekton.image.kind"] == "task"
    ) | .digest')

if [ -z "$LAYER_DIGEST" ]; then
    echo "ERROR: verify-enterprise-contract task not found in bundle $FIRST_PINNED" >&2
    exit 1
fi

REPO="${FIRST_PINNED%@*}"
REPO="${REPO%:*}"
CLI_IMAGE=$(crane blob "${REPO}@${LAYER_DIGEST}" | gunzip | tar -xO | yq eval '.spec.steps[0].image' -)

if [ -z "$CLI_IMAGE" ] || [ "$CLI_IMAGE" = "null" ]; then
    echo "ERROR: Could not extract CLI image from task definition" >&2
    exit 1
fi

CLI_REPO="${CLI_IMAGE%@*}"
CLI_REPO="${CLI_REPO%:*}"
RESULT=$(echo "$RESULT" | jq --arg url "$CLI_REPO" --arg pinned "$CLI_IMAGE" '. + {($url): $pinned}')
echo "Resolved CLI image: ${CLI_IMAGE}" >&2

echo "$RESULT"
