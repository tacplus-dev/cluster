#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests render.sh against fixtures: tests/fixtures/render/deployments.yaml renders to exactly
# tests/fixtures/render/out/ (one file for deploymentproxy, one per deployment); the image is pinned by digest;
# a deployment's own quota reaches deploymentproxy's config and the default leaves the release's ConfigMap as it
# is; deployments.yaml itself renders and passes ci/policy.sh; a removed entry renders nothing for it; a release
# file that does not match its checksum, and every malformed entry, is refused with a message. Needs bash and yq.
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
[ "$(ls "$work/out" 2>/dev/null | tr '\n' ' ')" = "00-deploymentproxy.yaml 10-deployment-alpha.yaml 10-deployment-beta-2.yaml " ] &&
  ok "one file for deploymentproxy, one per deployment" || fail "the files are: $(ls "$work/out" 2>/dev/null | tr '\n' ' ')"

dp=$work/out/00-deploymentproxy.yaml
image=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$dp")
[ "$image" = "$(yq '.image' "$here/deploymentproxy/pin.yaml")" ] && [[ $image == *@sha256:* ]] &&
  ok "the image is pinned by tag and digest: $image" || fail "the image is $image"
quota=$(yq 'select(.kind == "ConfigMap") | .data."config.yaml" | from_yaml | .quota.deployments | to_json(0)' "$dp")
[ "$quota" = '{"beta-2":{"pods":"20","requests.cpu":"2"}}' ] &&
  ok "beta-2's quota reaches deploymentproxy's config, alpha's default adds nothing" || fail "quota.deployments is $quota"

# The default quota leaves the release's ConfigMap as it is.
"$here/render.sh" "$fixtures/removed.yaml" "$work/removed" > "$work/log" 2>&1 || fail "render.sh failed on removed.yaml: $(cat "$work/log")"
diff <(yq 'select(.kind == "ConfigMap")' "$work/removed/00-deploymentproxy.yaml") \
     <(yq '.' "$here/deploymentproxy/release/config/manager/configmap.yaml") >/dev/null &&
  ok "with every quota the default, the ConfigMap is the release's" || fail "the default quota changed the release's ConfigMap"

# A removed entry renders nothing for it, and the rest as before.
[ "$(ls "$work/removed" | tr '\n' ' ')" = "00-deploymentproxy.yaml 10-deployment-alpha.yaml " ] &&
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
