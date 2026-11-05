#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The security job (tacplus-dev/looper#49's floor, in this pipeline: tacplus-dev/build's checks never reach it).
# On REPO's commit, its tree and its history, on the pinned tool binaries the pipeline runs, on the CI image and on
# the images the commit deploys:
#
#   OSV-Scanner               the tree's dependency manifests and lock files
#   govulncheck -mode=binary  each BINARY (ci/tools.sh's bin/: yq, kubeconform, kubectl, gke-gcloud-auth-plugin,
#                             gitleaks, osv-scanner, govulncheck, trivy); a finding is the vulnerable symbol in the
#                             binary, counted HIGH (govulncheck gives no severity), as looper-scan counts it
#   gitleaks                  the tree, and every commit of the history
#   Trivy                     IMAGE, the image the jobs run in (its platform: this machine's); and each image the
#                             tree's pins deploy, by digest, for linux/arm64 (the cluster's): gitlab-runner/pin.yaml's
#                             runner, helper and job, deploymentproxy/pin.yaml's image
#
# The policy (looper-scan's): a secret fails, and so does a HIGH or CRITICAL finding with a fixed version, unless
# an unexpired entry of the commit's security-exceptions.yaml names it (its id or an alias: a CVE, a GHSA). An
# entry has exactly id, reason, decided_by and expires (YYYY-MM-DD), the file a strict subset of YAML that
# looper-scan reads too; an entry that has expired, or says less, fails, and so does a tool that cannot run. The
# reports go to SECURITY_OUT (default ./security): findings.json (every finding, with excepted and blocking),
# summary.md, verdict, raw/ (each tool's own JSON). Exits 1 on a fail.
#
#   ci/security.sh REPO IMAGE BINARY...   # needs git, jq, tar and the tools (ci/tools.sh security) on the PATH
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: ci/security.sh REPO IMAGE BINARY..." >&2; exit 2; }
repo=$(cd "$1" && pwd) image=$2
shift 2
out=${SECURITY_OUT:-$PWD/security}
rm -rf "$out" && mkdir -p "$out/raw" "$out/norm" || exit 1
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
problems=()
log() { echo "security: $*" >&2; }

JQ_LIB='
def bucket: if . == null then "UNKNOWN" elif . >= 9 then "CRITICAL" elif . >= 7 then "HIGH"
  elif . >= 4 then "MEDIUM" elif . > 0 then "LOW" else "UNKNOWN" end;
