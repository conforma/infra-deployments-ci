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

# Compare current :konflux policy behavior with the candidate CLI and policy
# recorded in a release images.json file.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

TARGETS_FILE="${SCRIPT_DIR}/targets.json"
POLICY_TEMPLATE="${SCRIPT_DIR}/golden-policy.yaml"
REPORT_FILE="-"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
EFFECTIVE_TIME="${POLICY_BEHAVIOR_EFFECTIVE_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-}"
REGISTRY_AUTH_DEST="${REGISTRY_AUTH_DEST:-/root/.docker/config.json}"

PUBLIC_KEY_FILE="${REPO_ROOT}/acceptance/pub.key"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [options] <candidate-images.json>

Compare current and candidate policy behavior for the targets in targets.json.

Arguments:
  candidate-images.json  Generated release images.json containing CLI and policy digests

Options:
  --targets FILE             Target definitions (default: ${TARGETS_FILE})
  --policy-template FILE     EnterpriseContractPolicy template (default: ${POLICY_TEMPLATE})
  --report FILE              Write the Markdown report to FILE (default: stdout)
  --container-engine CMD     Container engine (default: \$CONTAINER_ENGINE or docker)
  --effective-time TIME      Shared RFC3339 policy effective time (default: now)
  -h, --help                Show this help
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets)
            [[ $# -ge 2 ]] || die "--targets requires a file path"
            TARGETS_FILE="$2"
            shift 2
            ;;
        --policy-template)
            [[ $# -ge 2 ]] || die "--policy-template requires a file path"
            POLICY_TEMPLATE="$2"
            shift 2
            ;;
        --report)
            [[ $# -ge 2 ]] || die "--report requires a file path"
            REPORT_FILE="$2"
            shift 2
            ;;
        --container-engine)
            [[ $# -ge 2 ]] || die "--container-engine requires a command"
            CONTAINER_ENGINE="$2"
            shift 2
            ;;
        --effective-time)
            [[ $# -ge 2 ]] || die "--effective-time requires a timestamp"
            EFFECTIVE_TIME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -* )
            die "Unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

[[ $# -eq 1 ]] || { usage >&2; die "Provide the candidate images.json file"; }
CANDIDATE_IMAGES_FILE="$1"

[[ -f "$CANDIDATE_IMAGES_FILE" ]] || die "Candidate images.json does not exist: ${CANDIDATE_IMAGES_FILE}"
[[ -f "$TARGETS_FILE" ]] || die "Target definitions do not exist: ${TARGETS_FILE}"
[[ -f "$POLICY_TEMPLATE" ]] || die "Policy template does not exist: ${POLICY_TEMPLATE}"
[[ -f "$PUBLIC_KEY_FILE" ]] || die "Public key does not exist: ${PUBLIC_KEY_FILE}"

for command in jq yq crane "$CONTAINER_ENGINE"; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: ${command}"
done

if ! jq -e 'type == "object" and (.policy | type == "array") and (.components | type == "array")' \
    "$CANDIDATE_IMAGES_FILE" >/dev/null 2>&1; then
    die "Candidate images.json is invalid or is missing policy/components arrays: ${CANDIDATE_IMAGES_FILE}"
fi

if ! jq -e '
    (.targets | type == "array" and length == 2) and
    all(.targets[];
        (.name | type == "string" and length > 0) and
        (.displayName | type == "string" and length > 0) and
        (.image | type == "string" and length > 0) and
        (.collection | type == "string" and length > 0))
' "$TARGETS_FILE" >/dev/null 2>&1; then
    die "Target definitions must contain exactly two complete targets: ${TARGETS_FILE}"
fi

if ! yq -e '
    .apiVersion == "appstudio.redhat.com/v1alpha1" and
    .kind == "EnterpriseContractPolicy" and
    (.spec.sources | type == "!!seq" and length > 0) and
    (.spec.sources[0].policy | type == "!!seq" and length > 0) and
    (.spec.sources[0].config.include | type == "!!seq" and length > 0)
' "$POLICY_TEMPLATE" >/dev/null 2>&1; then
    die "Policy template is not a valid EnterpriseContractPolicy with a policy and include collection: ${POLICY_TEMPLATE}"
fi

if [[ -n "$REGISTRY_AUTH_FILE" && ! -f "$REGISTRY_AUTH_FILE" ]]; then
    die "Registry auth file does not exist: ${REGISTRY_AUTH_FILE}"
fi

image_ref() {
    local images_file="$1"
    local section="$2"
    local image="$3"
    local description="$4"
    local count
    local digest

    if ! count=$(jq --arg section "$section" --arg image "$image" \
        '[.[$section][] | select(.image == $image)] | length' "$images_file"); then
        die "Could not read ${description} entry from ${images_file}"
    fi
    [[ "$count" -eq 1 ]] || die "${images_file} must contain exactly one ${description} entry for ${image}"

    if ! digest=$(jq -er --arg section "$section" --arg image "$image" \
        '.[$section][] | select(.image == $image) | .digest' "$images_file"); then
        die "${description} entry for ${image} is missing a digest in ${images_file}"
    fi
    [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || \
        die "${description} digest is not a valid sha256 digest for ${image}: ${digest}"

    printf '%s@%s\n' "$image" "$digest"
}

resolve_digest() {
    local image="$1"
    local digest

    if ! digest=$(crane digest "$image" 2>/dev/null); then
        die "Failed to resolve image digest: ${image}"
    fi
    [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || \
        die "crane returned an invalid digest for ${image}: ${digest}"
    printf '%s\n' "$digest"
}

image_repository() {
    local image="$1"
    image="${image%@*}"
    printf '%s\n' "${image%:*}"
}

render_policy() {
    local policy_ref="$1"
    local collection="$2"
    local output_file="$3"

    POLICY_BEHAVIOR_POLICY_REF="oci::${policy_ref}" \
        POLICY_BEHAVIOR_COLLECTION="$collection" \
        yq '
            .spec.sources[0].policy = [strenv(POLICY_BEHAVIOR_POLICY_REF)] |
            .spec.sources[0].config.include = [strenv(POLICY_BEHAVIOR_COLLECTION)]
        ' "$POLICY_TEMPLATE" > "$output_file"
}

validate_report_shape() {
    local report_file="$1"
    local description="$2"

    if ! jq -e '
        (.components | type == "array") and
        all(.components[];
            ((.violations // []) | type == "array") and
            ((.warnings // []) | type == "array")) and
        all([.components[] | ((.violations // []) + (.warnings // []))[]][];
            if ((.metadata? | type) == "object" and
                ((.metadata.code? // "") | type == "string") and
                ((.metadata.code? // "") | length > 0)) then
                true
            else
                ((.msg? // .message? // "") | type == "string" and length > 0)
            end)
    ' "$report_file" >/dev/null 2>&1; then
        echo "ERROR: ${description} produced a malformed JSON report; expected a components array with violations/warnings" >&2
        return 1
    fi
}

normalize_report() {
    local report_file="$1"
    local normalized_file="$2"

    jq '
        def normalized($kind):
            [.components[] | ((.[$kind] // [])[]) |
                (.metadata.code? // "") as $code |
                (.msg? // .message? // "") as $message |
                if ($code | type) == "string" and ($code | length) > 0 then
                    {id: ("code:" + $code), label: $code}
                else
                    {id: ("message:" + $message), label: $message}
                end
            ] | sort_by(.id, .label) | unique_by(.id);

        {violations: normalized("violations"), warnings: normalized("warnings")}
    ' "$report_file" > "$normalized_file"
}

run_validation() {
    local target_name="$1"
    local target_ref="$2"
    local cli_ref="$3"
    local policy_ref="$4"
    local collection="$5"
    local output_file="$6"
    local stderr_file="${output_file}.stderr"
    local policy_file="${output_file%.json}-policy.yaml"
    local -a container_args

    render_policy "$policy_ref" "$collection" "$policy_file"
    container_args=(
        run --rm
        --volume "${PUBLIC_KEY_FILE}:/workspace/pub.key:ro"
        --volume "${policy_file}:/workspace/golden-policy.yaml:ro"
    )
    if [[ -n "$REGISTRY_AUTH_FILE" ]]; then
        container_args+=(--volume "${REGISTRY_AUTH_FILE}:${REGISTRY_AUTH_DEST}:ro")
    fi
    container_args+=(
        "$cli_ref"
        validate image
        --image "$target_ref"
        --policy /workspace/golden-policy.yaml
        --public-key /workspace/pub.key
        --ignore-rekor
        --strict=false
        --show-warnings
        --info
        --effective-time "$EFFECTIVE_TIME"
        --allow-past-effective-time
        --timeout 30m
        --output json
    )

    echo "Running ${target_name} with ${cli_ref} and ${policy_ref}" >&2
    if ! "$CONTAINER_ENGINE" "${container_args[@]}" > "$output_file" 2> "$stderr_file"; then
        echo "ERROR: validation command failed for ${target_name} with ${cli_ref}" >&2
        if [[ -s "$stderr_file" ]]; then
            sed 's/^/  /' "$stderr_file" >&2
        fi
        return 1
    fi
    validate_report_shape "$output_file" "${target_name} validation"
}

diff_results() {
    local before_file="$1"
    local after_file="$2"

    jq -cn --slurpfile before "$before_file" --slurpfile after "$after_file" '
        def delta($new; $old):
            [$new[] | . as $item |
                select(($old | map(.id) | index($item.id)) == null)] |
            sort_by(.id) | unique_by(.id);

        ($before[0].violations) as $before_violations |
        ($after[0].violations) as $after_violations |
        ($before[0].warnings) as $before_warnings |
        ($after[0].warnings) as $after_warnings |
        {
            addedViolations: delta($after_violations; $before_violations),
            removedViolations: delta($before_violations; $after_violations),
            addedWarnings: delta($after_warnings; $before_warnings),
            removedWarnings: delta($before_warnings; $after_warnings)
        }
    '
}

render_labels() {
    local results="$1"
    jq -r 'if length == 0 then "—" else map("`" + .label + "`") | join("<br>") end' <<< "$results"
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

current_cli_ref="quay.io/conforma/cli:konflux"
candidate_cli_ref=$(image_ref "$CANDIDATE_IMAGES_FILE" components quay.io/conforma/cli "candidate CLI")
current_policy_ref="quay.io/conforma/release-policy:konflux"
candidate_policy_ref=$(image_ref "$CANDIDATE_IMAGES_FILE" policy quay.io/conforma/release-policy "candidate release policy")
policy_data=$(yq -o=json -I=0 '.spec.sources[0].data' "$POLICY_TEMPLATE")

report_file="${WORK_DIR}/policy-behavior.md"
{
    echo "## Policy Behavior Changes"
    echo
    echo "- Current CLI: \`${current_cli_ref}\`"
    echo "- Candidate CLI: \`${candidate_cli_ref}\`"
    echo "- Current policy: \`oci::${current_policy_ref}\`"
    echo "- Candidate policy: \`oci::${candidate_policy_ref}\`"
    echo "- Effective time: \`${EFFECTIVE_TIME}\`"
    echo "- Policy template: \`${POLICY_TEMPLATE#${REPO_ROOT}/}\`"
    echo "- Policy data: \`${policy_data}\`"
    echo
} > "$report_file"

while IFS= read -r target_json; do
    target_name=$(jq -r '.name' <<< "$target_json")
    display_name=$(jq -r '.displayName' <<< "$target_json")
    target_image=$(jq -r '.image' <<< "$target_json")
    collection=$(jq -r '.collection' <<< "$target_json")
    target_digest=$(resolve_digest "$target_image")
    target_ref="$(image_repository "$target_image")@${target_digest}"

    safe_name=$(printf '%s' "$target_name" | tr -cs '[:alnum:]_.-' '_')
    current_report="${WORK_DIR}/${safe_name}-current.json"
    candidate_report="${WORK_DIR}/${safe_name}-candidate.json"
    current_normalized="${WORK_DIR}/${safe_name}-current-normalized.json"
    candidate_normalized="${WORK_DIR}/${safe_name}-candidate-normalized.json"

    run_validation "$display_name" "$target_ref" "$current_cli_ref" "$current_policy_ref" \
        "$collection" "$current_report"
    run_validation "$display_name" "$target_ref" "$candidate_cli_ref" "$candidate_policy_ref" \
        "$collection" "$candidate_report"

    normalize_report "$current_report" "$current_normalized"
    normalize_report "$candidate_report" "$candidate_normalized"
    changes=$(diff_results "$current_normalized" "$candidate_normalized")

    {
        echo "### ${display_name}"
        echo
        echo "- Target image: \`${target_ref}\`"
        echo "- Policy collection: \`${collection}\`"
        echo
        if jq -e 'to_entries | all(.[]; (.value | length == 0))' <<< "$changes" >/dev/null; then
            echo "No behavior changes."
        else
            echo '| Change | Rules |'
            echo '|---|---|'
            for field in addedViolations removedViolations addedWarnings removedWarnings; do
                case "$field" in
                    addedViolations) label="Added violations" ;;
                    removedViolations) label="Removed violations" ;;
                    addedWarnings) label="Added warnings" ;;
                    removedWarnings) label="Removed warnings" ;;
                esac
                values=$(jq -c --arg field "$field" '.[$field]' <<< "$changes")
                echo "| ${label} | $(render_labels "$values") |"
            done
        fi
        echo
    } >> "$report_file"
done < <(jq -c '.targets[]' "$TARGETS_FILE")

if [[ "$REPORT_FILE" == "-" ]]; then
    cat "$report_file"
else
    mkdir -p "$(dirname "$REPORT_FILE")"
    cp "$report_file" "$REPORT_FILE"
    cat "$report_file"
fi
