# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by ci/plan.sh, ci/apply.sh and ci/delete-deployment.sh: what they check before they read or change the
# cluster.

# kube_check: kubectl's current context is the cluster CLUSTER (dev), and this account is cluster-admin there.
# Until the hub has granted it (README, What the hub does), it returns 3, saying "no cluster grant yet".
kube_check() {
  local cluster=${CLUSTER:-dev} ctx who
  ctx=$(kubectl config current-context 2>/dev/null) || { echo "kube: no current context" >&2; return 1; }
  case $ctx in
    *_"$cluster") ;;
    *) echo "kube: the context is $ctx, not the cluster $cluster" >&2; return 1 ;;
  esac
  if [ "$(kubectl auth can-i '*' '*' --all-namespaces 2>/dev/null)" != yes ]; then
    who=$(kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null) || who=
    echo "kube: no cluster grant yet: ${who:-the account of this job} is not cluster-admin on $cluster (README, What the hub does)" >&2
    return 3
  fi
}

# kube_object_names FILE: each object of a render, one per line, named as kubectl diff names them
# (group.version.Kind.namespace.name).
kube_object_names() {
  yq -N '(.apiVersion | sub("/", ".")) + "." + .kind + "." + (.metadata.namespace // "") + "." + .metadata.name' "$1"
}
