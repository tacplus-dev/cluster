#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/policy.sh: the fixture's render keeps the rules, and each way a deployment's file could reach outside
# its namespace is a breach: a `*` verb, resource or group; a cluster-scoped resource (nodes, namespaces,
# clusterroles, CRDs) in a Role; escalate, bind, impersonate; non-resource URLs; a ClusterRole or
# ClusterRoleBinding; a RoleBinding to a ClusterRole or to another namespace's service account; a Role in another
# namespace; an unlabelled namespace. Needs bash and yq.
#
#   tests/policy_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

"$here/render.sh" "$here/tests/fixtures/render/deployments.yaml" "$work/good" >/dev/null || { echo "FAIL render.sh"; exit 1; }
"$here/ci/policy.sh" "$work/good" > "$work/log" 2>&1 && ok "the fixture's render keeps the rules" || fail "the fixture's render: $(cat "$work/log")"

# breach WHAT YQ WANT: the fixture's alpha file changed by the yq expression YQ is a breach saying WANT.
breach() {
  rm -rf "$work/bad" && cp -R "$work/good" "$work/bad"
  yq -i "$2" "$work/bad/10-deployment-alpha.yaml"
  if "$here/ci/policy.sh" "$work/bad" > "$work/log" 2>&1; then
    fail "$1: passed"
  elif grep -q -- "$3" "$work/log"; then
    ok "breach: $1"
  else
    fail "$1: does not say [$3]: $(cat "$work/log")"
  fi
}
role='(select(.kind == "Role" and .metadata.name == "fleet-deploy") | .rules)'
breach "a * verb" "$role[0].verbs += [\"*\"]" "grants \*"
breach "a * resource" "$role[0].resources += [\"*\"]" "grants \*"
breach "a * group" "$role[0].apiGroups = [\"*\"]" "grants \*"
breach "nodes" "$role += [{\"apiGroups\": [\"\"], \"resources\": [\"nodes\"], \"verbs\": [\"get\"]}]" "/nodes, not a namespaced"
breach "namespaces" "$role += [{\"apiGroups\": [\"\"], \"resources\": [\"namespaces\"], \"verbs\": [\"get\"]}]" "/namespaces, not a namespaced"
breach "clusterroles" "$role += [{\"apiGroups\": [\"rbac.authorization.k8s.io\"], \"resources\": [\"clusterroles\"], \"verbs\": [\"get\"]}]" "clusterroles, not a namespaced"
breach "CRDs" "$role += [{\"apiGroups\": [\"apiextensions.k8s.io\"], \"resources\": [\"customresourcedefinitions\"], \"verbs\": [\"get\"]}]" "customresourcedefinitions, not a namespaced"
breach "escalate" "$role[0].verbs += [\"escalate\"]" "grants escalate"
breach "bind" "$role += [{\"apiGroups\": [\"rbac.authorization.k8s.io\"], \"resources\": [\"roles\"], \"verbs\": [\"bind\"]}]" "grants bind"
breach "impersonate" "$role += [{\"apiGroups\": [\"\"], \"resources\": [\"serviceaccounts\"], \"verbs\": [\"impersonate\"]}]" "grants impersonate"
breach "non-resource URLs" "$role += [{\"nonResourceURLs\": [\"/metrics\"], \"verbs\": [\"get\"]}]" "non-resource URLs"
breach "a ClusterRole" '(select(.kind == "Role" and .metadata.name == "fleet-deploy") | .kind) = "ClusterRole"' "ClusterRole fleet-deploy"
breach "a binding to a ClusterRole" '(select(.kind == "RoleBinding" and .metadata.name == "fleet-deploy") | .roleRef) = {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "admin"}' "binds a ClusterRole"
breach "another namespace's service account" '(select(.kind == "RoleBinding") | .subjects[0] | select(.kind == "ServiceAccount") | .namespace) = "kube-system"' "of \[kube-system\]"
breach "a Group" '(select(.kind == "RoleBinding" and .metadata.name == "fleet-deploy") | .subjects[0].kind) = "Group"' "binds the Group"
breach "a Role in another namespace" '(select(.kind == "Role" and .metadata.name == "fleet-deploy") | .metadata.namespace) = "tac-beta-2"' "in \[tac-beta-2\]"
breach "an unlabelled namespace" '(select(.kind == "Namespace") | .metadata.labels) = {}' "labelled tacplus.dev/deployment=\[\]"
breach "another namespace" '(select(.kind == "Namespace") | .metadata.name) = "kube-system"' "the Namespace kube-system"

# deploymentproxy's file: nothing namespaced outside deploymentproxy.
rm -rf "$work/bad" && cp -R "$work/good" "$work/bad"
yq -i '(select(.kind == "ConfigMap") | .metadata.namespace) = "letsencrypt"' "$work/bad/00-deploymentproxy.yaml"
"$here/ci/policy.sh" "$work/bad" > "$work/log" 2>&1 || grep -q 'ConfigMap deploymentproxy in \[letsencrypt\]' "$work/log" &&
  ! "$here/ci/policy.sh" "$work/bad" >/dev/null 2>&1 &&
  ok "breach: deploymentproxy's object in another namespace" || fail "deploymentproxy's object in letsencrypt: $(cat "$work/log")"

[ "$failed" = 0 ] && echo "policy_test: all passed" || { echo "policy_test: failed"; exit 1; }
