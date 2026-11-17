#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/grants.sh, the guard under security-exceptions.yaml's KSV-0053 and KSV-0056 entries (#28): this tree
# passes; a Role or ClusterRole granting pods/exec or pods/attach, or services, endpoints, endpointslices,
# networkpolicies or ingresses, fails unless it is one of the grants by design (the runners' gitlab-runner-*, the
# fleet's fleet-deploy, deploymentproxy's ClusterRole), each on the resources it has today only; so does `*`, in a
# resource or a group; any other Role, and a ConfigMap naming those resources, passes. Needs bash, git, yq
# (ci/tools.sh builds it into bin/).
#
#   tests/grants_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
command -v yq >/dev/null || { echo "FAIL no yq on the PATH (ci/tools.sh)"; exit 1; }

# role KIND NAME GROUP RESOURCES [VERBS]: a file in $work holding that Role or ClusterRole, its one rule.
role() {
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: %s\nmetadata:\n  name: %s\n  namespace: ci\nrules:\n  - apiGroups: ["%s"]\n    resources: [%s]\n    verbs: [%s]\n' \
    "$1" "$2" "$3" "$4" "${5:-get, create}" > "$work/role.yaml"
}
# passes WHAT / fails WHAT WANT: ci/grants.sh on the file passes; fails, saying WANT.
passes() { if "$here/ci/grants.sh" "$work/role.yaml" > "$work/log" 2>&1; then ok "passes: $1"; else fail "$1: failed: $(cat "$work/log")"; fi; }
fails() {
  if "$here/ci/grants.sh" "$work/role.yaml" > "$work/log" 2>&1; then fail "$1: passed"
  elif grep -q -- "$2" "$work/log"; then ok "fails: $1"
  else fail "$1: failed, but not saying [$2]: $(cat "$work/log")"; fi
}

if (cd "$here" && ci/grants.sh) > "$work/log" 2>&1; then ok "passes: this tree"; else fail "this tree: $(cat "$work/log")"; fi

role Role gitlab-runner-build "" "pods/attach, pods/exec, services"; passes "a runner's exec, attach and services"
role Role fleet-deploy "" "services, endpoints"; passes "fleet-deploy's services and endpoints"
role Role fleet-deploy networking.k8s.io networkpolicies; passes "fleet-deploy's networkpolicies"
role ClusterRole deploymentproxy networking.k8s.io networkpolicies delete; passes "deploymentproxy's networkpolicies"
role Role reader "" "pods, pods/log, configmaps"; passes "any other Role without them"

role Role debug "" pods/exec; fails "another Role's pods/exec" "Role debug grants pods/exec"
role Role debug "" pods/attach; fails "another Role's pods/attach" "Role debug grants pods/attach"
role ClusterRole gitlab-runner-build "" pods/exec; fails "a ClusterRole named as a runner's Role" "ClusterRole gitlab-runner-build grants pods/exec"
role Role operator "" services; fails "another Role's services" "Role operator grants services"
role Role operator "" endpoints get; fails "another Role's endpoints, read only" "Role operator grants endpoints"
role Role operator discovery.k8s.io endpointslices; fails "another Role's endpointslices" "Role operator grants discovery.k8s.io/endpointslices"
role Role operator networking.k8s.io ingresses; fails "another Role's ingresses" "Role operator grants networking.k8s.io/ingresses"
role Role deploymentproxy networking.k8s.io networkpolicies; fails "a Role named as deploymentproxy's ClusterRole" "Role deploymentproxy grants networking.k8s.io/networkpolicies"
role Role fleet-deploy "" pods/exec; fails "fleet-deploy's pods/exec" "Role fleet-deploy grants pods/exec"
role Role fleet-deploy networking.k8s.io ingresses; fails "fleet-deploy's ingresses" "Role fleet-deploy grants networking.k8s.io/ingresses"
role ClusterRole deploymentproxy "" services; fails "deploymentproxy's services" "ClusterRole deploymentproxy grants services"
role Role gitlab-runner-build networking.k8s.io networkpolicies; fails "a runner's networkpolicies" "Role gitlab-runner-build grants networking.k8s.io/networkpolicies"
role Role reader "" '"*"'; fails "another Role's every resource" "Role reader grants \*"
role Role reader '*' pods/exec; fails "another Role's pods/exec in every group" "Role reader grants \*/pods/exec"

printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: notes\ndata:\n  rules: "resources: [pods/exec]"\n' > "$work/role.yaml"
passes "a ConfigMap naming pods/exec"
role Role debug "" pods/exec
{ printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: ci\n---\n'; cat "$work/role.yaml"; } > "$work/two.yaml" && mv "$work/two.yaml" "$work/role.yaml"
fails "a Role after another document" "Role debug grants pods/exec"
role Role debug "" services
{ printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: fleet-deploy\nrules:\n  - apiGroups: [""]\n    resources: [services]\n    verbs: [get]\n---\n'; cat "$work/role.yaml"; } > "$work/two.yaml" && mv "$work/two.yaml" "$work/role.yaml"
fails "another Role's services after fleet-deploy's" "Role debug grants services"

[ "$failed" = 0 ] || exit 1
