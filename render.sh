#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Renders what the pipeline applies to the cluster `dev`, one file per unit (README, What it manages):
#
#   OUT/00-deploymentproxy.yaml     deploymentproxy's release (deploymentproxy/release, checked against its
#                                   SHA256SUMS), its image pinned by digest (deploymentproxy/pin.yaml), each
#                                   deployment's own quota merged into its config, and, for each deployment with
#                                   an operator, its deploy account as its tenant namespaces' reader
#   OUT/06-kernel-tokenreview.yaml  the ClusterRole kernel-tokenreview: create tokenreviews, nothing else (#67)
#   OUT/10-deployment-<name>.yaml  per entry of DEPLOYMENTS: the namespace tac-<name> labelled
#                                   tacplus.dev/deployment=<name>, deploymentproxy's per-deployment Role for its
#                                   operator account (config/deployment-namespace) and the operator's own Role
#                                   and RoleBinding (deployment-operator, #59) unless it has none, and the
#                                   deploy account's Role and RoleBinding (fleet-deploy), in tac-<name> only, and
#                                   the ClusterRoleBinding tac-<name>-kernel-tokenreview of its service account
#                                   kernel to kernel-tokenreview (#67)
#   OUT/20-ci.yaml                  CI in the cluster (README, CI in the cluster): the namespace ci, the jobs' service
#                                   account ci-job (no token), the runner managers' PriorityClass ci-runner-manager
#                                   (above their jobs, #39), a land's build's jobs' build, the nightly's
#                                   build-nightly (#46) and the report builds' build-report (#42), each preempting
#                                   the next on the spot pool, control's jobs' control-job (below infra's and kick's,
#                                   #49), the NetworkPolicy that keeps its pods off the metadata
#                                   server, the admission policy refusing a privileged pod, a host path or a host
#                                   namespace in ci, and one GitLab Runner per gitlab-runner/runners/<runner>.yaml:
#                                   the chart (gitlab-runner/release, checked against its SHA256SUMS) rendered with
#                                   gitlab-runner/values.yaml, the runner's file and the images of
#                                   gitlab-runner/pin.yaml, its token's Secret Manager version, its tags and whether
#                                   it takes protected refs only on its pods, and its concurrent (the normal pool's
#                                   room, and the looper pool's, for the one that says pool: gitlab-runner/pool.yaml;
#                                   the spot pool's, for those on it that say pool: gitlab-runner/spot-pool.yaml)
#
# A removed entry renders nothing, and the apply never deletes (ci/apply.sh). Every entry is checked before
# anything is written; a bad one is refused with what is wrong.
#
#   ./render.sh [DEPLOYMENTS [OUT]]     # deployments.yaml, out/ by default; needs bash, yq (mikefarah v4), helm,
#                                       # sha256sum
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
deployments=${1:-$here/deployments.yaml}
out=${2:-$here/out}
release=$here/deploymentproxy/release
pin=$here/deploymentproxy/pin.yaml
runner_release=$here/gitlab-runner/release
runner_pin=$here/gitlab-runner/pin.yaml
die() { echo "render.sh: $*" >&2; exit 1; }

# The release, as fetched.
(cd "$release" && sha256sum --quiet --strict -c SHA256SUMS >/dev/null 2>&1) ||
  die "deploymentproxy/release does not match its SHA256SUMS: run deploymentproxy/fetch.sh, never edit it"
(cd "$runner_release" && sha256sum --quiet --strict -c SHA256SUMS >/dev/null 2>&1) ||
  die "gitlab-runner/release does not match its SHA256SUMS: run gitlab-runner/fetch.sh, never edit it"

