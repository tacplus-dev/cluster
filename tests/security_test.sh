#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/security.sh, the security job, on a repository made here: a clean tree passes, and writes its JSON
# report; a secret fails the job, planted in the tree or only in the history (gitleaks itself, not a stub), and so
# does a shallow clone, whose history it cannot read; a HIGH or CRITICAL finding with a fix fails, from
# govulncheck on a binary, OSV-Scanner on the tree, Trivy on the image or on an image the tree's pins deploy (each
# by its digest, for linux/arm64; a pin without its image, or not by digest, fails), unless an unexpired exception names it
# (by its id or an alias); an expired exception fails the job, with or without its finding, and so does an entry
# with a field missing or one too many, or a tool that cannot run; a finding without a fix, or below HIGH, passes.
# This repository's own files hold no secret, and its security-exceptions.yaml reads, each entry with its four fields. OSV-Scanner, govulncheck
# and Trivy are stubs (tests/stub/security: they need the network and their databases). Needs bash, git, jq, tar,
# openssl and gitleaks (ci/tools.sh builds it into bin/).
#
#   tests/security_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
command -v gitleaks >/dev/null || { echo "FAIL no gitleaks on the PATH (ci/tools.sh)"; exit 1; }
export PATH=$here/tests/stub/security:$PATH SSTUB=$work/stub SECURITY_OUT=$work/security
image=ghcr.io/tacplus-dev/tacplus/build:2.5
mkdir -p "$work/bin" && printf 'not really a binary\n' > "$work/bin/kubectl"
today=$(date -u +%Y-%m-%d)
later=$(date -u -d '+30 days' +%Y-%m-%d)
earlier=$(date -u -d '-1 day' +%Y-%m-%d)
# A token gitleaks finds (github-pat), made here, so that this file holds none.
token=ghp_$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 36)

# repo: a fresh repository in $work/repo, one commit of a deployments file; and no stub reports.
repo() {
  rm -rf "$work/repo" "$SSTUB" && mkdir -p "$work/repo" "$SSTUB"
  git -C "$work/repo" init -q
  printf 'deployments:\n  - name: alpha\n' > "$work/repo/deployments.yaml"
  commit "a deployment"
}
commit() { git -C "$work/repo" add -A && git -C "$work/repo" -c user.name=t -c user.email=t@example.com commit -q -m "$1"; }
exceptions() { printf 'exceptions:\n' > "$work/repo/security-exceptions.yaml"; printf '%s\n' "$@" >> "$work/repo/security-exceptions.yaml"; commit exceptions; }
# entry ID EXPIRES: an exception entry.
entry() { printf '  - id: %s\n    reason: "no fixed release of the tool yet"\n    decided_by: Jody Scott\n    expires: %s\n' "$1" "$2"; }
# govulncheck_finding: kubectl's report, a vulnerable symbol of golang.org/x/net with a fix (FIX, empty: none).
govulncheck_finding() {
  jq -nc '{config: {db: "https://vuln.go.dev"}}, {osv: {id: "GO-2026-6860", aliases: ["CVE-2026-1111"], summary: "x/net: a parsing bug"}},
          {finding: {osv: "GO-2026-6860", fixed_version: $fix, trace: [{module: "golang.org/x/net", version: "v0.60.0", package: "golang.org/x/net/http2", function: "Read"}]}}' \
    --arg fix "$1" > "$SSTUB/govulncheck-kubectl.json"
}
# run: ci/security.sh on the repository; its exit status.
run() { "$here/ci/security.sh" "$work/repo" "$image" "$work/bin/kubectl" > "$work/log" 2>&1; }
# passes WHAT / fails WHAT WANT: the job passes; fails, its verdict or summary saying WANT.
passes() { if run; then ok "passes: $1"; else fail "$1: failed: $(cat "$work/security/verdict" 2>/dev/null) $(tail -5 "$work/log")"; fi; }
fails() {
  if run; then fail "$1: passed"
  elif grep -q -- "$2" "$work/security/verdict" "$work/security/summary.md"; then ok "fails: $1"
  else fail "$1: failed, but not saying [$2]: $(cat "$work/security/verdict") $(tail -5 "$work/log")"; fi
}

repo
passes "a clean tree"
jq -e 'type == "array" and length == 0' "$work/security/findings.json" >/dev/null && [ "$(cat "$work/security/verdict")" = pass ] &&
  ok "its JSON report: no finding, verdict pass" || fail "the clean tree's report: $(cat "$work/security/findings.json")"
