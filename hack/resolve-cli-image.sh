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

# Extracts the CLI image reference from a Tekton task bundle.
#
# Finds the verify-enterprise-contract task in the bundle, reads its first
# step's image field, and outputs the digest-pinned reference. This is the
# CLI image that was used when the bundle was built.
#
# Usage:
#   resolve-cli-image.sh <bundle-ref>
#
# Example:
#   resolve-cli-image.sh quay.io/conforma/tekton-task@sha256:abc123...
#   # outputs: quay.io/conforma/cli@sha256:def456...

set -euo pipefail

BUNDLE="${1:?Usage: resolve-cli-image.sh <bundle-ref>}"

MANIFEST=$(crane manifest "$BUNDLE")

# Find the verify-enterprise-contract task layer
DIGEST=$(echo "$MANIFEST" | jq -r '
    .layers[] |
    select(
        .annotations["dev.tekton.image.name"] == "verify-enterprise-contract" and
        .annotations["dev.tekton.image.kind"] == "task"
    ) | .digest')

if [ -z "$DIGEST" ]; then
    echo "ERROR: verify-enterprise-contract task not found in bundle $BUNDLE" >&2
    exit 1
fi

# Extract the task YAML and get the first step's image
REPO="${BUNDLE%%@*}"
REPO="${REPO%:*}"
CLI_IMAGE=$(crane blob "${REPO}@${DIGEST}" | gunzip | tar -xO | yq eval '.spec.steps[0].image' -)

if [ -z "$CLI_IMAGE" ] || [ "$CLI_IMAGE" = "null" ]; then
    echo "ERROR: Could not extract CLI image from task definition" >&2
    exit 1
fi

echo "Resolved CLI image: ${CLI_IMAGE}" >&2
echo "$CLI_IMAGE"
