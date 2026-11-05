#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests render.sh against fixtures: tests/fixtures/render/deployments.yaml renders to exactly
# tests/fixtures/render/out/ (one file for deploymentproxy, one per deployment, one for ci); the images are pinned by
# digest (deploymentproxy's, and the runners' and their jobs' in ci); ci's RBAC is in ci only; build jobs select and
# tolerate the spot pool and control jobs never; each runner's pods name its token's version, and no token is in it;
# a deployment's own quota reaches deploymentproxy's config and the default leaves the release's ConfigMap as it
# is; deployments.yaml itself renders and passes ci/policy.sh; a removed entry renders nothing for it; a release
# file or chart file that does not match its checksum, every malformed entry, and a runner file that names its token
# by latest or sets what only gitlab-runner/values.yaml sets, is refused with a message. Needs bash, yq and helm.
#
#   tests/render_test.sh
#   UPDATE=1 tests/render_test.sh    # rewrites the expected output (review the diff)
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fixtures=$here/tests/fixtures/render
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

# The fixture renders to the expected files, byte for byte.
if "$here/render.sh" "$fixtures/deployments.yaml" "$work/out" > "$work/log" 2>&1; then
  if [ -n "${UPDATE:-}" ]; then rm -rf "$fixtures/out" && cp -R "$work/out" "$fixtures/out"; fi
  if diff -ru "$fixtures/out" "$work/out"; then ok "the fixture renders to tests/fixtures/render/out"
  else fail "the fixture's render differs from tests/fixtures/render/out (UPDATE=1 to accept)"; fi
else
  fail "render.sh failed on the fixture: $(cat "$work/log")"
fi
[ "$(ls "$work/out" 2>/dev/null | tr '\n' ' ')" = "00-deploymentproxy.yaml 10-deployment-alpha.yaml 10-deployment-beta-2.yaml 20-ci.yaml " ] &&
  ok "one file for deploymentproxy, one per deployment, one for ci" || fail "the files are: $(ls "$work/out" 2>/dev/null | tr '\n' ' ')"

dp=$work/out/00-deploymentproxy.yaml
image=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$dp")
[ "$image" = "$(yq '.image' "$here/deploymentproxy/pin.yaml")" ] && [[ $image == *@sha256:* ]] &&
  ok "the image is pinned by tag and digest: $image" || fail "the image is $image"
quota=$(yq 'select(.kind == "ConfigMap") | .data."config.yaml" | from_yaml | .quota.deployments | to_json(0)' "$dp")
[ "$quota" = '{"beta-2":{"pods":"20","requests.cpu":"2"}}' ] &&
  ok "beta-2's quota reaches deploymentproxy's config, alpha's default adds nothing" || fail "quota.deployments is $quota"

# ci: every image by digest, gitlab-runner/pin.yaml's; the runners' RBAC in ci only; build jobs on the spot pool only.
ci=$work/out/20-ci.yaml
runner_pin=$here/gitlab-runner/pin.yaml
images=$(yq ea '[select(.kind == "Deployment") | .spec.template.spec | (.containers + (.initContainers // []))[] | .image] | unique | join(" ")' "$ci")
[ "$images" = "$(yq '.runner' "$runner_pin")" ] && [[ $images == *@sha256:* ]] &&
  ok "the runners run the pinned runner image, by digest: $images" || fail "the runners' images are [$images]"
runner_toml() { R=$1 yq 'select(.kind == "ConfigMap" and .metadata.name == "gitlab-runner-" + strenv(R)) | .data."config.template.toml"' "$ci" |
  yq -p toml ".runners[0].kubernetes | $2"; }
jobs=$(for r in build control; do runner_toml $r '.image + " " + .helper_image'; done | sort -u)
[ "$jobs" = "$(yq '.job + " " + .helper' "$runner_pin")" ] &&
  ok "every runner's jobs default to the pinned job image, with the pinned helper, by digest" || fail "the jobs' images are [$jobs]"
! grep -qiE 'image.*:latest|latest@' "$ci" && ok "nothing in ci's render names latest" || fail "ci's render names latest"
[ "$(yq ea '[select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding")] | length' "$ci")" = 0 ] &&
  [ "$(yq ea '[select(.kind == "Role" or .kind == "RoleBinding") | .metadata.namespace] | unique | join(" ")' "$ci")" = ci ] &&
  [ "$(yq ea '[select(.kind == "RoleBinding") | .roleRef.kind] | unique | join(" ")' "$ci")" = Role ] &&
  ok "the runners' accounts hold Roles in ci only, no cluster RBAC" || fail "ci's RBAC: $(yq -N 'select(.kind | test("Role")) | .kind + " " + (.metadata.namespace // "")' "$ci")"
