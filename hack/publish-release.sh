#!/usr/bin/env bash
# Copyright The Conforma Contributors
# SPDX-License-Identifier: Apache-2.0
# Run only after acceptance, with its committed manifest and a clean catalog checkout.
set -euo pipefail
MANIFEST=${1:?Usage: publish-release.sh images.json catalog-checkout}
CATALOG=${2:?Catalog checkout required}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$SCRIPT_DIR/check-release-inputs.sh" "$MANIFEST"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
bundle=$(jq -r '.components[] | select(.image == "quay.io/conforma/tekton-task") | .image+"@"+.digest' "$MANIFEST")
"$SCRIPT_DIR/extract-bundle-resources.sh" "$bundle" "$WORK/candidate" task tasks
"$SCRIPT_DIR/extract-bundle-resources.sh" "$bundle" "$WORK/candidate" stepaction stepactions
base=$(jq -r '.catalog.baseCommit' "$MANIFEST")
[[ -z $(git -C "$CATALOG" status --porcelain) ]] || { echo 'ERROR: catalog checkout must be clean' >&2; exit 1; }
[[ $(git -C "$CATALOG" remote get-url origin) =~ ^https://github.com/conforma/tekton-catalog(.git)?$ ]] || exit 1
git -C "$CATALOG" fetch origin "$base"
jq -r '(.policy + .components)[] | . as $candidate | (.image, .mirrors[]?) | [.+":konflux",$candidate.image+"@"+$candidate.digest] | @tsv' "$MANIFEST" > "$WORK/tags"
check_tag() {
    local target=$1 candidate=$2 baseline current
    baseline=$(jq -er --arg target "$target" '.baseline.images[] | select(.reference==$target) | .digest' "$MANIFEST")
    current=$(crane digest "$target")
    [[ "$current" == "${candidate##*@}" || "$current" == "$baseline" ]] || { echo "ERROR: release is stale: $target" >&2; exit 1; }
    TAG_CURRENT=$current
}
# A missing path is a valid baseline for a new file; read errors are not.
read_file() {
    local commit=$1 path=$2 output=$3 metadata
    rm -f "$output"
    metadata=$(git -C "$CATALOG" ls-tree "$commit" -- "$path")
    if [[ -n "$metadata" ]]; then
        [[ "$metadata" == '100644 blob '* ]] || { echo "ERROR: not a regular catalog file: $path" >&2; exit 1; }
        git -C "$CATALOG" show "$commit:$path" > "$output"
    fi
}
check_catalog() {
    git -C "$CATALOG" fetch origin refs/heads/konflux
    head=$(git -C "$CATALOG" rev-parse FETCH_HEAD)
    : > "$WORK/pending"
    while IFS= read -r file; do
        path=${file#"$WORK/candidate/"}
        read_file "$head" "$path" "$WORK/current"
        if [[ -f "$WORK/current" ]] && cmp -s "$file" "$WORK/current"; then continue; fi
        read_file "$base" "$path" "$WORK/baseline"
        if [[ ! -e "$WORK/current" && ! -e "$WORK/baseline" ]] || cmp -s "$WORK/current" "$WORK/baseline"; then
            printf '%s\n' "$path" >> "$WORK/pending"
        else
            echo "ERROR: catalog changed independently: $path" >&2; exit 1
        fi
    done < <(find "$WORK/candidate" -name '*.yaml' -type f | sort)
}
# Preflight every destination before changing any release tag or catalog file.
check_catalog
while IFS=$'\t' read -r target candidate; do check_tag "$target" "$candidate"; done < "$WORK/tags"
while IFS=$'\t' read -r target candidate; do
    check_tag "$target" "$candidate"
    if [[ "$TAG_CURRENT" != "${candidate##*@}" ]]; then
        skopeo copy --all --preserve-digests "docker://$candidate" "docker://$target"
    fi
    [[ $(crane digest "$target") == "${candidate##*@}" ]] || exit 1
done < "$WORK/tags"
for attempt in 1 2 3; do
    check_catalog
    [[ -s "$WORK/pending" ]] || break
    git -C "$CATALOG" checkout --detach "$head"
    while IFS= read -r path; do
        parent=$(dirname "$path")
        while [[ "$parent" != . ]]; do [[ ! -L "$CATALOG/$parent" ]] || exit 1; parent=$(dirname "$parent"); done
        mkdir -p "$CATALOG/$(dirname "$path")"
        cp "$WORK/candidate/$path" "$CATALOG/$path"
        git -C "$CATALOG" add -- "$path"
    done < "$WORK/pending"
    git -C "$CATALOG" -c user.name='github-actions[bot]' -c user.email='github-actions[bot]@users.noreply.github.com' commit -m 'Publish tested Conforma definitions'
    # On rejection or a lost acknowledgement, re-read contents before retrying.
    git -C "$CATALOG" push origin HEAD:refs/heads/konflux || continue
done
check_catalog
[[ ! -s "$WORK/pending" ]] || { echo 'ERROR: catalog update incomplete; retry this release' >&2; exit 1; }
while IFS=$'\t' read -r target candidate; do
    [[ $(crane digest "$target") == "${candidate##*@}" ]] || exit 1
    printf '%s %s\n' "$target" "${candidate##*@}"
done < "$WORK/tags"
printf 'Catalog commit: %s\n' "$head"
