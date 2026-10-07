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

# Check the policy images pinned by a submitted release against current
# production (:konflux). The diff tool checks each newly added rule.
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 releases/<date>/images.json [...]" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for images_file in "$@"; do
    if [[ ! -f "$images_file" ]]; then
        echo "ERROR: Release images file not found: $images_file" >&2
        exit 1
    fi

    if ! jq -e '(.policy | type == "array" and length > 0) and
        all(.policy[]; (.image | type == "string" and length > 0) and
                       (.digest | type == "string" and startswith("sha256:")))' \
        "$images_file" >/dev/null; then
        echo "ERROR: Invalid policy image list in $images_file" >&2
        exit 1
    fi

    echo "Checking new policy rules in $images_file"
    image_rows=$(jq -r '.policy[] | [.image, .digest] | @tsv' "$images_file")
    while IFS=$'\t' read -r image digest; do
        echo "  ${image}@${digest}"
        (cd "${SCRIPT_DIR}/policy-rule-diff" && go run . \
            -bundle -min-effective-lead-days 56 \
            "${image}:konflux" "${image}@${digest}" >/dev/null)
    done <<< "$image_rows"
done
