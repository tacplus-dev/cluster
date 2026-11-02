#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Deletes one deployment from the cluster `tacplus`, with its tenants' data (the delete-deployment job, Jody's
# only): the namespace tac-<name>, then whatever tenant namespace of it deploymentproxy has not deleted already
# (labelled deploymentproxy.tacplus.dev/deployment=<name>). It refuses a deployment deployments.yaml still lists
# (remove the entry and apply first, or the next apply recreates it), and a namespace that is not that
# deployment's (no tacplus.dev/deployment=<name> label). Nothing else is ever deleted.
#
#   DELETE_DEPLOYMENT=<name> ci/delete-deployment.sh [DEPLOYMENTS]   # deployments.yaml by default
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
deployments=${1:-$here/../deployments.yaml}
d=${DELETE_DEPLOYMENT:-}
source "$here/kube.sh"
die() { echo "delete-deployment: $*" >&2; exit 1; }

[ -n "$d" ] || die "no DELETE_DEPLOYMENT: set it to the deployment to delete when you run the job (README, Deleting a deployment)"
[[ $d =~ ^[a-z][a-z0-9-]{0,15}$ ]] || die "[$d] is not a deployment name"
! yq -e ".deployments[] | select(.name == \"$d\")" "$deployments" >/dev/null 2>&1 ||
  die "$d is still in deployments.yaml: remove its entry and apply first, or the next apply recreates it"
kube_check

ns=tac-$d
json=$(kubectl get namespace "$ns" -o json 2>/dev/null) || die "there is no namespace $ns"
label=$(jq -r '.metadata.labels["tacplus.dev/deployment"] // ""' <<<"$json")
[ "$label" = "$d" ] || die "$ns is labelled tacplus.dev/deployment=[$label], not $d: not a deployment namespace, not deleted"

tenants() {
  kubectl get namespaces -l "deploymentproxy.tacplus.dev/deployment=$d" -o json |
    jq -r --arg p "$ns-" '.items[].metadata.name | select(startswith($p))'
}
echo "delete-deployment: deleting $ns and its tenant namespaces: $(tenants | tr '\n' ' ')"
kubectl delete namespace "$ns" --wait=true --timeout=15m
left=$(tenants)
if [ -n "$left" ]; then
  echo "delete-deployment: deleting the tenant namespaces deploymentproxy left: $(echo $left)"
  kubectl delete namespace $left --wait=true --timeout=15m
fi
[ -z "$(tenants)" ] || die "tenant namespaces of $d are still there: $(tenants | tr '\n' ' ')"
echo "delete-deployment: $d deleted"
