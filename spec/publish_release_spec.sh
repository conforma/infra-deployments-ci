Describe 'publish-release.sh'
  setup() {
    setup_tmpdir
    export REAL_GIT=$(command -v git)
    export PUBLISH_ROOT="$TMPDIR"
    export PUBLISH_MODE=''
    mkdir -p "$TMPDIR/hack" "$TMPDIR/state" "$TMPDIR/source/tasks/test/0.1" "$TMPDIR/candidate/tasks/test/0.1"
    cp hack/publish-release.sh hack/check-release-inputs.sh "$TMPDIR/hack/"
    printf 'baseline\n' > "$TMPDIR/source/tasks/test/0.1/test.yaml"
    printf 'exact candidate bytes\n\n' > "$TMPDIR/candidate/tasks/test/0.1/test.yaml"
    printf 'unrelated\n' > "$TMPDIR/source/README.md"
    "$REAL_GIT" init -q -b konflux "$TMPDIR/source"
    "$REAL_GIT" -C "$TMPDIR/source" add .
    "$REAL_GIT" -C "$TMPDIR/source" -c user.name=test -c user.email=test@example.com commit -qm baseline
    base=$("$REAL_GIT" -C "$TMPDIR/source" rev-parse HEAD)
    "$REAL_GIT" clone -q --bare "$TMPDIR/source" "$TMPDIR/remote.git"
    "$REAL_GIT" clone -q "$TMPDIR/remote.git" "$TMPDIR/catalog"
    "$REAL_GIT" -C "$TMPDIR/catalog" remote set-url origin https://github.com/conforma/tekton-catalog.git
    "$REAL_GIT" -C "$TMPDIR/catalog" config "url.$TMPDIR/remote.git.insteadOf" https://github.com/conforma/tekton-catalog.git
    jq --arg base "$base" '.catalog.baseCommit=$base' spec/fixtures/release.json > "$TMPDIR/images.json"
    cat > "$TMPDIR/hack/extract-bundle-resources.sh" <<'MOCK'
#!/usr/bin/env bash
mkdir -p "$2"
cp -R "$PUBLISH_ROOT/candidate/." "$2/"
MOCK
    cat > "$MOCK_BIN/crane" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == digest ]]
key=${2//\//_}; key=${key//:/_}
if [[ -f "$PUBLISH_ROOT/state/$key" ]]; then cat "$PUBLISH_ROOT/state/$key"; else printf 'sha256:%s\n' "$(printf 'b%.0s' {1..64})"; fi
MOCK
    cat > "$MOCK_BIN/skopeo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == copy && $2 == --all && $3 == --preserve-digests ]]
printf '%s\n' "$5" >> "$PUBLISH_ROOT/writes"
target=${5#docker://}; key=${target//\//_}; key=${key//:/_}
printf '%s\n' "${4##*@}" > "$PUBLISH_ROOT/state/$key"
MOCK
    cat > "$MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${3:-} == remote && ${4:-} == get-url ]]; then
  echo https://github.com/conforma/tekton-catalog.git
  exit 0
fi
if [[ ${3:-} == push && $PUBLISH_MODE == lost-ack && ! -f "$PUBLISH_ROOT/lost-ack" ]]; then
  "$REAL_GIT" "$@"
  touch "$PUBLISH_ROOT/lost-ack"
  exit 1
fi
exec "$REAL_GIT" "$@"
MOCK
    chmod +x "$TMPDIR/hack/"*.sh "$MOCK_BIN/"*
    export PATH="$MOCK_BIN:$PATH"
  }
  Before setup
  After cleanup_tmpdir

  publish_twice() {
    "$PUBLISH_ROOT/hack/publish-release.sh" "$PUBLISH_ROOT/images.json" "$PUBLISH_ROOT/catalog" >/dev/null 2>&1
    first=$(git -C "$PUBLISH_ROOT/catalog" rev-parse HEAD)
    "$PUBLISH_ROOT/hack/publish-release.sh" "$PUBLISH_ROOT/images.json" "$PUBLISH_ROOT/catalog" >/dev/null 2>&1
    [[ $(wc -l < "$PUBLISH_ROOT/writes") -eq 8 ]]
    [[ $(git -C "$PUBLISH_ROOT/catalog" rev-parse HEAD) == "$first" ]]
    cmp "$PUBLISH_ROOT/candidate/tasks/test/0.1/test.yaml" "$PUBLISH_ROOT/catalog/tasks/test/0.1/test.yaml"
    [[ $(cat "$PUBLISH_ROOT/catalog/README.md") == unrelated ]]
  }
  It 'publishes exact bytes, preserves unrelated files and skips completed writes on retry'
    When run publish_twice
    The status should be success
  End
  It 'recovers after the catalog accepted a push but the client lost its acknowledgement'
    export PUBLISH_MODE=lost-ack
    When run publish_twice
    The status should be success
    The path "$TMPDIR/lost-ack" should be file
  End
  It 'checks every tag before any write'
    printf 'sha256:%s\n' "$(printf 'c%.0s' {1..64})" > "$TMPDIR/state/quay.io_conforma_tekton-task_konflux"
    When run script "$TMPDIR/hack/publish-release.sh" "$TMPDIR/images.json" "$TMPDIR/catalog"
    The status should be failure
    The stderr should include 'release is stale'
    The path "$TMPDIR/writes" should not be exist
  End
  It 'rejects catalog conflicts before promoting tags'
    printf 'independent edit\n' > "$TMPDIR/source/tasks/test/0.1/test.yaml"
    git -C "$TMPDIR/source" add .
    git -C "$TMPDIR/source" -c user.name=test -c user.email=test@example.com commit -qm conflict
    git -C "$TMPDIR/source" push -q "$TMPDIR/remote.git" konflux
    When run script "$TMPDIR/hack/publish-release.sh" "$TMPDIR/images.json" "$TMPDIR/catalog"
    The status should be failure
    The stderr should include 'catalog changed independently'
    The path "$TMPDIR/writes" should not be exist
  End
End
