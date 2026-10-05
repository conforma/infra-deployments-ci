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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/images.json" <<'EOF'
{"policy":[
  {"image":"quay.io/example/first","digest":"sha256:aaaa"},
  {"image":"quay.io/example/second","digest":"sha256:bbbb"},
  {"image":"quay.io/example/third","digest":"sha256:cccc"}
]}
EOF

mkdir "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/go" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_GO_LOG"
if [[ -n "${MOCK_FAIL_IMAGE:-}" && "$*" == *"$MOCK_FAIL_IMAGE"* ]]; then
    echo "simulated policy rule failure" >&2
    exit 1
fi
EOF
chmod +x "$TEST_DIR/bin/go"

export MOCK_GO_LOG="$TEST_DIR/go.log"
export PATH="$TEST_DIR/bin:$PATH"

bash "$SCRIPT_DIR/check-release-lead-time.sh" "$TEST_DIR/images.json" > /dev/null
expected=$(cat <<'EOF'
run . -bundle -min-effective-lead-days 56 quay.io/example/first:konflux quay.io/example/first@sha256:aaaa
run . -bundle -min-effective-lead-days 56 quay.io/example/second:konflux quay.io/example/second@sha256:bbbb
run . -bundle -min-effective-lead-days 56 quay.io/example/third:konflux quay.io/example/third@sha256:cccc
EOF
)
if [[ "$(cat "$MOCK_GO_LOG")" != "$expected" ]]; then
    echo "ERROR: CI helper did not check every pinned policy image" >&2
    exit 1
fi

: > "$MOCK_GO_LOG"
export MOCK_FAIL_IMAGE="second@sha256:bbbb"
if bash "$SCRIPT_DIR/check-release-lead-time.sh" "$TEST_DIR/images.json" > /dev/null 2>&1; then
    echo "ERROR: CI helper ignored a policy rule failure" >&2
    exit 1
fi
if [[ $(wc -l < "$MOCK_GO_LOG") -ne 2 ]]; then
    echo "ERROR: CI helper continued after a policy rule failure" >&2
    exit 1
fi

: > "$MOCK_GO_LOG"
if bash "$SCRIPT_DIR/check-release-lead-time.sh" "$TEST_DIR/missing.json" > /dev/null 2>&1; then
    echo "ERROR: CI helper accepted a missing images.json" >&2
    exit 1
fi
printf '{"policy":[]}' > "$TEST_DIR/invalid.json"
if bash "$SCRIPT_DIR/check-release-lead-time.sh" "$TEST_DIR/invalid.json" > /dev/null 2>&1; then
    echo "ERROR: CI helper accepted an empty policy image list" >&2
    exit 1
fi
if [[ -s "$MOCK_GO_LOG" ]]; then
    echo "ERROR: CI helper checked images from invalid release metadata" >&2
    exit 1
fi

echo "Release lead-time CI helper tests passed"
