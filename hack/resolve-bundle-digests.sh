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

# Resolves each unique bundle URL referenced in acceptance pipeline definitions
# to its current digest, and extracts the CLI image reference from the bundle.
# Outputs a JSON object mapping image URL to pinned "repo@digest" for use in
# downstream CI jobs.
#
# Usage:
#   resolve-bundle-digests.sh
#
# Output (JSON):
#   {
#     "quay.io/conforma/tekton-task:latest": "quay.io/conforma/tekton-task@sha256:abc...",
#     "quay.io/conforma/cli": "quay.io/conforma/cli@sha256:def..."
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get unique bundle URLs
BUNDLE_URLS=$("${SCRIPT_DIR}/tested-bundle-urls.sh")

# Build JSON map of url → url@digest
RESULT="{}"
for url in $BUNDLE_URLS; do
    digest=$(crane digest "$url")
    pinned="${url%:*}@${digest}"
    RESULT=$(echo "$RESULT" | jq --arg url "$url" --arg pinned "$pinned" '. + {($url): $pinned}')
    echo "Resolved ${url} → ${pinned}" >&2
done

# Extract the CLI image from the first bundle and add it to the map
FIRST_BUNDLE=$(echo "$RESULT" | jq -r 'to_entries[0].value')
CLI_IMAGE=$("${SCRIPT_DIR}/resolve-cli-image.sh" "$FIRST_BUNDLE")
CLI_REPO="${CLI_IMAGE%@*}"
CLI_REPO="${CLI_REPO%:*}"
RESULT=$(echo "$RESULT" | jq --arg url "$CLI_REPO" --arg pinned "$CLI_IMAGE" '. + {($url): $pinned}')

echo "$RESULT"
