#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploymentproxy/bump.sh against a fixture release (GitHub and ghcr.io as files, tests/stub/release/curl),
# in a copy of this tree: from the tag alone it pins the tag's commit (an annotated tag, peeled) and its image by
# digest, fetches the release and regenerates the render fixture, and the tree it leaves passes ci/checks.sh and
# deploymentproxy/fetch.sh --check. It refuses a tag of another line, a tag that does not exist, an image without
# the tag, an image built from another commit or of another version; and when fetching fails after pin.yaml is
# rewritten, it leaves pin.yaml, release/ and the fixture as they were. Needs bash, jq, yq, sha256sum.
#
#   tests/bump_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
export RSTUB=$work/r PATH=$here/tests/stub/release:$PATH
repository=$(yq '.repository' "$here/deploymentproxy/pin.yaml")
line=$(yq '.line' "$here/deploymentproxy/pin.yaml")
image_name=$(yq '.image | sub(":.*", "")' "$here/deploymentproxy/pin.yaml")
registry=${image_name%%/*} path=${image_name#*/}
sha() { sha256sum "$1" | cut -d' ' -f1; }

# The tree: this one, without its render or its tools, and without this test (its ci/checks.sh would run it again).
tree() {
  rm -rf "$work/tree" && mkdir "$work/tree"
  (cd "$here" && tar -c --exclude=./out --exclude=./bin --exclude=./.git .) | tar -x -C "$work/tree"
  rm "$work/tree/tests/bump_test.sh"
}

