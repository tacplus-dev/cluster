#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The pipeline's tools, into bin/ (the render job's artifact; none holds a secret), each pinned by its version and
# a SHA-256: the Go ones built from their module at that version with the Go toolchain below, the module checked
# against its pinned go.sum hash (h1:, a SHA-256 of the module's files) and the Go checksum database; the others
# downloaded from their release and checked against the SHA-256 of the release's file for this machine
# (linux/amd64 or linux/arm64). Every one of them is in the security job's govulncheck (ci/security.sh).
#
#   bin/yq                      render.sh, ci/policy.sh, the tests
#   bin/kubeconform             ci/validate.sh
#   bin/helm                    render.sh (helm template of GitLab Runner's chart, gitlab-runner/)
#   bin/kubectl                 the cluster jobs (ci_kube in ci/lib.sh)
#   bin/gke-gcloud-auth-plugin  kubectl's credentials for GKE (ci_kube)
#   bin/gitleaks                the security job, tests/security_test.sh
#   with `security`, the security job's scanners as well:
#   bin/osv-scanner bin/govulncheck bin/trivy
#
#   ci/tools.sh [security]   # needs go (ghcr.io/tacplus-dev/tacplus/build), curl, tar, sha256sum, the Go module
#                            # proxy and the releases' hosts
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# The toolchain every Go tool here is built with (fetched by go itself, checked against the checksum database), so
# that their standard library is this one's, whatever the image's go is: go1.27.4, with GO-2026-6859's fix (#21).
go_toolchain=go1.27.4
# module@version  h1 hash  package  [module@fixed-version...]
# A tool built from source is built with each fixed module it names (the policy of tacplus-dev/cloud#24, #10): the
# dependency's release with an advisory's fix, where no release of the tool has it yet. Drop each once the tool's
# own pin requires it (or newer).
go_tools=(
  "github.com/mikefarah/yq/v4@v4.54.1 h1:wFk+RhKFcx6fU6tkjC9z069vLTL4uDoXi9R4SytFB8s= github.com/mikefarah/yq/v4"
  "github.com/yannh/kubeconform@v0.7.0 h1:ZFfniR8VChrWQxaxTUGnNrxw8RIDkjVBrjdhXSamwjw= github.com/yannh/kubeconform/cmd/kubeconform"
  "github.com/zricethezav/gitleaks/v8@v8.30.1 h1:PmEvCfVI7ti9dV3s5aMZUY7sS2GxRvG3yzih7E+cS3w= github.com/zricethezav/gitleaks/v8 github.com/klauspost/compress@v1.20.2 github.com/andybalholm/brotli@v1.2.7 github.com/ulikunitz/xz@v0.5.15"
  "helm.sh/helm/v4@v4.3.1 h1:UndCoLe9UPmNoL7IvWzaUXveL7T5t/ijoorEmgJdI9g= helm.sh/helm/v4/cmd/helm"
)
security_go_tools=(
  "github.com/google/osv-scanner/v2@v2.7.0 h1:7aOrJ9vB7qbzxC3R+QCXs03SHQiRuM80RJdqZhUEl2g= github.com/google/osv-scanner/v2/cmd/osv-scanner github.com/klauspost/compress@v1.20.2"
  "golang.org/x/vuln@v1.9.0 h1:12VaqnI9kJfqwRoPptxoqsUhQtdfrSbdksT7X/KY/sc= golang.org/x/vuln/cmd/govulncheck"
  # Trivy's release binary is built with go1.27.3, without GO-2026-6859's fix: built here instead, as
  # tacplus-dev/cloud#39 builds it (#21).
  "github.com/aquasecurity/trivy@v0.76.1 h1:xzXcxZpfkZpTxAHzfuG3KS5BRP17KG70+c0uFFwZUU4= github.com/aquasecurity/trivy/cmd/trivy"
)
# kubectl at the cluster's minor (ci/validate.sh's schemas), from the Kubernetes release.
kubectl_version=v1.34.13
kubectl_sha256_amd64=b4bb494e9466a7a94bb851414548bc0d3e2f8da90757e6eccc3371e648648591
kubectl_sha256_arm64=66e8283d52d9bc1f9c0e9daade7c971cd20db5a379306862897dfb25395f3e03
# gke-gcloud-auth-plugin 0.5.21, the Cloud SDK component (Cloud SDK 592.0.0's components-2.json), not the CI image's
# own (an older SDK's, built with an older Go).
gke_plugin_version=0.5.21
gke_plugin_build=20261030071842
gke_plugin_sha256_amd64=b8d3bf3ebce3aff0146d85457146869ea66da7dc62d291e176cb88b6e73dd452
gke_plugin_sha256_arm64=773ce0d886108cc47d19816449948b4187bc2b54bb26ec55729e2f34e3f45dcc

