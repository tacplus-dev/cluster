#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The runners' authentication tokens (ci/apply.sh, after the render's files): for each runner of OUT/20-ci.yaml,
# its token read from Secret Manager at the version its pods name (tacplus.dev/runner-token, from
# gitlab-runner/runners/<runner>.yaml: never "latest"), written into the Secret its pods mount
# (tacplus.dev/runner-token-secret) in ci, server-side, with that version as an annotation. The token is in no file
# of this repository and in no GitLab variable; here it lives only in the job's temporary directory, and nothing
# prints it. A new version is a new pod annotation, so the runner restarts with it.
#
#   ci/runner-tokens.sh OUT     # needs gcloud as the pipeline's account (ci_gcp in ci/lib.sh), kubectl (ci_kube), yq
set -euo pipefail
out=${1:?usage: ci/runner-tokens.sh OUT}
die() { echo "runner-tokens: $*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

n=0
while IFS='|' read -r secret ref; do
  [[ $ref =~ ^projects/([a-z0-9-]+)/secrets/([A-Za-z0-9_-]+)/versions/([1-9][0-9]*)$ ]] ||
    die "the runner Secret $secret names [$ref], not a Secret Manager version"
  project=${BASH_REMATCH[1]} id=${BASH_REMATCH[2]} version=${BASH_REMATCH[3]}
  [[ $secret =~ ^gitlab-runner-[a-z][a-z0-9-]*$ ]] || die "[$secret] is not a runner's Secret"
  ( umask 077
    gcloud secrets versions access "$version" --secret="$id" --project="$project" --out-file="$tmp/token" >/dev/null 2>"$tmp/err" ) ||
    die "Secret Manager refused $ref to $(gcloud config get account 2>/dev/null): $(grep -m1 'ERROR' "$tmp/err" || head -c 300 "$tmp/err") (README, What the hub does)"
  token=$(tr -d '\r\n' < "$tmp/token")
  [[ $token =~ ^glrt-[A-Za-z0-9_.-]+$ ]] || die "$ref is not a runner authentication token (glrt-...)"
  ( umask 077
    cat > "$tmp/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $secret
  namespace: ci
  annotations:
    tacplus.dev/runner-token: $ref
type: Opaque
data:
  runner-token: $(printf '%s' "$token" | base64 -w0)
  runner-registration-token: ""
EOF
  )
  unset token
  kubectl apply --server-side --field-manager=tacplus-cluster --force-conflicts -f "$tmp/secret.yaml" >/dev/null
  rm -f "$tmp/token" "$tmp/secret.yaml"
  echo "runner-tokens: $secret: $ref"
  n=$((n + 1))
done < <(yq -N 'select(.kind == "Deployment") | .spec.template.metadata.annotations // {} | select(has("tacplus.dev/runner-token")) |
  .["tacplus.dev/runner-token-secret"] + "|" + .["tacplus.dev/runner-token"]' "$out/20-ci.yaml")
[ "$n" -gt 0 ] || die "no runner in $out/20-ci.yaml"
