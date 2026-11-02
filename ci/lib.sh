# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by the pipeline's jobs (ci/gitlab-project.gitlab-ci.yml), each run from this repository's checkout at
# the pinned commit: the job's credentials, each from the job's own GitLab id_token through Workload Identity
# Federation. No key file and no GitHub token is stored anywhere. Every credential lives in the job's temporary
# directory and goes with the job (the runner's VMs are used once). Nothing here prints one; never run these jobs
# with `set -x`.
ci_tmp=${ci_tmp:-$(mktemp -d)}

# ci_gcp: gcloud as the pipeline's service account (GCP_DEPLOY_SA, cluster-admin-pipeline), through GitLab OIDC and
# Workload Identity Federation: the job's ID token (id_tokens GCP_ID_TOKEN) is exchanged for a short-lived Google
# token. The provider admits only this project's protected main.
ci_gcp() {
  : "${GCP_ID_TOKEN:?the job has no id_tokens GCP_ID_TOKEN}"
  : "${GCP_WIF_PROVIDER:?the GitLab project variable GCP_WIF_PROVIDER is not set (README, What the hub does)}"
  : "${GCP_DEPLOY_SA:?GCP_DEPLOY_SA is not set}"
  export CLOUDSDK_CONFIG=$ci_tmp/gcloud CLOUDSDK_CORE_DISABLE_PROMPTS=1
  ( umask 077
    printf '%s' "$GCP_ID_TOKEN" > "$ci_tmp/oidc-token"
    gcloud iam workload-identity-pools create-cred-config "$GCP_WIF_PROVIDER" \
      --service-account="$GCP_DEPLOY_SA" --credential-source-file="$ci_tmp/oidc-token" \
      --output-file="$ci_tmp/gcp-federation.json" >/dev/null ) || return 1
  gcloud auth login --cred-file="$ci_tmp/gcp-federation.json" --quiet >/dev/null 2>"$ci_tmp/gcloud-err" ||
    { echo "gcp: Workload Identity Federation refused this job ($GCP_WIF_PROVIDER): $(grep -m1 '^ERROR' "$ci_tmp/gcloud-err" || head -c 300 "$ci_tmp/gcloud-err")" >&2
      return 1; }
  gcloud config set project "${GCP_PROJECT:-jody1-328023}" >/dev/null 2>&1
  echo "gcp: $(gcloud config get account 2>/dev/null) through workload identity federation"
}

# ci_kube: kubectl on the cluster CLUSTER (tacplus) in ZONE, as that account. Every job calls it in an && list,
# where errexit is off, so it returns on its own failures, saying why: no credentials for the cluster (the hub has
# not granted the account yet), or no current context.
ci_kube() {
  local cluster=${CLUSTER:-tacplus} zone=${ZONE:-us-central1-a} context
  command -v kubectl >/dev/null || gcloud components install kubectl gke-gcloud-auth-plugin --quiet >/dev/null 2>&1 || true
  export KUBECONFIG=$ci_tmp/kubeconfig USE_GKE_GCLOUD_AUTH_PLUGIN=True
  gcloud container clusters get-credentials "$cluster" --zone "$zone" \
      --project "${GCP_PROJECT:-jody1-328023}" >/dev/null 2>"$ci_tmp/kube-err" ||
    { echo "kube: no cluster grant yet? no credentials for the cluster $cluster ($zone) as $(gcloud config get account 2>/dev/null): $(grep -m1 '^ERROR' "$ci_tmp/kube-err" || head -c 300 "$ci_tmp/kube-err") (README, What the hub does)" >&2
      return 1; }
  context=$(kubectl config current-context 2>/dev/null) && [ -n "$context" ] ||
    { echo "kube: no current context after get-credentials for the cluster $cluster ($zone)" >&2; return 1; }
  echo "kube: $context"
}

