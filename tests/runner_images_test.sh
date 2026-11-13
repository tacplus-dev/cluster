#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/runner-images.sh's decisions that need no build (#21), on a copy of the script and gitlab-runner/pin.yaml
# in a repository made here: --if-changed builds nothing when the images' recipe (the script, pin.yaml's build:,
# runner: and helper:) is BASE's, and builds when it differs, when BASE is not a commit here, or when no BASE is given
# (the nightly scan); a change elsewhere in pin.yaml is no change of the recipe; a runner: or helper: that is not an
# image of build.registry at build.version, by digest, is refused before anything is fetched. The build itself (the
# network, minutes) is the gates' (gates.yaml's full) and the runner-images job's. Needs bash, git and yq.
#
#   tests/runner_images_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

r=$work/repo
mkdir -p "$r/ci" "$r/gitlab-runner"
cp "$here/ci/runner-images.sh" "$r/ci/" && cp "$here/gitlab-runner/pin.yaml" "$r/gitlab-runner/"
git -C "$r" init -q
commit() { git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@example.com commit -q -m "$1"; }
commit recipe
base=$(git -C "$r" rev-parse HEAD)
# run ARGS...: the script in the copy, with a PATH whose go, crane, curl and git fetch fail, so that a build stops at
# once.
mkdir "$work/stub"
for t in go crane curl; do printf '#!/bin/sh\necho "stub %s: no network here" >&2\nexit 1\n' "$t" > "$work/stub/$t"; done
printf '#!/bin/sh\n[ "$3" = fetch ] && { echo "stub git fetch: no network here" >&2; exit 1; }\nexec %s "$@"\n' "$(command -v git)" > "$work/stub/git"
chmod +x "$work/stub"/*
run() { PATH=$work/stub:$PATH "$r/ci/runner-images.sh" "$@" > "$work/log" 2>&1; }
pin=$r/gitlab-runner/pin.yaml

run --if-changed "$base" "$work/out" && grep -q "the images' recipe is $base's: nothing to build" "$work/log" &&
  ok "--if-changed: the recipe is BASE's, nothing built" || fail "--if-changed on the same recipe: $(cat "$work/log")"
yq -i '.chart.version = "0.94.4"' "$pin" && commit "the chart only"
run --if-changed "$base" "$work/out" && ok "--if-changed: a change outside the recipe builds nothing" ||
  fail "--if-changed with the chart changed: $(cat "$work/log")"
yq -i '.build.packages.helper[0] = "ca-certificates=20261021-r0"' "$pin" && commit "a package"
run --if-changed "$base" "$work/out" && fail "--if-changed: a changed package built nothing" ||
  { grep -q "the images' recipe differs from \[$base\]'s" "$work/log" && grep -q "stub" "$work/log" &&
    ok "--if-changed: a changed package builds" || fail "--if-changed with a package changed: $(cat "$work/log")"; }
git -C "$r" reset -q --hard "$base"
echo "# a comment" >> "$r/ci/runner-images.sh" && commit "the script"
run --if-changed "$base" "$work/out" && fail "--if-changed: a changed script built nothing" ||
  { grep -q "differs" "$work/log" && ok "--if-changed: a changed script builds" || fail "--if-changed with the script changed: $(cat "$work/log")"; }
git -C "$r" reset -q --hard "$base"
run --if-changed 0123456789abcdef0123456789abcdef01234567 "$work/out" && fail "--if-changed: an unknown BASE built nothing" ||
  { grep -q "differs" "$work/log" && ok "--if-changed: a BASE not here builds" || fail "--if-changed, an unknown BASE: $(cat "$work/log")"; }
run --if-changed "" "$work/out" && fail "--if-changed: no BASE built nothing" ||
  { grep -q "no BASE to compare the images' recipe with: building" "$work/log" && ok "--if-changed: no BASE (the nightly scan) builds" || fail "--if-changed, no BASE: $(cat "$work/log")"; }

# The pins: ours, of the build's release, by digest; refused before anything is fetched.
refused() { # WHAT YQ-EXPRESSION WANT
  git -C "$r" reset -q --hard "$base"
  yq -i "$2" "$pin"
  if run "$work/out"; then fail "$1: built"
  elif grep -q -- "$3" "$work/log" && ! grep -q stub "$work/log"; then ok "refused before any fetch: $1"
  else fail "$1: not refused saying [$3]: $(cat "$work/log")"; fi
}
refused "upstream's runner image" '.runner = "registry.gitlab.com/gitlab-org/gitlab-runner:alpine-v19.5.3@sha256:25adb59339aebbee89050b2d3fd0d193a30c1860c70fd4d98d1c8b1e154914a3"' \
  "pin.yaml's runner .* is not an image of"
refused "a helper by tag only" '.helper |= sub("@sha256:.*", "")' "pin.yaml's helper .* is not an image of"
refused "a helper of another release" '.helper |= sub(":v[0-9.]+@", ":v19.5.2@")' "pin.yaml's helper .* is not an image of"
refused "a short commit" '.build.commit = "33227fd4"' "is not a full commit"

[ "$failed" = 0 ] && echo "runner_images_test: all passed" || { echo "runner_images_test: failed"; exit 1; }
