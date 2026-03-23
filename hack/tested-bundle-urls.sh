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

# Outputs the unique bundle URLs referenced in acceptance pipeline definitions.
# Used by the CI workflow to determine which bundles to tag after tests pass.
#
# Usage:
#   tested-bundle-urls.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