grep -q -- "image -q --scanners vuln --platform linux/[a-z0-9]* --format json -o .* $image\$" "$SSTUB/trivy.log" &&
  ok "Trivy scans the image, for this platform" || fail "trivy ran: $(cat "$SSTUB/trivy.log")"

repo
printf 'token: %s\n' "$token" > "$work/repo/notes.yaml" && commit "a planted secret"
fails "a planted secret in the tree" "gitleaks"
jq -e 'any(.[]; .kind == "secret" and .blocking and (.where | startswith("notes.yaml:1")))' "$work/security/findings.json" >/dev/null &&
  ok "the report names the secret's file and line" || fail "the secret's finding: $(cat "$work/security/findings.json")"
grep -q -- "$token" "$work/security/findings.json" "$work/security/summary.md" "$work/log" && fail "the report holds the secret" ||
  ok "the report does not hold the secret (redacted)"

repo
printf 'token: %s\n' "$token" > "$work/repo/notes.yaml" && commit "a planted secret"
rm "$work/repo/notes.yaml" && commit "the secret removed"
fails "a secret in the history only" "1 finding(s) the policy fails"
jq -e 'any(.[]; .kind == "secret" and (.where | startswith("commit ")))' "$work/security/findings.json" >/dev/null &&
  ok "the history's secret names its commit" || fail "the history's finding: $(cat "$work/security/findings.json")"

repo
commit2() { printf 'more\n' >> "$work/repo/deployments.yaml" && commit more; }
commit2
git clone -q --depth 1 "file://$work/repo" "$work/shallow" && mv "$work/repo" "$work/full" && mv "$work/shallow" "$work/repo"
fails "a shallow clone" "shallow clone"
rm -rf "$work/full"

repo
govulncheck_finding v0.62.0
fails "a vulnerable symbol in a binary, with a fix" "GO-2026-6860"
jq -e '.[0] | .tool == "govulncheck" and .severity == "HIGH" and .fix and (.where | startswith("kubectl (golang.org/x/net@v0.60.0"))' \
  "$work/security/findings.json" >/dev/null && ok "govulncheck's finding names the binary and the module" ||
  fail "govulncheck's finding: $(cat "$work/security/findings.json")"
exceptions "$(entry GO-2026-6860 "$later")"
passes "the same, accepted by an unexpired exception"
jq -e '.[0].excepted == "GO-2026-6860" and (.[0].blocking | not)' "$work/security/findings.json" >/dev/null &&
  ok "the report says which exception accepts it" || fail "the excepted finding: $(cat "$work/security/findings.json")"
exceptions "$(entry CVE-2026-1111 "$today")"
passes "the same, accepted by its alias, the last day of the exception"
exceptions "$(entry GO-2026-6860 "$earlier")"
fails "the same, its exception expired" "exception GO-2026-6860 expired on $earlier"

repo
exceptions "$(entry GO-2026-0001 "$earlier")"
fails "an expired exception, with no finding" "expired on $earlier"
exceptions "$(entry GO-2026-0001 "$later")"
passes "an unexpired exception with no finding"
grep -q 'Exceptions no finding needs' "$work/security/summary.md" && ok "the summary lists an exception no finding needs" ||
  fail "the unused exception: $(cat "$work/security/summary.md")"
exceptions "  - id: GO-2026-0001" "    reason: no fix yet" "    expires: $later"
fails "an exception without decided_by" "needs a reason and who decided"
exceptions "$(entry GO-2026-0001 "$later")" "    ticket: 12"
fails "an exception with a field it does not have" 'unknown key "ticket"'
exceptions "$(entry GO-2026-0001 2026-12)"
fails "an exception whose expiry is not a date" "is not a date"

repo
govulncheck_finding ""
passes "a vulnerable symbol without a fix"
jq -nc '{Results: [{Target: "debian 13", Vulnerabilities: [
  {VulnerabilityID: "CVE-2026-2222", PkgName: "libfoo", InstalledVersion: "1.0", FixedVersion: "1.1", Severity: "MEDIUM"},
  {VulnerabilityID: "CVE-2026-3333", PkgName: "libbar", InstalledVersion: "1.0", Severity: "CRITICAL"}]}]}' > "$SSTUB/trivy.json"
passes "the image's MEDIUM with a fix and CRITICAL without one"
jq -nc '{Results: [{Target: "debian 13", Vulnerabilities: [
  {VulnerabilityID: "CVE-2026-4444", PkgName: "openssl", InstalledVersion: "3.0", FixedVersion: "3.1", Severity: "CRITICAL"}]}]}' > "$SSTUB/trivy.json"
