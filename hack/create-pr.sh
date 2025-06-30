#!/usr/bin/env bash
# Copyright 2022 Red Hat, Inc.
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

# Creates a pull request with updates from a local directory to the designated
# remote repository.
# Usage:
#   create-pr.sh <REMOTE_GIT> <LOCAL_PATH> [<PR_REMOTE>]

set -o errexit
set -o pipefail

if [ -z "${1}" ] || [ -z "${2}" ]; then
  echo "Usage $0 <REMOTE_GIT> <LOCAL_PATH> [<PR_REMOTE>]

Example:
$0 git@github.com:conforma/infra-deployments.git local-infra-deployments origin"
  exit 1
fi

set -o nounset

# The git repository where the local changes will be pushed to.
REMOTE="${1}"
# Local git directory with the changed files
LOCAL="${2}"
# The name of the git remote to create the PR against.
PR_REMOTE="${3-origin}"

cd "${LOCAL}" || exit 1

# Setup key for access in the GH workflow
if [ -n "${APP_INSTALL_ID:-}" ]; then
  git config --global user.email "${APP_INSTALL_ID}-ec-automation[bot]@users.noreply.github.com"
  git config --global user.name "ec-automation[bot]"
  git config --global commit.gpgsign true
  git config --global gpg.format ssh
  mkdir -p "${HOME}/.ssh"
  echo "${DEPLOY_KEY}" > "${HOME}/.ssh/id_ed25519"
  chmod 600 "${HOME}/.ssh/id_ed25519"
  ssh-keygen -y -f "${HOME}/.ssh/id_ed25519" >"${HOME}/.ssh/id_ed25519.pub"
  git config --global user.signingKey "${HOME}/.ssh/id_ed25519.pub"
  trap 'rm -rf "${HOME}/.ssh/id_ed25519"' EXIT
  export GITHUB_USER="$GITHUB_ACTOR"
fi

git remote add ec "${REMOTE}"
# Shallow clones prevent pushing to the remote in some cases.
git fetch ec --unshallow

# Create the branch
BRANCH_NAME=ec-batch-update
git checkout -b ${BRANCH_NAME} --track "${PR_REMOTE}/main"

# commit & push
git commit -a -m "enterprise contract update"
git push --force -u ec ${BRANCH_NAME}

# create pull request, don't fail if it already exists
gh pr create --fill --no-maintainer-edit --repo "$(git remote get-url --push "${PR_REMOTE}")" || true