[ "$(runner_toml build '.node_selector.spot + " " + .node_tolerations."spot=true"')" = "true NoSchedule" ] &&
  [ "$(runner_toml control '[(.node_selector // {}) | keys[], (.node_tolerations // {}) | keys[]] | map(select(test("spot"))) | length')" = 0 ] &&
  [ "$(runner_toml control '.affinity.node_affinity.required_during_scheduling_ignored_during_execution.node_selector_terms[0].match_expressions[] | select(.key == "spot") | .operator + " " + .values[0]')" = "NotIn true" ] &&
  ok "build jobs select and tolerate the tainted spot pool; control jobs never tolerate it and refuse a spot node" || fail "the jobs' placement"
[ "$(yq ea '[select(.kind == "Deployment") | .spec.template.metadata.annotations."tacplus.dev/runner-token"] | join(" ")' "$ci")" = \
  "$(yq '.tacplus.token' "$here/gitlab-runner/runners/build.yaml") $(yq '.tacplus.token' "$here/gitlab-runner/runners/control.yaml")" ] &&
  ok "each runner's pods name its token's Secret Manager version" || fail "the runners' token versions"
! grep -q 'glrt-[A-Za-z0-9_]' "$ci" && [ "$(yq ea '[select(.kind == "Secret")] | length' "$ci")" = 0 ] &&
  ok "no token and no Secret in the render" || fail "the render holds a token or a Secret"

# The default quota leaves the release's ConfigMap as it is.
"$here/render.sh" "$fixtures/removed.yaml" "$work/removed" > "$work/log" 2>&1 || fail "render.sh failed on removed.yaml: $(cat "$work/log")"
diff <(yq 'select(.kind == "ConfigMap")' "$work/removed/00-deploymentproxy.yaml") \
     <(yq '.' "$here/deploymentproxy/release/config/manager/configmap.yaml") >/dev/null &&
  ok "with every quota the default, the ConfigMap is the release's" || fail "the default quota changed the release's ConfigMap"

# A removed entry renders nothing for it, and the rest as before.
[ "$(ls "$work/removed" | tr '\n' ' ')" = "00-deploymentproxy.yaml 10-deployment-alpha.yaml 20-ci.yaml " ] &&
  cmp -s "$work/removed/10-deployment-alpha.yaml" "$fixtures/out/10-deployment-alpha.yaml" &&
  ! grep -q beta "$work/removed/"* &&
  ok "a removed entry renders nothing for it" || fail "a removed entry: $(ls "$work/removed" | tr '\n' ' ')"

# The repository's own deployments.yaml renders and passes the policy.
if "$here/render.sh" "$here/deployments.yaml" "$work/real" > "$work/log" 2>&1 && "$here/ci/policy.sh" "$work/real" > "$work/policy" 2>&1; then
  ok "deployments.yaml renders and passes ci/policy.sh"
else
  fail "deployments.yaml: $(cat "$work/log" "$work/policy" 2>/dev/null)"
fi
ns=$(yq 'select(.kind == "Namespace") | .metadata.labels."tacplus.dev/deployment"' "$work/real/10-deployment-seatrials.yaml" 2>/dev/null)
[ "$ns" = seatrials ] && ok "seatrials: tac-seatrials labelled tacplus.dev/deployment=seatrials" || fail "seatrials' namespace label is [$ns]"

# A release file that does not match its checksum is refused.
cp -R "$here/." "$work/tree" 2>/dev/null; rm -rf "$work/tree/out"
echo "# edited" >> "$work/tree/deploymentproxy/release/config/rbac/cluster_role.yaml"
if "$work/tree/render.sh" "$fixtures/deployments.yaml" "$work/edited" > "$work/log" 2>&1; then
  fail "a release file edited by hand rendered"
else
  grep -q 'SHA256SUMS' "$work/log" && ok "a release file edited by hand is refused" || fail "the refusal says: $(cat "$work/log")"
fi

# A chart file edited by hand is refused.
cp -R "$here/." "$work/tree2" 2>/dev/null; rm -rf "$work/tree2/out"
echo "# edited" >> "$work/tree2/gitlab-runner/release/templates/deployment.yaml"
if "$work/tree2/render.sh" "$fixtures/deployments.yaml" "$work/edited2" > "$work/log" 2>&1; then
  fail "a chart file edited by hand rendered"
