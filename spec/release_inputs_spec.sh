Describe 'Release inputs'
  Before setup_tmpdir
  After cleanup_tmpdir

  It 'requires all publication baselines'
    jq '.baseline.images |= .[:-1]' spec/fixtures/release.json > "$TMPDIR/images.json"
    When run script ./hack/check-release-inputs.sh "$TMPDIR/images.json"
    The status should be failure
    The stderr should include 'invalid release manifest'
  End

  It 'rejects additional publication destinations'
    jq '.components[0].mirrors=["quay.io/conforma/unexpected"] | .baseline.images += [{reference:"quay.io/conforma/unexpected:konflux",digest:.components[0].digest}]' spec/fixtures/release.json > "$TMPDIR/images.json"
    When run script ./hack/check-release-inputs.sh "$TMPDIR/images.json"
    The status should be failure
    The stderr should include 'invalid release manifest'
  End

  It 'accepts a completed manifest'
    When run script ./hack/check-release-inputs.sh spec/fixtures/release.json
    The status should be success
  End

  pin_twice() {
    mkdir -p "$TMPDIR/catalog"
    cat > "$MOCK_BIN/crane" <<'CRANE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PIN_LOG"
printf 'sha256:%064d\n' 2
CRANE
    chmod +x "$MOCK_BIN/crane"
    export PATH="$MOCK_BIN:$PATH" PIN_LOG="$TMPDIR/calls"
    cat > "$TMPDIR/catalog/task.yaml" <<'TASK'
kind: Task
spec:
  steps:
  - image: quay.io/conforma/cli:latest
  - image: quay.io/example/runtime:latest
  - image: quay.io/example/runtime:latest
TASK
    cli="quay.io/conforma/cli@sha256:$(printf '%064d' 1)"
    bash hack/pin-task-inputs.sh "$TMPDIR/catalog" "$cli"
    bash hack/pin-task-inputs.sh "$TMPDIR/catalog" "$cli" --check
    test "$(wc -l < "$PIN_LOG")" -eq 1
  }
  It 'resolves repeated source tags once and only checks pins afterward'
    When call pin_twice
    The status should be success
  End
End