# The entries (tacplus-dev/roadmap decisions/deployments-per-cluster-2026-10-26.md: a deployment name is at most
# 16 characters, [a-z0-9-], starting with a letter).
[ -f "$deployments" ] || die "no $deployments"
[ "$(yq '.deployments | tag' "$deployments")" = '!!seq' ] || die "$deployments has no deployments list"
n=$(yq '.deployments | length' "$deployments")
names=()
for ((i = 0; i < n; i++)); do
  e=".deployments[$i]"
  name=$(yq "$e.name // \"\"" "$deployments")
  [[ $name =~ ^[a-z][a-z0-9-]{0,15}$ ]] ||
    die "deployments[$i]: the name [$name] is not 1 to 16 characters of [a-z0-9-] starting with a letter"
  for other in "${names[@]}"; do [ "$other" != "$name" ] || die "$name: listed twice"; done
  names+=("$name")
  extra=$(yq "$e | keys | .[] | select(. != \"name\" and . != \"deployAccount\" and . != \"operator\" and . != \"gitlabProject\" and . != \"quota\")" "$deployments")
  [ -z "$extra" ] || die "$name: unknown field $(echo $extra)"
  account=$(yq "$e.deployAccount // \"\"" "$deployments")
  [[ $account =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] ||
    die "$name: deployAccount [$account] is not a Google service account (<name>@<project>.iam.gserviceaccount.com)"
  # The operator is optional (a deployment without one, test-idp, asks deploymentproxy for nothing); when set, a name.
  if [ "$(yq "$e | has(\"operator\")" "$deployments")" = true ]; then
    operator=$(yq "$e.operator // \"\"" "$deployments")
    [[ $operator =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "$name: operator [$operator] is not a service account name"
  fi
  project=$(yq "$e.gitlabProject // \"\"" "$deployments")
  [[ $project =~ ^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+$ ]] || die "$name: gitlabProject [$project] is not a GitLab project path"
  [ "$(yq "($e.quota // {}) | tag" "$deployments")" = '!!map' ] &&
    [ -z "$(yq "($e.quota // {}) | to_entries | .[] | select((.key | test(\"^[a-z0-9./]+\$\") | not) or (.value | tag) != \"!!str\") | .key" "$deployments")" ] ||
    die "$name: quota is not a map of resource names to quoted quantities (deploymentproxy's quota.deployments.<name>)"
done

# The runners (gitlab-runner/runners/<runner>.yaml): each sets only its tags, whether it takes protected refs only
# (tacplus.protected, false unless said), its token's version, its concurrency (1 to 99, or `pool`: the normal pool's
# room, or the spot pool's for a runner whose jobs are there, below), its name and its config.toml; the rest is
# gitlab-runner/values.yaml's, for every runner alike.
runners_dir=${RUNNERS:-$here/gitlab-runner/runners}
runners=()
for f in "$runners_dir"/*.yaml; do
  [ -e "$f" ] || continue
  r=$(basename "$f" .yaml)
  [[ $r =~ ^[a-z][a-z0-9-]{0,20}$ ]] || die "runner $r: the name is not 1 to 21 characters of [a-z0-9-] starting with a letter"
  extra=$(yq '(keys | .[] | select(. != "tacplus" and . != "concurrent" and . != "runners")),
    ((.runners // {}) | keys | .[] | select(. != "name" and . != "config") | "runners." + .),
    ((.tacplus // {}) | keys | .[] | select(. != "tags" and . != "protected" and . != "token") | "tacplus." + .)' "$f")
  [ -z "$extra" ] || die "runner $r: sets $(echo $extra), which only gitlab-runner/values.yaml sets"
  [ "$(yq '.tacplus.tags | tag' "$f")" = '!!seq' ] && [ "$(yq '.tacplus.tags | length' "$f")" -gt 0 ] &&
    [ -z "$(yq '.tacplus.tags[] | select((tag != "!!str") or (test("^[a-z0-9][a-z0-9._-]*$") | not))' "$f")" ] ||
    die "runner $r: tacplus.tags is not a list of GitLab runner tags"
  [ "$(yq '.tacplus.protected // false | tag' "$f")" = '!!bool' ] ||
    die "runner $r: tacplus.protected [$(yq '.tacplus.protected' "$f")] is not true or false"
  token=$(yq '.tacplus.token // ""' "$f")
  [[ $token =~ ^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/secrets/[A-Za-z0-9_-]{1,255}/versions/[1-9][0-9]*$ ]] ||
    die "runner $r: tacplus.token [$token] is not a Secret Manager version (projects/<project>/secrets/<secret>/versions/<number>, never latest)"
  [[ $(yq '.concurrent // ""' "$f") =~ ^([1-9][0-9]?|pool)$ ]] || die "runner $r: concurrent is not 1 to 99, nor pool"
  [ "$(yq '.runners.config | tag' "$f")" = '!!str' ] || die "runner $r: no runners.config"
  runners+=("$r")
done
[ ${#runners[@]} -gt 0 ] || die "no runner in $runners_dir"

# The normal pool's room (gitlab-runner/pool.yaml, #36): what its nodes can allocate, less the reserve, every runner
# manager (all on the normal pool), deploymentproxy and every normal-pool runner's jobs at its fixed concurrent; the
# runner that says `concurrent: pool` takes as many jobs as fit in the rest, and in the looper pool's room (#47) when
# its jobs tolerate that pool's taint, less the looper's managers' room (#53), CPU and memory both. A job's pod is its
# runner's default requests, its job container's and its helper's.
pool=${POOL:-$here/gitlab-runner/pool.yaml}
[ -f "$pool" ] || die "no $pool"
# quantity WHAT VALUE UNIT: VALUE (CPU as 1930m or 2, memory as 512Mi or 4Gi) in millicores or MiB.
quantity() {
  case $3:$2 in
    m:[0-9]*m) [[ ${2%m} =~ ^[0-9]+$ ]] && echo "${2%m}" && return ;;
    m:[0-9]*) [[ $2 =~ ^[0-9]+$ ]] && echo $(($2 * 1000)) && return ;;
    Mi:[0-9]*Mi) [[ ${2%Mi} =~ ^[0-9]+$ ]] && echo "${2%Mi}" && return ;;
    Mi:[0-9]*Gi) [[ ${2%Gi} =~ ^[0-9]+$ ]] && echo $((${2%Gi} * 1024)) && return ;;
  esac
  die "$1 [$2] is not $([ "$3" = m ] && echo "a CPU quantity (1930m, 2)" || echo "a memory quantity (512Mi, 4Gi)")"
}
pool_q() { quantity "gitlab-runner/pool.yaml: $1" "$(yq ".$1 // \"\"" "$pool")" "$2"; }
nodes=$(yq '.nodes // ""' "$pool")
[[ $nodes =~ ^[1-9][0-9]*$ ]] || die "gitlab-runner/pool.yaml: nodes [$nodes] is not a number of nodes"
# One substitution per assignment, so a refusal stops the render (set -e).
node_cpu=$(pool_q allocatable.cpu m)
node_mem=$(pool_q allocatable.memory Mi)
reserved_cpu=$(pool_q reserved.cpu m)
reserved_mem=$(pool_q reserved.memory Mi)
values=$here/gitlab-runner/values.yaml
manager_cpu=$(quantity "gitlab-runner/values.yaml: resources.requests.cpu" "$(yq '.resources.requests.cpu // ""' "$values")" m)
manager_mem=$(quantity "gitlab-runner/values.yaml: resources.requests.memory" "$(yq '.resources.requests.memory // ""' "$values")" Mi)
free_cpu=$((nodes * node_cpu - reserved_cpu - ${#runners[@]} * manager_cpu))
free_mem=$((nodes * node_mem - reserved_mem - ${#runners[@]} * manager_mem))
dp=$release/config/manager/deployment.yaml
replicas=$(yq 'select(.kind == "Deployment") | .spec.replicas // 1' "$dp")
while IFS='|' read -r c cpu mem; do
  cpu=$(quantity "deploymentproxy's $c: requests.cpu" "$cpu" m)
  mem=$(quantity "deploymentproxy's $c: requests.memory" "$mem" Mi)
  free_cpu=$((free_cpu - replicas * cpu)) free_mem=$((free_mem - replicas * mem))
done < <(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | .name + "|" + (.resources.requests.cpu // "0") + "|" + (.resources.requests.memory // "0Mi")' "$dp")
# The spot pool's room (gitlab-runner/spot-pool.yaml, #41): its max nodes times the jobs a node holds once its
# daemonsets are counted, per node, by the runner's largest job: its ceilings (*_overwrite_max_allowed) where it has
# them, else its default requests, and its helper's.
spot_pool=${SPOT_POOL:-$here/gitlab-runner/spot-pool.yaml}
[ -f "$spot_pool" ] || die "no $spot_pool"
spot_q() { quantity "gitlab-runner/spot-pool.yaml: $1" "$(yq ".$1 // \"\"" "$spot_pool")" "$2"; }
spot_nodes=$(yq '.max_nodes // ""' "$spot_pool")
[[ $spot_nodes =~ ^[1-9][0-9]*$ ]] || die "gitlab-runner/spot-pool.yaml: max_nodes [$spot_nodes] is not a number of nodes"
spot_node_cpu=$(spot_q allocatable.cpu m)
spot_node_mem=$(spot_q allocatable.memory Mi)
spot_ds_cpu=$(spot_q daemonsets.cpu m)
spot_ds_mem=$(spot_q daemonsets.memory Mi)
spot_cpu=$((spot_node_cpu - spot_ds_cpu)) spot_mem=$((spot_node_mem - spot_ds_mem))
declare -A concurrent=() spot_pooled=()
pooled= pod_cpu=0 pod_mem=0
for r in "${runners[@]}"; do
  f=$runners_dir/$r.yaml
  k=$(yq '.runners.config' "$f" | yq -p toml -o json -I=0 '.runners[0].kubernetes // {}') || die "runner $r: runners.config is not TOML"
  c=$(yq '.concurrent' "$f")
  q() { quantity "runner $r: $1" "$(yq -p json ".$1 // \"\"" <<<"$k")" "$2"; }
  # The spot pool's runners (their jobs select spot) take nothing of the normal pool's but their managers, and each
  # the spot pool's room: a land's build preempts a report build (#42), so neither holds the other's.
  if [ "$(yq -p json '(.node_selector // {}) | has("spot")' <<<"$k")" = true ]; then
    job_cpu=$(q cpu_request m)
    job_mem=$(q memory_request Mi)
    if [ -n "$(yq -p json '.cpu_request_overwrite_max_allowed // ""' <<<"$k")" ]; then
      ceiling=$(q cpu_request_overwrite_max_allowed m); [ "$ceiling" -le "$job_cpu" ] || job_cpu=$ceiling
    fi
    if [ -n "$(yq -p json '.memory_request_overwrite_max_allowed // ""' <<<"$k")" ]; then
      ceiling=$(q memory_request_overwrite_max_allowed Mi); [ "$ceiling" -le "$job_mem" ] || job_mem=$ceiling
    fi
    helper_cpu=$(q helper_cpu_request m)
    helper_mem=$(q helper_memory_request Mi)
    cpu=$((job_cpu + helper_cpu)) mem=$((job_mem + helper_mem))
    room=$((spot_cpu / cpu < spot_mem / mem ? spot_cpu / cpu : spot_mem / mem))
    [ "$room" -ge 1 ] || die "the spot pool's nodes have no room for one job of $r (${cpu}m, ${mem}Mi): ${spot_cpu}m CPU and ${spot_mem}Mi memory a node (gitlab-runner/spot-pool.yaml)"
    room=$((room * spot_nodes))
    [ "$room" -le 99 ] || room=99
    if [ "$c" = pool ]; then
      concurrent[$r]=$room spot_pooled[$r]=1
    else
      [ "$c" -le "$room" ] || die "runner $r: concurrent $c, but the spot pool has room for $room of its jobs (gitlab-runner/spot-pool.yaml)"
      concurrent[$r]=$c
    fi
    continue
  fi
  job_cpu=$(q cpu_request m)
  helper_cpu=$(q helper_cpu_request m)
  job_mem=$(q memory_request Mi)
  helper_mem=$(q helper_memory_request Mi)
  cpu=$((job_cpu + helper_cpu)) mem=$((job_mem + helper_mem))
  if [ "$c" = pool ]; then
    [ -z "$pooled" ] || die "runner $r: concurrent pool, as $pooled: one runner only takes the pool's room"
    pooled=$r pod_cpu=$cpu pod_mem=$mem pooled_looper=$(yq -p json '.node_tolerations."looper=true" // ""' <<<"$k")
  else
    concurrent[$r]=$c
    free_cpu=$((free_cpu - c * cpu)) free_mem=$((free_mem - c * mem))
  fi
done
[ "$free_cpu" -ge 0 ] && [ "$free_mem" -ge 0 ] ||
  die "the normal pool has no room for its runners' jobs: ${free_cpu}m CPU and ${free_mem}Mi memory left (gitlab-runner/pool.yaml)"
# The looper pool (#47): the pooled runner's jobs, when they tolerate its taint, overflow there; it counts at its max
# nodes, less each node's daemonsets. Without it in gitlab-runner/pool.yaml, none.
looper_nodes=0 looper_cpu=0 looper_mem=0 looper_room=
if [ "$(yq 'has("looper")' "$pool")" = true ]; then
  looper_nodes=$(yq '.looper.max_nodes // ""' "$pool")
  [[ $looper_nodes =~ ^[0-9]+$ ]] || die "gitlab-runner/pool.yaml: looper.max_nodes [$looper_nodes] is not a number of nodes"
  looper_node_cpu=$(pool_q looper.allocatable.cpu m)
  looper_node_mem=$(pool_q looper.allocatable.memory Mi)
  looper_ds_cpu=$(pool_q looper.daemonsets.cpu m)
  looper_ds_mem=$(pool_q looper.daemonsets.memory Mi)
  [ "$looper_ds_cpu" -le "$looper_node_cpu" ] && [ "$looper_ds_mem" -le "$looper_node_mem" ] ||
    die "gitlab-runner/pool.yaml: the looper pool's daemonsets ask more than a node's allocatable"
  looper_cpu=$((looper_nodes * (looper_node_cpu - looper_ds_cpu))) looper_mem=$((looper_nodes * (looper_node_mem - looper_ds_mem)))
fi
# The looper's managers (#53): control's jobs that ask more than its defaults (a report's), each its own requests, held
# in the pools' room before control's slots. Without it in gitlab-runner/pool.yaml, none.
managers=0 manager_job_cpu=0 manager_job_mem=0
if [ "$(yq 'has("managers")' "$pool")" = true ]; then
  managers=$(yq '.managers.count // ""' "$pool")
  [[ $managers =~ ^[0-9]+$ ]] || die "gitlab-runner/pool.yaml: managers.count [$managers] is not a number of managers"
  manager_job_cpu=$(pool_q managers.cpu m)
  manager_job_mem=$(pool_q managers.memory Mi)
fi
if [ -n "$pooled" ]; then
  if [ "$looper_nodes" -gt 0 ] && [ "$pooled_looper" = NoSchedule ]; then
    free_cpu=$((free_cpu + looper_cpu)) free_mem=$((free_mem + looper_mem)) looper_room=true
  fi
  free_cpu=$((free_cpu - managers * manager_job_cpu)) free_mem=$((free_mem - managers * manager_job_mem))
  c=$((free_cpu / pod_cpu < free_mem / pod_mem ? free_cpu / pod_cpu : free_mem / pod_mem))
  [ "$c" -le 99 ] || c=99
  [ "$c" -ge 1 ] || die "the normal pool has no room for one job of $pooled (${pod_cpu}m, ${pod_mem}Mi): ${free_cpu}m CPU and ${free_mem}Mi memory left (gitlab-runner/pool.yaml)"
  concurrent[$pooled]=$c
fi

mkdir -p "$out"
rm -f "$out"/*.yaml

# deploymentproxy. The upstream Deployment must still run the line's tag, which the pin replaces with its digest.
line=$(yq -e '.line' "$pin")
image=$(yq -e '.image' "$pin")
upstream=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$release/config/manager/deployment.yaml")
[ "$upstream" = "ghcr.io/tacplus-dev/deploymentproxy:$line" ] ||
  die "the release's Deployment runs $upstream, not the line $line that pin.yaml pins"
quotas=$(yq -o=json -I=0 '[.deployments[] | select((.quota // {}) | length > 0) | {(.name): .quota}] | .[] as $q ireduce ({}; . * $q)' "$deployments")
# Each deployment with an operator reads its tenant namespaces (pods, their logs, events) as its deploy account
# (fleet-seatrials#85): deploymentproxy binds readers.deployments.<name> there. GKE names a Google service account by
# its email, the User subject fleet-deploy's RoleBinding names too.
readers=$(yq -o=json -I=0 '[.deployments[] | select(has("operator")) | {(.name): [{"kind": "User", "name": .deployAccount}]}] | .[] as $r ireduce ({}; . * $r)' "$deployments")
{
  first=1
  while read -r f; do
    [ "$f" != config/deployment-namespace/operator.yaml ] || continue
    [ -n "$first" ] || echo ---
    first=
    case $f in
      # The pod names the image's own user (distroless nonroot, 65532:65532), which the release leaves to the
      # image, and the container gets a CPU limit, which the release does not set (#31).
      config/manager/deployment.yaml)
        IMAGE=$image yq '.spec.template.spec.containers[0].image = strenv(IMAGE) |
          .spec.template.spec.securityContext.runAsUser = 65532 | .spec.template.spec.securityContext.runAsGroup = 65532 |
          .spec.template.spec.containers[0].resources.limits.cpu = "500m"' "$release/$f" ;;
      config/manager/configmap.yaml)
        if [ "$quotas" = '{}' ] && [ "$readers" = '{}' ]; then cat "$release/$f"
        else Q=$quotas R=$readers yq '.data."config.yaml" |= (from_yaml |
          (.quota.deployments = (strenv(Q) | from_json | ... style="")) |
          (.readers.deployments = (strenv(R) | from_json | ... style="")) | to_yaml)' "$release/$f"; fi ;;
      *) cat "$release/$f" ;;
    esac
  done < <(yq '.files[]' "$pin")
} > "$out/00-deploymentproxy.yaml"

# The cluster's default StorageClass: Hyperdisk Balanced, the disk every node of dev (C4A) can attach.
cat > "$out/05-storage.yaml" <<'STORAGE'
# The cluster's default StorageClass. Rendered by render.sh; never edited.
#
# Every node of dev is C4A (Axion), and C4A attaches Hyperdisk only: a claim that names no class took GKE's own
# default, standard-rwo (pd-balanced), and its volume never attached ("pd-balanced disk type cannot be used by
# c4a-standard-2 machine type": seatrials' first deploy, 2026-11-26: kernel, stratum and eventbus never started).
# Kubernetes gives a claim the newest of several default classes, so this one wins over GKE's, which GKE owns and
# this render leaves alone.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hyperdisk-balanced
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: pd.csi.storage.gke.io
parameters:
  type: hyperdisk-balanced
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
STORAGE

# Kernel's TokenReview right (#67): the one ClusterRole each deployment's kernel is bound to, below.
cat > "$out/06-kernel-tokenreview.yaml" <<'TOKENREVIEW'
# Kernel's TokenReview right, bound per deployment to tac-<name>'s service account kernel (10-deployment-<name>.yaml).
# Rendered by render.sh; never edited.
#
# Kernel verifies a workload's projected service-account token with the TokenReview API, which is cluster-scoped, so
# a deployment's operator, holding no cluster-wide right, renders no ClusterRole for it (tacplus-dev/operator#3): this
# pipeline grants it. Create tokenreviews and nothing else: not system:auth-delegator, which also grants
# subjectaccessreviews, which kernel never calls.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kernel-tokenreview
rules:
  - apiGroups: [authentication.k8s.io]
    resources: [tokenreviews]
    verbs: [create]
TOKENREVIEW

# Each deployment.
for ((i = 0; i < n; i++)); do
  e=".deployments[$i]"
  name=$(yq "$e.name" "$deployments")
  account=$(yq "$e.deployAccount" "$deployments")
  operator=$(yq "$e.operator // \"\"" "$deployments")
  project=$(yq "$e.gitlabProject" "$deployments")
  ns=tac-$name
  {
    if [ -n "$operator" ]; then
      echo "# The deployment $name (deployments.yaml): its namespace, its operator's Roles (deploymentproxy's, its own), its"
    else
      echo "# The deployment $name (deployments.yaml), without an operator: its namespace, its"
    fi
    cat <<EOF
# deploy account's Role, in $ns only, and its kernel's TokenReview right. Rendered by render.sh; never edited.
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    tacplus.dev/deployment: $name
  annotations:
    tacplus.dev/gitlab-project: $project
EOF
    if [ -n "$operator" ]; then
      echo ---
      # As config/deployment-namespace/operator.yaml says: NAMESPACE=tac-<deployment> envsubst '\$NAMESPACE'.
      sed 's/\${NAMESPACE}/'"$ns"'/g' "$release/config/deployment-namespace/operator.yaml" |
        OPERATOR=$operator yq '(select(.kind == "RoleBinding") | .subjects[0].name) = strenv(OPERATOR)'
      cat <<EOF
---
# The operator's own rights in $ns (#59): with \`deployment\` set, the operator's chart renders no Role and leaves
# them to this pipeline. Its chart's Role (operator helm/templates/role.yaml): the fleet's chart's objects and helm's
# release state, the Roles that chart ships, pods read and deleted (an old StatefulSet revision's), leader election
# and events. Each grant is within fleet-deploy (ci/policy.sh). In the tenant namespaces deploymentproxy binds it.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployment-operator
  namespace: $ns
rules:
  - apiGroups: [""]
    resources: [services, serviceaccounts, configmaps, secrets, persistentvolumeclaims]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apps]
    resources: [deployments, statefulsets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [batch]
    resources: [cronjobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, delete]
  - apiGroups: [coordination.k8s.io]
    resources: [leases]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [events]
    verbs: [create, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployment-operator
  namespace: $ns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deployment-operator
subjects:
  - kind: ServiceAccount
    name: $operator
    namespace: $ns
EOF
    fi
    cat <<EOF
---
# What the fleet's helm release needs inside $ns, and nothing cluster-scoped: no namespaces, no cluster RBAC, no
# CRDs; no quota or limit changes; no exec, attach or port-forward. Every verb is named. Kubernetes' escalation
# check means the Roles the release creates can grant no more than this.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: fleet-deploy
  namespace: $ns
rules:
  # Helm keeps its release state in Secrets.
  - apiGroups: [""]
    resources: [configmaps, secrets, services, serviceaccounts, persistentvolumeclaims]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, delete]
  - apiGroups: [""]
    resources: [pods/log, endpoints, resourcequotas, limitranges]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [events]
    verbs: [get, list, watch, create, patch]
  - apiGroups: [events.k8s.io]
    resources: [events]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apps]
    resources: [replicasets, controllerrevisions]
    verbs: [get, list, watch]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [coordination.k8s.io]
    resources: [leases]
    verbs: [get, list, watch, create, update, patch, delete]
  # Its operator's TenantNamespaces, read only (#59): which one deploymentproxy has not made Ready. Only the
  # operator's account creates them (deploymentproxy's Role).
  - apiGroups: [deploymentproxy.tacplus.dev]
    resources: [tenantnamespaces]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: fleet-deploy
  namespace: $ns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: fleet-deploy
subjects:
  # GKE names a Google service account by its email.
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: $account
---
# Kernel's TokenReview right (06-kernel-tokenreview.yaml, #67), to its service account in $ns alone.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $ns-kernel-tokenreview
  labels:
    tacplus.dev/deployment: $name
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kernel-tokenreview
subjects:
  - kind: ServiceAccount
    name: kernel
    namespace: $ns
EOF
  } > "$out/10-deployment-$name.yaml"
  ! grep -q '\${' "$out/10-deployment-$name.yaml" || die "$name: a variable is left in the render"
done

# CI in the cluster. The chart's Deployment must run its own appVersion's image, which the pin replaces with its
# digest.
app=$(yq -e '.appVersion' "$runner_release/Chart.yaml")
runner_image=$(yq -e '.runner' "$runner_pin")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
  cat <<'EOF'
# CI in the cluster (README, CI in the cluster): the namespace ci, where GitLab Runner's Kubernetes executor runs
# every job as a pod. Rendered by render.sh; never edited.
apiVersion: v1
kind: Namespace
metadata:
  name: ci
  labels:
    tacplus.dev/ci: "true"
---
# The runner managers' priority (gitlab-runner/values.yaml's priorityClassName, #39): above the jobs' pods (0 where
# none is set; the spot pool's, below, at most 1), preempting one when a manager has no room, so a runner is never down for want of its manager's pod. Never the
# cluster's default; far below the system's (over 1000000000).
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: ci-runner-manager
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: GitLab Runner managers in ci (tacplus-dev/cluster), ahead of their jobs' pods.
---
# A land's build's jobs' priority (gitlab-runner/runners/build.yaml's priority_class_name, #46): the spot pool's
# highest, preempting the nightly's and the report builds' jobs when the pool is full, so a land never waits for
# them. Above 0 only on the spot pool: its jobs select spot nodes, which no other pod but theirs and the daemonsets
# tolerates, so they can evict no deploymentproxy or deployment pod (0). Never the cluster's default.
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: build
value: 1
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: A land's build in ci (tacplus-dev/cluster), ahead of the nightly and the report builds.
---
# The nightly's jobs' priority (gitlab-runner/runners/nightly.yaml's priority_class_name, #46; tacplus-dev/looper#220):
# between a land's build's (build), which preempt them, and the report builds' (build-report), which they preempt, so
# a nightly security job evicts a report build instead of waiting Pending past poll_timeout, and never delays a land.
# At or above the cluster autoscaler's expendable cutoff (-10). Never the cluster's default.
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: build-nightly
value: 0
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: The nightly security fan-out in ci (tacplus-dev/cluster), preempted by a land's build, ahead of the report builds.
---
# The report builds' jobs' priority (gitlab-runner/runners/build-report.yaml's priority_class_name, #42;
# tacplus-dev/looper#209): below a land's build's jobs (build) and the nightly's (build-nightly, #46), which preempt
# them when the spot pool is full, and preempting nothing themselves. At or above the cluster autoscaler's expendable cutoff (-10), so a report
# build's pending pod still scales the spot pool up. Never the cluster's default.
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: build-report
value: -1
globalDefault: false
preemptionPolicy: Never
description: Report builds in ci (tacplus-dev/cluster), preempted by a land's build.
---
# control's jobs' priority (gitlab-runner/runners/control.yaml's priority_class_name, #49): below infra's and kick's
# jobs (0, theirs set none), which preempt them when the normal pool is full, so a cloud or cluster apply never waits
# Pending behind the looper's reports; below deploymentproxy's and the deployments' pods too, which a CI job never
# evicts. Preempting nothing themselves; at or above the cluster autoscaler's expendable cutoff (-10), so their pending
# pods still scale the looper pool up. Never the cluster's default.
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: control-job
value: -1
globalDefault: false
preemptionPolicy: Never
description: control's jobs in ci (tacplus-dev/cluster), preempted by infra's and kick's.
---
# The jobs' pods' account: no role anywhere, and no token in the pod.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-job
  namespace: ci
automountServiceAccountToken: false
---
# No pod in ci reaches the metadata server, so none gets the node's Google account, nor a Workload Identity one
# (169.254.169.252 is GKE's metadata server under Workload Identity). A job that needs Google Cloud federates its own
# GitLab id_token.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ci-no-metadata-server
  namespace: ci
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [169.254.169.254/32, 169.254.169.252/32]
        - namespaceSelector: {}
---
# Refused in ci, whatever creates the pod (the runners' account may create pods there): a privileged container, a
# host path, the host's network, PID or IPC namespace, a host port, an added capability.
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: ci-pods
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  variables:
    - name: containers
      expression: >-
        object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
  validations:
    - expression: >-
        variables.containers.all(c, !has(c.securityContext) || !has(c.securityContext.privileged) ||
        !c.securityContext.privileged)
      message: no privileged container in ci
    - expression: "!has(object.spec.volumes) || object.spec.volumes.all(v, !has(v.hostPath))"
      message: no host path in ci
    - expression: >-
        !(has(object.spec.hostNetwork) && object.spec.hostNetwork) && !(has(object.spec.hostPID) && object.spec.hostPID) &&
        !(has(object.spec.hostIPC) && object.spec.hostIPC)
      message: no host network, PID or IPC namespace in ci
    - expression: >-
        variables.containers.all(c, !has(c.ports) || c.ports.all(p, !has(p.hostPort) || p.hostPort == 0))
      message: no host port in ci
    - expression: >-
        variables.containers.all(c, !has(c.securityContext) || !has(c.securityContext.capabilities) ||
        !has(c.securityContext.capabilities.add) || size(c.securityContext.capabilities.add) == 0)
      message: no added capability in ci
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: ci-pods
spec:
  policyName: ci-pods
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: ci
EOF
  for r in "${runners[@]}"; do
    f=$runners_dir/$r.yaml
    # The images, the token's Secret and its version, the tags and the protection on the pods, and the concurrent it
    # counted: render.sh's, never the runner file's.
    protected=$(yq '.tacplus.protected // false' "$f")
    R=$r TOKEN=$(yq '.tacplus.token' "$f") TAGS=$(yq '.tacplus.tags | join(",")' "$f") PROTECTED=$protected \
      JOB=$(yq -e '.job' "$runner_pin") HELPER=$(yq -e '.helper' "$runner_pin") CONCURRENT=${concurrent[$r]} yq -n '
      .pinned.job = strenv(JOB) | .pinned.helper = strenv(HELPER) | .concurrent = (strenv(CONCURRENT) | to_number) |
      .runners.secret = "gitlab-runner-" + strenv(R) |
      .podLabels."tacplus.dev/ci-runner" = strenv(R) |
      .podAnnotations."tacplus.dev/runner-token-secret" = "gitlab-runner-" + strenv(R) |
      .podAnnotations."tacplus.dev/runner-token" = strenv(TOKEN) |
      .podAnnotations."tacplus.dev/runner-tags" = strenv(TAGS) |
      .podAnnotations."tacplus.dev/runner-protected" = strenv(PROTECTED)' > "$tmp/$r.yaml"
    helm template "gitlab-runner-$r" "$runner_release" --namespace ci \
        -f "$here/gitlab-runner/values.yaml" -f "$f" -f "$tmp/$r.yaml" > "$tmp/$r.out" 2> "$tmp/$r.err" ||
      die "runner $r: helm template failed: $(cat "$tmp/$r.err")"
    upstream=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$tmp/$r.out")
    [ "$upstream" = "registry.gitlab.com/gitlab-org/gitlab-runner:alpine-v$app" ] ||
      die "runner $r: the chart's Deployment runs $upstream, not its appVersion $app"
    echo ---
    echo "# The runner $r (gitlab-runner/runners/$r.yaml), tags $(yq '.tacplus.tags | join(", ")' "$f")$([ "$protected" != true ] || echo ", protected refs only"), concurrent ${concurrent[$r]}$([ "$r" != "$pooled" ] || echo ", the normal pool's room$([ -z "$looper_room" ] || echo " and the looper pool's at its max nodes") (gitlab-runner/pool.yaml)")$([ -z "${spot_pooled[$r]:-}" ] || echo ", the spot pool's room at its max nodes (gitlab-runner/spot-pool.yaml)"): GitLab Runner's chart $(yq '.version' "$runner_release/Chart.yaml")."
    # checksum/secrets is the hash of the chart's own Secret, which it does not render here (the token's Secret is
    # ci/runner-tokens.sh's): an empty file's, and nothing to roll the pods on.
    IMAGE=$runner_image yq '(select(.kind == "Deployment") | .spec.template.spec.containers[0].image) = strenv(IMAGE) |
        del(select(.kind == "Deployment") | .spec.template.metadata.annotations."checksum/secrets")' "$tmp/$r.out" |
      sed '1{/^---$/d}'
  done
} > "$out/20-ci.yaml"
! grep -q '{{' "$out/20-ci.yaml" || die "a template is left in the render of ci"
echo "render.sh: $out: deploymentproxy $(yq '.tag' "$pin"), ${n} deployment(s)${names:+: ${names[*]}}, ci with the runner(s) ${runners[*]}"
