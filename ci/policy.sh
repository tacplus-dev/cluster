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
#   20-ci.yaml                  namespaced objects only in ci, and only service accounts, ConfigMaps, NetworkPolicies,
#                               Roles, RoleBindings and Deployments; cluster-scoped, only the Namespace ci and the
#                               admission policy ci-pods (no ClusterRole, no ClusterRoleBinding). A Role names only
#                               what the Kubernetes executor needs (CI_RESOURCES below), every verb, no escalate,
#                               bind or impersonate; a RoleBinding binds a Role to service accounts of ci. The
#                               runners' pods and their jobs' pods (each runner's config.toml): images by digest, no
#                               privileged container, host path, host namespace or Docker socket; build jobs only on
#                               the spot pool, every other job never there (ci_runner below).
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
# What a runner's Role may name in ci: what GitLab's Kubernetes executor needs (gitlab-runner/values.yaml).
CI_RESOURCES=" /pods /pods/attach /pods/exec /pods/log /secrets /serviceaccounts /services /events "
breaches=0
breach() { echo "policy: $*"; breaches=$((breaches + 1)); }

# ci_pod WHAT SPEC: a pod spec (JSON) in ci keeps the pod rules: every image by digest; no privileged container, no
# added capability, no host path, no host network, PID or IPC, no Docker socket.
ci_pod() {
  local what=$1 m
  while IFS= read -r m; do breach "$what: $m"; done < <(jq -r '
    ((.containers // []) + (.initContainers // [])) as $c |
    ($c[] | select((.image // "") | test("@sha256:[0-9a-f]{64}$") | not) | "the image [\(.image // "")] is not pinned by digest"),
    ($c[] | select(.securityContext.privileged == true) | "the container \(.name) is privileged"),
    ($c[] | select((.securityContext.capabilities.add // []) | length > 0) | "the container \(.name) adds capabilities"),
    ((.volumes // [])[] | select(has("hostPath")) | "the volume \(.name) is a host path"),
    (("hostNetwork", "hostPID", "hostIPC") as $h | select(.[$h] == true) | "\($h)"),
    (select([.. | strings | select(test("docker\\.sock"))] | length > 0) | "the Docker socket")' <<<"$2")
}

# ci_runner FILE DEPLOYMENT RENDER: the runner DEPLOYMENT's config.toml (its ConfigMap's config.template.toml) keeps
# the job rules: one Kubernetes runner, its jobs in ci, as ci-job without a token, images by digest, no privilege,
# no host path, no Docker socket, no capability added, nothing a job may override but its resources up to a ceiling;
# a default and a ceiling for CPU and memory. A runner tagged build places its jobs on the spot pool only (its node
# selector and the spot taint's toleration), takes no other tag but arm64, runs them non-root, and is the only one
# whose build container may be Unconfined; any other runner's jobs never tolerate spot, refuse a spot node, and may
# not escalate privilege. No runner takes a VM runner's tag (autoscale, autoscale-16, gce): GitLab gives a job to
# whichever runner holding its tags asks first.
ci_runner() {
  local b=$1 d=$2 render=$3 tags token secret toml json m
  tags=$(D=$d yq 'select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.template.metadata.annotations."tacplus.dev/runner-tags" // ""' "$render")
  token=$(D=$d yq 'select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.template.metadata.annotations."tacplus.dev/runner-token" // ""' "$render")
  secret=$(D=$d yq 'select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.template.metadata.annotations."tacplus.dev/runner-token-secret" // ""' "$render")
  [ -n "$tags" ] || breach "$b: the runner $d has no tags (tacplus.dev/runner-tags)"
  [[ $token =~ ^projects/[a-z0-9-]+/secrets/[A-Za-z0-9_-]+/versions/[1-9][0-9]*$ ]] ||
    breach "$b: the runner $d's token [$token] is not a Secret Manager version"
  [ "$(D=$d yq ea '[select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.template.spec.volumes[] | .projected.sources[]? | .secret.name] | join(" ")' "$render")" = "$secret" ] ||
    breach "$b: the runner $d does not mount its token's Secret [$secret]"
  toml=$(D=$d yq 'select(.kind == "ConfigMap" and .metadata.name == strenv(D)) | .data."config.template.toml" // ""' "$render")
  [ -n "$toml" ] || { breach "$b: the runner $d has no config.template.toml"; return; }
  json=$(yq -p toml -o json -I=0 <<<"$toml") || { breach "$b: the runner $d's config.template.toml is not TOML"; return; }
  while IFS= read -r m; do breach "$b: the runner $d: $m"; done < <(jq -r --arg tags "$tags" '
    ($tags | split(",")) as $tags | ($tags | index("build") != null) as $build |
    if (.runners | length) != 1 then "has \(.runners | length) [[runners]], not one" else
    .runners[0] as $r | ($r.kubernetes // {}) as $k |
    (select($r.executor != "kubernetes") | "the executor is \($r.executor // "none"), not kubernetes"),
    (select($k.namespace != "ci") | "its jobs run in [\($k.namespace // "")], not ci"),
    (("image", "helper_image") as $i | select(($k[$i] // "") | test("@sha256:[0-9a-f]{64}$") | not) | "its \($i) [\($k[$i] // "")] is not pinned by digest"),
    (select($k.privileged == true) | "its jobs are privileged"),
    (select(($k.volumes.host_path // []) | length > 0) | "its jobs mount a host path"),
    (select([$r | .. | strings | select(test("docker\\.sock"))] | length > 0) | "its jobs reach the Docker socket"),
    (select(($k.cap_add // []) | length > 0) | "its jobs add capabilities"),
    ($k | keys[] | select(endswith("_overwrite_allowed")) | "a job may override what \(.) allows"),
    (select($k | has("pod_spec")) | "it patches its jobs pod spec (pod_spec)"),
    (select($k.service_account != "ci-job") | "its jobs run as [\($k.service_account // "")], not ci-job"),
    (select($k.automount_service_account_token != false) | "its jobs get a service account token"),
    ($tags[] | select(IN("autoscale", "autoscale-16", "gce")) | "takes a tag of the VM runners (\(.)): GitLab would give it their jobs"),
    (("cpu_request", "cpu_limit", "memory_request", "memory_limit") as $c |
      if $k[$c] == null then "no default \($c)" elif $k[$c + "_overwrite_max_allowed"] == null then "no ceiling for \($c) (\($c)_overwrite_max_allowed)" else empty end),
    ([$k | paths(. == "Unconfined") | map(tostring) | join(".")] as $u |
      ($u - (if $build then ["build_container_security_context.seccomp_profile.type", "build_container_security_context.app_armor_profile.type"] else [] end))[] |
      "its jobs are Unconfined (\(.))"),
    if $build then
      (select(($tags - ["arm64", "build"]) | length > 0) | "takes build with other tags (\($tags | join(", "))): their jobs would run on spot"),
      (select(($k.node_selector // {}).spot != "true") | "its build jobs do not select the spot pool (node_selector spot = \"true\")"),
      (select(($k.node_tolerations // {})["spot=true"] != "NoSchedule") | "its build jobs do not tolerate the spot pool (node_tolerations \"spot=true\" = \"NoSchedule\")"),
      (select($k.pod_security_context.run_as_non_root != true) | "its build jobs may run as root (pod_security_context run_as_non_root)")
    else
      (($k.node_tolerations // {}) | keys[] | select(startswith("spot")) | "its jobs tolerate the spot taint (\(.))"),
      (select(($k.node_selector // {}) | has("spot")) | "its jobs select a spot node"),
      (select([$k.affinity.node_affinity.required_during_scheduling_ignored_during_execution.node_selector_terms[]? |
          any(.match_expressions[]?; .key == "spot" and .operator == "NotIn" and ((.values // []) | index("true") != null))] |
          length == 0 or (all | not)) | "its jobs may land on a spot node (no required node affinity spot NotIn [true])"),
      (select($k.allow_privilege_escalation != false) | "its jobs may escalate privilege (allow_privilege_escalation = false)")
    end
    end' <<<"$json")
}

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
    20-ci.yaml)
      runners=()
      while IFS='|' read -r i kind ns name; do
        case $kind in
          Namespace)
            [ "$name" = ci ] || breach "$b: the Namespace $name, not ci" ;;
          ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding)
            [ "$name" = ci-pods ] || breach "$b: the $kind $name, not ci-pods" ;;
          ServiceAccount|ConfigMap|NetworkPolicy|Role|RoleBinding|Deployment)
            [ "$ns" = ci ] || breach "$b: $kind $name in [$ns], not ci" ;;
          *) breach "$b: $kind $name: ci holds only its Namespace, its admission policy, and service accounts, ConfigMaps, NetworkPolicies, Roles, RoleBindings and Deployments in ci" ;;
        esac
        case $kind in
          Role)
            [ "$(yq ea "select(document_index == $i) | [.rules[] | select(has(\"nonResourceURLs\"))] | length" "$f")" = 0 ] || breach "$b: the Role $name names non-resource URLs"
            while IFS='|' read -r group resource verbs names; do
              [[ "$group $resource $verbs $names" != *'*'* ]] || breach "$b: the Role $name grants * ($group/$resource: $verbs)"
              [[ $CI_RESOURCES == *" $group/$resource "* ]] || breach "$b: the Role $name grants $group/$resource, not what the Kubernetes executor needs"
              for v in escalate bind impersonate; do
                [[ " $verbs " != *" $v "* ]] || breach "$b: the Role $name grants $v on $group/$resource"
              done
            done < <(yq ea -N "select(document_index == $i) | .rules[] | .apiGroups[] as \$g | .resources[] as \$res | [\$g, \$res, (.verbs | join(\" \")), ((.resourceNames // []) | join(\" \"))] | join(\"|\")" "$f")
            ;;
          RoleBinding)
            ref=$(yq ea "select(document_index == $i) | .roleRef.kind" "$f")
            [ "$ref" = Role ] || breach "$b: the RoleBinding $name binds a $ref, not a Role"
            while IFS='|' read -r skind sname sns; do
              [ "$skind" = ServiceAccount ] && [ "$sns" = ci ] || breach "$b: the RoleBinding $name binds the $skind $sname of [$sns], not a service account of ci"
            done < <(yq ea -N "select(document_index == $i) | .subjects[] | [.kind, .name, .namespace // \"\"] | join(\"|\")" "$f")
            ;;
          Deployment)
            runners+=("$name")
            pod="select(document_index == $i) | .spec.template"
            ci_pod "$b: the Deployment $name" "$(yq ea -o=json -I=0 "$pod.spec" "$f")"
            [ "$(yq ea "$pod.spec.tolerations // [] | map(select(.key == \"spot\")) | length" "$f")" = 0 ] ||
              breach "$b: the Deployment $name tolerates spot: a runner manager runs on the normal pool"
            ;;
        esac
      done < <(yq -N '[document_index, .kind, .metadata.namespace // "", .metadata.name] | join("|")' "$f")
      [ "$(yq 'select(.kind == "Namespace") | .metadata.name' "$f")" = ci ] || breach "$b: no Namespace ci"
      [ ${#runners[@]} -gt 0 ] || breach "$b: no runner"
      for d in "${runners[@]}"; do ci_runner "$b" "$d" "$f"; done
      ;;
    *) breach "$b: not a file render.sh writes" ;;
  esac
done
[ "$breaches" = 0 ] && echo "policy: ${#files[@]} files keep the rules" || { echo "policy: $breaches breach(es)"; exit 1; }
