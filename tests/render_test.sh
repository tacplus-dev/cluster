#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests render.sh against fixtures: tests/fixtures/render/deployments.yaml renders to exactly
# tests/fixtures/render/out/ (one file for deploymentproxy, one per deployment, one for ci); the images are pinned by
# digest (deploymentproxy's, and the runners' and their jobs' in ci); deploymentproxy runs as its image's user,
# named, and with a CPU limit, the rest of its Deployment the release's; ci's RBAC is in ci only; build jobs select and
# tolerate the spot pool and control and infra jobs never; each runner's jobs have HOME on an emptyDir;
# each runner has a CPU limit and a read-only root filesystem, /tmp, its home and config on emptyDirs (#37); each runner's
# pods name its token's version, a new version a new pod template, that runner's alone (#58), and no token is in it; infra's pods name its tags (cloud, cluster, deploy) and that it
# is protected refs only, and no other runner is; kick's pods name arm64, kick (#36), control's arm64, control; kick's
# jobs default to 50m and 256Mi (#39); build-light's pods name arm64, build-light, its jobs on the normal pool at 50m
# and 256Mi (#51); every runner manager runs at the PriorityClass ci-runner-manager, above its
# jobs and preempting them, and no job at any but build-report's and control's (#39); build-report's jobs are build's (the spot pool,
# its security context and ceilings) at the PriorityClass build-report, below a land's build's pods (0) and preempted by
# them, never preempting, not the cluster's default and not expendable to the autoscaler (#42), its pods naming arm64,
# build-report; the nightly's jobs (#46) are build's too, at the PriorityClass build-nightly, its pods naming arm64,
# build-nightly, and a land's build's at the PriorityClass build, each preempting the next (build above 0, build-nightly
# 0, build-report -1), never the cluster's default; control's jobs at the PriorityClass control-job, below infra's and kick's (0, none set), which preempt
# them, never preempting, not the cluster's default and not expendable (#49); no runner's jobs tolerate, select or
# prefer against the looper pool, which is gone (#64; tacplus-dev/cloud#114); kick's and build-light's
# concurrent their own (2, 4), control's the normal pool's room, less the
# looper's managers' room (gitlab-runner/pool.yaml, #53), CPU or memory the bound, and runners the pool cannot hold, a second runner on its room,
# a looper pool in gitlab-runner/pool.yaml, or a quantity it cannot read, are refused; build's and build-report's each the spot pool's room at its max nodes by
# their largest job, its ceilings (gitlab-runner/spot-pool.yaml, #41: one a node, 8), counted per node, the nightly's
# fixed at half of it (4, #46), and a spot pool without room for one, a fixed concurrent beyond its room, or a quantity
# it cannot read, refused;
# a deployment's own quota reaches deploymentproxy's config and the default leaves the release's ConfigMap as it
# is; deployments.yaml itself renders and passes ci/policy.sh, test-idp with its namespace and deploy Role only; a
# deployment with an operator has the operator's Role in its namespace, bound to its operator account, each grant
# within fleet-deploy, and the deploy account reads (only reads) its TenantNamespaces (#59); a
# deployment without an operator has no deploymentproxy Role and no operator binding; a removed entry renders
# nothing for it; a release
# file or chart file that does not match its checksum, every malformed entry, and a runner file that names its token
# by latest, says protected with anything but true or false, or sets what only gitlab-runner/values.yaml sets, is
# refused with a message. Needs bash, yq and helm.
#
#   tests/render_test.sh
#   UPDATE=1 tests/render_test.sh    # rewrites the expected output (review the diff)
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fixtures=$here/tests/fixtures/render
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

# The fixture renders to the expected files, byte for byte.
if "$here/render.sh" "$fixtures/deployments.yaml" "$work/out" > "$work/log" 2>&1; then
  if [ -n "${UPDATE:-}" ]; then rm -rf "$fixtures/out" && cp -R "$work/out" "$fixtures/out"; fi
  if diff -ru "$fixtures/out" "$work/out"; then ok "the fixture renders to tests/fixtures/render/out"
  else fail "the fixture's render differs from tests/fixtures/render/out (UPDATE=1 to accept)"; fi
else
  fail "render.sh failed on the fixture: $(cat "$work/log")"
fi
[ "$(ls "$work/out" 2>/dev/null | tr '\n' ' ')" = "00-deploymentproxy.yaml 05-storage.yaml 10-deployment-alpha.yaml 10-deployment-beta-2.yaml 20-ci.yaml " ] &&
  ok "one file for deploymentproxy, one per deployment, one for ci" || fail "the files are: $(ls "$work/out" 2>/dev/null | tr '\n' ' ')"

dp=$work/out/00-deploymentproxy.yaml
image=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$dp")
[ "$image" = "$(yq '.image' "$here/deploymentproxy/pin.yaml")" ] && [[ $image == *@sha256:* ]] &&
  ok "the image is pinned by tag and digest: $image" || fail "the image is $image"
# #31: the image's own user (distroless nonroot, 65532:65532) named in the pod, above 10000, and a CPU limit; the
# rest of the release's Deployment as it is.
run_as=$(yq 'select(.kind == "Deployment") | .spec.template.spec.securityContext | (.runAsUser | tostring) + ":" + (.runAsGroup | tostring)' "$dp")
cpu=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits.cpu' "$dp")
[ "$run_as" = 65532:65532 ] && [ "$cpu" = 500m ] &&
  ok "deploymentproxy runs as 65532:65532, its CPU limited to 500m" || fail "deploymentproxy runs as [$run_as], CPU limit [$cpu]"
diff <(yq 'select(.kind == "Deployment") | del(.spec.template.spec.securityContext.runAsUser, .spec.template.spec.securityContext.runAsGroup,
    .spec.template.spec.containers[0].resources.limits.cpu, .spec.template.spec.containers[0].image)' "$dp") \
  <(yq 'del(.spec.template.spec.containers[0].image)' "$here/deploymentproxy/release/config/manager/deployment.yaml") >/dev/null &&
  ok "the rest of deploymentproxy's Deployment is the release's" || fail "the render changed more of the release's Deployment"
quota=$(yq 'select(.kind == "ConfigMap") | .data."config.yaml" | from_yaml | .quota.deployments | to_json(0)' "$dp")
[ "$quota" = '{"beta-2":{"pods":"20","requests.cpu":"2"}}' ] &&
  ok "beta-2's quota reaches deploymentproxy's config, alpha's default adds nothing" || fail "quota.deployments is $quota"

