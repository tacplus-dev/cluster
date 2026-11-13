#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# GitLab Runner's runner and helper images, built here from source (#21): upstream's (gitlab-runner/pin.yaml's
# build: block names its release) are built with go1.26.10 (GO-2026-6859), x/net v0.58.0 and go-jose v4.1.4, on
# Alpine packages since fixed (git 2.54.0-r0). This builds the same release's two binaries with go1.27.4, x/net
# v0.62.0, klauspost/compress v1.20.2 and go-jose v4.1.6, as tacplus-dev/cloud's ci/runner.sh builds the VM
# manager's runner (one release in both places: the runner's SHA-256 is cloud's runner_sha256), and puts each on a
# pinned alpine:3.24 with upstream's packages, files and config (its base images' Dockerfiles, at the commit
# build.base_images), without docker-machine (the Kubernetes executor never runs it). No container runtime: the
# packages are installed into the root file system by Alpine's static apk (unprivileged, no scripts: their only
# effects are the files written here), every package checked against Alpine's signed index; crane assembles the
# image on a registry of its own on localhost. linux/arm64 only, the cluster's; a cross-build, so on any host.
#
# Reproducible: every file's time is the commit's, every owner root but the runner's home, the layer sorted, so the
# image's digest is the build's identity. Each image is refused unless its digest is the one pin.yaml's runner: and
# helper: name. Alpine keeps only each package's latest build, so a build stops being reproducible once Alpine ships
# a newer one of any package in an image: the refusal lists the image's packages, and the bump (README, Our GitLab
# Runner images) is a new digest in pin.yaml, after a second build agrees.
#
#   ci/runner-images.sh OUT            # build both images into OUT/<runner|helper> (OCI layouts), refused unless
#                                      # each digest is pin.yaml's
#   ci/runner-images.sh --push OUT     # each image pin.yaml names that the registry already has, by digest: pulled
#                                      # into OUT/; any other built, checked, then pushed with its tag (the
#                                      # runner-images job on main, as cluster-admin-pipeline, ci_gcp)
#   ci/runner-images.sh --if-changed BASE OUT
#                                      # the build, if the images' recipe (this file, pin.yaml's build:, runner: or
#                                      # helper:) differs from commit BASE's or BASE is not here; else nothing (the
#                                      # gates: LOOPER_GATES_BASE)
#
# Needs bash, git, go (the toolchain is fetched by the go command), crane and yq (ci/tools.sh), curl, jq, tar,
# sha256sum, openssl, and https to gitlab.com, the Go module proxy, Docker Hub and dl-cdn.alpinelinux.org.
set -euo pipefail
# The same files, modes and order whoever builds: what this writes is 0755/0644, what it unpacks keeps its own modes.
umask 022
export LC_ALL=C
here=$(cd "$(dirname "$0")/.." && pwd)
pin=$here/gitlab-runner/pin.yaml
yq=${YQ:-yq}
die() { echo "runner-images.sh: $*" >&2; exit 1; }
say() { echo "runner-images.sh: $*" >&2; }

# The binaries' recipe: tacplus-dev/cloud's ci/runner.sh's, which builds the same commit.
go_version=go1.27.4
deps=(golang.org/x/net@v0.62.0 github.com/klauspost/compress@v1.20.2 github.com/go-jose/go-jose/v4@v4.1.6)
# Alpine's static apk, run on this machine (linux/amd64 or linux/arm64), from the same release as the images.
alpine=https://dl-cdn.alpinelinux.org/alpine/v3.24
apk_tools=3.0.9-r0
apk_tools_sha256_x86_64=0a1a0682375f66a83b7b903f6e4638ccfe312547d50d336b5f2be9fc391281be
apk_tools_sha256_aarch64=1f4c822fd14e8eb51ba27e17d5a1649aef33c91611c77eddeb318e8f2cb57fb1

mode=build if_changed= base=
case ${1:-} in
  --push) mode=push; shift ;;
  --if-changed) if_changed=1 base=${2:-}; shift 2 || true ;;
esac
out=${1:?usage: ci/runner-images.sh [--push | --if-changed BASE] OUT}

b() { "$yq" -e ".build.$1" "$pin"; }
recipe() { # the recipe at commit $1, or here
  if [ -n "${1:-}" ]; then
    git -C "$here" show "$1:ci/runner-images.sh"
    git -C "$here" show "$1:gitlab-runner/pin.yaml" | "$yq" '{"build": .build, "runner": .runner, "helper": .helper}'
  else
    cat "$here/ci/runner-images.sh"
    "$yq" '{"build": .build, "runner": .runner, "helper": .helper}' "$pin"
  fi
}
if [ -n "$if_changed" ] && [ -z "$base" ]; then
  say "no BASE to compare the images' recipe with: building"
