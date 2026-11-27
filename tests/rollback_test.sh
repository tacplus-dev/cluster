#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/rollback.sh (#37), the way back that needs no in-cluster runner, against a copy of this tree committed to a
# repository of its own (CLUSTER_REPO), the stub cluster (tests/stub/kubectl) and Secret Manager (tests/stub/gcloud),
# the commit's ci/tools.sh a no-op (the tools are on the PATH):
#
#   - it refuses a commit that is not a full hash, and one the repository does not have;
#   - it applies the commit's render as the pipeline does: the four files server-side, the runners' tokens into their
#     Secrets, the runners' rollouts waited for, and says to re-pin the GitLab project to it;
#   - without cluster-admin on dev it fails, saying so, and applies nothing.
#
# Needs bash, git, yq, jq, helm.
#
#   tests/rollback_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
export PATH=$here/tests/stub:$work/bin:$PATH KSTUB=$work/k SMSTUB=$work/sm
mkdir -p "$KSTUB" "$work/bin"
printf '#!/bin/sh\n' > "$work/bin/gke-gcloud-auth-plugin" && chmod +x "$work/bin/gke-gcloud-auth-plugin"
for f in "$here"/gitlab-runner/runners/*.yaml; do
  r=$(basename "$f" .yaml)
  ref=$(yq '.tacplus.token' "$f")
  mkdir -p "$SMSTUB/$(dirname "${ref#projects/}" | sed 's|/secrets/|/|; s|/versions$||')"
  printf 'glrt-stub%s_t0ken\n' "$r" > "$SMSTUB/$(echo "${ref#projects/}" | sed 's|/secrets/|/|; s|/versions/|/|')"
done
echo gke_tacplus-dev_us-central1-a_dev > "$KSTUB/context"
echo yes > "$KSTUB/grant"

# This tree, as it is (without its render, its tools or its history), committed to a repository of its own.
repo=$work/repo
mkdir -p "$repo"
(cd "$here" && tar -c --exclude=./out --exclude=./bin --exclude=./.git .) | tar -x -C "$repo"
printf '#!/bin/sh\n' > "$repo/ci/tools.sh"
git -C "$repo" init -q && git -C "$repo" add -A &&
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -q -m good
commit=$(git -C "$repo" rev-parse HEAD)
export CLUSTER_REPO=$repo

run() { # run LOG CMD...: CMD's output in $work/LOG; its status returned.
  local log=$1; shift
  "$@" > "$work/$log" 2>&1
}

run rb "$here/ci/rollback.sh" 8762d36 && fail "a short hash was taken" ||
  { grep -q 'rollback: \[8762d36\] is not a full commit hash' "$work/rb" && ok "a short hash is refused" || fail "a short hash: $(cat "$work/rb")"; }
run rb "$here/ci/rollback.sh" 0123456789abcdef0123456789abcdef01234567 && fail "a commit not in the repository was taken" ||
  { grep -q 'rollback: no commit 0123456789abcdef0123456789abcdef01234567 in' "$work/rb" && ok "a commit the repository does not have is refused" || fail "a missing commit: $(cat "$work/rb")"; }

echo no > "$KSTUB/grant"
run rb "$here/ci/rollback.sh" "$commit" && fail "rollback without cluster-admin succeeded" ||
  { grep -q 'no cluster grant yet' "$work/rb" && ! grep -q '^kubectl apply' "$KSTUB/log" &&
    ok "without cluster-admin on dev it fails, saying so, and applies nothing" || fail "without a grant: $(cat "$work/rb")"; }
echo yes > "$KSTUB/grant"

: > "$KSTUB/log"
if run rb "$here/ci/rollback.sh" "$commit"; then
  grep -q "^rollback: tacplus-dev/cluster at $commit: good$" "$work/rb" &&
    grep -qx 'gcloud container clusters get-credentials dev --zone us-central1-a --project tacplus-dev' "$KSTUB/log" &&
    [ "$(grep -cE '^kubectl apply --server-side --field-manager=tacplus-cluster --force-conflicts -f out/(00-deploymentproxy|05-storage|10-deployment-seatrials|10-deployment-test-idp|20-ci)\.yaml$' "$KSTUB/log")" = 5 ] &&
    grep -qx 'kubectl -n ci rollout status deployment/gitlab-runner-infra --timeout=5m' "$KSTUB/log" &&
    [ -f "$KSTUB/live/v1.Secret.ci.gitlab-runner-infra" ] &&
    grep -q "^rollback: dev is at $commit; now re-pin the GitLab project to it: ci/pin.sh $commit" "$work/rb" &&
    ok "it applies the commit's render, the runners' tokens and rollouts, and says to re-pin" ||
    fail "rollback: $(cat "$work/rb" "$KSTUB/log")"
else
  fail "rollback: $(cat "$work/rb")"
fi
! grep -rq 't0ken\|Z2xydC1zdHVi' "$work/rb" && ok "no token in its output" || fail "a token is printed: $(cat "$work/rb")"

[ "$failed" = 0 ] && echo "rollback_test: all passed" || { echo "rollback_test: failed"; exit 1; }