# ci: every image by digest, gitlab-runner/pin.yaml's; the runners' RBAC in ci only; build jobs on the spot pool only.
ci=$work/out/20-ci.yaml
runner_pin=$here/gitlab-runner/pin.yaml
images=$(yq ea '[select(.kind == "Deployment") | .spec.template.spec | (.containers + (.initContainers // []))[] | .image] | unique | join(" ")' "$ci")
[ "$images" = "$(yq '.runner' "$runner_pin")" ] && [[ $images == *@sha256:* ]] &&
  ok "the runners run the pinned runner image, by digest: $images" || fail "the runners' images are [$images]"
runner_cfg() { R=$1 yq 'select(.kind == "ConfigMap" and .metadata.name == "gitlab-runner-" + strenv(R)) | .data."config.template.toml"' "$ci" |
  yq -p toml ".runners[0] | $2"; }
runner_toml() { runner_cfg "$1" ".kubernetes | $2"; }
jobs=$(for r in build build-light build-report control infra kick nightly; do runner_toml $r '.image + " " + .helper_image'; done | sort -u)
[ "$jobs" = "$(yq '.job + " " + .helper' "$runner_pin")" ] &&
  ok "every runner's jobs default to the pinned job image, with the pinned helper, by digest" || fail "the jobs' images are [$jobs]"
! grep -qiE 'image.*:latest|latest@' "$ci" && ok "nothing in ci's render names latest" || fail "ci's render names latest"
[ "$(yq ea '[select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding")] | length' "$ci")" = 0 ] &&
  [ "$(yq ea '[select(.kind == "Role" or .kind == "RoleBinding") | .metadata.namespace] | unique | join(" ")' "$ci")" = ci ] &&
  [ "$(yq ea '[select(.kind == "RoleBinding") | .roleRef.kind] | unique | join(" ")' "$ci")" = Role ] &&
  ok "the runners' accounts hold Roles in ci only, no cluster RBAC" || fail "ci's RBAC: $(yq -N 'select(.kind | test("Role")) | .kind + " " + (.metadata.namespace // "")' "$ci")"
for r in build build-report nightly; do
  [ "$(runner_toml $r '.node_selector.spot + " " + .node_tolerations."spot=true"')" = "true NoSchedule" ] &&
    ok "$r jobs select and tolerate the tainted spot pool" || fail "$r jobs' placement"
done
# The report builds' runner (#42; tacplus-dev/looper#209): build's jobs as they are (the spot pool, the security
# context, the defaults and ceilings), but at the PriorityClass build-report, so a land's build preempts them.
[ "$(runner_toml build-report 'del(.priority_class_name, .pod_labels) | to_json(0)')" = "$(runner_toml build 'del(.priority_class_name, .pod_labels) | to_json(0)')" ] &&
  [ "$(runner_toml build-report '.priority_class_name + " " + .pod_labels."tacplus.dev/ci-runner"')" = "build-report build-report" ] &&
  [ "$(runner_cfg build-report 'del(.kubernetes) | to_json(0)')" = "$(runner_cfg build 'del(.kubernetes) | to_json(0)')" ] &&
  ok "build-report's jobs are build's, at the PriorityClass build-report" ||
  fail "build-report's jobs differ from build's: $(diff <(runner_cfg build-report '.') <(runner_cfg build '.'))"
# The nightly's runner (#46; tacplus-dev/looper#220): build's jobs as they are too (a nightly's CodeQL asks build's
# ceilings, 3500m and 12Gi, tacplus-dev/looper#189), at the PriorityClass build-nightly, so it preempts a report build
# and a land's build preempts it; a land's build's at the PriorityClass build.
[ "$(runner_toml nightly 'del(.priority_class_name, .pod_labels) | to_json(0)')" = "$(runner_toml build 'del(.priority_class_name, .pod_labels) | to_json(0)')" ] &&
  [ "$(runner_toml nightly '.priority_class_name + " " + .pod_labels."tacplus.dev/ci-runner"')" = "build-nightly nightly" ] &&
  [ "$(runner_toml build '.priority_class_name')" = build ] &&
  [ "$(runner_cfg nightly 'del(.kubernetes) | to_json(0)')" = "$(runner_cfg build 'del(.kubernetes) | to_json(0)')" ] &&
  ok "the nightly's jobs are build's, at the PriorityClass build-nightly; build's at build" ||
  fail "the nightly's jobs differ from build's: $(diff <(runner_cfg nightly '.') <(runner_cfg build '.'))"
for r in build-light control infra kick; do
  [ "$(runner_toml $r '[(.node_selector // {}) | keys[], (.node_tolerations // {}) | keys[]] | map(select(test("spot"))) | length')" = 0 ] &&
    [ "$(runner_toml $r '.affinity.node_affinity.required_during_scheduling_ignored_during_execution.node_selector_terms[0].match_expressions[] | select(.key == "spot") | .operator + " " + .values[0]')" = "NotIn true" ] &&
    [ "$(runner_toml $r '.automount_service_account_token')" = false ] &&
    ok "$r jobs never tolerate the spot taint, refuse a spot node, and get no service account token" || fail "$r jobs' placement or token"
done
# The looper pool is gone (#64; tacplus-dev/cloud#114, step 1): no runner's jobs tolerate its taint, select its label or
# name it in a node affinity, and control's wait GitLab's default poll_timeout, not the minutes a looper node from 0 took.
for r in build build-light build-report control infra kick nightly; do
  [ "$(runner_toml $r '[(.node_selector // {}) | keys[], (.node_tolerations // {}) | keys[], (.affinity // {} | .. | select(tag == "!!map" and has("key")) | .key)] | map(select(test("looper"))) | length')" = 0 ] &&
    ok "$r jobs never tolerate, select or prefer against the looper pool" || fail "$r jobs name the looper pool"
done
[ "$(runner_toml control '.poll_timeout // "none"')" = none ] &&
  ok "control jobs wait GitLab's default poll_timeout" || fail "control's poll_timeout: [$(runner_toml control '.poll_timeout')]"
[ "$(yq ea '[select(.kind == "Deployment") | .spec.template.spec.tolerations[]? | select(.key == "looper")] | length' "$ci")" = 0 ] &&
  ok "no runner manager tolerates the looper taint" || fail "a runner manager tolerates the looper taint"