# release TAG [REVISION] [VERSION]: a fixture release TAG of the pinned repository, an annotated tag of a commit of
# its own, its manifests the pinned release's with a pod annotation in the Deployment; its image an index of amd64
# and arm64 images labelled with REVISION (the tag's commit) and VERSION (TAG), and an attestation. Prints the commit.
release() {
  local tag=$1 version=${1#v} commit object d c m idx arch
  commit=$(printf 'commit %s' "$tag" | sha1sum | cut -d' ' -f1)
  object=$(printf 'tag %s' "$tag" | sha1sum | cut -d' ' -f1)
  mkdir -p "$RSTUB/api.github.com/repos/$repository/git/ref/tags" "$RSTUB/api.github.com/repos/$repository/git/tags"
  echo "{\"object\": {\"type\": \"tag\", \"sha\": \"$object\"}}" > "$RSTUB/api.github.com/repos/$repository/git/ref/tags/$tag"
  echo "{\"object\": {\"type\": \"commit\", \"sha\": \"$commit\"}}" > "$RSTUB/api.github.com/repos/$repository/git/tags/$object"
  d=$RSTUB/raw.githubusercontent.com/$repository/$commit
  mkdir -p "$d"
  (cd "$here/deploymentproxy/release" && cp -R config "$d/")
  TAG=$tag yq -i '.spec.template.metadata.annotations."test.tacplus.dev/release" = strenv(TAG)' "$d/config/manager/deployment.yaml"
  d=$RSTUB/$registry/v2/$path
  mkdir -p "$d/manifests" "$d/blobs" "$RSTUB/$registry/token?scope=repository:${path%/*}"
  echo '{"token": "stub"}' > "$RSTUB/$registry/token?scope=repository:$path:pull"
  m='{"mediaType": "application/vnd.oci.image.index.v1+json", "manifests": []}'
  for arch in amd64 arm64; do
    jq -n --arg a "$arch" --arg r "${2:-$commit}" --arg v "${3:-$tag}" \
      '{architecture: $a, os: "linux", config: {Labels: {"org.opencontainers.image.revision": $r, "org.opencontainers.image.version": $v}}}' > "$work/c"
    c=sha256:$(sha "$work/c") && cp "$work/c" "$d/blobs/$c"
    jq -n --arg c "$c" '{mediaType: "application/vnd.oci.image.manifest.v1+json", config: {digest: $c}}' > "$work/m"
    cp "$work/m" "$d/manifests/sha256:$(sha "$work/m")"
    m=$(jq --arg d "sha256:$(sha "$work/m")" --arg a "$arch" '.manifests += [{digest: $d, platform: {architecture: $a, os: "linux"}}]' <<<"$m")
  done
  jq '.manifests += [{digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000", platform: {architecture: "unknown", os: "unknown"}}]' <<<"$m" > "$work/i"
  idx=sha256:$(sha "$work/i")
  cp "$work/i" "$d/manifests/$idx"
  printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "$idx" > "$d/manifests/$version.headers"
  echo "$commit"
}

# refused NAME TAG WANT: bump.sh refuses TAG, saying WANT, and leaves pin.yaml, release/ and the fixture as they were.
refused() {
  tree
  if "$work/tree/deploymentproxy/bump.sh" "$2" > "$work/log" 2>&1; then
    fail "$1: bumped"
  elif ! grep -q -- "$3" "$work/log"; then
    fail "$1: the refusal does not say [$3]: $(cat "$work/log")"
  elif ! diff -r "$here/deploymentproxy" "$work/tree/deploymentproxy" >/dev/null ||
       ! diff -r "$here/tests/fixtures/render/out" "$work/tree/tests/fixtures/render/out" >/dev/null; then
    fail "$1: refused, but changed the tree: $(diff -r "$here/deploymentproxy" "$work/tree/deploymentproxy" | head -5)"
  else
    ok "refused: $1"
  fi
}

# A bump.
tag=v$line.99
commit=$(release "$tag")
tree
if "$work/tree/deploymentproxy/bump.sh" "$tag" > "$work/log" 2>&1; then ok "bump.sh $tag: $(tail -1 "$work/log")"
else fail "bump.sh $tag: $(cat "$work/log")"; fi
pin=$work/tree/deploymentproxy/pin.yaml
index=$(sed -n 's/^docker-content-digest: *//p' "$RSTUB/$registry/v2/$path/manifests/${tag#v}.headers" | tr -d '\r')
[ "$(yq '.tag' "$pin") $(yq '.commit' "$pin") $(yq '.image' "$pin")" = "$tag $commit $image_name:${tag#v}@$index" ] &&
  ok "pin.yaml: the tag, its commit, the image by the index's digest" || fail "pin.yaml: $(yq -o json -I0 '.' "$pin")"
[ "$(yq '.line' "$pin") $(yq '.files | length' "$pin")" = "$line $(yq '.files | length' "$here/deploymentproxy/pin.yaml")" ] &&
  diff <(grep '^#' "$here/deploymentproxy/pin.yaml") <(grep '^#' "$pin") >/dev/null &&
  ok "pin.yaml: its line, files and comments as they were" || fail "pin.yaml: $(diff "$here/deploymentproxy/pin.yaml" "$pin")"
diff -r "$RSTUB/raw.githubusercontent.com/$repository/$commit/config" "$work/tree/deploymentproxy/release/config" >/dev/null &&
  ok "release/ is the release's" || fail "release/ is not the release's"
fixture=$work/tree/tests/fixtures/render/out/00-deploymentproxy.yaml
[ "$(yq 'select(.kind == "Deployment") | .spec.template.metadata.annotations."test.tacplus.dev/release"' "$fixture")" = "$tag" ] &&
  [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$fixture")" = "$(yq '.image' "$pin")" ] &&
  ok "the render fixture has the release's Deployment and image" || fail "the render fixture is not the release's: $(diff "$here/tests/fixtures/render/out/00-deploymentproxy.yaml" "$fixture")"
if "$work/tree/deploymentproxy/fetch.sh" --check > "$work/log" 2>&1; then ok "fetch.sh --check: release/ matches"
else fail "fetch.sh --check: $(cat "$work/log")"; fi
if "$work/tree/ci/checks.sh" > "$work/log" 2>&1; then ok "the tree passes ci/checks.sh"
else fail "the tree fails ci/checks.sh: $(grep -v '^ok' "$work/log")"; fi

# Refusals.
refused "a tag of another line" v9.9.0 "not a release of the line $line"
refused "no such tag" "v$line.98" "no tag v$line.98"
commit=$(release "v$line.97")
rm "$RSTUB/$registry/v2/$path/manifests/$line.97.headers"
refused "no image for the tag" "v$line.97" "no image $image_name:$line.97"
release "v$line.96" 0123456789abcdef0123456789abcdef01234567 >/dev/null
refused "an image built from another commit" "v$line.96" "built from \[0123456789abcdef0123456789abcdef01234567\]"
release "v$line.95" "" "v$line.94" >/dev/null
refused "an image of another version" "v$line.95" "the version \[v$line.94\]"
commit=$(release "v$line.93")
rm "$RSTUB/raw.githubusercontent.com/$repository/$commit/config/manager/deployment.yaml"
refused "a release missing a manifest (fetch.sh fails after pin.yaml is rewritten)" "v$line.93" "left as they were"

[ "$failed" = 0 ] && echo "bump_test: all passed" || { echo "bump_test: failed"; exit 1; }
