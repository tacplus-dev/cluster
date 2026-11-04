#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# GitLab Runner's chart, fetched as it is from the archive gitlab-runner/pin.yaml names, into
# gitlab-runner/release/ (the chart's directory, unpacked), with the checksums of its files in
# gitlab-runner/release/SHA256SUMS. Nothing here edits it: render.sh sets the images and the runners' values at
# render time.
#
#   gitlab-runner/fetch.sh            # after a change to pin.yaml: fetch, check, write the sums
#   gitlab-runner/fetch.sh --check    # the files and sums here are the chart's, byte for byte (validate job)
#
# Refused: an archive whose SHA-256 is not the pinned digest, or not the digest charts.gitlab.io's index gives that
# version; a chart whose appVersion is not the images' version; an image whose tag no longer has the pinned digest.
# Needs bash, curl, jq, yq (mikefarah v4), sha256sum, tar.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pin=$here/pin.yaml
release=$here/release
yq=${YQ:-yq}
die() { echo "gitlab-runner/fetch.sh: $*" >&2; exit 1; }

name=$("$yq" -e '.chart.name' "$pin")
version=$("$yq" -e '.chart.version' "$pin")
url=$("$yq" -e '.chart.url' "$pin")
index=$("$yq" -e '.chart.index' "$pin")
digest=$("$yq" -e '.chart.digest' "$pin")
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "the chart's digest $digest is not sha256:<64 hex>"
[[ $url == https://*/"$name-$version.tgz" ]] || die "the chart's url $url is not $name-$version.tgz over https"

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# The index still gives this version that digest, and the archive is it.
curl -fsSL --retry 3 -o "$t/index.yaml" "$index" || die "no index at $index"
listed=$(N=$name V=$version "$yq" '.entries[strenv(N)][] | select(.version == strenv(V)) | .digest' "$t/index.yaml")
[ "sha256:$listed" = "$digest" ] || die "$index gives $name $version the digest [${listed}], not the pinned $digest"
curl -fsSL --retry 3 -o "$t/chart.tgz" "$url" || die "no chart at $url"
[ "sha256:$(sha256sum "$t/chart.tgz" | cut -d' ' -f1)" = "$digest" ] || die "$url is not the pinned $digest"
mkdir "$t/x"
tar -xzf "$t/chart.tgz" -C "$t/x"
[ -f "$t/x/$name/Chart.yaml" ] && [ "$(ls -A "$t/x")" = "$name" ] || die "the archive holds more than the chart $name/"
[ "$("$yq" '.version' "$t/x/$name/Chart.yaml")" = "$version" ] || die "the archive's Chart.yaml is not version $version"
app=$("$yq" '.appVersion' "$t/x/$name/Chart.yaml")

# live_digest IMAGE: the digest its registry gives its tag now (the index, for a multi-platform image).
live_digest() {
  local ref=${1%@*} registry path tag auth realm service token
  registry=${ref%%/*} path=${ref#*/} tag=${path##*:} path=${path%:*}
  auth=$(curl -sS -D- -o /dev/null "https://$registry/v2/" | tr -d '\r' | sed -n 's/^www-authenticate: *Bearer *//Ip')
  realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$auth") service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$auth")
  token=$(curl -fsS "$realm?service=$service&scope=repository:$path:pull" | jq -r '.token // .access_token') || return 1
  curl -fsSI -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
      "https://$registry/v2/$path/manifests/$tag" | tr -d '\r' | sed -n 's/^docker-content-digest: *//Ip'
}
for key in runner helper job; do
  image=$("$yq" -e ".$key" "$pin")
  [[ $image =~ ^[a-z0-9.-]+/[a-z0-9/._-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] ||
    die "the $key image $image is not <registry>/<path>:<tag>@sha256:<digest>"
  case $key in
    runner) [[ ${image%@*} == *:alpine-v"$app" ]] || die "the runner image $image is not the chart's appVersion $app" ;;
    helper) [[ ${image%@*} == *:v"$app" ]] || die "the helper image $image is not the chart's appVersion $app" ;;
  esac
  live=$(live_digest "$image") || live=
  [ "$live" = "${image#*@}" ] || die "${image%@*} is [${live}], not the pinned ${image#*@}"
done

(cd "$t/x/$name" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$t/SHA256SUMS"
mv "$t/SHA256SUMS" "$t/x/$name/SHA256SUMS"
if [ "${1:-}" = --check ]; then
  (cd "$release" && sha256sum --quiet -c SHA256SUMS) || die "release/ does not match its SHA256SUMS"
  diff -u "$release/SHA256SUMS" "$t/x/$name/SHA256SUMS" || die "release/ is not $name $version ($digest): run gitlab-runner/fetch.sh"
  echo "$name $version ($digest, app $app): release/ matches, $(wc -l < "$release/SHA256SUMS") files; the images' tags have their digests"
else
  rm -rf "$release"
  cp -R "$t/x/$name" "$release"
  echo "$name $version ($digest, app $app): fetched $(wc -l < "$release/SHA256SUMS") files into release/"
fi