elif [ -n "$if_changed" ]; then
  if git -C "$here" cat-file -e "$base^{commit}" 2>/dev/null && old=$(recipe "$base" 2>/dev/null) &&
      [ "$old" = "$(recipe)" ]; then
    say "the images' recipe is $base's: nothing to build"
    exit 0
  fi
  say "the images' recipe differs from [$base]'s (or it is not here): building"
fi

version=$(b version) commit=$(b commit) registry=$(b registry)
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "pin.yaml's build.commit $commit is not a full commit"
for key in runner helper; do
  image=$("$yq" -e ".$key" "$pin")
  [[ $image =~ ^$registry/gitlab-runner(-helper)?:(alpine-)?$version@sha256:[0-9a-f]{64}$ ]] ||
    die "pin.yaml's $key $image is not an image of $registry at $version, by digest"
done

mkdir -p "$out" && out=$(cd "$out" && pwd)
tmp=$(mktemp -d)
reg_pid=
cleanup() { [ -z "$reg_pid" ] || kill "$reg_pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

# With --push, each image the registry has (by its pinned digest) is only pulled: nothing is built for it.
todo=()
for key in runner helper; do
  image=$("$yq" -e ".$key" "$pin")
  if [ "$mode" = push ] && crane manifest "$image" >/dev/null 2>&1; then
    rm -rf "$out/$key"
    crane pull --format=oci "$image" "$out/$key"
    [ "$(jq -r '.manifests[0].digest' "$out/$key/index.json")" = "${image#*@}" ] || die "$image pulled as another digest"
    say "$key: $image is in the registry: pulled, not built"
  else
    todo+=("$key")
  fi
done
[ ${#todo[@]} -gt 0 ] || exit 0

# The source: GitLab Runner at build.commit, and its base images' files at build.base_images.
fetch_git() { # REPO COMMIT DIR
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2" || die "cannot fetch $2 from $1"
  git -C "$3" checkout -q FETCH_HEAD
  [ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || die "$1 gave $(git -C "$3" rev-parse HEAD), not $2"
}
src=$tmp/gitlab-runner bi=$tmp/base-images
fetch_git https://gitlab.com/gitlab-org/gitlab-runner.git "$commit" "$src"
fetch_git https://gitlab.com/gitlab-org/ci-cd/runner-tools/base-images.git "$(b base_images)" "$bi"
built=$(TZ=UTC0 git -C "$src" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ)
epoch=$(git -C "$src" log -1 --format=%ct)
rm -rf "$src/.git"

# The binaries, as tacplus-dev/cloud's ci/runner.sh builds the runner: upstream's ldflags (its Makefile's
# GO_LDFLAGS; REVISION and BUILT, which its build reads from the VCS stamp, from the commit), CGO off, -trimpath,
# each refused unless its SHA-256 is the pinned one.
(
  export GOTOOLCHAIN=$go_version GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64=v8.0 GOEXPERIMENT='' \
    GONOSUMDB='' GOPRIVATE='' GOINSECURE='' GOFIPS140=off
  get=()
  for d in "${deps[@]}"; do (cd "$src" && go list -m "${d%@*}" >/dev/null 2>&1) && get+=("$d"); done
  (cd "$src" && go get "${get[@]}" > "$tmp/get.log" 2>&1) || { cat "$tmp/get.log" >&2; die "cannot require ${get[*]}"; }
  [ "$(cd "$src" && go version | cut -d' ' -f3)" = "$go_version" ] || die "go is $(cd "$src" && go version), not $go_version"
  r=gitlab.com/gitlab-org/gitlab-runner/common
  for name in gitlab-runner gitlab-runner-helper; do
    pkg=. && [ "$name" = gitlab-runner ] || pkg=./apps/gitlab-runner-helper
    (cd "$src" && go build -trimpath -buildvcs=false -o "$tmp/bin/$name" -ldflags \
      "-X $r.NAME=$name -X $r.VERSION=${version#v} -X $r.BRANCH=$(b branch) -X $r.REVISION=${commit:0:8} -X $r.BUILT=$built -w" \
      "$pkg") || die "the build of $name failed"
    got=$(sha256sum "$tmp/bin/$name" | cut -c1-64)
    if [ "$name" = gitlab-runner ]; then want=$(b runner_sha256); else want=$(b helper_sha256); fi
    [ "$got" = "$want" ] || die "the build of $name has SHA-256 $got, not the pinned $want"
    say "$name $version ($go_version, ${get[*]}) for linux/arm64, SHA-256 $got"
  done
)

# Alpine's static apk for this machine.
case $(uname -m) in x86_64|amd64) host=x86_64 ;; aarch64|arm64) host=aarch64 ;; *) die "no apk-tools-static for $(uname -m)" ;; esac
sum=apk_tools_sha256_$host
curl -fsSL --retry 3 -o "$tmp/apk-tools-static.apk" "$alpine/main/$host/apk-tools-static-$apk_tools.apk"
echo "${!sum}  $tmp/apk-tools-static.apk" | sha256sum -c --quiet - >/dev/null 2>&1 ||
  die "apk-tools-static $apk_tools ($host) is not the pinned sha256 ${!sum}"
mkdir "$tmp/apk" && tar -xzf "$tmp/apk-tools-static.apk" --no-same-owner -C "$tmp/apk" sbin/apk.static 2>/dev/null
apk() { "$tmp/apk/sbin/apk.static" --root "$1" --arch aarch64 --no-cache --repositories-file /dev/null \
  -X "$alpine/main" -X "$alpine/community" "${@:2}"; }

# A registry of crane's own, on localhost, where each image is assembled.
port=$(( 20000 + RANDOM % 20000 ))
crane registry serve --address "127.0.0.1:$port" > "$tmp/registry.log" 2>&1 &
reg_pid=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$port/v2/" >/dev/null 2>&1 && break; sleep 0.1; done
local_reg=127.0.0.1:$port

alpine_image=$(b alpine)
lfs_gitconfig='[filter "lfs"]
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process
	required = true'

wrong=()
for key in "${todo[@]}"; do
  image=$("$yq" -e ".$key" "$pin")
  root=$tmp/$key/root
  mkdir -p "$root"
  # Docker Hub's, or the same digest from Google's mirror of it when Docker Hub refuses (its anonymous pull limit).
  { crane export --platform linux/arm64 "$alpine_image" - ||
      crane export --platform linux/arm64 "mirror.gcr.io/${alpine_image#docker.io/}" -; } |
    tar -x --same-permissions --no-same-owner -C "$root" 2>/dev/null || die "cannot export $alpine_image (linux/arm64)"
  mapfile -t pkgs < <("$yq" -e ".build.packages.$key[]" "$pin")
  # Upstream's base images: apk upgrade, then the packages (each pinned name=version, checked after the add).
  apk "$root" --no-scripts --no-interactive upgrade > "$tmp/apk.log" 2>&1 &&
    apk "$root" --no-scripts --no-interactive add "${pkgs[@]%%=*}" >> "$tmp/apk.log" 2>&1 ||
    { cat "$tmp/apk.log" >&2; die "$key: apk failed"; }
  installed=$(apk "$root" list --installed 2>/dev/null | sed 's/ .*//' | LC_ALL=C sort)
  for p in "${pkgs[@]}"; do
    grep -qxF "${p%%=*}-${p#*=}" <<<"$installed" ||
      die "$key: Alpine has $(grep "^${p%%=*}-[0-9]" <<<"$installed" | head -1) now, not the pinned $p: the images need a bump (README)"
  done
  # apk's own traces of this run (its log has the time and this machine's paths), which the base image has none of.
  rm -rf "$root/var/log/apk.log" "$root/lib/apk/db/lock" "$root/var/cache/apk"/*
  # What the packages' scripts would have done (the image as upstream's has it): git-lfs' post-install (git lfs
  # install --system), bash's (add-shell), and ca-certificates' trigger (update-ca-certificates: each certificate
  # /etc/ca-certificates.conf names, linked as ca-cert-<name>.pem and by its subject hash; the bundle is
  # ca-certificates-bundle's own).
  printf '%s\n' "$lfs_gitconfig" > "$root/etc/gitconfig"
  grep -qx /bin/bash "$root/etc/shells" || echo /bin/bash >> "$root/etc/shells"
  while read -r c; do
    case $c in ''|'#'*|'!'*) continue ;; esac
    n=ca-cert-$(basename "$c" .crt).pem h=$(openssl x509 -hash -noout -in "$root/usr/share/ca-certificates/$c") i=0
    ln -s "/usr/share/ca-certificates/$c" "$root/etc/ssl/certs/$n"
    while [ -L "$root/etc/ssl/certs/$h.$i" ]; do i=$((i + 1)); done
    ln -s "$n" "$root/etc/ssl/certs/$h.$i"
  done < "$root/etc/ca-certificates.conf"
  case $key in
    runner)
      # adduser -D -S -h /home/gitlab-runner gitlab-runner, as upstream's image has it.
      echo 'gitlab-runner:x:100:65533::/home/gitlab-runner:/sbin/nologin' >> "$root/etc/passwd"
      sed -i 's/^nogroup:x:65533:$/nogroup:x:65533:gitlab-runner/' "$root/etc/group"
      echo 'gitlab-runner:!:20755:0:99999:7:::' >> "$root/etc/shadow"
      mkdir -p "$root/home/gitlab-runner" "$root/etc/gitlab-runner/certs" "$root/usr/share/gitlab-runner"
      chmod 2755 "$root/home/gitlab-runner"
      chmod 0700 "$root/etc/gitlab-runner" "$root/etc/gitlab-runner/certs"
      install -m 0755 "$bi/dockerfiles/runner/alpine/entrypoint" "$root/entrypoint"
      install -m 0755 "$tmp/bin/gitlab-runner" "$root/usr/bin/gitlab-runner"
      install -m 0755 "$src/packaging/root/usr/share/gitlab-runner/clear-docker-cache" "$root/usr/share/gitlab-runner/"
      entrypoint='["/usr/bin/dumb-init","/entrypoint"]'
      cmd='["run","--user=gitlab-runner","--working-directory=/home/gitlab-runner"]'
      extra='{"StopSignal":"SIGQUIT","Volumes":{"/etc/gitlab-runner":{},"/home/gitlab-runner":{}}}'
      ;;
    helper)
      install -m 0755 "$bi/dockerfiles/runner-helper/helpers/entrypoint" "$root/entrypoint"
      install -m 0755 "$bi"/dockerfiles/runner-helper/scripts/* "$root/usr/bin/"
      ln -s miniperl "$root/usr/bin/perl"
      echo 'hosts: files dns' >> "$root/etc/nsswitch.conf"
      install -m 0755 "$tmp/bin/gitlab-runner-helper" "$root/usr/bin/gitlab-runner-helper"
      entrypoint='["/usr/bin/dumb-init","/entrypoint"]'
      cmd='["sh"]'
      extra='{}'
      ;;
  esac
  # One layer, the whole root file system: sorted, every time the commit's, every owner root but /etc/shadow's group
  # (shadow, as alpine's) and the runner's home (gitlab-runner:nogroup); no package here owns a file otherwise.
  owners=("./etc/shadow 0 42")
  [ "$key" != runner ] || owners+=("./home/gitlab-runner 100 65533")
  tar=(tar --sort=name --format=gnu --numeric-owner --mtime="@$epoch" -C "$root")
  excludes=()
  for o in "${owners[@]}"; do excludes+=("--exclude=${o%% *}"); done
  "${tar[@]}" --owner=0 --group=0 "${excludes[@]}" -cf "$tmp/$key/layer.tar" .
  for o in "${owners[@]}"; do
    read -r f u g <<<"$o"
    "${tar[@]}" --owner="$u" --group="$g" --no-recursion -rf "$tmp/$key/layer.tar" "$f"
  done

  ref=$local_reg/$key:build
  crane append --oci-empty-base -f "$tmp/$key/layer.tar" -t "$ref" >/dev/null
  diff_id=$(crane config "$ref" | jq -r '.rootfs.diff_ids[0]')
  jq -n --arg built "$built" --arg diff "$diff_id" --arg version "$version" --arg commit "$commit" \
      --arg base "$alpine_image" --argjson entrypoint "$entrypoint" --argjson cmd "$cmd" --argjson extra "$extra" '{
    architecture: "arm64", os: "linux", created: $built,
    config: ({Env: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], Entrypoint: $entrypoint,
              Cmd: $cmd, WorkingDir: "/",
              Labels: {"org.opencontainers.image.source": "https://gitlab.com/gitlab-org/gitlab-runner",
                       "org.opencontainers.image.version": $version, "org.opencontainers.image.revision": $commit,
                       "org.opencontainers.image.base.name": $base,
                       "dev.tacplus.built-by": "https://github.com/tacplus-dev/cluster/blob/main/ci/runner-images.sh"}}
             + $extra),
    rootfs: {type: "layers", diff_ids: [$diff]},
    history: [{created: $built, created_by: "tacplus-dev/cluster ci/runner-images.sh"}]}' > "$tmp/$key/config.json"
  crane edit config "$ref" < "$tmp/$key/config.json" >/dev/null
  digest=$(crane digest "$ref")
  rm -rf "$out/$key"
  crane pull --format=oci "$ref@$digest" "$out/$key"
  apk "$root" list --installed 2>/dev/null | sed 's/ .*//' | LC_ALL=C sort > "$out/$key.packages"
  if [ "$digest" != "${image#*@}" ]; then
    say "$key: its packages:"; sed 's/^/  /' "$out/$key.packages" >&2
    wrong+=("$key: the build is $digest, not pin.yaml's ${image#*@}")
    continue
  fi
  say "$key: built $digest, pin.yaml's ($(wc -l < "$out/$key.packages") packages)"
  if [ "$mode" = push ]; then
    crane copy "$ref@$digest" "${image%@*}"
    say "$key: pushed ${image%@*}@$digest"
  fi
done
[ ${#wrong[@]} = 0 ] ||
  die "$(printf '%s; ' "${wrong[@]}")refused: a new package from Alpine, or a change to the recipe (README, Our GitLab Runner images)"
