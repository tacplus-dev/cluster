#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/plan.sh, ci/apply.sh, ci/delete-deployment.sh and ci/drift.sh against a stub cluster (tests/stub/kubectl)
# and, for the drift's issue, a stub gcloud, Cloud KMS and GitHub (tests/stub/curl):
#
#   - with no cluster grant, plan says "no cluster grant yet" and exits 3; on another context it refuses;
#   - on an empty cluster, plan lists every unit as added; apply applies it; the plan after is empty;
#   - a changed render is a change, by object, with its diff;
#   - a removed entry: plan lists it as removed and kept; apply runs no delete and no prune, and the namespace stays;
#   - delete-deployment refuses no name, no DELETE_CONFIRM or one that differs, a bad name, a listed deployment, an
#     unlabelled namespace; it deletes the deployment's namespace and its tenant namespaces, and nothing else;
#   - drift: nothing when in sync; an issue when it differs; a comment for a new drift; nothing for the same one;
#     it never applies.
#
# Needs bash, yq, jq, openssl.
#
#   tests/cluster_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
export PATH=$here/tests/stub:$PATH KSTUB=$work/k
mkdir -p "$KSTUB"
echo gke_jody1-328023_us-central1-a_tacplus > "$KSTUB/context"
fixtures=$here/tests/fixtures/render
"$here/render.sh" "$fixtures/deployments.yaml" "$work/out" >/dev/null || { echo "FAIL render.sh"; exit 1; }
"$here/render.sh" "$fixtures/removed.yaml" "$work/removed" >/dev/null || { echo "FAIL render.sh"; exit 1; }
# A cluster's own namespaces.
mkdir -p "$KSTUB/ns" "$KSTUB/live"
echo '{"kubernetes.io/metadata.name": "kube-system"}' > "$KSTUB/ns/kube-system"
echo '{}' > "$KSTUB/ns/letsencrypt"

run() { # run LOG CMD...: CMD's output in $work/LOG; its status returned.
  local log=$1; shift
  "$@" > "$work/$log" 2>&1
}

# No grant yet, then the wrong cluster.
echo no > "$KSTUB/grant"
run plan "$here/ci/plan.sh" "$work/out"; s=$?
[ "$s" = 3 ] && grep -q 'no cluster grant yet: cluster-admin-pipeline@' "$work/plan" &&
  ok "no grant: plan says no cluster grant yet, exit 3" || fail "no grant: exit $s: $(cat "$work/plan")"
echo yes > "$KSTUB/grant"
echo gke_jody1-328023_us-central1-a_seatrials > "$KSTUB/context"
run plan "$here/ci/plan.sh" "$work/out" && fail "plan ran on the seatrials cluster" ||
  { grep -q 'not the cluster tacplus' "$work/plan" && ok "another cluster's context is refused" || fail "another context: $(cat "$work/plan")"; }
echo gke_jody1-328023_us-central1-a_tacplus > "$KSTUB/context"

# An empty cluster: everything added; the apply; then in sync.
if run plan env PLAN_SUMMARY="$work/summary" "$here/ci/plan.sh" "$work/out"; then
  grep -qx 'deploymentproxy: add apps.v1.Deployment.deploymentproxy.deploymentproxy' "$work/summary" &&
    grep -qx 'alpha: add v1.Namespace..tac-alpha' "$work/summary" &&
    grep -qx 'beta-2: add rbac.authorization.k8s.io.v1.Role.tac-beta-2.fleet-deploy' "$work/summary" &&
    grep -q '^plan: alpha: add rbac.authorization.k8s.io.v1.RoleBinding.tac-alpha.fleet-deploy$' "$work/plan" &&
    ok "an empty cluster: every unit's objects are added, per deployment" || fail "the first plan: $(cat "$work/plan")"
else
  fail "the first plan failed: $(cat "$work/plan")"
fi
: > "$KSTUB/log"
run apply "$here/ci/apply.sh" "$work/out" && grep -q 'apply: done' "$work/apply" &&
  [ "$(grep -c '^kubectl apply --server-side --field-manager=tacplus-cluster --force-conflicts -f ' "$KSTUB/log")" = 3 ] &&
  ok "apply applies the three files server-side" || fail "apply: $(cat "$work/apply" "$KSTUB/log")"
