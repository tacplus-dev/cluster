#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Renders what the pipeline applies to the cluster `tacplus`, one file per unit (README, What it manages):
#
#   OUT/00-deploymentproxy.yaml     deploymentproxy's release (deploymentproxy/release, checked against its
#                                   SHA256SUMS), its image pinned by digest (deploymentproxy/pin.yaml), each
#                                   deployment's own quota merged into its config
#   OUT/10-deployment-<name>.yaml   per entry of DEPLOYMENTS: the namespace tac-<name> labelled
#                                   tacplus.dev/deployment=<name>, deploymentproxy's per-deployment Role for its
#                                   operator account (config/deployment-namespace), and the deploy account's Role
#                                   and RoleBinding (fleet-deploy), in tac-<name> only
#
# A removed entry renders nothing, and the apply never deletes (ci/apply.sh). Every entry is checked before
# anything is written; a bad one is refused with what is wrong.
#
#   ./render.sh [DEPLOYMENTS [OUT]]     # deployments.yaml, out/ by default; needs bash, yq (mikefarah v4), sha256sum
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
deployments=${1:-$here/deployments.yaml}
out=${2:-$here/out}
release=$here/deploymentproxy/release
pin=$here/deploymentproxy/pin.yaml
die() { echo "render.sh: $*" >&2; exit 1; }

# The release, as fetched.
(cd "$release" && sha256sum --quiet --strict -c SHA256SUMS >/dev/null 2>&1) ||
  die "deploymentproxy/release does not match its SHA256SUMS: run deploymentproxy/fetch.sh, never edit it"

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
  operator=$(yq "$e.operator // \"\"" "$deployments")
  [[ $operator =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "$name: operator [$operator] is not a service account name"
  project=$(yq "$e.gitlabProject // \"\"" "$deployments")
  [[ $project =~ ^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+$ ]] || die "$name: gitlabProject [$project] is not a GitLab project path"
  [ "$(yq "($e.quota // {}) | tag" "$deployments")" = '!!map' ] &&
    [ -z "$(yq "($e.quota // {}) | to_entries | .[] | select((.key | test(\"^[a-z0-9./]+\$\") | not) or (.value | tag) != \"!!str\") | .key" "$deployments")" ] ||
    die "$name: quota is not a map of resource names to quoted quantities (deploymentproxy's quota.deployments.<name>)"
done

mkdir -p "$out"
rm -f "$out"/*.yaml

# deploymentproxy. The upstream Deployment must still run the line's tag, which the pin replaces with its digest.
line=$(yq -e '.line' "$pin")
image=$(yq -e '.image' "$pin")
upstream=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$release/config/manager/deployment.yaml")
[ "$upstream" = "ghcr.io/tacplus-dev/deploymentproxy:$line" ] ||
  die "the release's Deployment runs $upstream, not the line $line that pin.yaml pins"
quotas=$(yq -o=json -I=0 '[.deployments[] | select((.quota // {}) | length > 0) | {(.name): .quota}] | .[] as $q ireduce ({}; . * $q)' "$deployments")
{
  first=1
  while read -r f; do
    [ "$f" != config/deployment-namespace/operator.yaml ] || continue
    [ -n "$first" ] || echo ---
    first=
    case $f in
      config/manager/deployment.yaml) IMAGE=$image yq '.spec.template.spec.containers[0].image = strenv(IMAGE)' "$release/$f" ;;
      config/manager/configmap.yaml)
        if [ "$quotas" = '{}' ]; then cat "$release/$f"
        else Q=$quotas yq '.data."config.yaml" |= (from_yaml | .quota.deployments = (strenv(Q) | from_json | ... style="") | to_yaml)' "$release/$f"; fi ;;
      *) cat "$release/$f" ;;
    esac
  done < <(yq '.files[]' "$pin")
} > "$out/00-deploymentproxy.yaml"

# Each deployment.
for ((i = 0; i < n; i++)); do
  e=".deployments[$i]"
  name=$(yq "$e.name" "$deployments")
  account=$(yq "$e.deployAccount" "$deployments")
  operator=$(yq "$e.operator" "$deployments")
  project=$(yq "$e.gitlabProject" "$deployments")
  ns=tac-$name
  {
    cat <<EOF
# The deployment $name (deployments.yaml): its namespace, deploymentproxy's Role for its operator, and its
# deploy account's Role, in $ns only. Rendered by render.sh; never edited.
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    tacplus.dev/deployment: $name
  annotations:
    tacplus.dev/gitlab-project: $project
---
EOF
    # As config/deployment-namespace/operator.yaml says: NAMESPACE=tac-<deployment> envsubst '\$NAMESPACE'.
    sed 's/\${NAMESPACE}/'"$ns"'/g' "$release/config/deployment-namespace/operator.yaml" |
      OPERATOR=$operator yq '(select(.kind == "RoleBinding") | .subjects[0].name) = strenv(OPERATOR)'
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
EOF
  } > "$out/10-deployment-$name.yaml"
  ! grep -q '\${' "$out/10-deployment-$name.yaml" || die "$name: a variable is left in the render"
done
echo "render.sh: $out: deploymentproxy $(yq '.tag' "$pin"), ${n} deployment(s)${names:+: ${names[*]}}"
