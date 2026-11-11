# Proposals: cluster

Written by loopers. Each proposal: what, why, links. Jody promotes accepted ones into ROADMAP.md (via an agent);
the looper then marks it `promoted` or `declined` here with the date.

## Open
- **A read-only identity for `plan` and `drift`** (2026-11-02, #1): today they run as `cluster-admin-pipeline`,
  so every pipeline on main holds cluster-admin without anyone playing a job, though they only read and dry-run.
  A second account (cluster `view` plus the server-side dry-run its diff needs, or a narrower ClusterRole) would
  leave cluster-admin to the manual `apply` and `delete-deployment` alone. Needs a WIF binding per environment
  (`attribute.environment`, as fleet-seatrials' test IdP does). For the security round-table the decision
  (`tacplus-dev/roadmap:decisions/cluster-pipeline-2026-11-02.md`, Open) still lists.
- **A dedicated app for the drift issue** (2026-11-02, #1): the issue asks for the tacplus-reader app, which then
  needs Issues: write on this repository; "reader" stops meaning read-only. A small app (or the repository's
  looper bot, tacplus-dev/looper#28) with Issues: write on `cluster` alone would keep tacplus-reader read-only.
- **Cluster-scoped objects for fleets' charts** (2026-11-02, #1): the README says they come only from here, but
  the render has no place for them yet. When a fleet needs one (the operator chart's ClusterRoles move out of it
  in tacplus-dev/operator#3), add a reviewed directory of them, with a policy of its own.
- **`plan` on merge requests** (2026-11-02, #1): a merge request gets `render` and `validate` only, since WIF
  admits protected main alone. With the read-only identity above, a binding for merge request pipelines would show
  the plan before the merge.
- **GitLab's own lint of the pipelines** (2026-11-02, #2): `tests/ci_test.sh` evaluates the jobs' `rules` itself,
  for the expression forms the file uses, to show which jobs each pipeline has (no deletion job but in a deletion
  pipeline). GitLab's CI Lint API with `dry_run` (`POST /projects/88422580/ci/lint`, per ref) would check the same
  against GitLab's own evaluator, but needs a GitLab token the agents do not hold; a job in the project itself could
  run it with its CI_JOB_TOKEN, if that token may call it.
- **A Jody-only environment for the deletion job** (2026-11-03, #3): the automatic `apply` needs the account whose
  merges start main's pipelines (the hub's) among the deployers of the protected environment `cluster`, which the
  deletion job shares, so that account could play a deletion job too. Only a deletion pipeline has one, and only
  the Owner role may set its variables, but an environment of its own (`cluster-delete`, deployable by Jody alone)
  would keep deleting Jody's by GitLab's protection, not only by the variables' role.
- **Bump the accepted tools when their fixes ship** (2026-11-04, #5): `security-exceptions.yaml` accepts 11
  govulncheck findings until 2026-12-04, each waiting on an upstream release (kubectl 1.34 with x/net v0.60.0+,
  x/text v0.41.0+ and otel v1.42.0+; gke-gcloud-auth-plugin and trivy with x/net v0.62.0; trivy past x/crypto
  v0.58.0; gitleaks' xz is built in at v0.5.15 since #10). #10 adds trivy with klauspost/compress v1.20.2+
  (GO-2026-6865) until 2026-12-06. Before then, move each pin in `ci/tools.sh` and drop its entries; the job's
  summary lists the entries no finding needs. A nightly that files an issue a week before an expiry (as `drift`
  does) would make that a reminder rather than a red pipeline.
- **GKE credentials without the auth plugin** (2026-11-04, #5): kubectl reaches GKE through
  gke-gcloud-auth-plugin, a binary of its own to pin and scan (the CI image's, Cloud SDK 549.0.0's, built with
  go1.23.1, had 69 standard-library findings: #5 pins 0.5.21 instead). A kubeconfig written by `ci_kube` with the
  cluster's endpoint and CA (`gcloud container clusters describe`) and the job's access token would drop the binary.
- **Bump GitLab Runner to the first release with #9's fixes** (2026-11-05, #9): `security-exceptions.yaml` accepts
  20 Trivy findings in the runner and helper images of 19.5.2 (GitLab's latest release) until 2026-12-05: libexpat
  2.10.0-r0, curl 8.23.0-r0, go-jose/v4 4.1.6 and x/net 0.60.0 in both, the helper's miniperl 5.42.3-r0 (two
  CRITICAL), and docker-machine's x/net, x/text, x/crypto and grpc in the runner. When GitLab ships 19.5.3 or later
  (chart 0.94.3 or later) with them, bump chart, runner and helper together (README, `gitlab-runner/pin.yaml`'s "A
  bump"), and drop the entries the security job's summary then lists as needed by no finding.
  Update 2026-11-06 (nightly scan): 19.5.3 (chart 0.94.3) is out, and only some of the fixes are in it. Its images
  drop docker-machine's findings and curl's, but still carry libexpat 2.9.0-r0, go-jose/v4 4.1.4 and x/net 0.58.0, and
  the helper's miniperl 5.42.2-r1. So a bump to it removes about 8 of the 20 entries, not all of them (#11).
  Update 2026-11-07 (#11): bumped to 19.5.3 (chart 0.94.3), CVE-2026-115506 accepted next to its libexpat siblings,
  and the 8 entries no finding needed any more removed; 13 remain until 2026-12-05, for the next release with
  libexpat 2.10.0-r0, go-jose/v4 4.1.6, x/net 0.60.0 and miniperl 5.42.3-r0.
- **The Go tools built with their vulnerable dependencies raised** (2026-11-06, nightly scan, #10): done for the
  tools built here (#10): `ci/tools.sh` builds gitleaks and OSV-Scanner in a module of their own with the fixed
  modules (`go get <module>@<fixed>`), each checked against the checksum database. Left: the result's `go.sum` is
  not pinned in the repository (the versions are, and the checksum database checks every module), and Trivy is
  still a release binary, excepted for GO-2026-6865 until 2026-12-06; building it here too would drop that
  entry and #5's trivy ones, at the cost of a build upstream never tested.
- **New findings in the pinned images** (2026-11-07, seen while verifying #10): the security job also fails on
  CVE-2026-123158 (openssh 10.3_p1-r1 in the runner image) and CVE-2026-78661 (x/net/html, in the runner, helper,
  docker-machine and the CI image's `gh`), beside #11's CVE-2026-115506. Neither is #10's; the nightly scan should
  file them, with #11 and #12 their likely homes.
  Update 2026-11-07 (#11): filed as #15; still failing the job after #11's bump to 19.5.3.
  Update 2026-11-07 (#15): both accepted (Jody's decision on #15), CVE-2026-123158 until 2026-12-05 with its
  siblings and CVE-2026-78661 until 2026-12-06; remove them with the next GitLab Runner release and, for the CI
  image's `gh` (build:2.6.2 since #16, x/net v0.60.0 still), tacplus-dev/tacplus#350.
  Update 2026-11-08 (#16): the CI image's zlib1g CVE-2026-85091 and CVE-2026-76844 accepted until 2026-12-06 (hub);
  build:2.6.2 fixes them on amd64 only, its arm64 image is still v2.6.1's: move the pin to the first build:2.6.x
  whose arm64 image has zlib1g 1-1+deb13u1 (tacplus-dev/tacplus#369) and remove both entries.
- **The CI image's gcloud SDK** (2026-11-04, #5): `ghcr.io/tacplus-dev/tacplus/build:2.5` carries Cloud SDK 549.0.0
  (2025-12), whose kubectl dispatcher and gke-gcloud-auth-plugin are built with Go 1.22 to 1.24 (61 to 82
  govulncheck findings each). This pipeline no longer runs them (#5 pins its own), but other jobs in the image may:
  tacplus-dev/tacplus's to decide.
- **The in-cluster runners registered by tacplus-dev/cloud's gitlab stack** (2026-11-04, #6): the stack already
  registers the VM pools' runners and writes their tokens to Secret Manager (`modules/gitlab`). Registering
  `build` and `control` there too (group runners of tacplus-dev, the tags of `gitlab-runner/runners/`, run untagged
  off) would make the hub's step 7 a plan, and a new token a new version the runner files then pin.
- **A bump script for GitLab Runner** (2026-11-04, #6): a bump is five values in `gitlab-runner/pin.yaml` changed
  together, then `fetch.sh` and the fixture. As `deploymentproxy/bump.sh` does from a tag (#4), a
  `gitlab-runner/bump.sh <chart version>` could resolve the archive's digest from charts.gitlab.io's index and the
  images' digests from the chart's appVersion, then fetch and regenerate the fixture.
- **A narrower profile than Unconfined for builds** (2026-11-04, #6): rootless BuildKit's build container is
  Unconfined for seccomp and AppArmor. Once tacplus-dev/tacplus#315 settles the build image, a `Localhost` seccomp
  profile allowing only what rootlesskit needs (unshare, mount, the user namespace calls) would replace it, or user
  namespaces (`hostUsers: false`) where GKE supports them for these pods.
- **The admission policy tested against an API server in the tests** (2026-11-04, #6): `ci-pods` was checked by
  hand against envtest's kube-apiserver 1.35 (each refusal, and the build and manager pods admitted); the tests
  check its render only. A test running envtest's kube-apiserver and etcd (pinned like the other tools) would keep
  its CEL honest on every change.
- **Runner managers apart from their jobs** (2026-11-04, #6): the managers and their token Secrets share `ci` with
  the job pods. Job pods hold no Kubernetes token, so they cannot read those Secrets, but the chart's
  `runners.jobNamespace` would put the jobs in a namespace of their own (`ci-jobs`), with the managers' Role there.
- **`ci/security.sh` refusing a partial tool set** (2026-11-08, #16): #16 was filed saying GO-2026-6865 (trivy
  0.76.1's klauspost/compress) was an exception no finding needed; with `ci/tools.sh security`, govulncheck still finds
  `fse.Compress` in trivy 0.76.1 (arm64 and amd64), so the exception stays. The likeliest cause: a run with `bin/*`
  from `ci/tools.sh` without `security` has no `bin/trivy`, so trivy's binary is never scanned and its exceptions look
  stale. The script could take its binaries from ci/tools.sh's list and fail when one is missing, rather than
  scanning whatever `bin/*` holds.
- **The reader key's version from KMS, not `cryptoKeyVersions/1`** (2026-11-11, #19): `github_app_token` signs
  `cryptoKeyVersions/1` of `TACPLUS_READER_KMS_KEY`, the version imported for tacplus-dev/cloud#30. A key imported
  again (a new private key on the app, a rotation) is version 2, and the drift job would sign with the old one until
  this file changes. Reading the key's primary version (`cryptoKeys.get`: likely a viewer's binding beside the
  signer's, tacplus-dev/cloud's) or taking the version from the variable would follow it. Links: #19,
  tacplus-dev/cloud README (The GitHub Apps' keys).

## Promoted / declined
- **The drift job signs with tacplus-ci's `tacplus-reader`** (2026-11-11, #19): `TACPLUS_READER_KMS_KEY` still
  names jody1-328023's key, and cloud#30 cannot revoke the App's old key or drain jody1-328023 until no signer uses
  it. The new key's version 1 is imported (tacplus-dev/cloud#38, closed). One variable in the pinned file, README's
  runbook and a test, then the hub's re-pin. `ci/drift.sh` mints only when it finds drift, so the proof cloud waits
  on could take weeks; minting every night (or on `drift: none` too) would show it the first night. Approved in the
  hub triage; it needs its ROADMAP.md entry. Links: #19, tacplus-dev/cloud#30, tacplus-dev/cloud#38.
  **Promoted** 2026-11-11: Jody, on #19 (cloud#30); built in #19: the key in tacplus-ci, minted every night.
- **A security report of the pipeline's own** (2026-11-04, nightly scan): no job checks the Go tools `ci/tools.sh`
  builds (yq v4.54.1, kubeconform v0.7.0) for known vulnerabilities, and the README has no "Security checks"
  section, so the nightly scan has no build report to read and runs the auditor itself. Tonight's
  `govulncheck -mode=binary bin/yq` and `bin/kubeconform` found none reachable (yq: 2 in imported packages and 5 in
  required modules, uncalled; kubeconform: 2 in required modules, uncalled). A step in `validate` running
  govulncheck on `bin/`, and a README section saying where its report is, would make that a gate. Links:
  tacplus-dev/looper#49 (the scans), tacplus-dev/roadmap:items/tacplus-security-sweep.md (tacplus's equivalent).
  **Promoted** 2026-11-04: the `security` job (#5).
- **Trivy on the images this pipeline deploys** (2026-11-04, #5; widened 2026-11-05, nightly scan): the security
  job scans the CI image only. The images this pipeline deploys, each by digest, go unscanned: deploymentproxy's
  (`deploymentproxy/pin.yaml`) and GitLab Runner's `runner`, `helper` and `job` (`gitlab-runner/pin.yaml`). A Trivy
  run on each pinned digest in `ci/security.sh`, under the same policy and exceptions, would catch a finding
  published after its release. Tonight's scan, by hand, found the runner 19.5.2 images carrying fixed HIGH and
  CRITICAL findings (#9; the helper's miniperl is CRITICAL), and the `job` image the same Debian findings as the CI
  image (#8). deploymentproxy 0.2.1 was clean. Since no upstream release may have the fix yet, an expiring
  exception is the way to accept one.
  **Promoted** 2026-11-05: Jody, on #9; the `security` job scans each pinned image by digest, for linux/arm64 (#9).