# A job runs as a user with no home in the job image (uid 1000), so each runner gives it HOME on an emptyDir of its
# own, writable and there before the script runs (#20: git config --global wrote //.gitconfig).
for r in build build-light build-report control infra kick nightly; do
  home=$(runner_cfg $r '(.environment // [])[] | select(test("^HOME=")) | sub("^HOME="; "")')
  [ -n "$home" ] && [ "$home" != / ] &&
    [ "$(H=$home runner_toml $r '[(.volumes.empty_dir // [])[] | select(.mount_path == strenv(H))] | length')" = 1 ] &&
    ok "$r jobs have HOME=$home, an emptyDir" || fail "$r jobs' HOME is [$home], or no emptyDir is mounted there"
done
# Each runner's own container has a CPU limit (#34: KSV-0011), the chart's resources value, gitlab-runner/values.yaml's.
for r in build build-light build-report control infra kick nightly; do
  cpu=$(R=$r yq 'select(.kind == "Deployment" and .metadata.name == "gitlab-runner-" + strenv(R)) | .spec.template.spec.containers[0].resources.limits.cpu' "$ci")
  [ "$cpu" = 500m ] && ok "$r's runner has its CPU limited to 500m" || fail "$r's runner's CPU limit is [$cpu]"
done
# Each runner's own container has a read-only root filesystem (#29: KSV-0014); where GitLab Runner writes, /tmp (each
# job's log buffer: without it every job failed at once, #37), its home (its working directory) and its config under
# it, is an emptyDir.
pod() { R=$r yq "select(.kind == \"Deployment\" and .metadata.name == \"gitlab-runner-\" + strenv(R)) | .spec.template.spec | $1" "$ci"; }
emptydir() { local v; v=$(pod ".containers[0].volumeMounts[] | select(.mountPath == \"$1\") | .name")
  [ -n "$v" ] && [ "$(pod ".volumes[] | select(.name == \"$v\" and has(\"emptyDir\")) | .name")" = "$v" ] && echo 1 || echo 0; }
for r in build build-light build-report control infra kick nightly; do
  [ "$(pod '.containers[0].securityContext.readOnlyRootFilesystem')" = true ] &&
    [ "$(emptydir /tmp)" = 1 ] && [ "$(emptydir /home/gitlab-runner)" = 1 ] &&
    [ "$(emptydir /home/gitlab-runner/.gitlab-runner)" = 1 ] &&
    ok "$r's runner has a read-only root filesystem, /tmp, its home and config on emptyDirs" ||
    fail "$r's runner: readOnlyRootFilesystem [$(pod '.containers[0].securityContext.readOnlyRootFilesystem')], /tmp [$(emptydir /tmp)], home [$(emptydir /home/gitlab-runner)], config [$(emptydir /home/gitlab-runner/.gitlab-runner)]"
done
[ "$(yq ea '[select(.kind == "Deployment") | .spec.template.metadata.annotations."tacplus.dev/runner-token"] | join(" ")' "$ci")" = \
  "$(for r in build-light build-report build control infra kick nightly; do yq '.tacplus.token' "$here/gitlab-runner/runners/$r.yaml"; done | paste -sd ' ')" ] &&
  ok "each runner's pods name its token's Secret Manager version" || fail "the runners' token versions"
# A new token version is a new pod template, so the apply rolls that runner's pods onto it, and no other's (#58).
rm -rf "$work/runners" "$work/rotated" && cp -R "$here/gitlab-runner/runners" "$work/runners" &&
  yq -i '.tacplus.token = "projects/tacplus-dev/secrets/gitlab-runner-build-light/versions/2"' "$work/runners/build-light.yaml"
if RUNNERS=$work/runners "$here/render.sh" "$fixtures/deployments.yaml" "$work/rotated" > "$work/log" 2>&1; then
  template() { R=$2 yq 'select(.kind == "Deployment" and .metadata.name == "gitlab-runner-" + strenv(R)) | .spec.template' "$1/20-ci.yaml"; }
  [ "$(template "$work/rotated" build-light | yq '.metadata.annotations."tacplus.dev/runner-token"')" = \
    projects/tacplus-dev/secrets/gitlab-runner-build-light/versions/2 ] &&
    [ "$(template "$work/rotated" build-light | yq 'del(.metadata.annotations."tacplus.dev/runner-token")')" = \
      "$(template "$work/out" build-light | yq 'del(.metadata.annotations."tacplus.dev/runner-token")')" ] &&
    [ "$(template "$work/rotated" control)" = "$(template "$work/out" control)" ] &&
    ok "a new token version is a new pod template annotation, that runner's alone" ||
    fail "a new token version: build-light's pods name [$(template "$work/rotated" build-light | yq '.metadata.annotations."tacplus.dev/runner-token"')]"
else
  fail "render.sh failed on a new token version: $(cat "$work/log")"
fi
# The infra runner (#25): the cloud, cluster and deploy pipelines' tags, nothing else, protected refs only; the other
# two neither protected nor holding one of its tags. Its pods say so (the hub registers it as its file says).
annotation() { R=$1 A=$2 yq 'select(.kind == "Deployment" and .metadata.name == "gitlab-runner-" + strenv(R)) | .spec.template.metadata.annotations[("tacplus.dev/" + strenv(A))] // ""' "$ci"; }
[ "$(annotation infra runner-tags)" = "cloud,cluster,deploy" ] && [ "$(annotation infra runner-protected)" = true ] &&
  ok "infra's pods name its tags cloud, cluster, deploy, and that it is protected refs only" ||
  fail "infra's pods: tags [$(annotation infra runner-tags)], protected [$(annotation infra runner-protected)]"
[ "$(annotation build runner-protected) $(annotation build-light runner-protected) $(annotation build-report runner-protected) $(annotation control runner-protected) $(annotation kick runner-protected) $(annotation nightly runner-protected)" = "false false false false false false" ] &&
  ! [[ ",$(annotation build runner-tags),$(annotation build-light runner-tags),$(annotation build-report runner-tags),$(annotation control runner-tags),$(annotation kick runner-tags),$(annotation nightly runner-tags)," =~ ,(cloud|cluster|deploy), ]] &&
  ok "build, build-light, build-report, control, kick and nightly are not protected and hold none of infra's tags" ||
  fail "build [$(annotation build runner-tags), protected $(annotation build runner-protected)], build-light [$(annotation build-light runner-tags), protected $(annotation build-light runner-protected)], build-report [$(annotation build-report runner-tags), protected $(annotation build-report runner-protected)], control [$(annotation control runner-tags), protected $(annotation control runner-protected)], kick [$(annotation kick runner-tags), protected $(annotation kick runner-protected)]"
# The report builds' runner (#42): arm64 and build-report, never build (GitLab would give it a land's build's jobs too),
# so tacplus-dev/build's report builds (BUILD_REPORT_TAGS) reach it and a land's (arm64, build) never does.
[ "$(annotation build-report runner-tags)" = "arm64,build-report" ] && [ "$(annotation build runner-tags)" = "arm64,build" ] &&
  ok "build-report's pods name its tags arm64, build-report; build's arm64, build" ||
  fail "build-report's tags [$(annotation build-report runner-tags)], build's [$(annotation build runner-tags)]"
# The nightly's runner (#46): arm64 and build-nightly, never build, so tacplus-dev/build's nightly (BUILD_NIGHTLY_TAGS)
# reaches it and a land's never does.
[ "$(annotation nightly runner-tags)" = "arm64,build-nightly" ] &&
  ok "nightly's pods name its tags arm64, build-nightly" || fail "nightly's tags [$(annotation nightly runner-tags)]"
# The kick runner (#36): the looper's kicker and plan (.control, tagged arm64, kick) on a runner of their own, so they
# never wait behind the reports filling control: arm64 and kick, never control (GitLab would give it the reports too).
[ "$(annotation kick runner-tags)" = "arm64,kick" ] && [ "$(annotation control runner-tags)" = "arm64,control" ] &&
  ok "kick's pods name its tags arm64, kick; control's arm64, control" ||
  fail "kick's tags [$(annotation kick runner-tags)], control's [$(annotation control runner-tags)]"
# A kick or a plan job asks little (#39: the looper's .control requests, tacplus-dev/looper#165): kick's defaults are
# 50m and 256Mi.
[ "$(runner_toml kick '.cpu_request + " " + .memory_request')" = "50m 256Mi" ] &&
  ok "kick's jobs default to 50m and 256Mi, a kicker's or a plan's requests" ||
  fail "kick's jobs default to [$(runner_toml kick '.cpu_request + " " + .memory_request')]"
# The light builds' runner (#51; tacplus-dev/cloud#100): tacplus-dev/build's pending, plan and reports (arm64,
# build-light) on the normal pool, on slots of their own, so they never wait behind the gates and security jobs holding
# build's; arm64 and build-light, never build (GitLab would give it those jobs too, off the spot pool). Each asks what
# a kick does: 50m and 256Mi.
[ "$(annotation build-light runner-tags)" = "arm64,build-light" ] &&
  [ "$(runner_toml build-light '.cpu_request + " " + .memory_request + " " + .memory_limit')" = "50m 256Mi 2Gi" ] &&
  ok "build-light's pods name its tags arm64, build-light; its jobs default to 50m and 256Mi, limited to 2Gi" ||
  fail "build-light's tags [$(annotation build-light runner-tags)], its jobs' defaults [$(runner_toml build-light '.cpu_request + " " + .memory_request + " " + .memory_limit')]"
# The runner managers first (#39): a manager that cannot schedule takes its whole runner down, so each runs at the
# PriorityClass ci-runner-manager, above the jobs' pods (0, none set but build-report's and control's), preempting them; never the
# cluster's default.
pclass() { N=$1 yq 'select(.kind == "PriorityClass" and .metadata.name == strenv(N)) | (.value | tostring) + " " + .preemptionPolicy + " " + (.globalDefault // false | tostring)' "$ci"; }
[ "$(yq ea '[select(.kind == "PriorityClass") | .metadata.name] | join(" ")' "$ci")" = "ci-runner-manager build build-nightly build-report control-job" ] &&
  [ "$(pclass ci-runner-manager)" = "1000000 PreemptLowerPriority false" ] &&
  ok "the PriorityClass ci-runner-manager, above the jobs, preempting them, not the cluster's default" ||
  fail "the PriorityClasses: $(yq -o=json -I=0 'select(.kind == "PriorityClass")' "$ci")"
# The report builds' jobs (#42; tacplus-dev/looper#209): a land's build (0, build's jobs set none) preempts them when the
# spot pool is full, so it never waits ~55 minutes for a report build to end; they preempt nothing themselves, and stay
# at or above the cluster autoscaler's expendable cutoff (-10), so they still scale the spot pool up.
[ "$(pclass build-report)" = "-1 Never false" ] &&
  ok "the PriorityClass build-report, below a land's build's jobs (0), never preempting, not expendable, not the default" ||
  fail "the PriorityClass build-report: [$(pclass build-report)]"
# The spot pool's order (#46): a land's build (build, 1) preempts the nightly (build-nightly, 0), which preempts the
# report builds (build-report, -1): a nightly security job evicts a report build instead of waiting past poll_timeout
# (2026-11-21/22: 10 of 31 repositories' nightly published nothing), and never delays a land. Not the default.
[ "$(pclass build)" = "1 PreemptLowerPriority false" ] && [ "$(pclass build-nightly)" = "0 PreemptLowerPriority false" ] &&
  ok "the PriorityClasses build (1) and build-nightly (0), above build-report, preempting, not the default" ||
  fail "the PriorityClasses build [$(pclass build)], build-nightly [$(pclass build-nightly)]"
# control's jobs (#49): infra's and kick's (0, theirs set none) preempt them when the normal pool is full of them, so a
# cloud or cluster apply never waits Pending behind the looper's reports (cloud's pipelines 3100887560 and 3101379440,
# 2026-11-23); they preempt nothing themselves, below deploymentproxy's and the deployments' pods, and stay at or above
# the autoscaler's expendable cutoff.
[ "$(pclass control-job)" = "-1 Never false" ] &&
  ok "the PriorityClass control-job, below infra's and kick's jobs (0), never preempting, not expendable, not the default" ||
  fail "the PriorityClass control-job: [$(pclass control-job)]"
for r in build build-light build-report control infra kick nightly; do
  case $r in build|build-report) want=$r ;; nightly) want=build-nightly ;; control) want=control-job ;; *) want= ;; esac
  [ "$(pod '.priorityClassName')" = ci-runner-manager ] && [ "$(runner_toml $r '.priority_class_name // ""')" = "$want" ] &&
    ok "$r's runner runs at ci-runner-manager, its jobs at ${want:-none}" ||
    fail "$r's runner's priorityClassName [$(pod '.priorityClassName')], its jobs' [$(runner_toml $r '.priority_class_name // ""')]"
