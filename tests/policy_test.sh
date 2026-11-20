#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/policy.sh: the fixture's render keeps the rules, and each way a deployment's file could reach outside
# its namespace is a breach: a `*` verb, resource or group; a cluster-scoped resource (nodes, namespaces,
# clusterroles, CRDs) in a Role; escalate, bind, impersonate; non-resource URLs; a ClusterRole or
# ClusterRoleBinding; a RoleBinding to a ClusterRole or to another namespace's service account; a Role in another
# namespace; an unlabelled namespace; no deploy Role or binding; deploymentproxy's Role without its operator binding
# or the binding without the Role (a deployment without an operator has neither, and keeps the rules). In ci's file: privileged jobs or runners, a host path, the Docker socket, an
# added capability, host networking, an image by tag only; build jobs off the spot pool or as root, control jobs
# tolerating spot, landing on a spot node, Unconfined or escalating privilege; a job allowed to override its
# placement, a job's token, no resource ceiling; build taking other tags; a VM runner's tag (autoscale,
# autoscale-16, gce) on any runner; an infra pipeline's tag (cloud, cluster, deploy) on build or control, infra
# taking any other tag, or not protected refs only (#25); kick taking a tag but arm64 and kick, or not kick, and kick
# on any other runner (#36); a runner manager on a read-only root filesystem without a
# writable emptyDir where GitLab Runner writes (/tmp or its TMPDIR, its home; #37); a runner manager not at the
# PriorityClass ci-runner-manager, none, another, or one that is the default, never preempts, or is not above the jobs
# and below the system's, and a job at a priority class (#39); a token by latest; cluster RBAC,
# a `*`, a resource the executor does not need, another namespace's account or object, a Secret. Needs bash, yq, jq, helm.
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
dp='.metadata.name == "deploymentproxy-tenantnamespaces"'
breach "deploymentproxy's Role without its binding" "del(select(.kind == \"RoleBinding\" and $dp))" "the Role deploymentproxy-tenantnamespaces without its RoleBinding"
breach "the operator's binding without deploymentproxy's Role" "del(select(.kind == \"Role\" and $dp))" "the RoleBinding deploymentproxy-tenantnamespaces without its Role"
breach "no deploy Role" 'del(select(.kind == "Role" and .metadata.name == "fleet-deploy"))' "no Role fleet-deploy"
breach "no deploy binding" 'del(select(.kind == "RoleBinding" and .metadata.name == "fleet-deploy"))' "no RoleBinding fleet-deploy"

# A deployment without an operator: neither deploymentproxy's Role nor its binding keeps the rules.
rm -rf "$work/bad" && cp -R "$work/good" "$work/bad"
yq -i "del(select($dp))" "$work/bad/10-deployment-alpha.yaml"
"$here/ci/policy.sh" "$work/bad" > "$work/log" 2>&1 && ok "a deployment without an operator keeps the rules" ||
  fail "a deployment without an operator: $(cat "$work/log")"

# deploymentproxy's file: nothing namespaced outside deploymentproxy.
rm -rf "$work/bad" && cp -R "$work/good" "$work/bad"
yq -i '(select(.kind == "ConfigMap") | .metadata.namespace) = "letsencrypt"' "$work/bad/00-deploymentproxy.yaml"
"$here/ci/policy.sh" "$work/bad" > "$work/log" 2>&1 || grep -q 'ConfigMap deploymentproxy in \[letsencrypt\]' "$work/log" &&
  ! "$here/ci/policy.sh" "$work/bad" >/dev/null 2>&1 &&
  ok "breach: deploymentproxy's object in another namespace" || fail "deploymentproxy's object in letsencrypt: $(cat "$work/log")"

