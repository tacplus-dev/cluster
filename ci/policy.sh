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
#                               service account only of tac-<name>. The deploy account's Role fleet-deploy and its
#                               RoleBinding always, fleet-deploy granting only get, list and watch on
#                               TenantNamespaces; deploymentproxy's Role deploymentproxy-tenantnamespaces and its
#                               operator's RoleBinding both, or neither (a deployment without an operator); the
#                               operator's own Role deployment-operator and its RoleBinding both, only with
#                               deploymentproxy's, each grant within fleet-deploy (#59).
#   00-deploymentproxy.yaml     namespaced objects only in deploymentproxy; cluster-scoped, only the Namespace
#                               deploymentproxy, CRDs, ClusterRoles and ClusterRoleBindings.
#   20-ci.yaml                  namespaced objects only in ci, and only service accounts, ConfigMaps, NetworkPolicies,
#                               Roles, RoleBindings and Deployments; cluster-scoped, only the Namespace ci, the
#                               admission policy ci-pods, the runner managers' PriorityClass ci-runner-manager, the
#                               report builds' build-report and control's jobs' control-job (no ClusterRole, no
#                               ClusterRoleBinding): every manager runs at ci-runner-manager, and it is above the
#                               jobs (0, which set none but build-report's and control's), preempts them, is no
#                               default and no system priority (#39); the report builds' jobs alone run at
#                               build-report (#42), control's alone at control-job (#49: infra's and kick's preempt
#                               them), each below the jobs' (0) and at or above the autoscaler's expendable cutoff
#                               (-10), never preempting, no default. A Role
#                               names only
#                               what the Kubernetes executor needs (CI_RESOURCES below), every verb, no escalate,
#                               bind or impersonate; a RoleBinding binds a Role to service accounts of ci. The
#                               runners' pods and their jobs' pods (each runner's config.toml): images by digest, no
#                               privileged container, host path, host namespace or Docker socket; build jobs only on
#                               the spot pool, every other job never there; control's and manager's jobs alone
#                               tolerate the looper pool, preferring the normal pool, and no workload in any file
#                               does (#47, #60); the infra
#                               pipelines' tags (cloud, cluster,
#                               deploy) on the runner infra alone, which takes no other and protected refs only;
#                               kick (the looper's kicker and plan, #36) on the runner kick alone, which takes no
#                               other but arm64; build-report (the report builds, #42) on the runner build-report
#                               alone, which takes no other but arm64 and places its jobs as build's (ci_runner
#                               below); build-light (tacplus-dev/build's pending, plan and reports, #51) on the
#                               runner build-light alone, which takes no other but arm64, never build; manager (the
#                               looper's managers, #60) on the runner manager alone, which takes no other but arm64,
#                               never control. A runner
#                               manager on a read-only root filesystem has a writable emptyDir wherever GitLab Runner
#                               writes (RUNNER_WRITES below; #37).
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
# grants FILE ROLE: each "group/resource verb" the Role ROLE in FILE grants, one a line, sorted.
grants() { R=$2 yq ea -N 'select(.kind == "Role" and .metadata.name == strenv(R)) | .rules[] | .apiGroups[] as $g | .resources[] as $r | .verbs[] as $v | $g + "/" + $r + " " + $v' "$1" | sort -u; }
# has FILE KIND NAME: FILE holds the object KIND NAME.
has() { [ "$(K=$2 N=$3 yq ea '[select(.kind == strenv(K) and .metadata.name == strenv(N))] | length' "$1")" != 0 ]; }

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