done
[ "$(yq '.tacplus.protected' "$here/gitlab-runner/runners/infra.yaml")" = true ] && ok "gitlab-runner/runners/infra.yaml says protected: true" || fail "infra.yaml's protected is [$(yq '.tacplus.protected' "$here/gitlab-runner/runners/infra.yaml")]"
! grep -q 'glrt-[A-Za-z0-9_]' "$ci" && [ "$(yq ea '[select(.kind == "Secret")] | length' "$ci")" = 0 ] &&
  ok "no token and no Secret in the render" || fail "the render holds a token or a Secret"

# The default quota leaves the release's ConfigMap as it is.
"$here/render.sh" "$fixtures/removed.yaml" "$work/removed" > "$work/log" 2>&1 || fail "render.sh failed on removed.yaml: $(cat "$work/log")"
diff <(yq 'select(.kind == "ConfigMap")' "$work/removed/00-deploymentproxy.yaml") \
     <(yq '.' "$here/deploymentproxy/release/config/manager/configmap.yaml") >/dev/null &&
  ok "with every quota the default, the ConfigMap is the release's" || fail "the default quota changed the release's ConfigMap"

# A removed entry renders nothing for it, and the rest as before.
[ "$(ls "$work/removed" | tr '\n' ' ')" = "00-deploymentproxy.yaml 05-storage.yaml 10-deployment-alpha.yaml 20-ci.yaml " ] &&
  cmp -s "$work/removed/10-deployment-alpha.yaml" "$fixtures/out/10-deployment-alpha.yaml" &&
  ! grep -q beta "$work/removed/"* &&
  ok "a removed entry renders nothing for it" || fail "a removed entry: $(ls "$work/removed" | tr '\n' ' ')"

