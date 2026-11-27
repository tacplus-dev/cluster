#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Applies the render OUT to the cluster `dev` (the apply job, automatic on main once plan succeeds): the plan first, so the job's log says
# what it changes, then each file server-side, in order (deploymentproxy, the storage, kernel's TokenReview ClusterRole,
# then each deployment, then ci), then checks that each deployment's kernel may create TokenReviews (#67), then the
# runners' tokens from Secret Manager (ci/runner-tokens.sh), then waits for deploymentproxy and the runners, restarting
# one an earlier rollout left past its progress deadline (#58). It only
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
# Each deployment's kernel verifies its workloads' tokens with TokenReview (#67): as the API server authorizes it.
for f in "$out"/10-deployment-*.yaml; do
  ns=$(yq -N 'select(.kind == "Namespace") | .metadata.name' "$f")
  [ "$(kubectl auth can-i create tokenreviews.authentication.k8s.io --as "system:serviceaccount:$ns:kernel" 2>/dev/null)" = yes ] ||
    { echo "apply: $ns's kernel may not create tokenreviews.authentication.k8s.io: its ClusterRoleBinding $ns-kernel-tokenreview (render.sh)" >&2; exit 1; }
  echo "apply: $ns's kernel may create tokenreviews"
done
# The runners' tokens, from Secret Manager by the version the render names.
"$here/runner-tokens.sh" "$out"
# A Deployment whose last rollout exceeded its progress deadline (#58: build-light, applied before its token was in
# Secret Manager) keeps that condition while its pod template is unchanged, its pod ready or not, and rollout status
# fails on it at once: restart it, a fresh rollout, then wait for that.
rollout() { # rollout NAMESPACE DEPLOYMENT
  if [ "$(kubectl -n "$1" get deployment "$2" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}')" = ProgressDeadlineExceeded ]; then
    echo "apply: $1/$2 exceeded its progress deadline in an earlier rollout: restarting it"
    kubectl -n "$1" rollout restart "deployment/$2"
  fi
  kubectl -n "$1" rollout status "deployment/$2" --timeout=5m
}
rollout deploymentproxy deploymentproxy
for d in $(yq -N 'select(.kind == "Deployment") | .metadata.name' "$out/20-ci.yaml"); do
  rollout ci "$d"
done
echo "apply: done"