# RUNNER_WRITES: where GitLab Runner's manager writes (19.5.3), each path|why. On a read-only root filesystem
# (#29), each must be a writable emptyDir; /tmp is TMPDIR when the container sets it. #37: without /tmp, every job
# failed at once with runner_system_failure and an empty log.
RUNNER_WRITES="/tmp|each job's log buffer, before the job starts (helpers/trace/buffer.go: os.CreateTemp)
/home/gitlab-runner|its working directory (--working-directory)
/home/gitlab-runner/.gitlab-runner|its config.toml (the chart's entrypoint copies it there; the runner rewrites it)"

# ci_runner_writes WHAT SPEC: in a runner manager's pod spec (JSON), every container on a read-only root filesystem
# has each path of RUNNER_WRITES on a writable emptyDir: the deepest mount at or above it is an emptyDir, not
# readOnly.
ci_runner_writes() {
  local what=$1 m
  while IFS= read -r m; do breach "$what: $m"; done < <(jq -r --arg writes "$RUNNER_WRITES" '
    ([(.volumes // [])[] | select(has("emptyDir")) | .name]) as $empty |
    ($writes | split("\n") | map(split("|") | {path: .[0], why: .[1]})) as $writes |
    (.containers // [])[] | select(.securityContext.readOnlyRootFilesystem == true) | . as $c |
    ([(.env // [])[] | select(.name == "TMPDIR") | .value][0] // "/tmp" | rtrimstr("/")) as $tmp |
    $writes[] | (if .path == "/tmp" then .path = $tmp else . end) | . as $w |
    ([($c.volumeMounts // [])[] | (.mountPath | rtrimstr("/")) as $p |
      select($w.path == $p or ($w.path | startswith($p + "/"))) | .path = $p] |
      max_by(.path | length)) as $m |
    if $m == null then "the container \($c.name) writes \($w.path), \($w.why), on a read-only root filesystem: no volume is mounted there"
    elif $m.readOnly == true then "the container \($c.name) writes \($w.path), \($w.why), but its mount \($m.name) is readOnly"
    elif ($empty | index($m.name)) == null then "the container \($c.name) writes \($w.path), \($w.why), but its mount \($m.name) is not an emptyDir"
    else empty end' <<<"$2")
}

# ci_runner FILE DEPLOYMENT RENDER: the runner DEPLOYMENT's config.toml (its ConfigMap's config.template.toml) keeps
# the job rules: one Kubernetes runner, its jobs in ci, as ci-job without a token, images by digest, no privilege,
# no host path, no Docker socket, no capability added, no priority class but the report builds' and control's (below), nothing a
# job may override but its resources up to a ceiling;
# a default and a ceiling for CPU and memory. A runner tagged build places its jobs on the spot pool only (its node
# selector and the spot taint's toleration), takes no other tag but arm64, runs them non-root, and is the only one
# whose build container may be Unconfined; any other runner's jobs never tolerate spot, refuse a spot node, and may
# not escalate privilege. Only control's and manager's jobs tolerate the looper pool's taint (#47, #60), and then prefer the normal pool, so
# they overflow there only when it is full; no runner's jobs select it. No runner takes a VM runner's tag (autoscale,
# autoscale-16, gce): GitLab gives a job to whichever runner holding its tags asks first. The infra pipelines' tags (cloud, cluster, deploy: tacplus-dev/cloud's,
# this one's and fleet-seatrials' deploy, which hold WIF to the projects and cluster-admin) are the runner infra's
# alone (#25): no other runner takes one, infra takes no other tag (no agent's or build's job lands beside their
# credentials), and infra is registered for protected refs only (tacplus.dev/runner-protected). The tag kick is the
# runner kick's alone (#36), and kick takes no other but arm64: its slots are the kicker's and the plan's, never a
# report's, so they never wait behind control's. The tag build-report is the runner build-report's alone (#42;
# tacplus-dev/looper#209), which takes no other but arm64, places its jobs as a build runner's (the spot pool, non-root,
# its build container alone Unconfined), and runs them at the PriorityClass build-report, below a land's build's, which
# preempt them. control's jobs run at the PriorityClass control-job (#49), below infra's and kick's, which preempt them
# when the normal pool is full of control's; no other runner's jobs set a priority class. The tag build-light is the
# runner build-light's alone (#51; tacplus-dev/cloud#100), and build-light takes no other but arm64: above all not build,
# which would bring the gates and security jobs onto the normal pool; its slots are the light builds' (pending, plan,
# the reports), never behind a gates or security job. The tag manager is the runner manager's alone (#60), and manager
# takes no other but arm64: above all not control, which would fill its slots with reports; its slots are the
# looper's managers', which merge, never behind a report.
ci_runner() {
  local b=$1 d=$2 render=$3 tags protected token secret toml json m
  tags=$(D=$d yq 'select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.template.metadata.annotations."tacplus.dev/runner-tags" // ""' "$render")
  protected=$(D=$d yq 'select(.kind == "Deployment" and .metadata.name == strenv(D)) | .spec.template.metadata.annotations."tacplus.dev/runner-protected" // ""' "$render")
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
  while IFS= read -r m; do breach "$b: the runner $d: $m"; done < <(jq -r --arg tags "$tags" --arg runner "$d" --arg protected "$protected" '
    ($tags | split(",")) as $tags | ($tags | index("build") != null) as $build | ($runner == "gitlab-runner-infra") as $infra |
    ($runner == "gitlab-runner-kick") as $kick | ($runner == "gitlab-runner-build-report") as $report |
    ($runner == "gitlab-runner-control") as $control | ($runner == "gitlab-runner-build-light") as $light |
    ($runner == "gitlab-runner-manager") as $manager |
    ["cloud", "cluster", "deploy"] as $infra_tags |
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
    (if $report then
      (select($k.priority_class_name != "build-report") | "its jobs do not run at the report builds\u0027 priority (priority_class_name = \"build-report\"): a land\u0027s build would wait for them to end")
    elif $control then
      (select($k.priority_class_name != "control-job") | "its jobs do not run at control\u0027s priority (priority_class_name = \"control-job\"): infra\u0027s and kick\u0027s jobs would wait Pending for them to end")
    else
      (select($k | has("priority_class_name")) | "its jobs set a priority class (priority_class_name): only the runner managers run above the jobs, and the report builds and control\u0027s below them")
    end),
    (select($k.service_account != "ci-job") | "its jobs run as [\($k.service_account // "")], not ci-job"),
    (select($k.automount_service_account_token != false) | "its jobs get a service account token"),
    ($tags[] | select(IN("autoscale", "autoscale-16", "gce")) | "takes a tag of the VM runners (\(.)): GitLab would give it their jobs"),
    (if $infra then
      (($tags - $infra_tags)[] | "takes a tag that is not cloud, cluster or deploy (\(.)): a job tagged for it would run beside the infra pipelines\u0027 credentials"),
      (select($protected != "true") | "is not protected refs only (tacplus.dev/runner-protected): it holds the infra pipelines\u0027 tags")
    else
      ($tags[] | select(IN($infra_tags[])) | "takes a tag of the infra pipelines (\(.)): only the runner infra, protected refs only, takes cloud, cluster and deploy")
    end),
    (if $kick then
      (($tags - ["arm64", "kick"])[] | "takes a tag that is not arm64 or kick (\(.)): its jobs would hold the slots the kicker and the plan keep"),
      (select($tags | index("kick") == null) | "does not take kick: the kicker and the plan would have no runner of their own")
    else
      ($tags[] | select(. == "kick") | "takes kick, the kick runner\u0027s tag: the kicker and the plan would queue behind its jobs")
    end),
    (if $light then
      (($tags - ["arm64", "build-light"])[] | "takes a tag that is not arm64 or build-light (\(.)): build holds the gates and security jobs, which need a spot node; its jobs would run on the normal pool"),
      (select($tags | index("build-light") == null) | "does not take build-light: the light builds (pending, plan, reports) would have no runner of their own")
    else
      ($tags[] | select(. == "build-light") | "takes build-light, the light builds\u0027 runner\u0027s tag: pending, plan and the reports would queue behind its jobs")
    end),
    (if $manager then
      (($tags - ["arm64", "manager"])[] | "takes a tag that is not arm64 or manager (\(.)): its slots would fill with jobs that are not the managers\u0027, which would wait behind them"),
      (select($tags | index("manager") == null) | "does not take manager: the managers would have no runner of their own")
    else
      ($tags[] | select(. == "manager") | "takes manager, the manager runner\u0027s tag: the managers would queue behind its jobs")
    end),
    (if $report then
      (($tags - ["arm64", "build-report"])[] | "takes a tag that is not arm64 or build-report (\(.)): its jobs would run at the report builds\u0027 priority, preempted"),
      (select($tags | index("build-report") == null) | "does not take build-report: the report builds would have no runner of their own")
    else
      ($tags[] | select(. == "build-report") | "takes build-report, the report builds\u0027 runner\u0027s tag: report builds would run at a land\u0027s priority")
    end),
    (("cpu_request", "cpu_limit", "memory_request", "memory_limit") as $c |
      if $k[$c] == null then "no default \($c)" elif $k[$c + "_overwrite_max_allowed"] == null then "no ceiling for \($c) (\($c)_overwrite_max_allowed)" else empty end),
    ([$k | paths(. == "Unconfined") | map(tostring) | join(".")] as $u |
      ($u - (if $build or $report then ["build_container_security_context.seccomp_profile.type", "build_container_security_context.app_armor_profile.type"] else [] end))[] |
      "its jobs are Unconfined (\(.))"),
    (select(($k.node_selector // {}) | has("looper")) | "its jobs select a looper node"),
    (if $control or $manager then
      (select((($k.node_tolerations // {}) | keys | any(startswith("looper"))) and
          ([$k.affinity.node_affinity.preferred_during_scheduling_ignored_during_execution[]? | select(.weight > 0) | .preference |
            any(.match_expressions[]?; .key == "looper" and .operator == "NotIn" and ((.values // []) | index("true") != null))] |
            any | not)) |
        "its jobs tolerate the looper taint but do not prefer the normal pool (a preferred node affinity looper NotIn [true]): they would fill the looper pool first and keep it from 0")
    else
      (($k.node_tolerations // {}) | keys[] | select(startswith("looper")) | "its jobs tolerate the looper taint (\(.)): only control\u0027s and manager\u0027s jobs overflow onto the looper pool")
    end),
    if $build or $report then
      (select($build and (($tags - ["arm64", "build"]) | length > 0)) | "takes build with other tags (\($tags | join(", "))): their jobs would run on spot"),
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
  # The looper pool (#47; tacplus-dev/cloud#95), tainted looper=true:NoSchedule: only the control and manager runners' jobs land
  # there (their config.toml: ci_runner), so it scales back to 0 when they end. No workload here tolerates it.
  while IFS= read -r w; do
    breach "$b: the $w tolerates the looper taint: only the control and manager runners' jobs run on the looper pool"
  done < <(yq -N 'select([.. | select(tag == "!!map" and has("tolerations")) | .tolerations[]? |
    select(.key == "looper" or ((.key // "") == "" and .operator == "Exists"))] | length > 0) | .kind + " " + .metadata.name' "$f")
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
      has "$f" Role fleet-deploy || breach "$b: no Role fleet-deploy"
      has "$f" RoleBinding fleet-deploy || breach "$b: no RoleBinding fleet-deploy"
      if has "$f" Role deploymentproxy-tenantnamespaces; then
        has "$f" RoleBinding deploymentproxy-tenantnamespaces || breach "$b: the Role deploymentproxy-tenantnamespaces without its RoleBinding"
      else
        ! has "$f" RoleBinding deploymentproxy-tenantnamespaces || breach "$b: the RoleBinding deploymentproxy-tenantnamespaces without its Role"
      fi
      # The operator's own Role (#59): with its binding, only beside deploymentproxy's (a deployment with an
      # operator), and nothing the deploy account does not hold itself.
      if has "$f" Role deployment-operator; then
        has "$f" RoleBinding deployment-operator || breach "$b: the Role deployment-operator without its RoleBinding"
        has "$f" Role deploymentproxy-tenantnamespaces || breach "$b: the Role deployment-operator, but no deploymentproxy Role"
        while read -r grant; do
          breach "$b: the Role deployment-operator grants $grant, which fleet-deploy does not"
        done < <(comm -23 <(grants "$f" deployment-operator) <(grants "$f" fleet-deploy))
      else
        ! has "$f" RoleBinding deployment-operator || breach "$b: the RoleBinding deployment-operator without its Role"
      fi
      # The deploy account reads its TenantNamespaces; only the operator's account writes them.
      while read -r grant; do
        [[ $grant =~ ^deploymentproxy\.tacplus\.dev/tenantnamespaces\ (get|list|watch)$ ]] ||
          breach "$b: the Role fleet-deploy grants ${grant#* } on ${grant% *}"
      done < <(grants "$f" fleet-deploy | grep '^deploymentproxy\.tacplus\.dev/')
      ;;
    20-ci.yaml)
      runners=()
      while IFS='|' read -r i kind ns name; do
        case $kind in
          Namespace)
            [ "$name" = ci ] || breach "$b: the Namespace $name, not ci" ;;
          ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding)
            [ "$name" = ci-pods ] || breach "$b: the $kind $name, not ci-pods" ;;
          PriorityClass)
            [ "$name" = ci-runner-manager ] || [ "$name" = build-report ] || [ "$name" = control-job ] ||
              breach "$b: the PriorityClass $name, not ci-runner-manager, build-report or control-job" ;;
          ServiceAccount|ConfigMap|NetworkPolicy|Role|RoleBinding|Deployment)
            [ "$ns" = ci ] || breach "$b: $kind $name in [$ns], not ci" ;;
          *) breach "$b: $kind $name: ci holds only its Namespace, its admission policy, the runner managers', the report builds' and control's PriorityClasses, and service accounts, ConfigMaps, NetworkPolicies, Roles, RoleBindings and Deployments in ci" ;;
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
            ci_runner_writes "$b: the Deployment $name" "$(yq ea -o=json -I=0 "$pod.spec" "$f")"
            [ "$(yq ea "$pod.spec.tolerations // [] | map(select(.key == \"spot\")) | length" "$f")" = 0 ] ||
              breach "$b: the Deployment $name tolerates spot: a runner manager runs on the normal pool"
            [ "$(yq ea "$pod.spec.priorityClassName // \"\"" "$f")" = ci-runner-manager ] ||
              breach "$b: the Deployment $name does not run at the runner managers' priority (priorityClassName ci-runner-manager): a manager that cannot schedule takes its runner down"
            ;;
        esac
      done < <(yq -N '[document_index, .kind, .metadata.namespace // "", .metadata.name] | join("|")' "$f")
      [ "$(yq 'select(.kind == "Namespace") | .metadata.name' "$f")" = ci ] || breach "$b: no Namespace ci"
      # The runner managers' priority (#39): above the jobs' pods (0), preempting them, never the cluster's default,
      # and a user's (at most 1000000000, the system's above).
      if has "$f" PriorityClass ci-runner-manager; then
        pc='select(.kind == "PriorityClass" and .metadata.name == "ci-runner-manager")'
        [ "$(yq "$pc | .globalDefault // false" "$f")" = false ] || breach "$b: the PriorityClass ci-runner-manager is the cluster's default"
        [ "$(yq "$pc | .preemptionPolicy // \"PreemptLowerPriority\"" "$f")" = PreemptLowerPriority ] ||
          breach "$b: the PriorityClass ci-runner-manager does not preempt the jobs (preemptionPolicy PreemptLowerPriority)"
        value=$(yq "$pc | .value // 0" "$f")
        [[ $value =~ ^[1-9][0-9]{0,8}$ ]] ||
          breach "$b: the PriorityClass ci-runner-manager's value [$value] is not above the jobs' (0) and below the system's (1000000000)"
      else
        breach "$b: no PriorityClass ci-runner-manager"
      fi
      # The report builds' priority (#42) and control's jobs' (#49): below the jobs' (0: a land's build's, and infra's
      # and kick's, preempt them), at or above the cluster autoscaler's expendable cutoff (-10: below it, their pods
      # would scale nothing up), preempting nothing, never the cluster's default.
      for n in build-report control-job; do
        if has "$f" PriorityClass "$n"; then
          pc="select(.kind == \"PriorityClass\" and .metadata.name == \"$n\")"
          [ "$(yq "$pc | .globalDefault // false" "$f")" = false ] || breach "$b: the PriorityClass $n is the cluster's default"
          [ "$(yq "$pc | .preemptionPolicy // \"PreemptLowerPriority\"" "$f")" = Never ] ||
            breach "$b: the PriorityClass $n preempts (preemptionPolicy Never): its job would evict another's pod"
          value=$(yq "$pc | .value // 0" "$f")
          [[ $value =~ ^-([1-9]|10)$ ]] ||
            breach "$b: the PriorityClass $n's value [$value] is not below the jobs' (0) and at or above the autoscaler's expendable cutoff (-10)"
        else
          breach "$b: no PriorityClass $n"
        fi
      done
      [ ${#runners[@]} -gt 0 ] || breach "$b: no runner"
      for d in "${runners[@]}"; do ci_runner "$b" "$d" "$f"; done
      ;;
    *) breach "$b: not a file render.sh writes" ;;
  esac
done
[ "$breaches" = 0 ] && echo "policy: ${#files[@]} files keep the rules" || { echo "policy: $breaches breach(es)"; exit 1; }