case ${1:-} in "") security=no ;; security) security=yes ;; *) echo "usage: ci/tools.sh [security]" >&2; exit 2 ;; esac
case $(uname -m) in
  x86_64|amd64) arch=amd64 plugin_arch=x86_64 ;;
  aarch64|arm64) arch=arm64 plugin_arch=arm ;;
  *) echo "tools: no pinned tools for $(uname -m)" >&2; exit 1 ;;
esac
sha() { local v=${1}_sha256_$arch; echo "${!v}"; }
mkdir -p "$here/bin"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# go_tool "MODULE@VERSION H1 PACKAGE [FIX@VERSION...]": the package built into bin/, once its module's hash is the
# pinned one. With fixes, in a module of its own that requires the package at its version and each fix (go install
# pkg@version cannot raise a dependency): minimal version selection takes every other module as the tool's go.mod
# has it, or as the fixes require, each checked against the checksum database.
go_tool() {
  local mv h1 pkg fixes sum d
  read -r mv h1 pkg fixes <<<"$1"
  sum=$(GOTOOLCHAIN=$go_toolchain go mod download -json "$mv" | jq -r .Sum)
  [ "$sum" = "$h1" ] || { echo "tools: $mv is $sum, not the pinned $h1" >&2; exit 1; }
  if [ -z "$fixes" ]; then
    GOTOOLCHAIN=$go_toolchain GOBIN="$here/bin" go install "$pkg@${mv#*@}"
    return
  fi
  d=$(mktemp -d "$t/build.XXXXXX")
  (cd "$d" && export GOTOOLCHAIN=$go_toolchain && go mod init tools.local/build 2>/dev/null &&
    { go get "$pkg@${mv#*@}" $fixes 2>get.log || { cat get.log >&2; false; }; } && go build -o "$here/bin/" "$pkg") ||
    { echo "tools: cannot build $pkg@${mv#*@} with $fixes" >&2; exit 1; }
}
# fetch URL SHA256 FILE: URL into FILE, if its SHA-256 is SHA256.
fetch() {
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - >/dev/null 2>&1 || { echo "tools: $1 is not the pinned sha256 $2" >&2; exit 1; }
}

for g in "${go_tools[@]}"; do go_tool "$g"; done
fetch "https://dl.k8s.io/release/$kubectl_version/bin/linux/$arch/kubectl" "$(sha kubectl)" "$t/kubectl"
install -m 0755 "$t/kubectl" "$here/bin/kubectl"
fetch "https://dl.google.com/dl/cloudsdk/channels/rapid/components/google-cloud-sdk-gke-gcloud-auth-plugin-linux-$plugin_arch-$gke_plugin_build.tar.gz" \
  "$(sha gke_plugin)" "$t/plugin.tar.gz"
tar -xzf "$t/plugin.tar.gz" -C "$t" bin/gke-gcloud-auth-plugin
install -m 0755 "$t/bin/gke-gcloud-auth-plugin" "$here/bin/gke-gcloud-auth-plugin"
if [ "$security" = yes ]; then
  for g in "${security_go_tools[@]}"; do go_tool "$g"; done
fi
echo "bin/: $(ls "$here/bin" | tr '\n' ' ')"
