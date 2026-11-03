#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# A deploymentproxy bump, in one command: from the release tag alone, resolves the commit it names and the digest of
# its image, refuses an image not built from that commit, rewrites tag, commit and image in deploymentproxy/pin.yaml,
# runs deploymentproxy/fetch.sh (which checks both again and rewrites release/), and regenerates the render fixture
# (tests/fixtures/render/out) the release's manifests reach. What it leaves is the bump's whole diff, to review.
#
#   deploymentproxy/bump.sh v0.2.2      # a release of pin.yaml's line; another line is a change to pin.yaml first
#
# The image is pin.yaml's, tagged with the release's version (v0.2.2: 0.2.2). Every platform image of it must carry
# org.opencontainers.image.revision = the tag's commit and org.opencontainers.image.version = the tag. On any refusal
# or failure, pin.yaml, release/ and the fixture are left as they were. Needs bash, curl, jq, yq (mikefarah v4),
# sha256sum.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
pin=$here/pin.yaml
yq=${YQ:-yq}
api=${GITHUB_API:-https://api.github.com}
die() { echo "deploymentproxy/bump.sh: $*" >&2; exit 1; }

tag=${1:?usage: deploymentproxy/bump.sh <tag>}
repository=$("$yq" -e '.repository' "$pin")
line=$("$yq" -e '.line' "$pin")
image=$("$yq" -e '.image' "$pin")
[[ $tag =~ ^v${line//./\\.}\.[0-9]+$ ]] || die "the tag $tag is not a release of the line $line (pin.yaml's line)"
[[ $image =~ ^(ghcr\.io/[a-z0-9/_-]+): ]] || die "pin.yaml's image $image is not a ghcr.io image"
image_name=${BASH_REMATCH[1]} version=${tag#v}

# The commit the tag names (a lightweight tag, or an annotated one peeled).
ref=$(curl -fsS "$api/repos/$repository/git/ref/tags/$tag") || die "no tag $tag in $repository"
commit=$(jq -r '.object.sha' <<<"$ref")
if [ "$(jq -r '.object.type' <<<"$ref")" = tag ]; then
  commit=$(curl -fsS "$api/repos/$repository/git/tags/$commit" | jq -r '.object.sha') || die "cannot peel the tag $tag"
fi
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "the tag $tag names [$commit], not a commit"

# The digest of the image tag, and every platform image of it built from that commit.
registry=${image_name%%/*} path=${image_name#*/}
accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
token=$(curl -fsS "https://$registry/token?scope=repository:$path:pull" | jq -r '.token') || die "no pull token for $image_name"
get() { curl -fsSL -H "Authorization: Bearer $token" -H "Accept: $accept" "https://$registry/v2/$path/$1"; }
digest=$(curl -fsSI -H "Authorization: Bearer $token" -H "Accept: $accept" "https://$registry/v2/$path/manifests/$version" |
    tr -d '\r' | sed -n 's/^docker-content-digest: *//Ip') || die "no image $image_name:$version"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$image_name:$version has no digest [$digest]"
top=$(get "manifests/$digest") || die "no manifest $digest for $image_name:$version"
if [ "$(jq 'has("manifests")' <<<"$top")" = true ]; then
  mapfile -t platforms < <(jq -r '.manifests[] | select(.platform.os != "unknown") | .digest' <<<"$top")
else
  platforms=("$digest")
fi
[ "${#platforms[@]}" -gt 0 ] || die "$image_name:$version ($digest) has no platform image"
for p in "${platforms[@]}"; do
  config=$(get "manifests/$p" | jq -r '.config.digest') || die "no manifest $p in $image_name:$version"
  labels=$(get "blobs/$config" | jq -c '.config.Labels // {}') || die "no config $config for $p in $image_name:$version"
  revision=$(jq -r '."org.opencontainers.image.revision" // ""' <<<"$labels")
  built=$(jq -r '."org.opencontainers.image.version" // ""' <<<"$labels")
  [ "$revision" = "$commit" ] ||
    die "$image_name:$version ($digest): its image $p is built from [$revision], not $tag's commit $commit"
  [ "$built" = "$tag" ] || die "$image_name:$version ($digest): its image $p is the version [$built], not $tag"
done

# pin.yaml, then the release and the fixture; all three back as they were if any step fails.
fixture=$root/tests/fixtures/render/out
keep=$(mktemp -d)
cp "$pin" "$keep/pin.yaml" && cp -R "$here/release" "$keep/release" && cp -R "$fixture" "$keep/out"
restore() {
  rm -rf "$here/release" "$fixture" && cp "$keep/pin.yaml" "$pin" && cp -R "$keep/release" "$here/release" &&
    cp -R "$keep/out" "$fixture" && echo "deploymentproxy/bump.sh: pin.yaml, release/ and the fixture left as they were" >&2
}
trap 'status=$?; [ "$status" = 0 ] || restore; rm -rf "$keep"' EXIT
TAG=$tag COMMIT=$commit IMAGE=$image_name:$version@$digest \
  "$yq" -i '.tag = strenv(TAG) | .commit = strenv(COMMIT) | .image = strenv(IMAGE)' "$pin"
"$here/fetch.sh"
UPDATE=1 "$root/tests/render_test.sh" > "$keep/render_test.log" 2>&1 ||
  { cat "$keep/render_test.log" >&2; die "the render tests fail on $tag"; }
echo "deploymentproxy $tag ($commit, $image_name:$version@$digest): pin.yaml, release/ and tests/fixtures/render/out rewritten; review their diff"