run plan env PLAN_SUMMARY="$work/summary" "$here/ci/plan.sh" "$work/out" && [ ! -s "$work/summary" ] &&
  grep -q 'plan: no difference' "$work/plan" && ok "after the apply, plan finds no difference" || fail "the plan after the apply: $(cat "$work/plan")"

# A changed render: one change, with its diff.
cp -R "$work/out" "$work/changed"
yq -i '(select(.kind == "Role" and .metadata.name == "fleet-deploy") | .rules[0].resources) += ["podtemplates"]' "$work/changed/10-deployment-alpha.yaml"
run plan env PLAN_SUMMARY="$work/summary" "$here/ci/plan.sh" "$work/changed" &&
  [ "$(cat "$work/summary")" = 'alpha: change rbac.authorization.k8s.io.v1.Role.tac-alpha.fleet-deploy' ] &&
  grep -q '^+ .*podtemplates' "$work/plan" && ok "a changed Role is a change of that object, with its diff" || fail "a change: $(cat "$work/plan")"

# A removed entry: listed, kept, never deleted.
echo '{"deploymentproxy.tacplus.dev/deployment": "beta-2", "deploymentproxy.tacplus.dev/tid": "a1234567"}' > "$KSTUB/ns/tac-beta-2-a1234567"
run plan env PLAN_SUMMARY="$work/summary" "$here/ci/plan.sh" "$work/removed" &&
  [ "$(cat "$work/summary")" = "deploymentproxy: change v1.ConfigMap.deploymentproxy.deploymentproxy
beta-2: removed from deployments.yaml: tac-beta-2 is kept (the apply never deletes; delete-deployment does, Jody's)" ] &&
  ok "a removed entry: plan lists it as removed and kept (and its quota leaves deploymentproxy's config)" || fail "a removed entry's plan: $(cat "$work/plan")"
: > "$KSTUB/log"
run apply "$here/ci/apply.sh" "$work/removed" || fail "apply of the removed entry: $(cat "$work/apply")"
if grep -E '^kubectl (delete|.*--prune)' "$KSTUB/log"; then fail "a removed entry: apply ran a delete or a prune"
elif [ ! -e "$KSTUB/ns/tac-beta-2" ] || [ ! -e "$KSTUB/ns/tac-beta-2-a1234567" ]; then fail "a removed entry: its namespaces are gone after the apply"
else ok "a removed entry: apply runs no delete and no prune, and tac-beta-2 stays"; fi
! grep -v '^ *#' "$here/ci/apply.sh" | grep -qE 'delete|prune' && ok "ci/apply.sh holds no delete or prune" || fail "ci/apply.sh mentions delete or prune"

# delete-deployment.
refused() { # refused WHAT NAME WANT [DEPLOYMENTS [CONFIRM]]: CONFIRM is NAME by default
  : > "$KSTUB/log"
  if run delete env DELETE_DEPLOYMENT="$2" DELETE_CONFIRM="${5-$2}" "$here/ci/delete-deployment.sh" "${4:-$fixtures/removed.yaml}"; then fail "delete-deployment $1: ran"
  elif ! grep -q -- "$3" "$work/delete"; then fail "delete-deployment $1: does not say [$3]: $(cat "$work/delete")"
  elif grep -q '^kubectl delete' "$KSTUB/log"; then fail "delete-deployment $1: deleted something"
  else ok "delete-deployment refuses $1"; fi
}
refused "no name" "" "no DELETE_DEPLOYMENT"
refused "no confirmation" "beta-2" "DELETE_CONFIRM is not beta-2" "" ""
refused "a confirmation that differs" "beta-2" "DELETE_CONFIRM is not beta-2" "" "beta"
refused "a bad name" "kube-system/x" "not a deployment name"
refused "a deployment still listed" "alpha" "alpha is still in deployments.yaml"
echo '{}' > "$KSTUB/ns/tac-other"
refused "an unlabelled namespace" "other" "not a deployment namespace"
refused "a namespace that does not exist" "gone" "there is no namespace tac-gone"
echo no > "$KSTUB/grant"
refused "without a cluster grant" "beta-2" "no cluster grant yet"
echo yes > "$KSTUB/grant"
touch "$KSTUB/keep-tenants"
echo '{"deploymentproxy.tacplus.dev/deployment": "alpha"}' > "$KSTUB/ns/tac-alpha-b7654321"
: > "$KSTUB/log"
if run delete env DELETE_DEPLOYMENT=beta-2 DELETE_CONFIRM=beta-2 "$here/ci/delete-deployment.sh" "$fixtures/removed.yaml"; then
  left=$(ls "$KSTUB/ns" | tr '\n' ' ')
  [ "$left" = "deploymentproxy kube-system letsencrypt tac-alpha tac-alpha-b7654321 tac-other " ] &&
    grep -qx 'kubectl delete namespace tac-beta-2 --wait=true --timeout=15m' "$KSTUB/log" &&
    grep -qx 'kubectl delete namespace tac-beta-2-a1234567 --wait=true --timeout=15m' "$KSTUB/log" &&
    ok "delete-deployment deletes tac-beta-2 and its tenant namespace, and nothing else" ||
    fail "delete-deployment left [$left]: $(cat "$KSTUB/log")"
else
  fail "delete-deployment beta-2: $(cat "$work/delete")"
fi
rm -f "$KSTUB/keep-tenants" "$KSTUB/ns/tac-other" "$KSTUB/ns/tac-alpha-b7654321"

# drift, against stub gcloud, KMS and GitHub (tests/stub/curl keeps GitHub's issues in $GSTUB).
export GSTUB=$work/g GCP_ID_TOKEN=id-token GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/g \
  TACPLUS_READER_KMS_KEY=projects/p/locations/us/keyRings/looper/cryptoKeys/tacplus-reader \
  TACPLUS_READER_APP_ID=1 TACPLUS_READER_INSTALLATION_ID=2 KMS_API=https://kms.stub GITHUB_API=https://github.stub \
  CI_PIPELINE_URL=https://gitlab.com/tacplus-dev/cluster/-/pipelines/1 CLUSTER_COMMIT=0123456789abcdef0123456789abcdef01234567
mkdir -p "$GSTUB/issues"
touch "$GSTUB/allow"
"$here/ci/apply.sh" "$work/out" >/dev/null 2>&1 || fail "the apply before drift"
: > "$KSTUB/log"
run drift "$here/ci/drift.sh" "$work/out" && grep -qx 'drift: none' "$work/drift" && [ -z "$(ls "$GSTUB/issues")" ] &&
  ok "drift: in sync, nothing is filed" || fail "drift in sync: $(cat "$work/drift")"
cp -R "$work/out" "$work/drifted"
yq -i '(select(.kind == "Role" and .metadata.name == "fleet-deploy") | .rules[0].verbs) = ["get"]' "$work/drifted/10-deployment-beta-2.yaml"
run drift "$here/ci/drift.sh" "$work/drifted" && grep -q 'drift: filed tacplus-dev/cluster#1' "$work/drift" &&
  jq -e '.title == "Drift on the tacplus cluster" and (.body | contains("beta-2: change rbac.authorization.k8s.io.v1.Role.tac-beta-2.fleet-deploy"))' "$GSTUB/issues/1" >/dev/null &&
  grep -q 'permissions.*"issues":"write".*"repositories":\["cluster"\]' "$GSTUB/token-requests" &&
  ok "drift: an issue saying what differs, with a token for issues on cluster alone" || fail "drift: $(cat "$work/drift"; cat "$GSTUB/issues/1" 2>/dev/null)"
run drift "$here/ci/drift.sh" "$work/drifted" && grep -q 'the same drift is already on tacplus-dev/cluster#1' "$work/drift" &&
  [ ! -e "$GSTUB/issues/1.comments" ] && ok "drift: the same drift again files nothing" || fail "the same drift: $(cat "$work/drift")"
run drift "$here/ci/drift.sh" "$work/removed" && grep -q 'drift: commented on tacplus-dev/cluster#1' "$work/drift" &&
  [ "$(ls "$GSTUB/issues")" = "$(printf '1\n1.comments')" ] && ok "drift: a new drift is a comment on the open issue" || fail "a new drift: $(cat "$work/drift")"
grep -E '^kubectl (apply|delete)' "$KSTUB/log" && fail "drift applied or deleted" || ok "drift never applies"
rm -f "$GSTUB/allow"
run drift "$here/ci/drift.sh" "$work/drifted" && fail "drift without a token succeeded" ||
  { grep -q 'GitHub refused the tacplus-reader app a token for cluster' "$work/drift" && ok "drift: a refused token fails, saying so" || fail "a refused token: $(cat "$work/drift")"; }

[ "$failed" = 0 ] && echo "cluster_test: all passed" || { echo "cluster_test: failed"; exit 1; }