else
  grep -q 'gitlab-runner/release does not match its SHA256SUMS' "$work/log" && ok "a chart file edited by hand is refused" || fail "the refusal says: $(cat "$work/log")"
fi

# refused_runner NAME YQ WANT: render.sh refuses the build runner's file changed by YQ, saying WANT.
refused_runner() {
  rm -rf "$work/runners" "$work/bad" && cp -R "$here/gitlab-runner/runners" "$work/runners"
  yq -i "$2" "$work/runners/build.yaml"
  if RUNNERS=$work/runners "$here/render.sh" "$fixtures/deployments.yaml" "$work/bad" > "$work/log" 2>&1; then
    fail "runner: $1: rendered"
  elif ! grep -q -- "$3" "$work/log"; then
    fail "runner: $1: the refusal does not say [$3]: $(cat "$work/log")"
  else
    ok "refused: a runner with $1"
  fi
}
refused_runner "its token by latest" '.tacplus.token = "projects/tacplus-dev/secrets/gitlab-runner-build/versions/latest"' "never latest"
refused_runner "no token" 'del(.tacplus.token)' "tacplus.token \[\] is not a Secret Manager version"
refused_runner "no tags" '.tacplus.tags = []' "tacplus.tags is not a list"
refused_runner "its own security context" '.securityContext.privileged = true' "sets securityContext, which only gitlab-runner/values.yaml sets"
refused_runner "its own RBAC" '.rbac.clusterWideAccess = true' "sets rbac, which only"
refused_runner "its own image" '.runners.image = "alpine"' "sets runners.image, which only"
refused_runner "no config" 'del(.runners.config)' "no runners.config"

# refused NAME YAML WANT: render.sh refuses deployments.yaml YAML, saying WANT, and writes nothing.
refused() {
  printf '%s\n' "$2" > "$work/bad.yaml"
  rm -rf "$work/bad"
  if "$here/render.sh" "$work/bad.yaml" "$work/bad" > "$work/log" 2>&1; then
    fail "$1: rendered"
  elif ! grep -q -- "$3" "$work/log"; then
    fail "$1: the refusal does not say [$3]: $(cat "$work/log")"
  elif [ -e "$work/bad" ]; then
    fail "$1: refused, but wrote $work/bad"
  else
    ok "refused: $1"
  fi
}
entry() { # entry NAME [FIELD: VALUE...]: one entry, its fields overridden or added.
  local name=$1; shift
  printf '  - name: %s\n' "$name"
  local -A f=([deployAccount]=x-deploy@project-1.iam.gserviceaccount.com [operator]=operator [gitlabProject]=tacplus-dev/fleet-x [quota]='{}')
  local kv; for kv in "$@"; do f[${kv%%:*}]=${kv#*: }; done
  for k in "${!f[@]}"; do [ "${f[$k]}" = - ] || printf '    %s: %s\n' "$k" "${f[$k]}"; done
}
refused "a name of 17 characters" "deployments:
$(entry abcdefghijklmnopq)" "abcdefghijklmnopq"
refused "a name starting with a digit" "deployments:
$(entry 1abc)" "1abc"
refused "a name with an upper-case letter" "deployments:
$(entry Abc)" "Abc"
refused "a name with a dot" "deployments:
$(entry a.b)" "a.b"
refused "a duplicate name" "deployments:
$(entry dup)
$(entry dup)" "dup"
refused "no deploy account" "deployments:
$(entry x 'deployAccount: -')" "deployAccount"
refused "a deploy account that is not a Google service account" "deployments:
$(entry x 'deployAccount: someone@gmail.com')" "someone@gmail.com"
refused "an operator account that is not a name" "deployments:
$(entry x 'operator: Op/erator')" "Op/erator"
refused "no GitLab project" "deployments:
$(entry x 'gitlabProject: -')" "gitlabProject"
refused "a quota that is not a map of strings" "deployments:
$(entry x 'quota: {pods: 20}')" "quota"
refused "an unknown field" "deployments:
$(entry x 'clusterAdmin: true')" "clusterAdmin"
refused "no deployments list" "deploy: []" "deployments"

[ "$failed" = 0 ] && echo "render_test: all passed" || { echo "render_test: failed"; exit 1; }