# The repository's own deployments.yaml renders and passes the policy.
if "$here/render.sh" "$here/deployments.yaml" "$work/real" > "$work/log" 2>&1 && "$here/ci/policy.sh" "$work/real" > "$work/policy" 2>&1; then
  ok "deployments.yaml renders and passes ci/policy.sh"
else
  fail "deployments.yaml: $(cat "$work/log" "$work/policy" 2>/dev/null)"
fi
ns=$(yq 'select(.kind == "Namespace") | .metadata.labels."tacplus.dev/deployment"' "$work/real/10-deployment-seatrials.yaml" 2>/dev/null)
[ "$ns" = seatrials ] && ok "seatrials: tac-seatrials labelled tacplus.dev/deployment=seatrials" || fail "seatrials' namespace label is [$ns]"
objects() { yq -N '.kind + " " + (.metadata.namespace // "") + " " + .metadata.name' "$1" 2>/dev/null | tr '\n' ','; }
# #59: a deployment with an operator has the operator's own Role in tac-<name> (the operator's chart renders none
# with `deployment` set), bound to its operator account there only; the deploy account reads its TenantNamespaces.
[ "$(objects "$work/real/10-deployment-seatrials.yaml")" = "Namespace  tac-seatrials,Role tac-seatrials deploymentproxy-tenantnamespaces,RoleBinding tac-seatrials deploymentproxy-tenantnamespaces,Role tac-seatrials deployment-operator,RoleBinding tac-seatrials deployment-operator,Role tac-seatrials fleet-deploy,RoleBinding tac-seatrials fleet-deploy," ] &&
  [ "$(yq -o=json -I=0 'select(.kind == "RoleBinding" and .metadata.name == "deployment-operator") | .subjects' "$work/real/10-deployment-seatrials.yaml")" = '[{"kind":"ServiceAccount","name":"operator","namespace":"tac-seatrials"}]' ] &&
  ok "seatrials: the operator's Role, bound to tac-seatrials/operator" ||
  fail "seatrials renders: $(objects "$work/real/10-deployment-seatrials.yaml")"
# grants FILE ROLE: each group/resource/verb the Role ROLE grants in FILE, one per line, sorted.
grants() { R=$2 yq -N 'select(.kind == "Role" and .metadata.name == strenv(R)) | .rules[] | .apiGroups[] as $g | .resources[] as $r | .verbs[] as $v | $g + "/" + $r + " " + $v' "$1" | sort -u; }
for d in alpha beta-2; do
  f=$work/out/10-deployment-$d.yaml
  op=$(yq ".deployments[] | select(.name == \"$d\") | .operator" "$fixtures/deployments.yaml")
  [ "$(yq ea -o=json -I=0 '[select(.kind == "RoleBinding" and .metadata.name == "deployment-operator")] | .[] | [.roleRef.kind, .roleRef.name, .subjects]' "$f")" = "[\"Role\",\"deployment-operator\",[{\"kind\":\"ServiceAccount\",\"name\":\"$op\",\"namespace\":\"tac-$d\"}]]" ] &&
    ok "$d: the operator's Role bound to tac-$d/$op" || fail "$d: the operator's binding: $(yq 'select(.metadata.name == "deployment-operator")' "$f")"
  # The chart's Role (operator helm/templates/role.yaml): the fleet's chart's objects, helm's Secrets, its Roles,
  # pods read and deleted, leases, events written; nothing the deploy account does not hold itself.
  [ "$(grants "$f" deployment-operator | wc -l)" -gt 0 ] &&
    [ -z "$(comm -23 <(grants "$f" deployment-operator) <(grants "$f" fleet-deploy))" ] &&
    grants "$f" deployment-operator | grep -qx 'rbac.authorization.k8s.io/roles create' &&
    grants "$f" deployment-operator | grep -qx '/secrets update' &&
    ! grants "$f" deployment-operator | grep -q tenantnamespaces &&
    ok "$d: the operator's Role is within fleet-deploy" ||
    fail "$d: the operator's Role grants beyond fleet-deploy: $(comm -23 <(grants "$f" deployment-operator) <(grants "$f" fleet-deploy) | tr '\n' ',')"
  [ "$(grants "$f" fleet-deploy | grep tenantnamespaces | tr '\n' ',')" = "deploymentproxy.tacplus.dev/tenantnamespaces get,deploymentproxy.tacplus.dev/tenantnamespaces list,deploymentproxy.tacplus.dev/tenantnamespaces watch," ] &&
    ok "$d: the deploy account reads its TenantNamespaces, and only reads them" ||
    fail "$d: fleet-deploy on tenantnamespaces: $(grants "$f" fleet-deploy | grep tenantnamespaces | tr '\n' ',')"