fails "the image's CRITICAL with a fix" "CVE-2026-4444"
jq -e --arg image "$image" 'any(.[]; .tool == "trivy" and .blocking and .where == "openssl@3.0 (\($image): debian 13)")' \
  "$work/security/findings.json" >/dev/null && ok "Trivy's finding names the image and the package" ||
  fail "trivy's finding: $(cat "$work/security/findings.json")"

# The images this repository deploys, read from its pins: each scanned by its digest, for the cluster's platform.
deployed=(registry.example/runner:alpine-v1@sha256:1111 registry.example/runner-helper:v1@sha256:2222
          registry.example/build:2@sha256:3333 registry.example/deploymentproxy:0.2.1@sha256:4444)
pins() {
  mkdir -p "$work/repo/gitlab-runner" "$work/repo/deploymentproxy"
  printf 'chart:\n  name: gitlab-runner\nrunner: %s\nhelper: %s\njob: %s\n' "${deployed[@]:0:3}" > "$work/repo/gitlab-runner/pin.yaml"
  printf 'repository: tacplus-dev/deploymentproxy\nimage: %s\nfiles:\n  - a.yaml\n' "${deployed[3]}" > "$work/repo/deploymentproxy/pin.yaml"
  commit pins
}
repo
pins
passes "the deployed images, clean"
all=1
for d in "${deployed[@]}"; do
  grep -q -- "image -q --scanners vuln --platform linux/arm64 --format json -o .* $d\$" "$SSTUB/trivy.log" || all=0
done
[ "$all" = 1 ] && ok "Trivy scans each pinned image by its digest, for linux/arm64" || fail "trivy ran: $(cat "$SSTUB/trivy.log")"
jq -nc '{Results: [{Target: "alpine 3.24.3", Vulnerabilities: [
  {VulnerabilityID: "CVE-2026-42496", PkgName: "miniperl", InstalledVersion: "5.42.2-r1", FixedVersion: "5.42.3-r0", Severity: "CRITICAL"}]}]}' \
  > "$SSTUB/trivy-runner-helper.json"
fails "a deployed image's CRITICAL with a fix" "CVE-2026-42496"
jq -e --arg image "${deployed[1]}" '[.[] | select(.blocking)] | length == 1 and .[0].where == "miniperl@5.42.2-r1 (\($image): alpine 3.24.3)"' \
  "$work/security/findings.json" >/dev/null && ok "the finding names the deployed image, and only it" ||
  fail "the deployed image's finding: $(cat "$work/security/findings.json")"
exceptions "$(entry CVE-2026-42496 "$later")"
passes "the same, accepted by an unexpired exception"
printf 'repository: tacplus-dev/deploymentproxy\n' > "$work/repo/deploymentproxy/pin.yaml" && commit "no image"
fails "a pin without its image" 'deploymentproxy/pin.yaml: no "image:" image to scan'
pins
printf 'image: registry.example/deploymentproxy:0.2.1\n' > "$work/repo/deploymentproxy/pin.yaml" && commit "a tag only"
fails "a pinned image not by digest" "not by digest"

repo
jq -nc --arg root "$work/repo" '{results:[{source: {path: "/tmp/x/go.sum"}, packages: [{package: {name: "golang.org/x/crypto", version: "v0.1.0"},
  vulnerabilities: [{id: "GO-2026-5932", summary: "ssh", affected: [{ranges: [{events: [{introduced: "0"}, {fixed: "0.58.1"}]}]}]}],
  groups: [{ids: ["GO-2026-5932"], aliases: ["CVE-2026-5555"], max_severity: "7.5"}]}]}]}' > "$SSTUB/osv-scanner.json"
fails "a HIGH dependency of the tree with a fix" "GO-2026-5932"

repo
touch "$SSTUB/govulncheck-fails"
fails "a tool that cannot run" "govulncheck .*kubectl: .*not a Go binary"

# This repository's own files, as they are (its pins' checksums are no secret, its exceptions read, each entry
# with its four fields: whether one has expired is the security job's to say).
repo
(cd "$here" && tar -c --exclude=./out --exclude=./bin --exclude=./security --exclude=./.git .) | tar -x -C "$work/repo" &&
  commit "this repository's files"
run
if grep -q 'gitleaks\|security-exceptions.yaml\|needs a reason\|is not a date' "$work/security/summary.md"; then
  fail "this repository's files: $(cat "$work/security/summary.md")"
else ok "this repository's files: no secret, and its security-exceptions.yaml reads"; fi
[ -f "$work/repo/security-exceptions.yaml" ] || fail "the repository has no security-exceptions.yaml"

[ "$failed" = 0 ] && echo "security: all passed" || { echo "security: FAILED"; exit 1; }