# ci's file (CI in the cluster): breach_ci WHAT YQ WANT [DOCUMENT], as breach on 20-ci.yaml, DOCUMENT added to it.
breach_ci() {
  rm -rf "$work/bad" && cp -R "$work/good" "$work/bad"
  yq -i "$2" "$work/bad/20-ci.yaml"
  [ -z "${4:-}" ] || printf -- '---\n%s\n' "$4" >> "$work/bad/20-ci.yaml"
  if "$here/ci/policy.sh" "$work/bad" > "$work/log" 2>&1; then
    fail "ci: $1: passed"
  elif grep -q -- "$3" "$work/log"; then
    ok "breach: ci: $1"
  else
    fail "ci: $1: does not say [$3]: $(cat "$work/log")"
  fi
}
# toml RUNNER FROM TO: the yq expression replacing FROM with TO (regular expressions) in RUNNER's config.toml.
toml() { echo "(select(.kind == \"ConfigMap\" and .metadata.name == \"gitlab-runner-$1\") | .data.\"config.template.toml\") |= sub(\"$2\", \"$3\")"; }
deployment() { echo "(select(.kind == \"Deployment\" and .metadata.name == \"gitlab-runner-$1\") | .spec.template$2)"; }
ci_role='(select(.kind == "Role" and .metadata.name == "gitlab-runner-build") | .rules)'
breach_ci "privileged jobs" "$(toml build 'privileged = false' 'privileged = true')" "runner gitlab-runner-build: its jobs are privileged"
breach_ci "a host path in a job" "$(toml control 'privileged = false' 'privileged = false\n    [[runners.kubernetes.volumes.host_path]]\n      name = \"var\"\n      mount_path = \"/var\"\n      host_path = \"/var\"\n  [runners.kubernetes.ignored]')" "gitlab-runner-control: its jobs mount a host path"
breach_ci "the Docker socket in a job" "$(toml control '\"HOME=/tmp/home\"' '\"HOME=/tmp/home\", \"DOCKER_HOST=unix:///var/run/docker.sock\"')" "gitlab-runner-control: its jobs reach the Docker socket"
breach_ci "a job image by tag only" "$(toml build 'helper_image = \"[^\"]*\"' 'helper_image = \"registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:latest\"')" "its helper_image \[registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:latest\] is not pinned by digest"
breach_ci "build jobs not selecting spot" "$(toml build '\"spot\" = \"true\"' '\"pool\" = \"any\"')" "gitlab-runner-build: its build jobs do not select the spot pool"
breach_ci "build jobs not tolerating spot" "$(toml build '\"spot=true\" = \"NoSchedule\"' '\"other=true\" = \"NoSchedule\"')" "gitlab-runner-build: its build jobs do not tolerate the spot pool"
breach_ci "build jobs as root" "$(toml build 'run_as_non_root = true' 'run_as_non_root = false')" "gitlab-runner-build: its build jobs may run as root"
breach_ci "control jobs tolerating spot" "$(toml control '\\[runners.kubernetes.node_tolerations\\]' '[runners.kubernetes.node_tolerations]\n      \"spot=true\" = \"NoSchedule\"')" "gitlab-runner-control: its jobs tolerate the spot taint (spot=true)"
breach_ci "control jobs that may land on spot" "$(toml control 'key = \"spot\"' 'key = \"pool\"')" "gitlab-runner-control: its jobs may land on a spot node"
breach_ci "control jobs Unconfined" "$(toml control 'type = \"RuntimeDefault\"' 'type = \"Unconfined\"')" "gitlab-runner-control: its jobs are Unconfined (pod_security_context.seccomp_profile.type)"
breach_ci "control jobs escalating privilege" "$(toml control 'allow_privilege_escalation = false\n    poll' 'poll')" "gitlab-runner-control: its jobs may escalate privilege"
breach_ci "a job moving its pod" "$(toml control 'privileged = false' 'privileged = false\n    node_selector_overwrite_allowed = \".*\"')" "a job may override what node_selector_overwrite_allowed allows"
breach_ci "a job's token" "$(toml build 'automount_service_account_token = false' 'automount_service_account_token = true')" "gitlab-runner-build: its jobs get a service account token"
breach_ci "no memory ceiling" "$(toml build 'memory_limit_overwrite_max_allowed = \"[^\"]*\"' '')" "no ceiling for memory_limit"
breach_ci "a capability added to jobs" "$(toml build 'privileged = false' 'privileged = false\n    cap_add = [\"SYS_ADMIN\"]')" "gitlab-runner-build: its jobs add capabilities"
breach_ci "build taking control's tags" "$(deployment build '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64,build,autoscale\"" "takes build with other tags (arm64, build, autoscale)"
breach_ci "control taking the VM runners' tags" "$(deployment control '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64,control,autoscale-16\"" "gitlab-runner-control: takes a tag of the VM runners (autoscale-16)"
breach_ci "build taking a VM runner's tag" "$(deployment build '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64,gce\"" "gitlab-runner-build: takes a tag of the VM runners (gce)"
breach_ci "control taking an infra pipeline's tag" "$(deployment control '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64,control,cluster\"" "gitlab-runner-control: takes a tag of the infra pipelines (cluster): only the runner infra"
breach_ci "build taking an infra pipeline's tag" "$(deployment build '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64,build,deploy\"" "gitlab-runner-build: takes a tag of the infra pipelines (deploy)"
breach_ci "infra taking control's tag" "$(deployment infra '.metadata.annotations."tacplus.dev/runner-tags"') = \"cloud,cluster,deploy,control\"" "gitlab-runner-infra: takes a tag that is not cloud, cluster or deploy (control)"
breach_ci "infra taking arm64" "$(deployment infra '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64,cloud,cluster,deploy\"" "gitlab-runner-infra: takes a tag that is not cloud, cluster or deploy (arm64)"
breach_ci "kick taking control's tag" "$(deployment kick '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64,kick,control\"" "gitlab-runner-kick: takes a tag that is not arm64 or kick (control)"
breach_ci "kick without its tag" "$(deployment kick '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64\"" "gitlab-runner-kick: does not take kick"
breach_ci "control taking kick's tag" "$(deployment control '.metadata.annotations."tacplus.dev/runner-tags"') = \"arm64,control,kick\"" "gitlab-runner-control: takes kick, the kick runner's tag"
breach_ci "infra not protected" "$(deployment infra '.metadata.annotations."tacplus.dev/runner-protected"') = \"false\"" "gitlab-runner-infra: is not protected refs only"
breach_ci "infra without the protected annotation" "del($(deployment infra '.metadata.annotations."tacplus.dev/runner-protected"'))" "gitlab-runner-infra: is not protected refs only"
breach_ci "infra jobs with a token" "$(toml infra 'automount_service_account_token = false' 'automount_service_account_token = true')" "gitlab-runner-infra: its jobs get a service account token"
breach_ci "infra jobs tolerating spot" "$(toml infra '\\[runners.kubernetes.node_tolerations\\]' '[runners.kubernetes.node_tolerations]\n      \"spot=true\" = \"NoSchedule\"')" "gitlab-runner-infra: its jobs tolerate the spot taint (spot=true)"
breach_ci "a token by latest" "$(deployment control '.metadata.annotations."tacplus.dev/runner-token"') = \"projects/p-1234/secrets/t/versions/latest\"" "gitlab-runner-control's token \[projects/p-1234/secrets/t/versions/latest\] is not a Secret Manager version"
breach_ci "a privileged runner manager" "$(deployment build '.spec.containers[0].securityContext.privileged') = true" "Deployment gitlab-runner-build: the container gitlab-runner-build is privileged"
breach_ci "a host path in a runner manager" "$(deployment build '.spec.volumes') += [{\"name\": \"docker\", \"hostPath\": {\"path\": \"/var/run/docker.sock\"}}]" "the volume docker is a host path"
breach_ci "a runner manager image by tag only" "$(deployment control '.spec.containers[0].image') = \"registry.gitlab.com/gitlab-org/gitlab-runner:latest\"" "the image \[registry.gitlab.com/gitlab-org/gitlab-runner:latest\] is not pinned by digest"
# The runner managers first (#39): each at the PriorityClass ci-runner-manager, above the jobs, preempting them, never
# the cluster's default nor a system priority; no job at a priority class of its own.
pc='(select(.kind == "PriorityClass") | '
breach_ci "a runner manager without the managers' priority" "del($(deployment control '.spec.priorityClassName'))" "Deployment gitlab-runner-control does not run at the runner managers' priority (priorityClassName ci-runner-manager)"
breach_ci "no PriorityClass for the managers" 'del(select(.kind == "PriorityClass"))' "no PriorityClass ci-runner-manager"
breach_ci "another PriorityClass" '.' "the PriorityClass high, not ci-runner-manager" '{"apiVersion": "scheduling.k8s.io/v1", "kind": "PriorityClass", "metadata": {"name": "high"}, "value": 1000}'
breach_ci "the managers' priority the cluster's default" "$pc.globalDefault) = true" "the PriorityClass ci-runner-manager is the cluster's default"
breach_ci "the managers' priority not preempting" "$pc.preemptionPolicy) = \"Never\"" "the PriorityClass ci-runner-manager does not preempt the jobs (preemptionPolicy PreemptLowerPriority)"
breach_ci "the managers' priority not above the jobs'" "$pc.value) = 0" "the PriorityClass ci-runner-manager's value \[0\] is not above the jobs' (0) and below the system's"
breach_ci "the managers' priority a system one" "$pc.value) = 2000000000" "the PriorityClass ci-runner-manager's value \[2000000000\] is not above"
breach_ci "a job at a priority class" "$(toml kick 'privileged = false' 'privileged = false\n    priority_class_name = \"ci-runner-manager\"')" "gitlab-runner-kick: its jobs set a priority class (priority_class_name)"
breach_ci "a runner manager on spot" "$(deployment control '.spec.tolerations') += [{\"key\": \"spot\", \"operator\": \"Exists\"}]" "Deployment gitlab-runner-control tolerates spot"
# Where the runner manager writes, on its read-only root filesystem (#37: no /tmp failed every job at once).
mounts=$(deployment control '.spec.containers[0].volumeMounts')
breach_ci "a runner manager without /tmp" "del($mounts[] | select(.mountPath == \"/tmp\"))" "Deployment gitlab-runner-control: the container gitlab-runner-control writes /tmp, each job's log buffer, before the job starts (helpers/trace/buffer.go: os.CreateTemp), on a read-only root filesystem: no volume is mounted there"
breach_ci "a runner manager's /tmp read-only" "($mounts[] | select(.mountPath == \"/tmp\") | .readOnly) = true" "the container gitlab-runner-control writes /tmp, each job's log buffer.*its mount tmp is readOnly"
breach_ci "a runner manager's /tmp not an emptyDir" "($mounts[] | select(.mountPath == \"/tmp\") | .name) = \"configmaps\"" "the container gitlab-runner-control writes /tmp, each job's log buffer.*its mount configmaps is not an emptyDir"
breach_ci "a runner manager's TMPDIR not mounted" "$(deployment infra '.spec.containers[0].env') += [{\"name\": \"TMPDIR\", \"value\": \"/var/tmp\"}]" "Deployment gitlab-runner-infra: the container gitlab-runner-infra writes /var/tmp, each job's log buffer"
breach_ci "a runner manager without its home" "del($(deployment build '.spec.containers[0].volumeMounts')[] | select(.mountPath == \"/home/gitlab-runner\"))" "the container gitlab-runner-build writes /home/gitlab-runner, its working directory (--working-directory), on a read-only root filesystem: no volume"
breach_ci "host networking" "$(deployment build '.spec.hostNetwork') = true" "gitlab-runner-build: hostNetwork"
breach_ci "a ClusterRole" '(select(.kind == "Role" and .metadata.name == "gitlab-runner-build") | .kind) = "ClusterRole"' "ClusterRole gitlab-runner-build: ci holds only"
breach_ci "a ClusterRoleBinding" '(select(.kind == "RoleBinding" and .metadata.name == "gitlab-runner-build") | .kind) = "ClusterRoleBinding"' "ClusterRoleBinding gitlab-runner-build: ci holds only"
breach_ci "a * verb" "$ci_role[0].verbs += [\"*\"]" "the Role gitlab-runner-build grants \*"
breach_ci "nodes" "$ci_role += [{\"apiGroups\": [\"\"], \"resources\": [\"nodes\"], \"verbs\": [\"get\"]}]" "grants /nodes, not what the Kubernetes executor needs"
breach_ci "deployments" "$ci_role += [{\"apiGroups\": [\"apps\"], \"resources\": [\"deployments\"], \"verbs\": [\"create\"]}]" "grants apps/deployments, not what"
breach_ci "a binding to another namespace's account" '(select(.kind == "RoleBinding" and .metadata.name == "gitlab-runner-build") | .subjects[0].namespace) = "kube-system"' "binds the ServiceAccount gitlab-runner-build of \[kube-system\]"
breach_ci "an object in another namespace" '(select(.kind == "ConfigMap" and .metadata.name == "gitlab-runner-control") | .metadata.namespace) = "default"' "ConfigMap gitlab-runner-control in \[default\], not ci"
breach_ci "a Secret in the render" '.' "Secret t: ci holds only" '{"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "t", "namespace": "ci"}}'
breach_ci "a ClusterRole beside" '.' "ClusterRole admin2: ci holds only" '{"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": "admin2"}, "rules": []}'

[ "$failed" = 0 ] && echo "policy_test: all passed" || { echo "policy_test: failed"; exit 1; }
