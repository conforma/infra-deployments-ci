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

# Updates the POLICY_BUNDLE_DIGEST default value in Tekton task definitions
# to match the current digest of a policy bundle image.
#
# Usage:
#   update-policy-digest.sh <tasks-dir> [<policy-image>]
#
# Arguments:
#   tasks-dir     - Directory containing task YAML files (searched recursively)
#   policy-image  - Policy bundle image reference (default: quay.io/conforma/release-policy:konflux)

set -euo pipefail

TASKS_DIR="${1:?Usage: update-policy-digest.sh <tasks-dir> [<policy-image>]}"
POLICY_IMAGE="${2:-quay.io/conforma/release-policy:konflux}"

NEW_DIGEST=$(crane digest "$POLICY_IMAGE")
echo "Release policy digest: ${NEW_DIGEST}"

TASK_FILES=$(grep -rl 'POLICY_BUNDLE_DIGEST' "$TASKS_DIR" || true)
if [ -z "$TASK_FILES" ]; then
    echo "ERROR: No task files contain POLICY_BUNDLE_DIGEST in ${TASKS_DIR}"
    exit 1
fi

UPDATED=0
for f in $TASK_FILES; do
    OLD_DIGEST=$(yq eval '.spec.params[] | select(.name == "POLICY_BUNDLE_DIGEST") | .default' "$f")
    if [ -z "$OLD_DIGEST" ] || [ "$OLD_DIGEST" = "null" ]; then
        echo "Warning: could not extract current digest from $f, skipping"
        continue
    fi
    if [ "$OLD_DIGEST" = "$NEW_DIGEST" ]; then
        echo "Already up to date in $f"
        continue
    fi
    yq eval '(.spec.params[] | select(.name == "POLICY_BUNDLE_DIGEST") | .default) = "'"${NEW_DIGEST}"'"' -i "$f"
    echo "Updated $f: ${OLD_DIGEST} → ${NEW_DIGEST}"
    UPDATED=$((UPDATED + 1))
done

echo ""
echo "Done. Updated ${UPDATED} file(s)."
