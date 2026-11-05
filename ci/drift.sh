#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The nightly drift check (the drift job, on a schedule): ci/plan.sh on the render OUT, and when anything differs,
# an issue on github.com/tacplus-dev/cluster saying what, filed through the tacplus-reader app (github_app_token in
# ci/lib.sh, issues: write on this repository alone). One open issue at a time: while it is open, a new drift is a
# comment on it, and the same drift again is nothing. It never applies.
#
#   ci/drift.sh OUT     # sources ci/lib.sh; needs what ci/plan.sh needs, and curl, jq, openssl
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: ci/drift.sh OUT}
source "$here/lib.sh"
repo=${GITHUB_REPOSITORY:-tacplus-dev/cluster}
api=${GITHUB_API:-https://api.github.com}
title="Drift on the ${CLUSTER:-dev} cluster"
die() { echo "drift: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
PLAN_SUMMARY=$tmp/summary "$here/plan.sh" "$out"
[ -s "$tmp/summary" ] || { echo "drift: none"; exit 0; }

mark="drift-sha256:$(sha256sum < "$tmp/summary" | cut -c1-16)"
{
  echo "The nightly drift check found the cluster \`${CLUSTER:-dev}\` differs from the render of $repo@${CLUSTER_COMMIT:-unknown} (what an apply would change):"
  echo
  echo '```'
  cat "$tmp/summary"
  echo '```'
  echo
  echo "Pipeline: ${CI_PIPELINE_URL:-unknown}. The drift job never applies: look at the plan, then fix the cluster or this repository: a pipeline on main applies the render (README)."
  echo
  echo "<!-- $mark -->"
} > "$tmp/body"

token=$(github_app_token "${repo#*/}" '{"issues":"write"}') || die "no GitHub token to file the drift: it is in this job's log only"
( umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth" )
gh_api() { # gh_api METHOD PATH [BODY_FILE]
  local code
  code=$(curl -sS -o "$tmp/answer" -w '%{http_code}' -X "$1" -H @"$tmp/auth" -H 'Accept: application/vnd.github+json' \
    ${3:+--data-binary @"$3"} "$api$2") || return 1
  [[ $code == 2?? ]] || { echo "drift: GitHub answered $1 $2 with HTTP $code: $(head -c 300 "$tmp/answer")" >&2; return 1; }
  cat "$tmp/answer"
}

open=$(gh_api GET "/repos/$repo/issues?state=open&per_page=100" |
  jq -r --arg t "$title" '[.[] | select(.title == $t and (has("pull_request") | not))][0].number // empty') || die "cannot list the issues of $repo"
if [ -z "$open" ]; then
  jq -n --arg t "$title" --rawfile b "$tmp/body" '{title: $t, body: $b}' > "$tmp/req"
  n=$(gh_api POST "/repos/$repo/issues" "$tmp/req" | jq -r '.number') || die "cannot file the issue"
  echo "drift: filed $repo#$n"
elif { gh_api GET "/repos/$repo/issues/$open" | jq -r '.body // ""'
       gh_api GET "/repos/$repo/issues/$open/comments?per_page=100" | jq -r '.[].body'; } | grep -qF "$mark"; then
  echo "drift: the same drift is already on $repo#$open"
else
  jq -n --rawfile b "$tmp/body" '{body: $b}' > "$tmp/req"
  gh_api POST "/repos/$repo/issues/$open/comments" "$tmp/req" >/dev/null || die "cannot comment on $repo#$open"
  echo "drift: commented on $repo#$open"
fi
