#!/usr/bin/env bash
# Copyright The Conforma Contributors
# SPDX-License-Identifier: Apache-2.0
# Validate the documented manifest; optionally inspect its extracted bundle.
set -euo pipefail
MANIFEST=${1:?Usage: check-release-inputs.sh images.json [catalog-directory]}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
jq -e '
  def digest: type == "string" and test("^sha256:[a-f0-9]{64}$");
  def commit: type == "string" and test("^[a-f0-9]{40}$");
  def artifact: (.image | type == "string" and test("^[a-z0-9.-]+/[a-z0-9._/-]+$")) and (.digest | digest);
  {"quay.io/conforma/release-policy":"quay.io/enterprise-contract/ec-release-policy",
   "quay.io/conforma/task-policy":"quay.io/enterprise-contract/ec-task-policy",
   "quay.io/conforma/build-task-policy":"quay.io/enterprise-contract/ec-build_task-policy"} as $policies |
  (.policy + .components) as $candidates |
  [$candidates[] | (.image, .mirrors[]?) + ":konflux"] as $destinations |
  .schemaVersion == 2 and
  ([.policy[].image] | sort) == ($policies | keys | sort) and
  all(.policy[]; artifact and .mirrors == [$policies[.image]]) and
  ([.components[].image] | sort) == ["quay.io/conforma/cli", "quay.io/conforma/tekton-task"] and
  all(.components[]; artifact and .mirrors == null) and
  (.components[] | select(.image == "quay.io/conforma/tekton-task") | .retentionTag | test("^candidate-[A-Za-z0-9_.-]+$")) and
  (.inputs.sourceTaskBundle | artifact and .image == "quay.io/conforma/tekton-task") and
  (.inputs.stepActionsBundle | artifact and .image == "quay.io/conforma/step-actions") and
  (.inputs.testInputs.configCommit | commit) and
  (.inputs.testInputs.comparisonTime | fromdateiso8601 | type == "number") and
  ([.inputs.testInputs.targets[].name] | sort) == ["golden-container", "golden-rpm"] and
  all(.inputs.testInputs.targets[]; artifact) and
  (.inputs.testInputs.policyData | length > 0) and
  all(.inputs.testInputs.policyData[]; test("^oci::[^@ ]+@sha256:[a-f0-9]{64}$")) and
  .catalog.repository == "conforma/tekton-catalog" and .catalog.branch == "konflux" and
  (.catalog.baseCommit | commit) and
  ([.baseline.images[].reference] | sort) == ($destinations | sort) and
  all(.baseline.images[]; .digest | digest)
' "$MANIFEST" >/dev/null || { echo "ERROR: invalid release manifest: $MANIFEST" >&2; exit 1; }
if [[ $# == 2 ]]; then
    cli=$(jq -r '.components[] | select(.image == "quay.io/conforma/cli") | .image + "@" + .digest' "$MANIFEST")
    "$SCRIPT_DIR/pin-task-inputs.sh" "$2" "$cli" --check
    policy=$(jq -r '.policy[] | select(.image == "quay.io/conforma/release-policy") | .digest' "$MANIFEST")
    while IFS= read -r file; do
        value=$(yq '.spec.params[] | select(.name == "POLICY_BUNDLE_DIGEST") | .default' "$file")
        [[ -z "$value" || "$value" == "$policy" ]] || { echo "ERROR: wrong policy default: $file" >&2; exit 1; }
    done < <(find "$2/tasks" -name '*.yaml' -type f)
fi
