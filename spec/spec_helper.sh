set -euo pipefail

# Create a temporary directory for each test group and clean up after.
setup_tmpdir() {
  TMPDIR=$(mktemp -d)
  MOCK_BIN="${TMPDIR}/bin"
  mkdir -p "$MOCK_BIN"
}

cleanup_tmpdir() {
  rm -rf "$TMPDIR"
}

# Create a mock crane script that dispatches on subcommand.
# Uses files in $TMPDIR/crane/ to store mock data:
#   manifest.json        — returned by "crane manifest"
#   blobs/<digest>.tar.gz — returned by "crane blob repo@<digest>"
#   digest.txt           — returned by "crane digest"
create_mock_crane() {
  mkdir -p "${TMPDIR}/crane/blobs"
  cat > "${MOCK_BIN}/crane" <<'CRANE_EOF'
#!/usr/bin/env bash
set -euo pipefail
CRANE_DATA="${CRANE_DATA:?CRANE_DATA not set}"
case "${1:-}" in
  manifest)
    cat "${CRANE_DATA}/manifest.json"
    ;;
  blob)
    ref="$2"
    digest="${ref#*@}"
    cat "${CRANE_DATA}/blobs/${digest}.tar.gz"
    ;;
  digest)
    cat "${CRANE_DATA}/digest.txt"
    ;;
  auth)
    exit 0
    ;;
  *)
    echo "mock crane: unknown subcommand: $1" >&2
    exit 1
    ;;
esac
CRANE_EOF
  chmod +x "${MOCK_BIN}/crane"
}

# Create a gzipped tar blob containing a single YAML file.
# Usage: create_blob <digest> <yaml-content>
create_blob() {
  local digest="$1"
  local yaml="$2"
  local blob_dir="${TMPDIR}/crane/blobs"
  local staging="${TMPDIR}/blob-staging"

  mkdir -p "$blob_dir" "$staging"
  printf '%s' "$yaml" > "${staging}/task.yaml"
  tar -cf - -C "$staging" task.yaml | gzip > "${blob_dir}/${digest}.tar.gz"
  rm -rf "$staging"
}
