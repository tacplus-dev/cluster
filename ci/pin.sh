#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The GitLab project's .gitlab-ci.yml is ci/gitlab-project.gitlab-ci.yml with CLUSTER_COMMIT set to the commit of
# this repository it renders and applies, and nothing else changed (README, How a change reaches the cluster).
#
#   ci/pin.sh COMMIT         # prints it, from this checkout, for COMMIT (40 hex): commit it to the GitLab project
#   ci/pin.sh --check FILE   # FILE is that, for the CLUSTER_COMMIT it names (the render job, on the project's copy)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$here/gitlab-project.gitlab-ci.yml
die() { echo "pin.sh: $*" >&2; exit 1; }
blank='  CLUSTER_COMMIT: ""'
[ "$(grep -cxF "$blank" "$src")" = 1 ] || die "$src has no line [$blank]"

pinned() { # pinned COMMIT: the file for COMMIT
  [[ $1 =~ ^[0-9a-f]{40}$ ]] || die "[$1] is not a full commit hash"
  sed "s/^  CLUSTER_COMMIT: \"\"\$/  CLUSTER_COMMIT: \"$1\"/" "$src"
}

if [ "${1:-}" = --check ]; then
  file=${2:?usage: ci/pin.sh --check FILE}
  commit=$(sed -n 's/^  CLUSTER_COMMIT: "\([0-9a-f]*\)"$/\1/p' "$file")
  [ -n "$commit" ] || die "$file sets no CLUSTER_COMMIT: make it with ci/pin.sh COMMIT"
  diff -u <(pinned "$commit") "$file" >&2 ||
    die "$file is not ci/gitlab-project.gitlab-ci.yml of $commit with CLUSTER_COMMIT set: make it with ci/pin.sh $commit"
  echo "pin.sh: the project's .gitlab-ci.yml is this repository's, pinned to $commit"
else
  pinned "${1:?usage: ci/pin.sh COMMIT | --check FILE}"
fi