# github_app_token REPO PERMISSIONS: a one-hour installation token of the keyless tacplus-reader GitHub App for
# tacplus-dev/REPO alone, with PERMISSIONS (JSON, as {"issues":"write"}), on stdout (tacplus-dev/looper README,
# Credentials; fleet-seatrials' .github-reader). The job's id_token is exchanged through Workload Identity
# Federation, as the job itself; Cloud KMS signs the app's JWT with the app's key (TACPLUS_READER_KMS_KEY), which
# never leaves KMS. If KMS refuses the federated principal, the job signs as TACPLUS_READER_SA, which it may
# impersonate, when that is set. A refusal says KMS's or GitHub's HTTP status and error, never a token.
github_app_token() (
  set -uo pipefail
  repo=$1 permissions=$2
  say() { echo "github_app_token: $*" >&2; }
  die() { say "$@"; exit 1; }
  : "${GCP_ID_TOKEN:?the job has no id_tokens GCP_ID_TOKEN}"
  : "${GCP_WIF_PROVIDER:?the GitLab project variable GCP_WIF_PROVIDER is not set (README, What the hub does)}"
  : "${TACPLUS_READER_KMS_KEY:?TACPLUS_READER_KMS_KEY is not set}"
  : "${TACPLUS_READER_APP_ID:?the GitLab project variable TACPLUS_READER_APP_ID is not set (README, What the hub does)}"
  : "${TACPLUS_READER_INSTALLATION_ID:?the GitLab project variable TACPLUS_READER_INSTALLATION_ID is not set (README, What the hub does)}"
  t=$(mktemp -d) && trap 'rm -rf "$t"' EXIT || die "no temporary directory"
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  # error FILE: the error in an answer, its status and message, never a request.
  error() { jq -er '(.error // .) | select(.message) | [(.status | strings | select(test("^[A-Z_]+$"))), .message] | join(": ")' "$1" 2>/dev/null ||
    head -c 300 "$1" | tr '\n' ' '; }
  ( umask 077; printf '%s' "$GCP_ID_TOKEN" > "$t/oidc-token" ) || die "no temporary directory"
  now=$(date +%s)
  jwt=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url).$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    "$((now - 60))" "$((now + 540))" "$TACPLUS_READER_APP_ID" | b64url)
  # kms_sign AS WHO [create-cred-config FLAG...]: KMS's signature of the JWT's digest in $t/jwt-sig, as WHO;
  # 3 when KMS refused the caller (401, 403).
  kms_sign() {
    local as=$1 who=$2 token code=; shift 2
    export CLOUDSDK_CONFIG=$t/gcloud-$as
    gcloud iam workload-identity-pools create-cred-config "$GCP_WIF_PROVIDER" "$@" \
        --credential-source-file="$t/oidc-token" --output-file="$t/federation-$as.json" >/dev/null &&
      gcloud auth login --cred-file="$t/federation-$as.json" --quiet >/dev/null 2>"$t/gcloud-err" &&
      token=$(gcloud auth print-access-token 2>"$t/gcloud-err") ||
      { say "Workload Identity Federation refused this job ($GCP_WIF_PROVIDER) as $who: $(grep -m1 '^ERROR' "$t/gcloud-err" || head -c 300 "$t/gcloud-err")"; return 1; }
    ( umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$t/kms-auth" ) || return 1
    code=$(curl -sS -o "$t/kms" -w '%{http_code}' -X POST -H @"$t/kms-auth" -H 'Content-Type: application/json' \
      -d "{\"digest\":{\"sha256\":\"$(printf '%s' "$jwt" | openssl dgst -sha256 -binary | openssl base64 -A)\"}}" \
      "${KMS_API:-https://cloudkms.googleapis.com}/v1/$TACPLUS_READER_KMS_KEY/cryptoKeyVersions/1:asymmetricSign")
    rm -f "$t/kms-auth"
    [ "$code" = 200 ] && jq -er '.signature' "$t/kms" | openssl base64 -d -A > "$t/jwt-sig" && [ -s "$t/jwt-sig" ] && return 0
    say "Cloud KMS refused to sign with $TACPLUS_READER_KMS_KEY as $who: HTTP ${code:-none} $(error "$t/kms")"
    case $code in 401|403) return 3 ;; *) return 1 ;; esac
  }
  rc=0
  kms_sign direct "the job itself" || rc=$?
  if [ "$rc" = 3 ] && [ -n "${TACPLUS_READER_SA:-}" ]; then
    say "signing as the service account $TACPLUS_READER_SA instead"
    rc=0
    kms_sign sa "$TACPLUS_READER_SA" --service-account="$TACPLUS_READER_SA" || rc=$?
  fi
  [ "$rc" = 0 ] || die "no signature from Cloud KMS, so no token (README, What the hub does)"
  ( umask 077; printf 'Authorization: Bearer %s.%s\n' "$jwt" "$(b64url < "$t/jwt-sig")" > "$t/github-auth" ) || die "no temporary directory"
  code=$(curl -sS -o "$t/answer" -w '%{http_code}' -X POST -H @"$t/github-auth" -H 'Accept: application/vnd.github+json' \
      -d "{\"permissions\":$permissions,\"repositories\":[\"$repo\"]}" \
      "${GITHUB_API:-https://api.github.com}/app/installations/$TACPLUS_READER_INSTALLATION_ID/access_tokens")
  [[ $code == 2?? ]] && jq -er '.token // empty' "$t/answer" ||
    die "GitHub refused the tacplus-reader app a token for $repo with $permissions: HTTP ${code:-none} $(error "$t/answer")"
)
