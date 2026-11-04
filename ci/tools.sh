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
# that their standard library is this one's, whatever the image's go is.
go_toolchain=go1.27.3
# module@version  h1 hash  package
go_tools=(
  "github.com/mikefarah/yq/v4@v4.54.1 h1:wFk+RhKFcx6fU6tkjC9z069vLTL4uDoXi9R4SytFB8s= github.com/mikefarah/yq/v4"
  "github.com/yannh/kubeconform@v0.7.0 h1:ZFfniR8VChrWQxaxTUGnNrxw8RIDkjVBrjdhXSamwjw= github.com/yannh/kubeconform/cmd/kubeconform"
  "github.com/zricethezav/gitleaks/v8@v8.30.1 h1:PmEvCfVI7ti9dV3s5aMZUY7sS2GxRvG3yzih7E+cS3w= github.com/zricethezav/gitleaks/v8"
)
security_go_tools=(
  "github.com/google/osv-scanner/v2@v2.7.0 h1:7aOrJ9vB7qbzxC3R+QCXs03SHQiRuM80RJdqZhUEl2g= github.com/google/osv-scanner/v2/cmd/osv-scanner"
  "golang.org/x/vuln@v1.9.0 h1:12VaqnI9kJfqwRoPptxoqsUhQtdfrSbdksT7X/KY/sc= golang.org/x/vuln/cmd/govulncheck"
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
trivy_version=0.76.1
trivy_sha256_amd64=c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0
trivy_sha256_arm64=e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f

case ${1:-} in "") security=no ;; security) security=yes ;; *) echo "usage: ci/tools.sh [security]" >&2; exit 2 ;; esac
case $(uname -m) in
  x86_64|amd64) arch=amd64 plugin_arch=x86_64 trivy_arch=64bit ;;
  aarch64|arm64) arch=arm64 plugin_arch=arm trivy_arch=ARM64 ;;
  *) echo "tools: no pinned tools for $(uname -m)" >&2; exit 1 ;;
esac
sha() { local v=${1}_sha256_$arch; echo "${!v}"; }
mkdir -p "$here/bin"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# go_tool "MODULE@VERSION H1 PACKAGE": the package built into bin/, once its module's hash is the pinned one.
go_tool() {
  local mv h1 pkg sum
  read -r mv h1 pkg <<<"$1"
  sum=$(GOTOOLCHAIN=$go_toolchain go mod download -json "$mv" | jq -r .Sum)
  [ "$sum" = "$h1" ] || { echo "tools: $mv is $sum, not the pinned $h1" >&2; exit 1; }
  GOTOOLCHAIN=$go_toolchain GOBIN="$here/bin" go install "$pkg@${mv#*@}"
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
  fetch "https://github.com/aquasecurity/trivy/releases/download/v$trivy_version/trivy_${trivy_version}_Linux-$trivy_arch.tar.gz" \
    "$(sha trivy)" "$t/trivy.tar.gz"
  tar -xzf "$t/trivy.tar.gz" -C "$t" trivy
  install -m 0755 "$t/trivy" "$here/bin/trivy"
fi
echo "bin/: $(ls "$here/bin" | tr '\n' ' ')"
