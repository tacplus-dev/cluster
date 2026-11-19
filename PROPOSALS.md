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
- **The infra runner's sizing on the normal pool** (2026-11-16, #25): `infra`'s jobs (tofu plans and applies, Trivy,
  the scanners of tacplus-dev/cloud's pipeline; this one's; fleet-seatrials' deploy) had 2 CPUs and 6 to 7 GB each on
  the VM pools (cloud's `cluster` and `deploy` pools); here they default to 500m / 1500m CPU and 1Gi / 4Gi memory, with
  the same ceiling as `control`'s (1500m, 4Gi), what fits a c4a-standard-2 beside the platform. If the switch-over's
  pipelines show a job short of memory (an OOMKilled container) or slow, raise the ceiling in `infra.yaml` and let
  the job ask for more (`KUBERNETES_MEMORY_LIMIT`), or move the normal pool to a bigger machine type (cloud's `dev`
  stack); either is a pull request, not a registration change.
- **The normal pool's reserve, measured** (2026-11-18, #36): `gitlab-runner/pool.yaml`'s `reserved` (kube-system and
  the deployments' pods, 1200m and 3Gi of the three nodes) is CPU from tacplus-dev/looper#165's evidence and memory an
  estimate; `control`'s `concurrent` (14) follows from it. The hub's `kubectl describe nodes` (Allocated resources,
  less the `ci` and `deploymentproxy` pods), or tacplus-dev/cloud's hub audit reading the containers' requests
  (`kubernetes.io/container/cpu/request_cores`, `memory/request_bytes`), would replace both with what the nodes
  hold; a change of the pool (cloud's `dev` stack) is a change of `nodes` or `allocatable` there too.
- **A runner of their own for the kicker and the plan** (2026-11-18, #36, part 2): `gitlab-runner/runners/kick.yaml`,
  tags `arm64, kick` (not `arm64, control, kick`: GitLab gives a runner every job whose tags are a subset of its own,
  so one holding `control` would fill with reports too), a small fixed `concurrent` on the normal pool, its token
  `gitlab-runner-kick` version 1. Waits on tacplus-dev/cloud#81 (the registration and the secret: the apply refuses
  a version it cannot read); then tacplus-dev/looper tags `.control` `arm64, kick`.
- **A runner change proven by a job before main takes it** (2026-11-19, #37): e246907's runners rolled out green
  (`apply` waits for their rollouts) yet failed every job at once, because nothing here starts a job: `ci/policy.sh`
  now refuses a read-only root filesystem without a writable emptyDir where GitLab Runner writes, but only for the
  paths it knows (RUNNER_WRITES). A job pod started by the rendered runner would prove the rest: either the gates
  (an envtest API server plus the runner binary against a stub GitLab, no container runtime needed for the manager,
  though the job pod itself needs a node), or `apply` running one canary job on each changed runner (a GitLab
  trigger, a token the pipeline does not hold today) and the hub rolling back (`ci/rollback.sh`) on its failure.
  Either is a design for Jody: a token, or a kubelet in the gates.
- **A runner that deploys this pipeline outside the cluster it deploys** (2026-11-19, #37): `ci/rollback.sh` needs
  a person with cluster-admin; tacplus-dev/cloud#11 removes the VM `cluster` runner that applied #37's rollback. A
  GitLab-hosted arm64 runner enabled on this project for a rollback-only job (README's recorded risk already names one
  for a lost cluster), or keeping one VM runner paused for it, would give the pipeline a way back with no person on
  Cloud Shell; a spend and a placement of cluster-admin credentials Jody decides.
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
  Update 2026-11-13 (#21): moot for the runner and helper, which are built here now (below); all 13 entries are gone.
  A GitLab Runner release is still a bump of `build:` too (README, Our GitLab Runner images).
- **The Go tools built with their vulnerable dependencies raised** (2026-11-06, nightly scan, #10): done for the
  tools built here (#10): `ci/tools.sh` builds gitleaks and OSV-Scanner in a module of their own with the fixed
  modules (`go get <module>@<fixed>`), each checked against the checksum database. Left: the result's `go.sum` is
  not pinned in the repository (the versions are, and the checksum database checks every module), and Trivy is
  still a release binary, excepted for GO-2026-6865 until 2026-12-06; building it here too would drop that
  entry and #5's trivy ones, at the cost of a build upstream never tested. Update 2026-11-12 (#21): Trivy is built
  here now (go1.27.4, for GO-2026-6859), but with its own go.mod's modules; giving it compress v1.20.2 and x/net
  v0.62.0 as gitleaks has them would drop GO-2026-6865, 6860 and 6866 for it.
  Update 2026-11-15 (nightly scan): filed as #23: Trivy v0.76.2 (2026-11-05) requires x/net v0.62.0 itself, and
  compress v1.20.2 as a fix module builds in; so built, govulncheck finds no symbol in the binary (GO-2026-5932 at
  module level only). The same run shows crane (v0.22.1, compress v1.19.2) carrying GO-2026-6865's symbols too,
  accepted by the entry that names only Trivy: the fix module for it as well (#23).
  Update 2026-11-15 (#23): done: trivy v0.76.2 and crane v0.22.1 built with compress v1.20.2, GO-2026-6865's entry
  gone and Trivy out of the x/net/html and openpgp entries' reasons. Left: the unpinned `go.sum` above.
  Seen while verifying #23 (a local `ci/security.sh`, 2026-11-15): the job image (`build:2.6.10`, linux/arm64)
  showed no zlib1g finding, and the summary listed CVE-2026-85091 and CVE-2026-76844 as needed by no finding; the
  same run's Trivy scan of the CI image itself timed out, so it proves nothing yet. If the security job agrees,
  tacplus-dev/tacplus#369 is done for us and #16's two entries go.
  Update 2026-11-15 (#24): the security job agreed (#24's report); both entries gone with the move to build 2.6.12.
- **New findings in the pinned images** (2026-11-07, seen while verifying #10): the security job also fails on
  CVE-2026-123158 (openssh 10.3_p1-r1 in the runner image) and CVE-2026-78661 (x/net/html, in the runner, helper,
  docker-machine and the CI image's `gh`), beside #11's CVE-2026-115506. Neither is #10's; the nightly scan should
  file them, with #11 and #12 their likely homes.
  Update 2026-11-07 (#11): filed as #15; still failing the job after #11's bump to 19.5.3.
  Update 2026-11-07 (#15): both accepted (Jody's decision on #15), CVE-2026-123158 until 2026-12-05 with its
  siblings and CVE-2026-78661 until 2026-12-06; remove them with the next GitLab Runner release and, for the CI
  image's `gh` (build:2.6.2 since #16, x/net v0.60.0 still), tacplus-dev/tacplus#350.
  Update 2026-11-17 (#32): tacplus-dev/tacplus#350 closed; build 2.6.12's gh has x/net v0.62.0, so CVE-2026-78661's
  entry is gone. Both findings are done here.
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
  Update 2026-11-13 (#21): the runner and helper images are ours now, so a bump also moves `build:` (commit, branch,
  `base_images`) and rebuilds; see the next-but-one entry for the more frequent Alpine-only bump.
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

- **Our own GitLab Runner and helper images** (2026-11-12, #21; the hub's decision on #21): upstream's 19.5.3 images
  are built with go1.26.10 and git 2.54.0-r0, and no newer release exists, so #21's interim entries (the three git
  CVEs, GO-2026-6859) run until 2026-11-25. Then: (1) an Artifact Registry repository `ci-images` in `tacplus-dev`,
  from tacplus-dev/cloud's `dev` stack, `cluster-admin-pipeline` its writer, the cluster's nodes its readers; (2) a
  `runner-images` job here (main only, before `plan`, no container runtime): `ci/runner-images.sh` builds
  gitlab-runner and gitlab-runner-helper at v19.5.3 (`33227fd4`) with go1.27.4, x/net v0.62.0 and go-jose v4.1.6,
  assembles each with `crane` on a pinned `alpine:3.24` digest (git 2.54.1-r0, libexpat 2.10.0-r0, miniperl
  5.42.3-r0, openssh 10.3_p1-r2), without docker-machine, and pushes only the digest `pin.yaml` names; the first
  land proves the build reproducible before `pin.yaml` points at it, and `tests/ci_test.sh` pairs those digests with
  the runner commit and cloud's build (one release in both places, 19.5.3). That also drops #9's, #11's and #15's
  entries for these images.
  Done 2026-11-13 (#21): `ci/runner-images.sh`, the `runner-images` job, `pin.yaml`'s `build:` and our digests, the
  security job scanning the job's layouts, `fetch.sh` pairing the release with cloud's; 17 entries removed. The
  first push is the first pipeline on main after cloud's `apply:dev` creates `ci-images`.
- **An Alpine-only bump of our runner images, by script** (2026-11-13, #21): Alpine keeps only each package's latest
  build, so `ci/runner-images.sh` stops reproducing the pinned digests whenever Alpine v3.24 updates a package in
  either image (about weekly), and the nightly gates say so. The bump is mechanical: the new versions into
  `build.packages`, the new digests into `runner:` and `helper:`, the fixture. A `ci/runner-images.sh --bump` (or the
  nightly scan filing it) would rewrite those from its own output, as `deploymentproxy/bump.sh` does, and a land's
  gates prove the new digests on another machine. Until then it is by hand (README, Our GitLab Runner images). The
  image already pushed keeps running meanwhile: the job on main pulls a digest the registry has instead of
  building it.
- **GO-2026-6859 in kubectl and gke-gcloud-auth-plugin after 2026-11-25** (2026-11-13, #21): the interim entry
  (CVE-2026-97054) now covers only kubectl v1.34.13 (go1.26.10) and gke-gcloud-auth-plugin 0.5.21 (go1.27.3), no
  release of either with the fix, and it expires on 2026-11-25 as the hub dated it. Before then: a kubectl 1.34
  patch and a Cloud SDK component built with go1.26.11+/go1.27.4, or kubectl built here from its tag with go1.27.4
  (as Trivy is since #21), or a new dated decision.
- **tacplus-dev/cloud's jobs on our helper image** (2026-11-13, #21): cloud's VM runners still pull upstream's
  `gitlab-runner-helper:arm64-v19.5.3` (its `stacks/ci/main.tf` `helper_image`; cloud's PROPOSALS "the jobs' helper
  image built here"). Ours is in `ci-images`, the same release; cloud's VMs would need `ci-images` reader for their
  account. A cloud issue, once the cluster pipeline has pushed it.
- **A render fixture test for a pin change** (2026-11-12, #21): 823eae0 edited `pin.yaml`'s `job:` and the fixture's
  image lines by hand, leaving the `checksum/configmap` annotations helm derives from them stale, so
  `tests/render_test.sh` failed on main until #21 regenerated it. A land runs the gates, so this came in another way;
  `UPDATE=1 tests/render_test.sh` is the only right way to move the fixture.
- **A pin behind its line, said by the gates** (2026-11-15, nightly scan, #22): `deploymentproxy/pin.yaml` declares
  the line 0.2 and pinned v0.2.1 for six days after v0.2.2 (deploymentproxy#14, Jody's no-NetworkPolicy decision)
  was the line's highest patch; nothing here notices, since `fetch.sh --check` only proves the pin consistent with
  itself. deploymentproxy's README (tacplus#180) defines a line as its highest patch, so a check in `validate` (or
  `deploymentproxy/fetch.sh --check`, with the network it already uses) that compares `tag` with the releases of
  `line` and says "behind: v0.2.2" without failing, and the same for `build.lock`'s digest against the CI image's
  `build:2.6` tag, would make the lag visible on every pipeline, and the nightly scan's issue a formality. Links: #22,
  tacplus-dev/deploymentproxy README (Releases), tacplus-dev/tacplus#180.
  Update 2026-11-15 (#24): `build.lock` moved to 2.6.12 (its arm64 image scanned clean of fixed HIGH and CRITICAL
  findings); v2.6.13 was published the same day and `build:2.6` is already its digest, so the pin is behind again.
  Update 2026-11-17 (nightly scan): still on 2.6.12 with v2.6.13 out. That is the right line (2.6, tacplus' newest), so it
  is no pin-rule finding, and the pinned image has no fixed HIGH or CRITICAL finding (Trivy, linux/arm64).
- **A nightly build of this repository in tacplus-dev/build** (2026-11-15, #14): since cloud#26 and looper#113,
  tacplus-dev/build builds a commit of this repository from `build.lock` when a land or a `--build` asks for one, and
  its security checks (osv-scanner, semgrep, trivy, gitleaks …, failing on HIGH/CRITICAL) run with it: main 481c74d
  passed with 0 findings. But only on demand: cloud's `stacks/gitlab/nightly-builds.yaml` lists `looper` alone, so a
  dependency that moves while nothing lands here is seen by the GitLab project's nightly `security` job (our own
  scan) and not by the pipeline's. Filed as tacplus-dev/cloud#33 (bug, open): one entry in that file, in cloud, not
  here. Links: #14, tacplus-dev/cloud#33, tacplus-dev/looper#84.
- **STATE.md's other lines from before main's first green `apply`** (2026-11-16, #26): #26 rewrote the Blocked on
  line and the runners' Known gaps from the hub's comments closing #18 and #25. Still stale, and not settled by those
  comments: Released / deployed (pipeline 3019831835's outcome, 2026-11-02, "not recorded"), "No pipeline has run" and
  what the hub owes after it (the drift job's first mint, cloud#30's proof; the re-pins), "The job has not run in
  GitLab yet (no runner)" under Known vulnerabilities, and the nightly schedule 4547285's state. A run with the hub's
  answers (or a GitLab token) can rewrite them; cluster#8 (open) also reads as done by #24's move to `build:2.6`.
  Links: #18, #25, #8, #26.
- **The build's Trivy config scan: vendored releases and the render fixture counted once** (2026-11-17, nightly
  scan, #28–#31): the build's security checks now scan the Kubernetes manifests too (40 trivy config findings on
  6c4f82e, after 0 before; tacplus-dev/operator#39–#41 the same night). Two kinds of `where` repeat one cause.
  First, the vendored upstream releases (`gitlab-runner/release/`, `deploymentproxy/release/`). They are pinned by
  digest and never edited, and Trivy scans them with upstream's defaults rather than ours: KSV-0015, -0016, -0018,
  -0030 and -0104 are on the chart's template only, and our render sets each of them. Second, the render fixture
  (`tests/fixtures/render/out/`) repeats each finding once per rendered deployment. A way for a repository to name
  its vendored paths (a key in `gates.yaml`, or a `.trivyignore`/skip-dirs that looper-scan reads), so that only
  the render is scanned, would leave one finding per real cause. That is a looper-scan feature
  (tacplus-dev/looper#49, #129); `security-baseline.json` is the interim. Links: #28, #29, #30, #31,
  tacplus-dev/operator#40.
  Update 2026-11-17 (#29): the render's runners have a read-only root filesystem now, so KSV-0014 is gone from
  `tests/fixtures/render/out/20-ci.yaml` (`trivy fs --scanners misconfig` on the tree). It stays on
  `gitlab-runner/release/templates/deployment.yaml`, the chart's defaults, a HIGH finding: a baseline takes only
  MEDIUM and below, and the hub decided no exception for it, so only this feature removes it. The looper-scan of
  #29's run (`tool_trivy` defined but never called) runs no Trivy fs scan at all, which is why the build's report on
  630fc14 has 0 findings; once it runs again, this is the one blocking finding #29 leaves.
  Update 2026-11-18 (nightly scan): it runs again, and KSV-0014 on the chart's template fails main's nightly (#33);
  the 18 MEDIUM/LOW the vendored templates and the render add are #34. tacplus-dev/looper#182 (closed 2026-11-17)
  lets an exception take a `where`, so a scoped entry is now an interim the hub can decide (#33); no
  tacplus-dev/looper issue or roadmap entry asks for skipping vendored paths yet.
  Update 2026-11-18 (#33): the hub decided "fix the scan, no exception": config-scan the render and leave
  `gitlab-runner/release/` out, as "scan what ships". Nothing here can steer the scan, because looper-scan runs
  `trivy fs` on the whole tree and Trivy reads `trivy.yaml`/`.trivyignore` from the job's working directory, not
  from the tree. So the feature is tacplus-dev/looper#190 (a `feature`; it needs a roadmap entry). #33 waits on it,
  and once it lands, this repository names `gitlab-runner/release/` and `deploymentproxy/release/` there.
  Update 2026-11-18 (#34): the render's runners have a 500m CPU limit (KSV-0011 off `20-ci.yaml`); the other 17
  MEDIUM/LOW, the vendored templates' among them, are in `security-baseline.json` per file, the hub's decision.
  Once looper-scan skips vendored paths, their `gitlab-runner/release/` and `deploymentproxy/release/` entries go.
- **deploymentproxy's release naming its user and a CPU limit** (2026-11-17, #31): the render now sets the
  Deployment's `runAsUser`/`runAsGroup` (65532, the image's distroless `USER`) and a 500m CPU limit, which the
  release leaves out, so Trivy's KSV-0011, -0020 and -0021 are off the render but stay on `deploymentproxy/release/`
  (vendored, never edited; the hub's decision on #31 leaves them on the nightly report). A tacplus-dev/deploymentproxy
  release setting both in `config/manager/deployment.yaml` would clear them there too, and render.sh's override could
  go at that bump. KSV-0125 (ghcr.io/tacplus-dev not in Trivy's trusted registries) stays either way: the registry is
  ours. Links: #31, #28.
- **deploymentproxy's ClusterRole without `networkpolicies: [delete]`** (2026-11-17, #28): the rule is there only to
  remove the NetworkPolicies releases before #14 kept in tenant namespaces; it is one of the three grants
  `security-exceptions.yaml`'s KSV-0056 entry and `ci/grants.sh` accept. Once no tenant namespace holds one (`kubectl
  get networkpolicies -A -l` deploymentproxy's owner label, empty), a tacplus-dev/deploymentproxy release could drop
  it, and `deploymentproxy/bump.sh` to it would take its line out of `ci/grants.sh` and the entry's reason. No
  deploymentproxy issue asks for it yet. Links: #28, #14, tacplus-dev/looper#182 (the entries per file).

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
