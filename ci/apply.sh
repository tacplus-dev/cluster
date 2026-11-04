#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Applies the render OUT to the cluster `tacplus` (the apply job, automatic on main once plan succeeds): the plan first, so the job's log says
# what it changes, then each file server-side, in order (deploymentproxy, then each deployment, then ci), then the
# runners' tokens from Secret Manager (ci/runner-tokens.sh), then waits for deploymentproxy and the runners. It only
# creates and updates: it never deletes, and never prunes, so a removed entry's namespace stays until
# delete-deployment deletes it.
#
#   ci/apply.sh OUT     # needs kubectl on the cluster (ci_kube in ci/lib.sh), gcloud (ci_gcp), yq, jq
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: ci/apply.sh OUT}
source "$here/kube.sh"
kube_check
"$here/plan.sh" "$out"

echo "== apply"
for f in "$out"/*.yaml; do
  kubectl apply --server-side --field-manager=tacplus-cluster --force-conflicts -f "$f"
done
# The runners' tokens, from Secret Manager by the version the render names.
"$here/runner-tokens.sh" "$out"
kubectl -n deploymentproxy rollout status deployment/deploymentproxy --timeout=5m
for d in $(yq -N 'select(.kind == "Deployment") | .metadata.name' "$out/20-ci.yaml"); do
  kubectl -n ci rollout status "deployment/$d" --timeout=5m
done
echo "apply: done"
