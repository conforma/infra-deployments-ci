Describe "update-policy-digest.sh"
  SCRIPT="./hack/update-policy-digest.sh"
  MOCK_NEW_DIGEST="sha256:newdigestnewdigestnewdigestnewdigestnewdigestnewdigestnewdigest00"

  setup() {
    setup_tmpdir
    create_mock_crane
    echo "$MOCK_NEW_DIGEST" > "${TMPDIR}/crane/digest.txt"
    export CRANE_DATA="${TMPDIR}/crane"
    export PATH="${MOCK_BIN}:${PATH}"
  }

  cleanup() {
    cleanup_tmpdir
  }

  Before "setup"
  After "cleanup"

  create_task_yaml() {
    local dir="$1"
    local name="$2"
    local digest="$3"
    mkdir -p "$dir"
    cat > "${dir}/${name}.yaml" <<EOF
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: ${name}
spec:
  params:
  - name: POLICY_BUNDLE_DIGEST
    default: "${digest}"
  - name: OTHER_PARAM
    default: unchanged
EOF
  }

  Describe "updates digest in task files"
    setup_tasks() {
      create_task_yaml "${TMPDIR}/tasks/verify-ec/0.1" "verify-ec" "sha256:oldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldold0"
    }

    Before "setup_tasks"

    It "replaces the old digest with the new one"
      When run script "$SCRIPT" "${TMPDIR}/tasks"
      The status should be success
      The output should include "Updated"
      The output should include "Updated 1 file(s)"
      The contents of file "${TMPDIR}/tasks/verify-ec/0.1/verify-ec.yaml" should include "$MOCK_NEW_DIGEST"
    End

    It "does not modify other params"
      When run script "$SCRIPT" "${TMPDIR}/tasks"
      The status should be success
      The output should include "Updated 1 file(s)"
      The contents of file "${TMPDIR}/tasks/verify-ec/0.1/verify-ec.yaml" should include "unchanged"
    End
  End

  Describe "updates multiple task files"
    setup_multi() {
      create_task_yaml "${TMPDIR}/tasks/task-a/0.1" "task-a" "sha256:oldaoldaoldaoldaoldaoldaoldaoldaoldaoldaoldaoldaoldaoldaoldaolda"
      create_task_yaml "${TMPDIR}/tasks/task-b/0.1" "task-b" "sha256:oldboldboldboldboldboldboldboldboldboldboldboldboldboldboldbold0"
    }

    Before "setup_multi"

    It "updates all files that contain POLICY_BUNDLE_DIGEST"
      When run script "$SCRIPT" "${TMPDIR}/tasks"
      The status should be success
      The output should include "Updated 2 file(s)"
      The contents of file "${TMPDIR}/tasks/task-a/0.1/task-a.yaml" should include "$MOCK_NEW_DIGEST"
      The contents of file "${TMPDIR}/tasks/task-b/0.1/task-b.yaml" should include "$MOCK_NEW_DIGEST"
    End
  End

  Describe "idempotent when already up to date"
    setup_current() {
      create_task_yaml "${TMPDIR}/tasks/verify-ec/0.1" "verify-ec" "$MOCK_NEW_DIGEST"
    }

    Before "setup_current"

    It "reports already up to date"
      When run script "$SCRIPT" "${TMPDIR}/tasks"
      The status should be success
      The output should include "Already up to date"
      The output should include "Updated 0 file(s)"
    End
  End

  Describe "skips files without extractable digest"
    setup_no_param() {
      local dir="${TMPDIR}/tasks/odd-task/0.1"
      mkdir -p "$dir"
      # File contains POLICY_BUNDLE_DIGEST as text but not as a yq-extractable param
      cat > "${dir}/odd-task.yaml" <<'EOF'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: odd-task
spec:
  steps:
  - name: run
    script: echo POLICY_BUNDLE_DIGEST
EOF
    }

    Before "setup_no_param"

    It "warns and skips"
      When run script "$SCRIPT" "${TMPDIR}/tasks"
      The status should be success
      The output should include "Warning: could not extract current digest"
      The output should include "Updated 0 file(s)"
    End
  End

  Describe "custom policy image"
    setup_custom() {
      create_task_yaml "${TMPDIR}/tasks/verify-ec/0.1" "verify-ec" "sha256:oldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldold0"
    }

    Before "setup_custom"

    It "accepts a custom policy image reference"
      When run script "$SCRIPT" "${TMPDIR}/tasks" "quay.io/custom/policy:v1"
      The status should be success
      The output should include "Updated 1 file(s)"
    End
  End

  Describe "error cases"
    It "fails when no arguments provided"
      When run script "$SCRIPT"
      The status should be failure
      The stderr should include "Usage"
    End

    It "fails when no task files contain POLICY_BUNDLE_DIGEST"
      local dir="${TMPDIR}/tasks/no-digest/0.1"
      mkdir -p "$dir"
      cat > "${dir}/no-digest.yaml" <<'EOF'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: no-digest
spec:
  params:
  - name: SOME_OTHER_PARAM
    default: value
EOF
      When run script "$SCRIPT" "${TMPDIR}/tasks"
      The status should be failure
      The output should include "No task files contain POLICY_BUNDLE_DIGEST"
    End
  End
End