def finding($tool; $kind; $id; $aliases; $sev; $fix; $where; $title):
  {tool: $tool, kind: $kind, id: $id, aliases: ($aliases // [] | map(select(. != $id)) | unique),
   severity: $sev, fix: $fix, where: $where, title: ($title // "" | tostring | .[0:300])};
'
# norm NAME PROGRAM RAW [jq args...]: RAW's findings, normalized, as norm/NAME.json.
norm() {
  local name=$1 prog=$2 raw=$3
  shift 3
  jq -s "$@" "$JQ_LIB $prog" "$raw" > "$out/norm/$name.json" || problems+=("$name: its report could not be read")
}

# The commit's tree, as committed (no bin/, out/ or other untracked file).
git -C "$repo" rev-parse --verify -q HEAD >/dev/null || { log "$repo is not a git checkout with a commit"; exit 1; }
mkdir -p "$t/tree" && git -C "$repo" archive HEAD | tar -x -C "$t/tree" || { log "could not export $repo's tree"; exit 1; }
log "$repo at $(git -C "$repo" rev-parse HEAD)"

# OSV-Scanner: 1 is findings, 128 no manifest or lock file at all.
log "osv-scanner: the tree"
rc=0
osv-scanner scan source -r --format json --output "$out/raw/osv-scanner.json" "$t/tree" >/dev/null 2>"$out/raw/osv-scanner.log" || rc=$?
case $rc in
  0|1) norm osv-scanner '
    [.[0].results[]? | (.source.path | ltrimstr($root + "/")) as $where | .packages[]? | .package as $p | (.vulnerabilities // []) as $vs
     | .groups[]? | . as $g
     | ([$vs[] | select(.id as $i | $g.ids | index($i)) | .affected[]?.ranges[]?.events[]? | .fixed // empty] | length > 0) as $fix
     | finding("osv-scanner"; "sca"; $g.ids[0]; ($g.aliases + $g.ids); ($g.max_severity | if . == null or . == "" then null else tonumber end | bucket);
               $fix; ($p.name + "@" + ($p.version // "") + " (" + $where + ")"); ([$vs[] | select(.id == $g.ids[0]) | .summary // empty][0]))]' \
       "$out/raw/osv-scanner.json" --arg root "$t/tree" ;;
  128) log "osv-scanner: no dependency manifest or lock file in the tree" ;;
  *) problems+=("osv-scanner exited $rc: $(grep -m1 -i error "$out/raw/osv-scanner.log")") ;;
esac

# govulncheck on each binary.
i=0
for b in "$@"; do
  i=$((i + 1)) name=$(basename "$b")
  log "govulncheck: $b"
  raw=$out/raw/govulncheck-$i-$name.json
  if ! govulncheck -mode=binary -format json "$b" > "$raw" 2>"$raw.log"; then
    problems+=("govulncheck $b: $(grep -m1 . "$raw.log")"); continue
  fi
  norm "govulncheck-$i-$name" '
    ([.[] | .osv // empty | {(.id): .}] | add // {}) as $osv
    | [.[] | .finding // empty | select(.trace[0].function != null)]
    | unique_by(.osv) | map(.trace[0] as $t
      | finding("govulncheck"; "sca"; .osv; ($osv[.osv].aliases // []); "HIGH"; ((.fixed_version // "") != "");
                ($bin + " (" + $t.module + "@" + ($t.version // "") + ", " + ($t.package // "") + "." + ($t.function // "") + ")");
                $osv[.osv].summary))' "$raw" --arg bin "$name"
done

# gitleaks: the tree, then each commit of the history (which a shallow clone does not have).
log "gitleaks: the tree"
if gitleaks dir --no-banner --redact --exit-code 0 -f json -r "$out/raw/gitleaks-tree.json" "$t/tree" >/dev/null 2>"$out/raw/gitleaks-tree.log"; then
  norm gitleaks-tree '[.[0][]? | (.File | ltrimstr($root + "/")) as $f
    | finding("gitleaks"; "secret"; ($f + ":" + .RuleID + ":" + (.StartLine | tostring)); [.RuleID]; "CRITICAL"; true; ($f + ":" + (.StartLine | tostring)); .Description)]' \
    "$out/raw/gitleaks-tree.json" --arg root "$t/tree"
else problems+=("gitleaks on the tree: $(tail -1 "$out/raw/gitleaks-tree.log")"); fi
log "gitleaks: the history"
if [ "$(git -C "$repo" rev-parse --is-shallow-repository)" = true ]; then
  problems+=("gitleaks: $repo is a shallow clone: its history cannot be scanned (git fetch --unshallow)")
elif gitleaks git --no-banner --redact --exit-code 0 -f json -r "$out/raw/gitleaks-history.json" "$repo" >/dev/null 2>"$out/raw/gitleaks-history.log"; then
  norm gitleaks-history '[.[0][]? | finding("gitleaks"; "secret"; (.Commit[0:12] + ":" + .File + ":" + .RuleID + ":" + (.StartLine | tostring)); [.RuleID];
    "CRITICAL"; true; ("commit " + .Commit[0:12] + " " + .File + ":" + (.StartLine | tostring)); .Description)]' "$out/raw/gitleaks-history.json"
else problems+=("gitleaks on the history: $(tail -1 "$out/raw/gitleaks-history.log")"); fi

# trivy_image NAME IMAGE PLATFORM: Trivy on IMAGE for PLATFORM, its report raw/NAME.json.
trivy_image() {
  local name=$1 img=$2 platform=$3
  log "trivy: $img ($platform)"
  if trivy image -q --scanners vuln --platform "$platform" --format json -o "$out/raw/$name.json" "$img" 2>"$out/raw/$name.log"; then
    norm "$name" '[.[0].Results[]? | .Target as $t | (.Vulnerabilities // [])[]
      | finding("trivy"; "sca"; .VulnerabilityID; []; (.Severity // "UNKNOWN"); ((.FixedVersion // "") != "");
                (.PkgName + "@" + (.InstalledVersion // "") + " (" + $image + ": " + $t + ")"); .Title)]' \
      "$out/raw/$name.json" --arg image "$img"
  else problems+=("trivy on $img: $(tail -1 "$out/raw/$name.log")"); fi
}
# Trivy on the image, for this machine's platform: the one the jobs run.
case $(uname -m) in x86_64|amd64) platform=linux/amd64 ;; aarch64|arm64) platform=linux/arm64 ;; *) platform=linux/$(uname -m) ;; esac
trivy_image trivy-image "$image" "$platform"
# Trivy on each image the commit deploys, by the digest its pin names, for the cluster's platform (arm64): GitLab
# Runner's runner, helper and job (gitlab-runner/pin.yaml) and deploymentproxy's (deploymentproxy/pin.yaml). A pin
# file the tree has must name each, by digest.
i=0
for pin in gitlab-runner/pin.yaml:runner gitlab-runner/pin.yaml:helper gitlab-runner/pin.yaml:job deploymentproxy/pin.yaml:image; do
  f=${pin%%:*} key=${pin#*:}
  [ -f "$t/tree/$f" ] || continue
  i=$((i + 1))
  img=$(sed -n "s/^$key:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$t/tree/$f" | head -1)
  if [ -z "$img" ]; then problems+=("$f: no \"$key:\" image to scan"); continue; fi
  case $img in *@sha256:*) ;; *) problems+=("$f: its $key image $img is not by digest"); continue ;; esac
  trivy_image "trivy-deployed-$i-$key" "$img" linux/arm64
done

# security-exceptions.yaml, read as looper-scan reads it: a list "exceptions:" of entries with exactly id, reason,
# decided_by and expires. A JSON array on stdout; a file it cannot read that way is a problem, never an empty list.
read_exceptions() {
  [ -f "$1" ] || { echo '[]'; return 0; }
  awk '
    function flush() { if (n) printf "%s}", (out++ ? "," : "") cur; cur = ""; n = 0 }
    function str(v) { gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return "\"" v "\"" }
    function field(s, k, v) { k = s; sub(/:.*/, "", k); v = s; sub(/^[^:]*:/, "", v)
      if (k !~ /^(id|reason|decided_by|expires)$/) { print "line " NR ": unknown key \"" k "\"" > "/dev/stderr"; bad = 1 }
      cur = cur (n++ ? "," : "{") "\"" k "\":" str(v) }
    BEGIN { printf "[" }
    /^[ \t]*(#|$)/ { next }
    /^exceptions:[ \t]*(\[\])?[ \t]*$/ { seen = 1; next }
    seen && /^  - [a-z_]+:/ { flush(); s = $0; sub(/^  - /, "", s); field(s); next }
    seen && n && /^    [a-z_]+:/ { s = $0; sub(/^    /, "", s); field(s); next }
    { print "line " NR ": not an exception entry: " $0 > "/dev/stderr"; bad = 1 }
    END { flush(); printf "]\n"; if (!seen && NR) { print "no exceptions: list" > "/dev/stderr"; bad = 1 }; exit bad }
  ' "$1"
}
today=$(date -u +%Y-%m-%d)
if ! exceptions=$(read_exceptions "$t/tree/security-exceptions.yaml" 2>"$t/exceptions.err"); then
  problems+=("security-exceptions.yaml: $(head -1 "$t/exceptions.err")"); exceptions='[]'
fi
while IFS= read -r e; do [ -n "$e" ] && problems+=("$e"); done < <(jq -r --arg today "$today" '.[] |
  if (.id // "") == "" then "security-exceptions.yaml: an exception without an id"
  elif ((.reason // "") == "" or (.decided_by // "") == "") then "exception \(.id): it needs a reason and who decided (decided_by)"
  elif ((.expires // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) then "exception \(.id): expires \(.expires // "" | @json) is not a date YYYY-MM-DD"
  elif .expires < $today then "exception \(.id) expired on \(.expires) (\(.decided_by): \(.reason))"
  else empty end' <<<"$exceptions")

# The policy.
mapfile -t norms < <(find "$out/norm" -name '*.json' | LC_ALL=C sort)
[ ${#norms[@]} -gt 0 ] || norms=(/dev/null)
jq -s --argjson exc "$exceptions" --arg today "$today" '
  [.[][]] | unique_by([.tool, .id, .where]) | map(
      . as $f
      | ([$exc[] | select(.expires >= $today and (.id as $x | $f.id == $x or any($f.aliases[]; . == $x)))][0]) as $e
      | . + {excepted: ($e.id // null),
             blocking: ($e == null and (.kind == "secret" or ((.severity == "HIGH" or .severity == "CRITICAL") and .fix)))})
  | sort_by(if .blocking then 0 else 1 end, {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}[.severity] // 4, .tool, .id, .where)' \
  "${norms[@]}" > "$out/findings.json" || { log "the findings could not be read together"; exit 1; }

# Unused exceptions are listed, so that a fixed finding's entry is removed.
unused=$(jq -r --slurpfile f "$out/findings.json" '.[] | .id as $x
  | select([$f[0][] | select(.id == $x or any(.aliases[]; . == $x))] | length == 0) | .id' <<<"$exceptions")
blocking=$(jq '[.[] | select(.blocking)] | length' "$out/findings.json")
{
  echo "## Security checks: $(git -C "$repo" rev-parse HEAD)"
  echo
  jq -r '"\(length) finding(s): \([.[] | select(.blocking)] | length) failing the policy, \([.[] | select(.excepted)] | length) accepted by an exception."' "$out/findings.json"
  if [ ${#problems[@]} -gt 0 ]; then echo; echo "### Problems (each fails the job)"; printf -- '- %s\n' "${problems[@]}"; fi
  if [ "$blocking" -gt 0 ]; then
    echo; echo "### Failing the policy"
    jq -r '.[] | select(.blocking) | "- \(.severity) \(.tool) \(.id): \(.where)\(if .title != "" then ": " + .title else "" end)"' "$out/findings.json"
  fi
  if jq -e 'any(.excepted)' "$out/findings.json" >/dev/null; then
    echo; echo "### Accepted (security-exceptions.yaml)"
    jq -r '.[] | select(.excepted) | "- \(.excepted): \(.tool) \(.where)"' "$out/findings.json"
  fi
  if [ -n "$unused" ]; then echo; echo "### Exceptions no finding needs (remove them)"; printf -- '- %s\n' $unused; fi
} > "$out/summary.md"
cat "$out/summary.md" >&2
if [ ${#problems[@]} -gt 0 ]; then
  echo "fail: ${problems[0]}" > "$out/verdict"
elif [ "$blocking" -gt 0 ]; then
  echo "fail: $blocking finding(s) the policy fails: $(jq -r '[.[] | select(.blocking) | .id][0:3] | join(", ")' "$out/findings.json")" > "$out/verdict"
else
  echo pass > "$out/verdict"
fi
log "verdict: $(cat "$out/verdict")"
[ "$(cat "$out/verdict")" = pass ]