done
[ "$(objects "$work/real/10-deployment-test-idp.yaml")" = "Namespace  tac-test-idp,Role tac-test-idp fleet-deploy,RoleBinding tac-test-idp fleet-deploy," ] &&
  [ "$(yq 'select(.kind == "RoleBinding") | .subjects[0].name' "$work/real/10-deployment-test-idp.yaml")" = test-idp-deploy@tacplus-dev.iam.gserviceaccount.com ] &&
  ok "test-idp: its namespace and the deploy Role only, bound to test-idp-deploy" ||
  fail "test-idp renders: $(objects "$work/real/10-deployment-test-idp.yaml")"

# A deployment without an operator: its namespace and the deploy account's Role only, no deploymentproxy Role nor
# operator binding; the rest of it as with one, and it passes ci/policy.sh.
if "$here/render.sh" "$fixtures/no-operator.yaml" "$work/no-operator" > "$work/log" 2>&1; then
  g=$work/no-operator/10-deployment-gamma.yaml
  [ "$(objects "$g")" = "Namespace  tac-gamma,Role tac-gamma fleet-deploy,RoleBinding tac-gamma fleet-deploy," ] &&
    ! grep -q -e ServiceAccount -e deployment-operator "$g" &&
    diff <(yq 'select(.kind != "Namespace")' "$g") \
         <(yq 'select(.metadata.name == "fleet-deploy")' "$fixtures/out/10-deployment-alpha.yaml" | sed 's/tac-alpha/tac-gamma/; s/alpha-deploy/gamma-deploy/') >/dev/null &&
    ok "no operator: the namespace and the deploy Role only" || fail "no operator renders: $(objects "$g")"
  "$here/ci/policy.sh" "$work/no-operator" > "$work/policy" 2>&1 &&
    ok "no operator: passes ci/policy.sh" || fail "no operator: ci/policy.sh: $(cat "$work/policy")"
else
  fail "render.sh failed on no-operator.yaml: $(cat "$work/log")"
fi

# A release file that does not match its checksum is refused.
cp -R "$here/." "$work/tree" 2>/dev/null; rm -rf "$work/tree/out"
echo "# edited" >> "$work/tree/deploymentproxy/release/config/rbac/cluster_role.yaml"
if "$work/tree/render.sh" "$fixtures/deployments.yaml" "$work/edited" > "$work/log" 2>&1; then
  fail "a release file edited by hand rendered"
else
  grep -q 'SHA256SUMS' "$work/log" && ok "a release file edited by hand is refused" || fail "the refusal says: $(cat "$work/log")"
fi

# A chart file edited by hand is refused.
cp -R "$here/." "$work/tree2" 2>/dev/null; rm -rf "$work/tree2/out"
echo "# edited" >> "$work/tree2/gitlab-runner/release/templates/deployment.yaml"
if "$work/tree2/render.sh" "$fixtures/deployments.yaml" "$work/edited2" > "$work/log" 2>&1; then
  fail "a chart file edited by hand rendered"
else
  grep -q 'gitlab-runner/release does not match its SHA256SUMS' "$work/log" && ok "a chart file edited by hand is refused" || fail "the refusal says: $(cat "$work/log")"
fi

# refused_runner NAME YQ WANT: render.sh refuses the build runner's file changed by YQ, saying WANT.
refused_runner() {
  rm -rf "$work/runners" "$work/bad" && cp -R "$here/gitlab-runner/runners" "$work/runners"
  yq -i "$2" "$work/runners/build.yaml"
  if RUNNERS=$work/runners "$here/render.sh" "$fixtures/deployments.yaml" "$work/bad" > "$work/log" 2>&1; then
    fail "runner: $1: rendered"
  elif ! grep -q -- "$3" "$work/log"; then
    fail "runner: $1: the refusal does not say [$3]: $(cat "$work/log")"
  else
    ok "refused: a runner with $1"
  fi
}
refused_runner "its token by latest" '.tacplus.token = "projects/tacplus-dev/secrets/gitlab-runner-build/versions/latest"' "never latest"
refused_runner "no token" 'del(.tacplus.token)' "tacplus.token \[\] is not a Secret Manager version"
refused_runner "no tags" '.tacplus.tags = []' "tacplus.tags is not a list"
refused_runner "protected that is not a boolean" '.tacplus.protected = "yes"' "tacplus.protected \[yes\] is not true or false"
refused_runner "its own security context" '.securityContext.privileged = true' "sets securityContext, which only gitlab-runner/values.yaml sets"
refused_runner "its own RBAC" '.rbac.clusterWideAccess = true' "sets rbac, which only"
refused_runner "its own image" '.runners.image = "alpine"' "sets runners.image, which only"
refused_runner "no config" 'del(.runners.config)' "no runners.config"

# The normal pool's room (#36): control's concurrent is what gitlab-runner/pool.yaml leaves for its jobs' pods (their
# default requests, job and helper) once the reserve, every runner manager, deploymentproxy and infra's jobs at its
# full concurrent are counted, and kick's (#36: the kicker and the plan, never queued behind control's reports) and
# build-light's (#51), CPU and memory both; never a fixed number.
concurrent() { R=$1 yq 'select(.kind == "ConfigMap" and .metadata.name == "gitlab-runner-" + strenv(R)) | .data."config.toml"' "$2" |
  sed -n 's/^ *concurrent = //p'; }
