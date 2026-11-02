#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The rules a render must keep before anything reaches the cluster (validate job; tests/policy_test.sh):
#
#   10-deployment-<name>.yaml   only the Namespace tac-<name>, labelled tacplus.dev/deployment=<name>, and Roles
#                               and RoleBindings in it. A Role names every group, resource and verb (no `*`), only
#                               namespaced resources it knows (NAMESPACED below), no escalate, bind or impersonate,
#                               no non-resource URLs. A RoleBinding binds a Role, never a ClusterRole, and a
#                               service account only of tac-<name>.
#   00-deploymentproxy.yaml     namespaced objects only in deploymentproxy; cluster-scoped, only the Namespace
#                               deploymentproxy, CRDs, ClusterRoles and ClusterRoleBindings.
#
#   ci/policy.sh OUT     # exit 0: every file keeps them; else each breach, one per line. Needs bash, yq.
set -uo pipefail
out=${1:?usage: ci/policy.sh OUT}
# group/resource pairs that are namespaced, which a deployment's Role may name ("" is the core group).
NAMESPACED=" /configmaps /secrets /services /serviceaccounts /persistentvolumeclaims /pods /pods/log /endpoints
  /resourcequotas /limitranges /events /podtemplates /replicationcontrollers events.k8s.io/events
  apps/deployments apps/statefulsets apps/daemonsets apps/replicasets apps/controllerrevisions batch/jobs
  batch/cronjobs networking.k8s.io/networkpolicies networking.k8s.io/ingresses policy/poddisruptionbudgets
  rbac.authorization.k8s.io/roles rbac.authorization.k8s.io/rolebindings coordination.k8s.io/leases
  autoscaling/horizontalpodautoscalers discovery.k8s.io/endpointslices deploymentproxy.tacplus.dev/tenantnamespaces "
NAMESPACED=" $(echo $NAMESPACED) "
breaches=0
breach() { echo "policy: $*"; breaches=$((breaches + 1)); }

shopt -s nullglob
files=("$out"/*.yaml)
[ ${#files[@]} -gt 0 ] || { echo "policy: no render in $out" >&2; exit 1; }
plain=$(mktemp)
trap 'rm -f "$plain"' EXIT
for b in "${files[@]##*/}"; do
  # Without comments, which yq would carry into the answers.
  f=$plain
  yq '... comments=""' "$out/$b" > "$f" || { breach "$b: not YAML"; continue; }
  case $b in
    00-deploymentproxy.yaml)
      while IFS='|' read -r kind ns name; do
        case $kind in
          Namespace) [ "$name" = deploymentproxy ] || breach "$b: the Namespace $name" ;;
          CustomResourceDefinition|ClusterRole|ClusterRoleBinding) ;;
          *) [ "$ns" = deploymentproxy ] || breach "$b: $kind $name in [$ns], not deploymentproxy" ;;
        esac
      done < <(yq -N '[.kind, .metadata.namespace // "", .metadata.name] | join("|")' "$f")
      ;;
    10-deployment-*.yaml)
      d=${b#10-deployment-}; d=${d%.yaml}; tns=tac-$d
      while IFS='|' read -r i kind ns name; do
        case $kind in
          Namespace)
            [ "$name" = "$tns" ] || breach "$b: the Namespace $name, not $tns"
            label=$(yq ea "select(document_index == $i) | .metadata.labels.\"tacplus.dev/deployment\" // \"\"" "$f")
            [ "$label" = "$d" ] || breach "$b: the Namespace $name is labelled tacplus.dev/deployment=[$label], not $d" ;;
          Role)
            [ "$ns" = "$tns" ] || breach "$b: the Role $name in [$ns], not $tns"
            r="select(document_index == $i) | .rules"
            [ "$(yq ea "select(document_index == $i) | [.rules[] | select(has(\"nonResourceURLs\"))] | length" "$f")" = 0 ] || breach "$b: the Role $name names non-resource URLs"
            while IFS='|' read -r group resource verbs names; do
              [[ "$group $resource $verbs $names" != *'*'* ]] || breach "$b: the Role $name grants * ($group/$resource: $verbs)"
              [[ $NAMESPACED == *" $group/$resource "* ]] || breach "$b: the Role $name grants $group/$resource, not a namespaced resource it knows"
              for v in escalate bind impersonate; do
                [[ " $verbs " != *" $v "* ]] || breach "$b: the Role $name grants $v on $group/$resource"
              done
            done < <(yq ea -N "$r[] | .apiGroups[] as \$g | .resources[] as \$res | [\$g, \$res, (.verbs | join(\" \")), ((.resourceNames // []) | join(\" \"))] | join(\"|\")" "$f")
            ;;
          RoleBinding)
            [ "$ns" = "$tns" ] || breach "$b: the RoleBinding $name in [$ns], not $tns"
            ref=$(yq ea "select(document_index == $i) | .roleRef.kind" "$f")
            [ "$ref" = Role ] || breach "$b: the RoleBinding $name binds a $ref, not a Role"
            while IFS='|' read -r skind sname sns; do
              case $skind in
                ServiceAccount) [ "$sns" = "$tns" ] || breach "$b: the RoleBinding $name binds the service account $sname of [$sns]" ;;
                User) ;;
                *) breach "$b: the RoleBinding $name binds the $skind $sname" ;;
              esac
            done < <(yq ea -N "select(document_index == $i) | .subjects[] | [.kind, .name, .namespace // \"\"] | join(\"|\")" "$f")
            ;;
          *) breach "$b: $kind $name: a deployment holds only its Namespace, Roles and RoleBindings" ;;
        esac
      done < <(yq -N '[document_index, .kind, .metadata.namespace // "", .metadata.name] | join("|")' "$f")
      ;;
    *) breach "$b: not a file render.sh writes" ;;
  esac
done
[ "$breaches" = 0 ] && echo "policy: ${#files[@]} files keep the rules" || { echo "policy: $breaches breach(es)"; exit 1; }
