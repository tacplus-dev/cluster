#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests gitlab-runner/spot-pool.yaml against the spot pool it counts (#41): its machine_type and max_nodes are
# tacplus-dev/cloud's stacks/dev cluster.spot's, on cloud's main, so build's and build-report's concurrent never drifts
# from the nodes the pool can reach (it had: 3 counted, then 5 and 8 in cloud). A change to either there turns this
# red until gitlab-runner/spot-pool.yaml follows. The reading of cloud's block is tested on fixtures first: a match,
# a different max_nodes or machine type, and no spot pool. Needs bash, curl, yq.
#
#   tests/spot_pool_test.sh
#   CLOUD_DEV_MAIN_TF=<url or file://path> tests/spot_pool_test.sh    # another stacks/dev/main.tf
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
spot=$here/gitlab-runner/spot-pool.yaml

# cloud_spot FILE KEY: KEY of the `spot = { ... }` line of cloud's stacks/dev/main.tf FILE.
cloud_spot() { sed -n "s/^ *spot *= *{.*[{ ,] *$2 *= *\"\{0,1\}\([^\", }]*\)\"\{0,1\}.*}.*$/\1/p" "$1"; }
# matches FILE: nothing when gitlab-runner/spot-pool.yaml is FILE's spot pool, else what differs.
matches() {
  local k ours theirs
  for k in machine_type max_nodes; do
    ours=$(yq ".$k // \"\"" "$spot") theirs=$(cloud_spot "$1" $k)
    [ "$ours" = "$theirs" ] || echo "$k: gitlab-runner/spot-pool.yaml's [$ours], tacplus-dev/cloud's stacks/dev [$theirs]"
  done
}
tf() { printf '  node_pools = {\n    normal = { machine_type = "c4a-standard-2", nodes = 3 }\n%s\n  }\n' "$1" > "$work/main.tf"; }
nodes=$(yq '.max_nodes' "$spot") machine=$(yq '.machine_type' "$spot")
tf "    spot   = { machine_type = \"$machine\", max_nodes = $nodes }"
[ -z "$(matches "$work/main.tf")" ] && ok "fixture: the same spot pool matches" || fail "fixture: the same pool: $(matches "$work/main.tf")"
tf "    spot   = { machine_type = \"$machine\", max_nodes = $((nodes + 1)) }"
matches "$work/main.tf" | grep -q "^max_nodes: .*\[$nodes\], .*\[$((nodes + 1))\]" && ok "fixture: another max_nodes differs" ||
  fail "fixture: another max_nodes: [$(matches "$work/main.tf")]"
tf "    spot   = { machine_type = \"c4a-standard-8\", max_nodes = $nodes }"
matches "$work/main.tf" | grep -q "^machine_type: .*\[c4a-standard-8\]" && ok "fixture: another machine type differs" ||
  fail "fixture: another machine type: [$(matches "$work/main.tf")]"
tf ""
[ "$(matches "$work/main.tf" | wc -l)" = 2 ] && ok "fixture: no spot pool differs" || fail "fixture: no spot pool: [$(matches "$work/main.tf")]"

url=${CLOUD_DEV_MAIN_TF:-https://raw.githubusercontent.com/tacplus-dev/cloud/main/stacks/dev/main.tf}
if ! curl -fsSL --retry 3 -o "$work/cloud.tf" "$url"; then
  fail "no tacplus-dev/cloud stacks/dev at $url"
elif [ -n "$(matches "$work/cloud.tf")" ]; then
  fail "the spot pool drifted from tacplus-dev/cloud's: $(matches "$work/cloud.tf" | paste -sd ';' -)"
else
  ok "gitlab-runner/spot-pool.yaml is tacplus-dev/cloud's stacks/dev spot pool ($machine, max_nodes $nodes)"
fi

[ "$failed" = 0 ] && echo "spot_pool_test: all passed" || { echo "spot_pool_test: failed"; exit 1; }
