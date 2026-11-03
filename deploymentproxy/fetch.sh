#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# deploymentproxy's release manifests, fetched as they are from github.com/tacplus-dev/deploymentproxy at the
# release deploymentproxy/pin.yaml names, into deploymentproxy/release/, with their checksums in
# deploymentproxy/release/SHA256SUMS. Nothing here edits them: render.sh pins the image by digest and sets the
# per-deployment values at render time.
#
#   deploymentproxy/fetch.sh            # after a change to pin.yaml (deploymentproxy/bump.sh runs it): fetch, check
#                                       # the tag's commit, write the sums
#   deploymentproxy/fetch.sh --check    # the files and sums here are the release's, byte for byte (validate job)
#
# The tag must still name pin.yaml's commit, and the image tag pin.yaml names must still have its digest:
# either one moving is refused. Needs bash, curl, jq, yq (mikefarah v4), sha256sum.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pin=$here/pin.yaml
release=$here/release
yq=${YQ:-yq}
github=${GITHUB_RAW:-https://raw.githubusercontent.com}
api=${GITHUB_API:-https://api.github.com}
die() { echo "deploymentproxy/fetch.sh: $*" >&2; exit 1; }

repository=$("$yq" -e '.repository' "$pin")
line=$("$yq" -e '.line' "$pin")
tag=$("$yq" -e '.tag' "$pin")
commit=$("$yq" -e '.commit' "$pin")
image=$("$yq" -e '.image' "$pin")
mapfile -t files < <("$yq" -e '.files[]' "$pin")
[[ $tag =~ ^v${line//./\\.}\.[0-9]+$ ]] || die "the tag $tag is not a release of the line $line"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "the commit $commit is not a full commit hash"
[[ $image =~ ^(ghcr\.io/[a-z0-9/_-]+):${tag#v}@(sha256:[0-9a-f]{64})$ ]] ||
  die "the image $image is not <ghcr.io image>:${tag#v}@sha256:<digest>"
image_name=${BASH_REMATCH[1]} digest=${BASH_REMATCH[2]}

# The tag still names the commit (a lightweight tag, or an annotated one peeled).
ref=$(curl -fsS "$api/repos/$repository/git/ref/tags/$tag") || die "no tag $tag in $repository"
tag_commit=$(jq -r '.object.sha' <<<"$ref")
if [ "$(jq -r '.object.type' <<<"$ref")" = tag ]; then
  tag_commit=$(curl -fsS "$api/repos/$repository/git/tags/$tag_commit" | jq -r '.object.sha')
fi
[ "$tag_commit" = "$commit" ] || die "the tag $tag names $tag_commit, not the pinned $commit"

# The image tag still has the digest.
registry=${image_name%%/*} path=${image_name#*/}
token=$(curl -fsS "https://$registry/token?scope=repository:$path:pull" | jq -r '.token') || die "no pull token for $image_name"
live=$(curl -fsSI -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://$registry/v2/$path/manifests/${tag#v}" | tr -d '\r' | sed -n 's/^docker-content-digest: *//Ip') ||
  die "no manifest for $image_name:${tag#v}"
[ "$live" = "$digest" ] || die "$image_name:${tag#v} is $live, not the pinned $digest"

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
for f in "${files[@]}"; do
  [[ $f =~ ^config/[a-z0-9/_.-]+\.yaml$ && $f != *..* ]] || die "not a release manifest path: $f"
  mkdir -p "$t/$(dirname "$f")"
  curl -fsS -o "$t/$f" "$github/$repository/$commit/$f" || die "no $f at $commit"
done
(cd "$t" && sha256sum "${files[@]}") > "$t/SHA256SUMS"

if [ "${1:-}" = --check ]; then
  (cd "$release" && sha256sum --quiet -c SHA256SUMS) || die "release/ does not match its SHA256SUMS"
  diff -u "$release/SHA256SUMS" "$t/SHA256SUMS" ||
    die "release/ is not $repository $tag ($commit): run deploymentproxy/fetch.sh"
  echo "deploymentproxy $tag ($commit, $image): release/ matches, ${#files[@]} files"
else
  rm -rf "$release"
  mkdir -p "$release"
  cp -R "$t/." "$release/"
  echo "deploymentproxy $tag ($commit, $image): fetched ${#files[@]} files into release/"
fi
