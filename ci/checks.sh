#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The repository's tests, every tests/*_test.sh: the validate job's tests and the local gate. Need bash, git, jq,
# yq (ci/tools.sh builds it into bin/), openssl, sha256sum.
#
#   ci/checks.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH
failed=0
for t in "$here"/tests/*_test.sh; do
  echo "== ${t#"$here"/}"
  "$t" || failed=1
done
[ "$failed" = 0 ] && echo "all checks passed" || { echo "checks failed"; exit 1; }
