#!/usr/bin/env bash
# Copyright The Conforma Contributors
# SPDX-License-Identifier: Apache-2.0
# Capture inputs once, then assemble the candidate that images.json identifies.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUTPUT=${1:?Usage: prepare-release.sh new-release-directory}
[[ ! -e "$OUTPUT" ]] || { echo "ERROR: release directory already exists" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
artifact() {
    local image=$1 tag=$2 digest
    digest=$(crane digest "$image:$tag")
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
    jq -n --arg image "$image" --arg digest "$digest" '{image:$image,digest:$digest}'
}
config=$(git -C "$ROOT" rev-parse HEAD)
git -C "$ROOT" diff --quiet HEAD -- hack acceptance features || { echo "ERROR: commit test configuration before preparing a release" >&2; exit 1; }
policies='[]'
for pair in release-policy:ec-release-policy task-policy:ec-task-policy build-task-policy:ec-build_task-policy; do
    item=$(artifact "quay.io/conforma/${pair%:*}" latest)
    policies=$(jq --argjson item "$item" --arg mirror "quay.io/enterprise-contract/${pair#*:}" '. + [$item + {mirrors:[$mirror]}]' <<< "$policies")
done
cli=$(artifact quay.io/conforma/cli latest)
source=$(artifact quay.io/conforma/tekton-task latest)
steps=$(artifact quay.io/conforma/step-actions snapshot)
baselines='[]'
while IFS= read -r image; do
    digest=$(crane digest "$image:konflux")
    baselines=$(jq --arg ref "$image:konflux" --arg digest "$digest" '. + [{reference:$ref,digest:$digest}]' <<< "$baselines")
done < <(jq -r '.[].image, .[].mirrors[]' <<< "$policies"; printf '%s\n' quay.io/conforma/cli quay.io/conforma/tekton-task)
base=$(git ls-remote https://github.com/conforma/tekton-catalog.git refs/heads/konflux | cut -f1)
targets='[]'
while IFS=$'\t' read -r name reference; do
    image=${reference%:*}; tag=${reference##*:}
    item=$(artifact "$image" "$tag")
    targets=$(jq --argjson item "$item" --arg name "$name" '. + [$item + {name:$name}]' <<< "$targets")
done < <(git -C "$ROOT" show "$config:hack/policy-behavior/targets.json" | jq -r '.targets[] | [.name,.image] | @tsv')
data='[]'
while IFS= read -r reference; do
    [[ "$reference" == oci::* ]] || { echo 'ERROR: use an OCI policy data reference in golden-policy.yaml' >&2; exit 1; }
    reference=${reference#oci::}
    if [[ "$reference" != *@sha256:* ]]; then
        digest=$(crane digest "$reference"); reference="${reference%:*}@$digest"
    fi
    data=$(jq --arg ref "oci::$reference" '. + [$ref]' <<< "$data")
done < <(git -C "$ROOT" show "$config:hack/policy-behavior/golden-policy.yaml" | yq '.spec.sources[0].data[]' -)
"$SCRIPT_DIR/extract-bundle-resources.sh" "$(jq -r '.image+"@"+.digest' <<< "$source")" "$WORK/catalog" task tasks
"$SCRIPT_DIR/extract-bundle-resources.sh" "$(jq -r '.image+"@"+.digest' <<< "$steps")" "$WORK/catalog" stepaction stepactions
"$SCRIPT_DIR/update-policy-digest.sh" "$WORK/catalog/tasks" "$(jq -r '.[0] | .image+"@"+.digest' <<< "$policies")"
"$SCRIPT_DIR/pin-task-inputs.sh" "$WORK/catalog" "$(jq -r '.image+"@"+.digest' <<< "$cli")"
files=()
while IFS= read -r file; do files+=(-f "$file"); done < <(find "$WORK/catalog" -name '*.yaml' -type f | sort)
tag="candidate-${GITHUB_RUN_ID:-$(date -u +%Y%m%d%H%M%S)}-${GITHUB_RUN_ATTEMPT:-${WORK##*.}}"
tkn bundle push "quay.io/conforma/tekton-task:$tag" "${files[@]}"
bundle=$(artifact quay.io/conforma/tekton-task "$tag" | jq --arg tag "$tag" '. + {retentionTag:$tag}')
jq -n --argjson policy "$policies" --argjson cli "$cli" --argjson bundle "$bundle" \
    --argjson source "$source" --argjson steps "$steps" --argjson targets "$targets" --argjson data "$data" \
    --arg config "$config" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg base "$base" --argjson baseline "$baselines" '
    {schemaVersion:2,policy:$policy,components:[$cli,$bundle],
     inputs:{sourceTaskBundle:$source,stepActionsBundle:$steps,testInputs:{configCommit:$config,targets:$targets,policyData:$data,comparisonTime:$time}},
     catalog:{repository:"conforma/tekton-catalog",branch:"konflux",baseCommit:$base},baseline:{images:$baseline}}
' > "$WORK/images.json"
"$SCRIPT_DIR/check-release-inputs.sh" "$WORK/images.json" "$WORK/catalog"
mkdir -p "$OUTPUT"
cp "$WORK/images.json" "$OUTPUT/images.json"
