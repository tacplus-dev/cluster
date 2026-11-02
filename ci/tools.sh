#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The pipeline's tools, built from pinned module versions (checked against the Go checksum database) into bin/
# (the render job's artifact; none holds a secret). kubectl comes from gcloud (ci_kube in ci/lib.sh).
#
#   bin/yq            render.sh, ci/policy.sh, the tests
#   bin/kubeconform   ci/validate.sh
#
#   ci/tools.sh       # needs go (ghcr.io/tacplus-dev/tacplus/build) and the Go module proxy
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
yq_version=v4.54.1
kubeconform_version=v0.7.0
mkdir -p "$here/bin"
GOBIN="$here/bin" go install "github.com/mikefarah/yq/v4@$yq_version"
GOBIN="$here/bin" go install "github.com/yannh/kubeconform/cmd/kubeconform@$kubeconform_version"
echo "bin/: $(ls "$here/bin" | tr '\n' ' ')"
