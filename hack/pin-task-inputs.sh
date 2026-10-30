#!/usr/bin/env bash
# Copyright The Conforma Contributors
# SPDX-License-Identifier: Apache-2.0
# Freeze the execution images and Git StepActions used by our Tasks.
# --check verifies prepared definitions without resolving mutable references.
set -euo pipefail
DIRECTORY=${1:?Usage: pin-task-inputs.sh directory cli@digest [--check]}
CLI=${2:?Candidate CLI reference required}
MODE=${3:-prepare}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
declare -A images revisions
pin_image() {
    local image=$1 repo
    [[ "$image" != *'$('* ]] || { echo "ERROR: parameterized execution image: $image" >&2; exit 1; }
    if [[ "$image" == quay.io/conforma/cli:* || "$image" == quay.io/conforma/cli@* ]]; then
        PIN=$CLI
    elif [[ "$image" =~ @sha256:[a-f0-9]{64}$ ]]; then
        PIN=$image
    else
        [[ "$MODE" != --check ]] || { echo "ERROR: mutable execution image: $image" >&2; exit 1; }
        repo=${image%@*}; [[ "${repo##*/}" != *:* ]] || repo=${repo%:*}
        if [[ -z "${images[$image]:-}" ]]; then images[$image]="$repo@$(crane digest "$image")"; fi
        PIN=${images[$image]}
    fi
    [[ "$PIN" =~ @sha256:[a-f0-9]{64}$ ]] || exit 1
    [[ "$MODE" != --check || "$PIN" == "$image" ]] || { echo "ERROR: wrong CLI digest: $image" >&2; exit 1; }
}
while IFS= read -r file; do
    yq -o=json "$file" > "$WORK/resource.json"
    while IFS= read -r image; do
        pin_image "$image"
        jq --arg from "$image" --arg to "$PIN" 'walk(if type == "object" and .image? == $from then .image = $to else . end)' "$WORK/resource.json" > "$WORK/next.json"
        mv "$WORK/next.json" "$WORK/resource.json"
    done < <(jq -r '.spec | .. | objects | .image? // empty' "$WORK/resource.json" | sort -u)
    while IFS= read -r index; do
        reference=$(jq -c --argjson i "$index" '.spec.steps[$i].ref' "$WORK/resource.json")
        [[ $(jq -r '.resolver' <<< "$reference") == git ]] || { echo "ERROR: unsupported StepAction resolver in $file; add explicit support before releasing" >&2; exit 1; }
        params=$(jq '[.params[] | {key:.name,value:.value}] | from_entries' <<< "$reference")
        url=$(jq -er '.url' <<< "$params"); revision=$(jq -er '.revision' <<< "$params"); path=$(jq -er '.pathInRepo' <<< "$params")
        [[ "$url" == https://github.com/* && "$revision" != -* && "$path" != /* && "$path" != *..* ]] || exit 1
        [[ "$MODE" != --check || "$revision" =~ ^[a-f0-9]{40}$ ]] || { echo "ERROR: mutable StepAction revision" >&2; exit 1; }
        key="$url|$revision"
        if [[ -z "${revisions[$key]:-}" ]]; then
            repo=$(mktemp -d "$WORK/git.XXXXXX")
            git -C "$repo" init --bare -q
            git -C "$repo" fetch -q --depth=1 "$url" "$revision"
            revisions[$key]=$repo
        fi
        repo=${revisions[$key]}; commit=$(git -C "$repo" rev-parse FETCH_HEAD)
        git -C "$repo" show "$commit:$path" > "$WORK/action.yaml"
        [[ $(yq '.kind' "$WORK/action.yaml") == StepAction ]] || exit 1
        # External StepActions must already pin their runtime. Fix their source
        # if this fails; we do not silently create a fork of another project.
        runtime=$(yq '.spec.image' "$WORK/action.yaml")
        [[ "$runtime" =~ @sha256:[a-f0-9]{64}$ ]] || { echo "ERROR: pin the runtime image in $url/$path" >&2; exit 1; }
        jq --argjson i "$index" --arg commit "$commit" '(.spec.steps[$i].ref.params[] | select(.name == "revision").value) = $commit' "$WORK/resource.json" > "$WORK/next.json"
        mv "$WORK/next.json" "$WORK/resource.json"
        # Forward our existing ORAS_OPTIONS input to the archival StepAction.
        if [[ $(yq '[.spec.params[]? | select(.name == "orasOptions")] | length' "$WORK/action.yaml") == 1 ]] && jq -e 'any(.spec.params[]?; .name=="ORAS_OPTIONS")' "$WORK/resource.json" >/dev/null; then
            jq --argjson i "$index" 'if any(.spec.steps[$i].params[]?; .name=="orasOptions") then . else .spec.steps[$i].params += [{name:"orasOptions",value:"$(params.ORAS_OPTIONS)"}] end' "$WORK/resource.json" > "$WORK/next.json"
            mv "$WORK/next.json" "$WORK/resource.json"
        fi
    done < <(jq -r '.spec.steps // [] | to_entries[] | select(.value.ref) | .key' "$WORK/resource.json")
    if [[ "$MODE" == --check ]]; then
        yq -o=json "$file" | jq -S . > "$WORK/original.json"
        jq -S . "$WORK/resource.json" | cmp -s "$WORK/original.json" - || { echo "ERROR: unprepared references: $file" >&2; exit 1; }
    else
        yq -P '.' "$WORK/resource.json" > "$file"
    fi
done < <(find "$DIRECTORY" -name '*.yaml' -type f | sort)
