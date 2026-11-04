#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The validate job, offline from the cluster: the render OUT against the Kubernetes schemas (kubeconform, strict),
# then ci/policy.sh, then deploymentproxy/release against the release it pins (deploymentproxy/fetch.sh --check), and
# gitlab-runner/release and its images against gitlab-runner/pin.yaml (gitlab-runner/fetch.sh --check).
# The CRD is skipped by kubeconform, which has no schema for CustomResourceDefinition; it is deploymentproxy's own,
# checked by its checksum, and the plan's server-side diff validates it.
#
#   ci/validate.sh OUT     # needs kubeconform, yq, jq, curl, tar, and https to github.com, ghcr.io, charts.gitlab.io,
#                          # gitlab-charts.s3.amazonaws.com and registry.gitlab.com
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: ci/validate.sh OUT}
kubernetes_version=${KUBERNETES_VERSION:-1.34.0}
kubeconform -strict -summary -kubernetes-version "$kubernetes_version" -skip CustomResourceDefinition "$out"
"$here/ci/policy.sh" "$out"
"$here/deploymentproxy/fetch.sh" --check
"$here/gitlab-runner/fetch.sh" --check
