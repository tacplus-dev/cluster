#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The way back that needs no runner in the cluster (#37). This pipeline runs on the in-cluster runner `infra`, so a
# change that breaks the runners can take down the runner that would roll it back (e246907, 2026-11-18: every job
# failed at once, infra's too, and only the paused VM runner could apply the rollback). This applies a known-good
# commit of main to the cluster dev from wherever gcloud is signed in as someone who is cluster-admin on dev (Cloud
# Shell, as Jody), the way the pipeline does: that commit's own pinned tools (ci/tools.sh), its render, its policy,
# then its ci/apply.sh (the plan, the apply, the runners' tokens from Secret Manager, the rollouts waited for). Like
# the pipeline, it never deletes: an object only a later commit added stays.
#
# Then re-pin the GitLab project to the same commit (ci/pin.sh COMMIT, README: Rolling back), or its next pipeline
# on main applies the broken commit again.
#
#   ci/rollback.sh COMMIT    # COMMIT a full hash of github.com/tacplus-dev/cluster (CLUSTER_REPO); needs git, go,
#                            # curl, gcloud signed in; GCP_PROJECT, CLUSTER and ZONE as the pipeline's (tacplus-dev,
#                            # dev, us-central1-a) unless set
set -euo pipefail
commit=${1:?usage: ci/rollback.sh COMMIT}
repo=${CLUSTER_REPO:-https://github.com/tacplus-dev/cluster.git}
die() { echo "rollback: $*" >&2; exit 1; }
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "[$commit] is not a full commit hash"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The commit, as the pipeline's jobs fetch it.
git init -q "$work/src"
git -C "$work/src" fetch -q --depth 1 "$repo" "$commit" || die "no commit $commit in $repo"
git -C "$work/src" checkout -q FETCH_HEAD
echo "rollback: tacplus-dev/cluster at $commit: $(git -C "$work/src" log -1 --format=%s)"
cd "$work/src"
ci/tools.sh
export PATH=$PWD/bin:$PATH
./render.sh deployments.yaml out
ci/policy.sh out
# shellcheck source=lib.sh
ci_tmp=$work/tmp && mkdir -p "$ci_tmp" && source ci/lib.sh
ci_kube || die "no credentials for the cluster: sign gcloud in as someone who is cluster-admin on ${CLUSTER:-dev}"
ci/apply.sh out
echo "rollback: dev is at $commit; now re-pin the GitLab project to it: ci/pin.sh $commit (README, Rolling back)"
