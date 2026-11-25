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

# Validates a v2 release manifest (images.json). Without a catalog
# directory it checks the manifest schema: schemaVersion, the required
# policy and component entries, digest shapes and the candidate bundle's
# retention tag. With a second argument naming a directory of extracted
# task/StepAction definitions, it also verifies that everything inside the
# assembled bundle is pinned the way the manifest records: the CLI image
# matches the manifest, POLICY_BUNDLE_DIGEST defaults match the manifest,
# every image reference is digest-pinned and every Git-resolver StepAction
# revision is a full commit SHA.
#
# Usage:
#   check-release-inputs.sh <images.json> [catalog-directory]
#
# Dependencies:
#   jq, yq (only when a catalog directory is given)

set -euo pipefail

MANIFEST="${1:?Usage: check-release-inputs.sh <images.json> [catalog-directory]}"

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: Release manifest not found: $MANIFEST" >&2
    exit 1
fi

# The set of policy images and their enterprise-contract mirrors. The
# mirrors are release destinations, so a manifest that lists anything else
# would publish somewhere unexpected.
if ! jq -e '
  def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  def artifact: (.image | type == "string" and length > 0) and (.digest | digest);
  {"quay.io/conforma/release-policy": "quay.io/enterprise-contract/ec-release-policy",
   "quay.io/conforma/task-policy": "quay.io/enterprise-contract/ec-task-policy",
   "quay.io/conforma/build-task-policy": "quay.io/enterprise-contract/ec-build_task-policy"} as $policies |
  .schemaVersion == 2 and
  ([.policy[].image] | sort) == ($policies | keys | sort) and
  all(.policy[]; artifact and .mirrors == [$policies[.image]]) and
  ([.components[].image] | sort) == ["quay.io/conforma/cli", "quay.io/conforma/tekton-task"] and
  all(.components[]; artifact) and
  (.components[] | select(.image == "quay.io/conforma/tekton-task") |
     .retentionTag | type == "string" and test("^candidate-[A-Za-z0-9_.:-]+$")) and
  (.inputs.sourceTaskBundle | .image == "quay.io/conforma/tekton-task" and (.digest | digest)) and
  (.inputs.stepActionsBundle | .image == "quay.io/conforma/step-actions" and (.digest | digest))
' "$MANIFEST" > /dev/null; then
    echo "ERROR: invalid release manifest: $MANIFEST" >&2
    exit 1
fi

if [ $# -ne 2 ]; then
    echo "Release manifest OK: $MANIFEST"
    exit 0
fi

CATALOG_DIR="$2"
if [ ! -d "$CATALOG_DIR" ]; then
    echo "ERROR: catalog directory not found: $CATALOG_DIR" >&2
    exit 1
fi

CLI_REF=$(jq -r '.components[] | select(.image == "quay.io/conforma/cli") | .image + "@" + .digest' "$MANIFEST")
POLICY_DIGEST=$(jq -r '.policy[] | select(.image == "quay.io/conforma/release-policy") | .digest' "$MANIFEST")

STATUS=0
while IFS= read -r file; do
    # Every image reference inside the assembled bundle must be immutable.
    while IFS= read -r image; do
        [ -z "$image" ] && continue
        if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
            echo "ERROR: mutable image reference in ${file}: ${image}" >&2
            STATUS=1
        fi
        if [[ "$image" == quay.io/conforma/cli* && "$image" != "$CLI_REF" ]]; then
            echo "ERROR: CLI image in ${file} does not match the manifest: ${image}" >&2
            STATUS=1
        fi
    done < <(yq -r '.. | select(has("image")) | .image' "$file")

    # The policy default baked into the task definitions must be the digest
    # the manifest says will be promoted.
    while IFS= read -r value; do
        [ -z "$value" ] && continue
        if [ "$value" != "$POLICY_DIGEST" ]; then
            echo "ERROR: POLICY_BUNDLE_DIGEST in ${file} does not match the manifest: ${value}" >&2
            STATUS=1
        fi
    done < <(yq -r '.spec.params[]? | select(.name == "POLICY_BUNDLE_DIGEST") | .default // ""' "$file")

    # Git-resolver StepAction revisions must be full commit SHAs.
    while IFS= read -r revision; do
        [ -z "$revision" ] && continue
        if [[ ! "$revision" =~ ^[a-f0-9]{40}$ ]]; then
            echo "ERROR: mutable StepAction revision in ${file}: ${revision}" >&2
            STATUS=1
        fi
    done < <(yq -r '.spec.steps[]? | select(has("ref")) | .ref.params[]? | select(.name == "revision") | .value // ""' "$file")
done < <(find "$CATALOG_DIR" -name '*.yaml' -type f | sort)

if [ "$STATUS" -ne 0 ]; then
    echo "ERROR: bundle contents are not pinned as recorded in ${MANIFEST}" >&2
    exit 1
fi

echo "Release inputs OK: ${MANIFEST} and ${CATALOG_DIR}"
