#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The scope of security-exceptions.yaml's KSV-0053 and KSV-0056 entries (#28), which looper-scan matches by id
# alone, so on any Role: no Role or ClusterRole in the tree grants exec or attach in pods (KSV-0053), or services,
# endpoints, endpointslices, networkpolicies or ingresses (KSV-0056), with any verb, but the grants by design below,
# each on the resources it has today, and none by `*`. A new grant of them is a new decision: its own entry's reason,
# and its line here. Goes once looper-scan scopes an exception by its `where` (tacplus-dev/looper#182), when the
# entries become one per file.
#
#   Role gitlab-runner-*        pods/exec, pods/attach, services: GitLab's Kubernetes executor runs the job's script
#                               by attaching and exec-ing into the pod it creates, with its services
#                               (gitlab-runner/values.yaml, rendered in 20-ci.yaml)
#   Role fleet-deploy           services, endpoints (read), networkpolicies: what a fleet's helm release ships in its
#                               own namespace (render.sh, rendered in each 10-deployment-<name>.yaml)
#   ClusterRole deploymentproxy networkpolicies, delete only: to remove those earlier versions kept in tenant
#                               namespaces (#14; deploymentproxy/release, rendered in 00-deploymentproxy.yaml)
#
#   ci/grants.sh [FILE...]   # every YAML file git tracks but Helm's templates (their render is in the tree) by
#                            # default; exit 0: none breaks it; else each breach, one per line. Needs bash, git, yq.
set -uo pipefail
# The resources, in any group, that KSV-0053 and KSV-0056 watch.
WATCHED=" pods/exec pods/attach services endpoints endpointslices networkpolicies ingresses "
# KIND NAME (a glob) GROUP/RESOURCE..., "" the core group.
ALLOWED=(
  "Role gitlab-runner-* /pods/exec /pods/attach /services"
  "Role fleet-deploy /services /endpoints networking.k8s.io/networkpolicies"
  "ClusterRole deploymentproxy networking.k8s.io/networkpolicies"
)
if [ $# = 0 ]; then
  cd "$(dirname "$0")/.." || exit 1
  mapfile -t files < <(git ls-files '*.yaml' '*.yml' | grep -v '/templates/')
  set -- "${files[@]}"
fi
breaches=0
breach() { echo "grants: $*"; breaches=$((breaches + 1)); }
# allowed KIND NAME GRANT: GRANT is one of KIND NAME's grants by design.
allowed() {
  local a kind name grants
  for a in "${ALLOWED[@]}"; do
    read -r kind name grants <<<"$a"
    # shellcheck disable=SC2053 # NAME is a glob
    [ "$1" = "$kind" ] && [[ $2 == $name ]] && [[ " $grants " == *" $3 "* ]] && return 0
  done
  return 1
}
for f in "$@"; do
  # Each document on its own (yq e): one row per group and resource of each rule.
  if ! grants=$(yq e -o tsv 'select(.kind == "Role" or .kind == "ClusterRole") | .kind as $k | .metadata.name as $n |
      .rules[]? as $r | $r.apiGroups[]? as $g | $r.resources[]? as $x | [$k, $n, $g + "/" + $x]' "$f" 2>&1); then
    breach "$f: not read: $grants"
    continue
  fi
  while IFS=$'\t' read -r kind name grant; do
    [ -n "$grant" ] || continue
    resource=${grant#*/}
    [ "$resource" = "*" ] || [[ $WATCHED == *" $resource "* ]] || continue
    allowed "$kind" "$name" "$grant" || breach "$f: $kind $name grants ${grant#/}"
  done <<<"$grants"
done
[ "$breaches" = 0 ]