# 3 x 1930m - 1200m - 7 x 50m (managers, build-report's since #42, build-light's since #51, nightly's since #46) - 50m
# (deploymentproxy) - 4 x 550m (infra) - 2 x 100m (kick) - 4 x 100m (build-light) = 1390m (#39, #42, #51, #46); memory
# 3 x 6144Mi - 3Gi - 7 x 128Mi - 64Mi - 4 x 1088Mi - 2 x 320Mi - 4 x 320Mi = 8128Mi. The spot pool's runners (build,
# build-report, nightly) take nothing of it but their managers. The looper pool is gone (#64), so of the 1390m and
# 8128Mi the looper's managers' room (#53: 4 x 250m, 4 x 256Mi) leaves 390m for 1 pod of 200m (a report's 150m and the
# helper's 50m), 7104Mi for 12 of 576Mi.
[ "$(concurrent control "$ci")" = 1 ] && [ "$(concurrent infra "$ci")" = 4 ] && [ "$(concurrent kick "$ci")" = 2 ] &&
  [ "$(concurrent build-light "$ci")" = 4 ] && [ "$(concurrent build "$ci") $(concurrent build-report "$ci") $(concurrent nightly "$ci")" = "8 8 4" ] &&
  grep -q '^# The runner control .*concurrent 1, the normal pool.s room (gitlab-runner/pool.yaml)' "$ci" &&
  ok "control's concurrent is the normal pool's room for its jobs beside the managers' (1), infra's, kick's, build-light's, build's, build-report's and nightly's their own (4, 2, 4, 8, 8, 4)" ||
  fail "concurrent: control [$(concurrent control "$ci")], infra [$(concurrent infra "$ci")], kick [$(concurrent kick "$ci")], build-light [$(concurrent build-light "$ci")], build [$(concurrent build "$ci")], build-report [$(concurrent build-report "$ci")], nightly [$(concurrent nightly "$ci")]"
# pooled NAME YQ WANT: control's concurrent with gitlab-runner/pool.yaml changed by YQ is WANT, or render.sh refuses it
# saying WANT.
pooled() {
  rm -rf "$work/bad" && yq "$2" "$here/gitlab-runner/pool.yaml" > "$work/pool.yaml"
  if POOL=$work/pool.yaml "$here/render.sh" "$fixtures/deployments.yaml" "$work/bad" > "$work/log" 2>&1; then
    [ "$(concurrent control "$work/bad/20-ci.yaml")" = "$3" ] && ok "pool: $1: control's concurrent is $3" ||
      fail "pool: $1: control's concurrent is [$(concurrent control "$work/bad/20-ci.yaml")], not $3"
  else
    grep -q -- "$3" "$work/log" && ok "pool: refused: $1" || fail "pool: $1: $(cat "$work/log")"
  fi
}
# 1390m - 1000m = 390m: 1 pod.
pooled "two nodes, CPU the bound" '.nodes = 2 | .reserved.cpu = "450m" | .managers.count = 0' 1
pooled "4Gi nodes, memory the bound" '.allocatable.memory = "4Gi"' 1
pooled "a smaller reserve" '.reserved.cpu = "800m"' 3
pooled "no room for one job" '.reserved.cpu = "1500m"' "the normal pool has no room for one job of control"
pooled "a quantity it cannot read" '.reserved.cpu = "1.5"' "gitlab-runner/pool.yaml: reserved.cpu \[1.5\] is not"
# The looper pool is gone (#64; tacplus-dev/cloud#114): a looper block is refused, not counted, at any size.
pooled "a looper pool" '.looper = {"max_nodes": 2, "allocatable": {"cpu": "1930m", "memory": "6Gi"}, "daemonsets": {"cpu": "400m", "memory": "1Gi"}}' "gitlab-runner/pool.yaml: looper: the looper pool is gone (tacplus-dev/cloud#114)"
pooled "a looper pool at 0 nodes" '.looper.max_nodes = 0' "gitlab-runner/pool.yaml: looper: the looper pool is gone"
# The looper's managers' room (#53): control's jobs, at their own requests (250m and 256Mi, above the report's its
# defaults count), taken from the pool's room before its slots; without it, none: 1390m / 200m = 6. Memory the bound:
# 8128Mi - 4 x 1792Mi = 960Mi, 1 of 576Mi.
pooled "no managers' room" 'del(.managers)' 6
pooled "2 managers" '.managers.count = 2' 4
pooled "managers' memory the bound" '.managers.memory = "1792Mi"' 1
pooled "managers filling the pool" '.managers.count = 6' "the normal pool has no room for one job of control"
pooled "the managers' count not a number" '.managers.count = "four"' "gitlab-runner/pool.yaml: managers.count \[four\] is not a number of managers"
pooled "a managers' quantity it cannot read" '.managers.cpu = "0.25"' "gitlab-runner/pool.yaml: managers.cpu \[0.25\] is not"
# pool_runner NAME YQ WANT: render.sh refuses the runner files changed by YQ (on control.yaml, then infra.yaml), saying WANT.
pool_runner() {
  rm -rf "$work/runners" "$work/bad" && cp -R "$here/gitlab-runner/runners" "$work/runners"
  yq -i "$2" "$work/runners/control.yaml"; yq -i "$3" "$work/runners/infra.yaml"
  if RUNNERS=$work/runners "$here/render.sh" "$fixtures/deployments.yaml" "$work/bad" > "$work/log" 2>&1; then
    fail "pool: $1: rendered"
  else
    grep -q -- "$4" "$work/log" && ok "pool: refused: $1" || fail "pool: $1: the refusal does not say [$4]: $(cat "$work/log")"
  fi
}
pool_runner "two runners on the pool's room" '.' '.concurrent = "pool"' "runner infra: concurrent pool, as control: one runner only"
pool_runner "fixed runners overfilling the pool" '.concurrent = 8' '.concurrent = 9' "the normal pool has no room for its runners' jobs"

# The spot pool's room (#41): build's and build-report's concurrent, each, is gitlab-runner/spot-pool.yaml's max nodes
# times the jobs of its largest kind a node holds once its daemonsets are counted: their ceilings (3500m, 12Gi) and
# the helper's requests (100m, 128Mi), 3600m and 12416Mi, in (3920m - 300m) and (13600Mi - 1Gi) = 1 a node, 8 on 8. Per
# node, not the pool's sum: these pods are large beside a node. Each counts the whole pool: a land's build preempts a
# report build (#42), so the two never wait on each other's room.
[ "$(concurrent build "$ci") $(concurrent build-report "$ci")" = "8 8" ] &&
  grep -q '^# The runner build .*concurrent 8, the spot pool.s room at its max nodes (gitlab-runner/spot-pool.yaml)' "$ci" &&
  grep -q '^# The runner build-report .*concurrent 8, the spot pool.s room at its max nodes' "$ci" &&
  ok "build's and build-report's concurrent is the spot pool's room for their largest jobs, one a node (8, 8)" ||
  fail "concurrent: build [$(concurrent build "$ci")], build-report [$(concurrent build-report "$ci")]"
