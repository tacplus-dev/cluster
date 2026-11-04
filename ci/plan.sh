#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# What an apply of the render OUT would change on the cluster `tacplus`, and nothing else: `kubectl diff`
# (server-side, as ci/apply.sh applies) of each file of the render, then a summary per unit (deploymentproxy, each
# deployment, and ci) of what is added, changed or removed. A unit whose namespace does not exist yet is all added,
# listed from the render (the server cannot diff objects in a namespace it does not have). A namespace labelled
# tacplus.dev/deployment whose entry is gone is listed as removed from deployments.yaml: the apply keeps it, only
# delete-deployment deletes it.
#
#   ci/plan.sh OUT                  # needs kubectl on the cluster (ci_kube in ci/lib.sh), yq, jq
#   PLAN_SUMMARY=FILE ci/plan.sh OUT    # also writes the summary's lines there, empty when nothing differs
#
# Exit 0 whether or not anything differs; 3 when the job's account has no cluster grant yet (ci/kube.sh).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: ci/plan.sh OUT}
source "$here/kube.sh"
kube_check

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
summary=$tmp/summary
: > "$summary"
existing=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name')

rendered=()
for f in "$out"/*.yaml; do
  b=$(basename "$f" .yaml)
  case $b in
    00-deploymentproxy) unit=deploymentproxy ;;
    10-deployment-*) unit=${b#10-deployment-}; rendered+=("$unit") ;;
    20-ci) unit=ci ;;
    *) echo "plan: $f is not a file render.sh writes" >&2; exit 1 ;;
  esac
  missing=$(yq -N '.metadata.namespace | select(. != null)' "$f" | sort -u | grep -vxF -f <(printf '%s\n' $existing) || true)
  : > "$tmp/objects"
  if [ -n "$missing" ]; then
    echo "== $unit: the namespace $(echo $missing) does not exist yet: all of it is added"
    kube_object_names "$f" | sed 's/^/add /' > "$tmp/objects"
  else
    echo "== $unit: kubectl diff"
    status=0
    KUBECTL_EXTERNAL_DIFF=$here/plan-diff.sh PLAN_OBJECTS=$tmp/objects \
      kubectl diff --server-side --field-manager=tacplus-cluster --force-conflicts -f "$f" || status=$?
    [ "$status" -le 1 ] || { echo "plan: kubectl diff failed on $unit (exit $status)" >&2; exit "$status"; }
  fi
  sed "s/^/$unit: /" "$tmp/objects" >> "$summary"
done

# Deployments on the cluster that deployments.yaml no longer lists.
for d in $(kubectl get namespaces -l tacplus.dev/deployment -o json | jq -r '.items[].metadata.labels["tacplus.dev/deployment"]' | sort -u); do
  printf '%s\n' "${rendered[@]}" | grep -qxF "$d" ||
    echo "$d: removed from deployments.yaml: tac-$d is kept (the apply never deletes; delete-deployment does, Jody's)" >> "$summary"
done

echo "== plan"
if [ -s "$summary" ]; then
  sed 's/^/plan: /' "$summary"
  echo "plan: $(wc -l < "$summary") difference(s)"
else
  echo "plan: no difference: the cluster matches the render"
fi
[ -z "${PLAN_SUMMARY:-}" ] || cp "$summary" "$PLAN_SUMMARY"
