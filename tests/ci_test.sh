#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/gitlab-project.gitlab-ci.yml and ci/pin.sh: the file parses; every job runs on the project's runner (tag
# cluster); render and validate run on every push and merge request; plan, apply, delete-deployment and drift run
# on main only, never from a merge request, each with its id_token; apply and delete-deployment are manual, in the
# protected environment cluster, and run what they say; drift runs only on a schedule and never applies; plan is
# not on a schedule. ci/pin.sh sets CLUSTER_COMMIT and nothing else, --check accepts its output and refuses any
# other change, and the jobs refuse an empty CLUSTER_COMMIT. Needs bash and yq.
#
#   tests/ci_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ci=$here/ci/gitlab-project.gitlab-ci.yml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
q() { yq -r "$1" "$ci"; }

yq -e '.' "$ci" >/dev/null 2>&1 && ok "the CI file parses" || { echo "FAIL the CI file does not parse"; exit 1; }
jobs=$(q 'keys | .[] | select(test("^(stages|variables|workflow|default)$|^\\.") | not)')
[ "$(echo $jobs)" = "render validate plan apply delete-deployment drift" ] && ok "the jobs: $(echo $jobs)" || fail "the jobs are: $(echo $jobs)"
stages=" $(q '.stages | join(" ")') "
for j in $jobs; do
  [[ $stages == *" $(q ".\"$j\".stage") "* ]] || fail "$j: its stage $(q ".\"$j\".stage") is not in stages"
  [ "$(q ".\"$j\".tags // \"\"")" = "" ] || fail "$j: sets its own tags"
done
[ "$(q '.default.tags | join(",")')" = cluster ] && ok "every job runs on the runner tagged cluster" || fail "default tags: $(q '.default.tags')"

# The workflow: merge requests, and pushes, web, API and schedules on a branch.
[ "$(q '.workflow.rules[0].if')" = '$CI_PIPELINE_SOURCE == "merge_request_event"' ] &&
  [[ $(q '.workflow.rules[2].if') == *push*schedule* ]] && ok "pipelines run for merge requests and pushes" || fail "workflow rules: $(q '.workflow.rules')"
for j in render validate; do
  [ "$(q ".\"$j\".rules // \"none\"")" = none ] && ok "$j: on every pipeline, so every push and merge request" || fail "$j has rules"
done

main_only() { # main_only JOB SOURCES: the job's one rule is main, from SOURCES only
  [ "$(q ".\"$1\".rules | length")" = 1 ] && [ "$(q ".\"$1\".rules[0].if")" = "\$CI_COMMIT_BRANCH == \"main\" && \$CI_PIPELINE_SOURCE $2" ]
}
cluster_job() { # cluster_job JOB: extends .cluster, which has the id_token
  [ "$(q ".\"$1\".extends")" = .cluster ] && [ "$(q '.".cluster".id_tokens.GCP_ID_TOKEN.aud')" = 'https://iam.googleapis.com/$GCP_WIF_PROVIDER' ]
}
main_only plan '=~ /^(push|web|api)$/' && cluster_job plan && [ "$(q '.plan.rules[0].when // "on_success"')" = on_success ] &&
  [[ $(q '.plan.script[0]') == *"ci_gcp && ci_kube && ci/plan.sh out" ]] &&
  ok "plan: on main (never a merge request or the schedule), automatic, ci/plan.sh" || fail "plan: $(q '.plan')"
for j in apply delete-deployment; do
  main_only "$j" '=~ /^(push|web|api)$/' && cluster_job "$j" && [ "$(q ".\"$j\".rules[0].when")" = manual ] &&
    [ "$(q ".\"$j\".environment.name")" = cluster ] && [ "$(q ".\"$j\".resource_group")" = cluster ] &&
    ok "$j: manual, on main only, in the protected environment cluster" || fail "$j: $(q ".\"$j\"")"
done
[[ $(q '.apply.script[0]') == *"ci_gcp && ci_kube && ci/apply.sh out" ]] && [ "$(q '.apply.needs | join(",")')" = render,plan ] &&
  ok "apply: ci/apply.sh, after plan" || fail "apply runs: $(q '.apply.script')"
[[ $(q '."delete-deployment".script[0]') == *"ci/delete-deployment.sh deployments.yaml" ]] && ok "delete-deployment: ci/delete-deployment.sh" ||
  fail "delete-deployment runs: $(q '."delete-deployment".script')"
for j in render validate plan drift; do
  [ "$(q ".\"$j\".environment // \"none\"")" = none ] && [ "$(q ".\"$j\".rules[0].when // \"\"")" != manual ] ||
    fail "$j: manual or in an environment"
done
main_only drift '== "schedule"' && cluster_job drift && [[ $(q '.drift.script[0]') == *"ci/drift.sh out" ]] &&
  ! q '.drift.script[]' | grep -qE 'apply|delete' && ok "drift: on the schedule only, ci/drift.sh, never apply or delete" || fail "drift: $(q '.drift')"
for j in apply delete-deployment plan drift; do
  [[ $(q ".\"$j\".rules[0].if") != *merge_request* ]] || fail "$j runs on merge requests"
done

# The pin.
c=0123456789abcdef0123456789abcdef01234567
"$here/ci/pin.sh" "$c" > "$work/pinned" || fail "ci/pin.sh $c"
[ "$(diff "$ci" "$work/pinned" | grep -c '^[<>]')" = 2 ] && grep -qx "  CLUSTER_COMMIT: \"$c\"" "$work/pinned" &&
  [ "$(yq -r '.variables.CLUSTER_COMMIT' "$work/pinned")" = "$c" ] && ok "ci/pin.sh sets CLUSTER_COMMIT and nothing else" || fail "ci/pin.sh: $(diff "$ci" "$work/pinned")"
"$here/ci/pin.sh" --check "$work/pinned" >/dev/null 2>&1 && ok "ci/pin.sh --check accepts its own output" || fail "ci/pin.sh --check refuses its own output"
sed 's/when: manual/when: on_success/' "$work/pinned" > "$work/edited"
"$here/ci/pin.sh" --check "$work/edited" > "$work/log" 2>&1 && fail "ci/pin.sh --check accepts an apply made automatic" ||
  { grep -q "ci/pin.sh $c" "$work/log" && ok "ci/pin.sh --check refuses a copy edited by hand" || fail "the refusal: $(cat "$work/log")"; }
"$here/ci/pin.sh" --check "$ci" > "$work/log" 2>&1 && fail "ci/pin.sh --check accepts no CLUSTER_COMMIT" ||
  { grep -q "sets no CLUSTER_COMMIT" "$work/log" && ok "ci/pin.sh --check refuses the unpinned file" || fail "the refusal: $(cat "$work/log")"; }
"$here/ci/pin.sh" abc > /dev/null 2>&1 && fail "ci/pin.sh accepts a short hash" || ok "ci/pin.sh refuses a short hash"

# The jobs refuse an empty CLUSTER_COMMIT, before fetching anything.
script=$(q '.default.before_script[0]')
(cd "$work" && CLUSTER_COMMIT="" bash -c "$script") > "$work/log" 2>&1 && fail "the jobs run with no CLUSTER_COMMIT" ||
  { grep -q 'CLUSTER_COMMIT is not a full commit hash' "$work/log" && [ ! -e "$work/src" ] && ok "the jobs refuse an empty CLUSTER_COMMIT" ||
    fail "no CLUSTER_COMMIT: $(cat "$work/log")"; }

[ "$failed" = 0 ] && echo "ci_test: all passed" || { echo "ci_test: failed"; exit 1; }
