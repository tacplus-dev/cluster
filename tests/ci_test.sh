#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/gitlab-project.gitlab-ci.yml and ci/pin.sh: the file parses; every job runs on the project's runner (tag
# cluster). The pipelines GitLab makes of it, by its workflow and its jobs' rules (pipeline, below): render,
# runner-images, validate and security in every pipeline, so every push and merge request and the schedule; plan, apply and drift
# on main only, never from a merge request; apply automatic on main once plan succeeds (not manual: main is not production), from the render the plan
# saved; a push, a merge request, a schedule or a plain run has no deletion job; a deletion pipeline (web or API, on
# main, DELETE_DEPLOYMENT set and DELETE_CONFIRM equal to it) has it, manual, and no apply; the cluster jobs have
# their id_token; apply and the deletion job are in the protected environment cluster, and run what they say; a
# failed apply fails the pipeline; drift runs only on a schedule and never applies. ci/pin.sh sets CLUSTER_COMMIT and nothing else, --check
# accepts its output and refuses any other change, and the jobs refuse an empty CLUSTER_COMMIT. The security job has
# no id_token, fetches the history, runs ci/security.sh on runner-images' images, keeps its report pass or fail, and
# plan waits for it. runner-images (#21) builds our GitLab Runner images, pushes them on main only, as
# cluster-admin-pipeline, and plan waits for it; gitlab-runner/pin.yaml's runner: and helper: are its images, in
# tacplus-dev/cloud's ci-images, of the build's release. build.lock pins the CI image by digest,
# gitlab-runner/pin.yaml's job:, and gates.yaml's full runs the render, validate, the tests and the images' build
# when their recipe changed.
# drift signs with tacplus-ci's tacplus-reader, and no file names a KMS key in jody1-328023.
# Needs bash and yq.
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
del='DELETE deployment: removes tac-<DELETE_DEPLOYMENT> and every tenant namespace (data loss)'
mapfile -t jobs < <(q 'keys | .[] | select(test("^(stages|variables|workflow|default)$|^\\.") | not)')
[ "$(printf '%s,' "${jobs[@]}")" = "render,runner-images,validate,security,plan,apply,$del,drift," ] && ok "the jobs: ${jobs[*]}" || fail "the jobs are: ${jobs[*]}"
stages=" $(q '.stages | join(" ")') "
for j in "${jobs[@]}"; do
  [[ $stages == *" $(q ".[\"$j\"].stage") "* ]] || fail "$j: its stage $(q ".[\"$j\"].stage") is not in stages"
  [ "$(q ".[\"$j\"].tags // \"\"")" = "" ] || fail "$j: sets its own tags"
done
[ "$(q '.default.tags | join(",")')" = cluster ] && ok "every job runs on the runner tagged cluster" || fail "default tags: $(q '.default.tags')"
# build.lock pins tacplus-dev/build's builds to the CI image by digest (#14), read as its plan reads it: the image
# gitlab-runner/pin.yaml's job: already pins, of the CI file's line (build:2.6, a patch of it, by its digest). And
# gates.yaml gives those builds the gates to run in it: its full set, the render, validate and the tests, as CI.
lock=$(sed -n 's/^build_image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$here/build.lock" 2>/dev/null | head -1)
[[ $lock =~ ^[^@]+:[0-9.]+@sha256:[0-9a-f]{64}$ ]] && ok "build.lock pins an image by digest" || fail "build.lock's build_image: [$lock]"
[ "$lock" = "$(yq -r '.job' "$here/gitlab-runner/pin.yaml")" ] && ok "build.lock pins gitlab-runner/pin.yaml's job image" ||
  fail "build.lock's build_image [$lock] is not gitlab-runner/pin.yaml's job: $(yq -r '.job' "$here/gitlab-runner/pin.yaml")"
[[ ${lock%@*} == "$(q '.default.image')".* ]] && ok "build.lock pins a patch of the CI image's line" ||
  fail "build.lock's build_image [$lock] is not of the CI image $(q '.default.image')"
gates='ci/tools.sh && export PATH=$PWD/bin:$PATH && ./render.sh deployments.yaml out && ci/validate.sh out && ci/checks.sh'
gates+=' && ci/runner-images.sh --if-changed "${LOOPER_GATES_BASE:-}" images'
[ "$(yq -r '.full.run // ""' "$here/gates.yaml" 2>/dev/null)" = "$gates" ] &&
  ok "gates.yaml's full runs the render, validate, the tests and the images' build" || fail "gates.yaml's full: [$(yq -r '.full.run' "$here/gates.yaml" 2>&1)]"
# Our GitLab Runner images (#21): gitlab-runner/pin.yaml's runner: and helper: are the images ci/runner-images.sh
# builds, in tacplus-dev/cloud's ci-images (its dev stack's registry), of the build's release, by digest; its recipe
# names the runner's commit, both binaries' SHA-256s, upstream's base images' commit, alpine:3.24 by digest and each
# image's packages by version. (gitlab-runner/fetch.sh checks the release is the chart's and cloud's.)
pin=$here/gitlab-runner/pin.yaml
registry=$(yq -r '.build.registry' "$pin") version=$(yq -r '.build.version' "$pin")
[ "$registry" = us-central1-docker.pkg.dev/tacplus-dev/ci-images ] && ok "our images' registry is tacplus-dev/cloud's ci-images" ||
  fail "pin.yaml's build.registry is [$registry]"
[[ $(yq -r '.runner' "$pin") =~ ^$registry/gitlab-runner:alpine-$version@sha256:[0-9a-f]{64}$ &&
   $(yq -r '.helper' "$pin") =~ ^$registry/gitlab-runner-helper:$version@sha256:[0-9a-f]{64}$ ]] &&
  ok "pin.yaml's runner and helper are our $version images, by digest" ||
  fail "pin.yaml's runner [$(yq -r '.runner' "$pin")] and helper [$(yq -r '.helper' "$pin")] are not $registry's at $version"
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $(yq -r '.build.commit' "$pin") =~ ^[0-9a-f]{40}$ &&
   $(yq -r '.build.runner_sha256' "$pin") =~ ^[0-9a-f]{64}$ && $(yq -r '.build.helper_sha256' "$pin") =~ ^[0-9a-f]{64}$ &&
   $(yq -r '.build.base_images' "$pin") =~ ^[0-9a-f]{40}$ && $(yq -r '.build.alpine' "$pin") =~ ^docker.io/library/alpine:3\.24@sha256:[0-9a-f]{64}$ ]] &&
  ok "the images' recipe pins the release, its commit, both binaries, the base images' commit and alpine:3.24" ||
  fail "pin.yaml's build: $(yq -o=json -I=0 '.build' "$pin")"
bad=$(yq -r '.build.packages.runner[], .build.packages.helper[]' "$pin" | grep -vE '^[a-z0-9.+_-]+=[0-9][0-9a-z._+-]*-r[0-9]+$')
[ -z "$bad" ] && [ "$(yq '.build.packages.runner | length' "$pin")" -gt 0 ] && [ "$(yq '.build.packages.helper | length' "$pin")" -gt 0 ] &&
  ok "each image's packages are pinned name=version" || fail "packages not name=version: $bad"

# cond EXPR: whether the rules:if expression EXPR holds under the variables set: clauses joined by &&, each $VAR
# (set and not empty), $VAR == "string", $VAR == $VAR or $VAR =~ /regex/, the forms the file uses. Any other
# form fails the test, so that one the file starts using is added here first.
cond() {
  local rest=$1 c re_var='^\$([A-Z_]+)$' re_str='^\$([A-Z_]+) == "([^"]*)"$' re_eq='^\$([A-Z_]+) == \$([A-Z_]+)$' re_m='^\$([A-Z_]+) =~ /(.*)/$'
  while [ -n "$rest" ]; do
    c=${rest%% && *}
    [ "$c" = "$rest" ] && rest= || rest=${rest#* && }
    if [[ $c =~ $re_var ]]; then [ -n "${!BASH_REMATCH[1]:-}" ] || return 1
    elif [[ $c =~ $re_str ]]; then [ "${!BASH_REMATCH[1]:-}" = "${BASH_REMATCH[2]}" ] || return 1
    elif [[ $c =~ $re_eq ]]; then [ "${!BASH_REMATCH[1]:-}" = "${!BASH_REMATCH[2]:-}" ] || return 1
    elif [[ $c =~ $re_m ]]; then [[ ${!BASH_REMATCH[1]:-} =~ ${BASH_REMATCH[2]} ]] || return 1
    else echo "cond: an expression this test cannot evaluate: [$c]" >&2; return 2; fi
  done
}
# when PATH: the when of the first of PATH's rules that holds ("never" if none does), on_success if it has no rules.
when() {
  local n i r
  n=$(q "$1.rules | length")
  [ "$n" = 0 ] && { echo on_success; return; }
  for ((i = 0; i < n; i++)); do
    r=0
    [ "$(q "$1.rules[$i].if // \"\"")" = "" ] || { cond "$(q "$1.rules[$i].if")"; r=$?; }
    [ "$r" = 2 ] && return 2
    [ "$r" = 0 ] && { q "$1.rules[$i].when // \"on_success\""; return; }
  done
  echo never
}
# pipeline SOURCE BRANCH [VAR=VALUE...]: the jobs of the pipeline GitLab makes for SOURCE on BRANCH with those
# variables, "JOB:WHEN" each, comma-separated; "none" when the workflow makes no pipeline.
pipeline() {
  (
    unset DELETE_DEPLOYMENT DELETE_CONFIRM CI_OPEN_MERGE_REQUESTS
    export CI_PIPELINE_SOURCE=$1 CI_COMMIT_BRANCH=$2; shift 2
    [ "$CI_PIPELINE_SOURCE" = merge_request_event ] && CI_COMMIT_BRANCH=
    for v in "$@"; do export "$v"; done
    [ "$(when .workflow)" = never ] && { echo none; exit; }
    out=
    for j in "${jobs[@]}"; do
      w=$(when ".[\"$j\"]") || exit 1
      [ "$w" = never ] || out+="$j:$w,"
    done
    echo "$out"
  )
}
expect() { # expect WHAT GOT WANT
  [ "$2" = "$3" ] && ok "$1: ${3//"$del"/the deletion job}" || fail "$1: the jobs are [$2], not [$3]"
}
checks="render:on_success,runner-images:on_success,validate:on_success,security:on_success,"
normal="${checks}plan:on_success,apply:on_success,"
deletion="${checks}plan:on_success,$del:manual,"
expect "a push to main" "$(pipeline push main)" "$normal"
expect "a web pipeline on main" "$(pipeline web main)" "$normal"
expect "an API pipeline on main" "$(pipeline api main)" "$normal"
expect "the schedule" "$(pipeline schedule main)" "${checks}drift:on_success,"
expect "a merge request" "$(pipeline merge_request_event "")" "$checks"
expect "a push to another branch" "$(pipeline push topic)" "$checks"
expect "a deletion pipeline (web)" "$(pipeline web main DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta-2)" "$deletion"
expect "a deletion pipeline (API)" "$(pipeline api main DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta-2)" "$deletion"
nodel="${checks}plan:on_success,"
expect "DELETE_DEPLOYMENT without DELETE_CONFIRM" "$(pipeline web main DELETE_DEPLOYMENT=beta-2)" "$nodel"
expect "a DELETE_CONFIRM that differs" "$(pipeline web main DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta)" "$nodel"
expect "DELETE_CONFIRM alone" "$(pipeline web main DELETE_CONFIRM=beta-2)" "$normal"
expect "both on a push" "$(pipeline push main DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta-2)" "$nodel"
expect "both on the schedule" "$(pipeline schedule main DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta-2)" "${checks}drift:on_success,"
expect "both on another branch" "$(pipeline web topic DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta-2)" "$checks"
expect "both on a merge request" "$(pipeline merge_request_event "" DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta-2)" "$checks"
# The same of the copy ci/pin.sh makes, the file the GitLab project runs.
c=0123456789abcdef0123456789abcdef01234567
ci_src=$ci ci=$work/rendered
"$here/ci/pin.sh" "$c" > "$ci" || fail "ci/pin.sh $c"
expect "the project's copy, a push to main" "$(pipeline push main)" "$normal"
expect "the project's copy, a deletion pipeline" "$(pipeline web main DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta-2)" "$deletion"
ci=$ci_src

cluster_job() { # cluster_job JOB: extends .cluster, which has the id_token
  [ "$(q ".[\"$1\"].extends")" = .cluster ] && [ "$(q '.".cluster".id_tokens.GCP_ID_TOKEN.aud')" = 'https://iam.googleapis.com/$GCP_WIF_PROVIDER' ]
}
for j in runner-images plan apply "$del" drift; do
  cluster_job "$j" || fail "$j: does not extend .cluster"
done
# runner-images: in every pipeline, it pushes on main only (where the provider admits the pipeline), as
# cluster-admin-pipeline; elsewhere it builds with no credential. Its images are the security job's artifact, and plan
# waits for it, so apply never deploys an image the registry does not have.
ri=$(q '.["runner-images"].script[0]')
[[ $ri == *'if [ "$CI_COMMIT_BRANCH" = main ]; then'*'ci_gcp'*'crane auth login us-central1-docker.pkg.dev -u oauth2accesstoken --password-stdin'*'ci/runner-images.sh --push images'*'else'*'ci/runner-images.sh images'* ]] &&
  [ "$(q '.["runner-images"].needs | join(",")')" = render ] && [ "$(q '.["runner-images"].artifacts.paths | join(",")')" = src/images/ ] &&
  [ "$(q '.plan.needs[] | select(.job == "runner-images") | .job')" = runner-images ] &&
  ok "runner-images: builds, pushes on main only, its images the artifact, and plan waits for it" || fail "runner-images: $(q '.["runner-images"]')"
[ "$(sed -n '/^  *else$/,/^  *fi$/p' <<<"$ri" | grep -c 'ci_gcp\|--push\|crane auth')" = 0 ] &&
  ok "runner-images: no credential and no push outside main" || fail "runner-images outside main: $ri"

[[ $(q '.plan.script[0]') == *"ci_gcp && ci_kube && PLAN_SUMMARY=plan.txt ci/plan.sh out" ]] && ok "plan: ci/plan.sh" || fail "plan runs: $(q '.plan.script')"
for j in apply "$del"; do
  [ "$(q ".[\"$j\"].environment.name")" = cluster ] && [ "$(q ".[\"$j\"].resource_group")" = cluster ] &&
    ok "${j//"$del"/the deletion job}: in the protected environment cluster" || fail "$j: $(q ".[\"$j\"]")"
done
[[ $(q '.apply.script[0]') == *"ci_gcp && ci_kube && ci/apply.sh out" ]] && [ "$(q '.apply.needs | join(",")')" = plan ] &&
  ok "apply: ci/apply.sh, after plan" || fail "apply runs: $(q '.apply.script'), after $(q '.apply.needs')"
[ "$(q '[.apply.rules[].when] | map(select(. == "manual")) | length')" = 0 ] && [ "$(q '.apply.allow_failure // false')" = false ] &&
  ok "apply: never manual, and its failure fails the pipeline" || fail "apply: $(q '.apply.rules'), allow_failure $(q '.apply.allow_failure')"
# apply applies the render plan diffed: plan saves it (src/out/, with src/bin/) and its summary, and apply takes them from plan.
[ "$(q '(.plan.artifacts.paths // []) | join(",")')" = src/bin/,src/out/,src/plan.txt ] && [[ $(q '.plan.script[0]') == *"PLAN_SUMMARY=plan.txt ci/plan.sh out" ]] &&
  ok "plan: saves the render it diffed and its summary" || fail "plan saves: $(q '.plan.artifacts'), runs $(q '.plan.script')"
[[ $(q ".[\"$del\"].script[0]") == *"ci/delete-deployment.sh deployments.yaml" ]] && ok "the deletion job: ci/delete-deployment.sh" ||
  fail "the deletion job runs: $(q ".[\"$del\"].script")"
for j in render runner-images validate security plan drift; do
  [ "$(q ".[\"$j\"].environment // \"none\"")" = none ] || fail "$j: in an environment"
done
# The security job: no render, no id_token, only runner-images' images, the whole history fetched for gitleaks, the
# pinned scanners, ci/security.sh on the tree, every tool in bin/, the job's own image and our images; its report
# kept, pass or fail; plan waits for it, and so apply.
[ "$(q '.security.needs | join(",")')" = runner-images ] && [ "$(q '.security.extends // "none"')" = none ] && [ "$(q '.security.id_tokens // "none"')" = none ] &&
  ok "security: needs only runner-images' images, and has no id_token" || fail "security: $(q '.security')"
sec=$(q '.security.script[0]')
[[ $sec == *'git fetch -q --unshallow https://github.com/tacplus-dev/cluster.git "$CLUSTER_COMMIT"'* && $sec == *"ci/tools.sh security"* &&
   $sec == *'SECURITY_IMAGES=images ci/security.sh . "$CI_JOB_IMAGE" bin/*'* ]] && ok "security: the history, the pinned scanners, ci/security.sh, our images" || fail "security runs: $sec"
[ "$(q '.security.artifacts.when')" = always ] && [ "$(q '.security.artifacts.paths | join(",")')" = src/security/ ] &&
  ok "security: its report is kept, pass or fail" || fail "security's artifacts: $(q '.security.artifacts')"
[ "$(q '.security.allow_failure // false')" = false ] && [ "$(q '.plan.needs[] | select(.job == "security") | .job')" = security ] &&
  ok "security: its failure fails the pipeline, and plan waits for it" || fail "security: allow_failure $(q '.security.allow_failure'), plan needs $(q '.plan.needs')"
[[ $(q '.drift.script[0]') == *"ci/drift.sh out" ]] && ! q '.drift.script[]' | grep -qE 'apply|delete' &&
  ok "drift: ci/drift.sh, never apply or delete" || fail "drift: $(q '.drift')"

# The pin.
"$here/ci/pin.sh" "$c" > "$work/pinned" || fail "ci/pin.sh $c"
[ "$(diff "$ci" "$work/pinned" | grep -c '^[<>]')" = 2 ] && grep -qx "  CLUSTER_COMMIT: \"$c\"" "$work/pinned" &&
  [ "$(yq -r '.variables.CLUSTER_COMMIT' "$work/pinned")" = "$c" ] && ok "ci/pin.sh sets CLUSTER_COMMIT and nothing else" || fail "ci/pin.sh: $(diff "$ci" "$work/pinned")"
"$here/ci/pin.sh" --check "$work/pinned" >/dev/null 2>&1 && ok "ci/pin.sh --check accepts its own output" || fail "ci/pin.sh --check refuses its own output"
sed 's/when: manual/when: on_success/' "$work/pinned" > "$work/edited"
"$here/ci/pin.sh" --check "$work/edited" > "$work/log" 2>&1 && fail "ci/pin.sh --check accepts a deletion job made automatic" ||
  { grep -q "ci/pin.sh $c" "$work/log" && ok "ci/pin.sh --check refuses a copy edited by hand" || fail "the refusal: $(cat "$work/log")"; }
"$here/ci/pin.sh" --check "$ci" > "$work/log" 2>&1 && fail "ci/pin.sh --check accepts no CLUSTER_COMMIT" ||
  { grep -q "sets no CLUSTER_COMMIT" "$work/log" && ok "ci/pin.sh --check refuses the unpinned file" || fail "the refusal: $(cat "$work/log")"; }
"$here/ci/pin.sh" abc > /dev/null 2>&1 && fail "ci/pin.sh accepts a short hash" || ok "ci/pin.sh refuses a short hash"

# The jobs refuse an empty CLUSTER_COMMIT, before fetching anything.
script=$(q '.default.before_script[0]')
(cd "$work" && CLUSTER_COMMIT="" bash -c "$script") > "$work/log" 2>&1 && fail "the jobs run with no CLUSTER_COMMIT" ||
  { grep -q 'CLUSTER_COMMIT is not a full commit hash' "$work/log" && [ ! -e "$work/src" ] && ok "the jobs refuse an empty CLUSTER_COMMIT" ||
    fail "no CLUSTER_COMMIT: $(cat "$work/log")"; }

# The target (#7): the cluster dev in us-central1-a, in the project tacplus-dev, as its cluster-admin-pipeline; the
# runners' tokens and the deployments' accounts in that project too.
[ "$(q '.variables.GCP_PROJECT')" = tacplus-dev ] && [ "$(q '.variables.CLUSTER')" = dev ] && [ "$(q '.variables.ZONE')" = us-central1-a ] &&
  [ "$(q '.variables.GCP_DEPLOY_SA')" = cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com ] &&
  ok "the pipeline targets the cluster dev (us-central1-a) in tacplus-dev, as cluster-admin-pipeline there" ||
  fail "the pipeline's target: $(q '.variables')"
for r in "$here"/gitlab-runner/runners/*.yaml; do
  [[ $(yq '.tacplus.token' "$r") == "projects/tacplus-dev/secrets/gitlab-runner-$(basename "$r" .yaml)/versions/"* ]] ||
    fail "${r#"$here"/}: its token is not gitlab-runner-$(basename "$r" .yaml) in tacplus-dev: $(yq '.tacplus.token' "$r")"
done
others=$(yq '.deployments[].deployAccount | select(test("@tacplus-dev\\.iam\\.gserviceaccount\\.com$") | not)' "$here/deployments.yaml")
[ -z "$others" ] && ok "the runners' tokens and the deployments' accounts are in tacplus-dev" || fail "deploy accounts outside tacplus-dev: $others"
# The drift job signs with tacplus-ci's tacplus-reader (#19; tacplus-dev/cloud#30), and nothing here names
# jody1-328023's key any more.
[ "$(q '.variables.TACPLUS_READER_KMS_KEY')" = projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/tacplus-reader ] &&
  ok "drift signs with tacplus-ci's tacplus-reader" || fail "TACPLUS_READER_KMS_KEY is $(q '.variables.TACPLUS_READER_KMS_KEY')"
old_key=$(grep -rlIE --exclude-dir=.git --exclude-dir=bin --exclude-dir=out 'projects/jody1-328023/[^ ]*cryptoKeys' "$here")
[ -z "$old_key" ] && ok "no file names a KMS key in jody1-328023" || fail "a KMS key in jody1-328023 in: $old_key"

[ "$failed" = 0 ] && echo "ci_test: all passed" || { echo "ci_test: failed"; exit 1; }