# spotted NAME YQ WANT: build's concurrent with gitlab-runner/spot-pool.yaml changed by YQ is WANT, or render.sh
# refuses it saying WANT.
spotted() {
  rm -rf "$work/bad" && yq "$2" "$here/gitlab-runner/spot-pool.yaml" > "$work/spot-pool.yaml"
  if SPOT_POOL=$work/spot-pool.yaml "$here/render.sh" "$fixtures/deployments.yaml" "$work/bad" > "$work/log" 2>&1; then
    [ "$(concurrent build "$work/bad/20-ci.yaml")" = "$3" ] && ok "spot pool: $1: build's concurrent is $3" ||
      fail "spot pool: $1: build's concurrent is [$(concurrent build "$work/bad/20-ci.yaml")], not $3"
  else
    grep -q -- "$3" "$work/log" && ok "spot pool: refused: $1" || fail "spot pool: $1: $(cat "$work/log")"
  fi
}
spotted "five nodes" '.max_nodes = 5' 5
spotted "fewer nodes than the nightly's fixed concurrent" '.max_nodes = 3' "runner nightly: concurrent 4, but the spot pool has room for 3 of its jobs"
spotted "larger nodes, CPU the bound: 11700m for 3, 63Gi for 5" '.allocatable.cpu = "12" | .allocatable.memory = "64Gi"' 24
spotted "larger nodes, memory the bound: 11700m for 3, 25Gi for 2" '.allocatable.cpu = "12" | .allocatable.memory = "26Gi"' 16
spotted "more nodes than GitLab's count" '.max_nodes = 120' 99
spotted "daemonsets leaving no room for one job" '.daemonsets.cpu = "400m"' "the spot pool's nodes have no room for one job of build-report (3600m, 12416Mi)"
spotted "no nodes" '.max_nodes = 0' "gitlab-runner/spot-pool.yaml: max_nodes \[0\] is not a number of nodes"
spotted "a quantity it cannot read" '.daemonsets.cpu = "0.3"' "gitlab-runner/spot-pool.yaml: daemonsets.cpu \[0.3\] is not"
# A runner without ceilings counts its default requests (1100m, 4224Mi): 3 a node by CPU, 2 by memory, 16; one with a
# fixed concurrent is held to the room.
rm -rf "$work/runners" "$work/bad" && cp -R "$here/gitlab-runner/runners" "$work/runners"
yq -i '.runners.config |= sub("\\n *(cpu|memory)_request_overwrite_max_allowed = \"[^\"]*\""; "")' "$work/runners/build.yaml"
RUNNERS=$work/runners "$here/render.sh" "$fixtures/deployments.yaml" "$work/bad" > "$work/log" 2>&1 &&
  [ "$(concurrent build "$work/bad/20-ci.yaml") $(concurrent build-report "$work/bad/20-ci.yaml")" = "16 8" ] &&
  ok "spot pool: build without ceilings: its defaults count, 16" ||
  fail "spot pool: build without ceilings: [$(concurrent build "$work/bad/20-ci.yaml" 2>/dev/null)] $(cat "$work/log")"
refused_runner "a fixed concurrent beyond the spot pool's room" '.concurrent = 9' "runner build: concurrent 9, but the spot pool has room for 8 of its jobs"
refused_runner "concurrent neither a number nor pool" '.concurrent = "many"' "concurrent is not 1 to 99, nor pool"

# refused NAME YAML WANT: render.sh refuses deployments.yaml YAML, saying WANT, and writes nothing.
refused() {
  printf '%s\n' "$2" > "$work/bad.yaml"
  rm -rf "$work/bad"
  if "$here/render.sh" "$work/bad.yaml" "$work/bad" > "$work/log" 2>&1; then
    fail "$1: rendered"
  elif ! grep -q -- "$3" "$work/log"; then
    fail "$1: the refusal does not say [$3]: $(cat "$work/log")"
  elif [ -e "$work/bad" ]; then
    fail "$1: refused, but wrote $work/bad"
  else
    ok "refused: $1"
  fi
}
entry() { # entry NAME [FIELD: VALUE...]: one entry, its fields overridden or added.
  local name=$1; shift
  printf '  - name: %s\n' "$name"
  local -A f=([deployAccount]=x-deploy@project-1.iam.gserviceaccount.com [operator]=operator [gitlabProject]=tacplus-dev/fleet-x [quota]='{}')
  local kv; for kv in "$@"; do f[${kv%%:*}]=${kv#*: }; done
  for k in "${!f[@]}"; do [ "${f[$k]}" = - ] || printf '    %s: %s\n' "$k" "${f[$k]}"; done
}
refused "a name of 17 characters" "deployments:
$(entry abcdefghijklmnopq)" "abcdefghijklmnopq"
refused "a name starting with a digit" "deployments:
$(entry 1abc)" "1abc"
refused "a name with an upper-case letter" "deployments:
$(entry Abc)" "Abc"
refused "a name with a dot" "deployments:
$(entry a.b)" "a.b"
refused "a duplicate name" "deployments:
$(entry dup)
$(entry dup)" "dup"
refused "no deploy account" "deployments:
$(entry x 'deployAccount: -')" "deployAccount"
refused "a deploy account that is not a Google service account" "deployments:
$(entry x 'deployAccount: someone@gmail.com')" "someone@gmail.com"
refused "an operator account that is not a name" "deployments:
$(entry x 'operator: Op/erator')" "Op/erator"
refused "an empty operator account" "deployments:
$(entry x 'operator: ""')" "operator \[\] is not a service account name"
refused "no GitLab project" "deployments:
$(entry x 'gitlabProject: -')" "gitlabProject"
refused "a quota that is not a map of strings" "deployments:
$(entry x 'quota: {pods: 20}')" "quota"
refused "an unknown field" "deployments:
$(entry x 'clusterAdmin: true')" "clusterAdmin"
refused "no deployments list" "deploy: []" "deployments"

[ "$failed" = 0 ] && echo "render_test: all passed" || { echo "render_test: failed"; exit 1; }
