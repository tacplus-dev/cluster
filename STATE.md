# State: cluster

Overwritten to stay current (loopers and agents). Last updated: 2026-11-19 by the looper (#36).

- **Version / line:** unreleased (main); no tacplus floor (shell and yq, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.6` (#12; tacplus' latest line).
- **Target (#7):** tacplus-dev/cloud's cluster `dev` (us-central1-a) in the project `tacplus-dev` (seabeam.net), as
  `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com`; seatrials' deploy account and the runners' token
  secrets (`gitlab-runner-build`, `gitlab-runner-control`, version 1; `gitlab-runner-infra`, #25, made and
  written by tacplus-dev/cloud's stacks, cloud#64; `gitlab-runner-kick`, #36, the same, cloud#81) in `tacplus-dev` too. The old `tacplus` in
  `jody1-328023` is no longer the target; Jody deletes it once the pipeline applies to `dev`.
- **Works:** the cluster pipeline (#1): `deployments.yaml` (`seatrials`; `test-idp`, #17, without an operator: `operator` optional, no deploymentproxy Role or operator binding then, the policy requiring both or neither); deploymentproxy v0.2.2 (#22) fetched
  and pinned by commit, checksum and image digest, rendered as its image's user 65532:65532 with a 500m CPU limit (#31), bumped by one command (`deploymentproxy/bump.sh <tag>`, #4: the
  pin, the release and the render fixture); `render.sh`; `ci/policy.sh` (no cluster-scoped resource or `*`
  in a deployment's Roles); `ci/tools.sh` pinning every tool by version and SHA-256 (#5: kubectl v1.34.13 and
  gke-gcloud-auth-plugin 0.5.21 pinned, no longer the CI image's gcloud components); the GitLab jobs `render`, `validate`,
  `security` (#5: OSV-Scanner, govulncheck on `bin/`, gitleaks on the tree and history, Trivy on the CI image and,
  #9, on each image the pins deploy by digest for linux/arm64 (GitLab Runner's runner, helper and job, deploymentproxy's);
  `security-exceptions.yaml` enforced; every pipeline, nightly too; `plan` waits for it), `plan`, `apply` (#3: automatic on main once `plan`
  succeeds, applying the render `plan` saved; protected `cluster`, never deletes; not in a deletion pipeline), the
  deletion job (#2: only in a deletion pipeline, run on main from the web form or the API with `DELETE_DEPLOYMENT` and `DELETE_CONFIRM` both the deployment's name; manual, protected,
  named for what it destroys), `drift` (nightly, files an issue, never applies; #19: mints its tacplus-reader token every
  night through tacplus-ci's KMS key `tacplus-reader`, saying so, and nothing here names jody1-328023's key). CI in the cluster (#6):
  `out/20-ci.yaml`, the namespace `ci` with GitLab Runner's chart 0.94.3 (runner 19.5.3, #11; chart by archive digest,
  images by digest, `gitlab-runner/`, rendered by `helm template`, helm v4.3.1 pinned in `ci/tools.sh`); the runner
  and helper images our own build since #21 (`ci/runner-images.sh`: 19.5.3 at `33227fd4` with go1.27.4, x/net v0.62.0,
  go-jose v4.1.6 and compress v1.20.2, the runner binary SHA-256-identical to tacplus-dev/cloud's; on `alpine:3.24`,
  no docker-machine; reproducible, refused unless the pinned digest; the job `runner-images` pushes them on main to
  cloud's `ci-images`, the security job scans its OCI layouts, the gates build them when their recipe changes) as four
  runners, `build` (tags `arm64, build`, jobs on the spot pool only), `control` (`arm64, control`, #13;
  no VM runner's tag, the policy refuses one; the normal pool) and `infra` (#25, for cloud#11: `cloud, cluster, deploy`,
  the three infrastructure pipelines', protected refs only (`tacplus.protected`, on every runner's pods as
  `tacplus.dev/runner-protected`), the normal pool as control, no token in the pod; the policy admits those three tags
  to `infra` alone, refuses it any other tag and an `infra` not protected) and `kick` (#36: `arm64, kick`, the looper's
  kicker and plan on slots of their own, `concurrent` 2, the normal pool, its jobs at the looper's `.control` 50m/256Mi,
  #39; the policy keeps `kick` its tag alone and it on `arm64, kick` only); every runner manager at the PriorityClass
  `ci-runner-manager`, above the jobs and preempting them (#39: `kick`'s manager stayed Pending while `control`'s old
  manager's jobs ran beside the new one's after an apply), per-runner requests, limits and ceilings; `control`'s `concurrent` the normal pool's room (#36: `concurrent: pool`,
  `gitlab-runner/pool.yaml`, 12 today beside `kick`'s 2, CPU the bound, 140m left; its default CPU request a report's 100m, looper#165; the pool's reserve, kube-system and the
  deployments' pods, CPU from looper#165's evidence and memory an estimate, not measured on the nodes, PROPOSALS.md), the
  render refusing runners the pool cannot hold; each job's HOME `/tmp/home`, an emptyDir (#20: uid 1000 has no home in
  the job image, and `git config --global` failed on `//.gitconfig`); each runner's own container CPU-limited to 500m (#34) and on a
  read-only root filesystem, its home, its config and `/tmp` on emptyDirs (#29: KSV-0014; #37: `/tmp`, where the runner
buffers each job's log, was missing, and every job failed at once; `ci/policy.sh` now refuses a runner on a read-only
root without a writable emptyDir where GitLab Runner writes); a way back with no in-cluster runner (#37:
`ci/rollback.sh <commit>`, from Cloud Shell as someone cluster-admin on `dev`; README, Rolling back); Roles in `ci` only; jobs as `ci-job`
  with no token, kept off the metadata server (NetworkPolicy); the admission policy `ci-pods` refusing privileged,
  host path, host namespaces, host ports and added capabilities in `ci` (checked against a real kube-apiserver
  1.35, envtest, by hand); the tokens from Secret Manager by version at apply (`ci/runner-tokens.sh`); all of it in
  `ci/policy.sh`. Tests green (`ci/checks.sh`), here and in the CI image.
- **Pinned for the build pipeline (#14; looper#71, #84):** `build.lock` names the CI image by digest (build 2.6.12's since 2026-11-15, #24; 2.6.10's, OpenEXR-free (tacplus#554), from 2026-11-12; 2.6.2's since #16 before that,
  `gitlab-runner/pin.yaml`'s `job:`) and `gates.yaml` its one set, full (`ci/tools.sh`, the render, `ci/validate.sh
  out`, `ci/checks.sh`), so tacplus-dev/build builds this repository in that image, with no Docker, and runs its
  security checks; `tests/ci_test.sh` refuses a `build.lock` that is not that `job:`, of the CI image's line. Verified
  2026-11-15 (#14, once cloud#26 and looper#113 were done): builds of main planned from the pin report green on the
  gates full (481c74d, pipeline 3070525179; 66e1835, pipeline 3070897201), and the pipeline's first security run of
  main found nothing (0 findings, 0 exceptions needed). On demand only: the nightly build schedule is cloud#33's
  (PROPOSALS.md).
- **Released / deployed:** the cluster runs 8762d36 (2026-11-16): the hub re-pinned to e246907 on 2026-11-18 23:29Z,
  every new job on the in-cluster runners then failed at once (runner_system_failure, empty log: #29's read-only root
  without `/tmp`), and the hub rolled back to 8762d36 at 00:30Z on the VM `cluster` runner (#37). #28 to #36 reach the
  cluster when the hub re-pins to a commit with #37's fix. The GitLab project runs pipelines on main: #2 reports Jody playing `apply` in pipeline
  3019831835 (job 17680247127) on 2026-11-02; its outcome is not recorded here yet. The lines below predate it.
- **Known gaps:** the in-cluster runners are registered and applied (the hub, closing #18 and #25, 2026-11-16 09:25Z):
  `infra` (59271051, #25; registered by cloud's `gitlab` stack, cloud#64) carries cloud's and cluster's pipelines since
  the switch-over (cloud#66): cluster pipelines 3072054740 (applied `infra`) and 3072736343 (green through `apply`, on
  `infra`), cloud pipeline 3072736206; the VM `cluster` runner 58534920 is paused, and tacplus-dev/cloud#11 removes the
  VMs. `control` (58541761) is live since 2026-11-16 01:28Z (tacplus-dev/looper#84). `build` (58541760) stays paused:
  rootless BuildKit is not in the build image yet (tacplus-dev/tacplus#315), and until it is the VM build runner takes
  tacplus-dev/build's scheduled jobs. `kick` (#36; registered by cloud's `gitlab` stack, cloud#81) takes no job until
  the hub re-pins to a commit with it and tacplus-dev/looper#197 tags `.control` (the kicker, the plan) `arm64, kick`;
  that its token's version 1 is readable is cloud#81's, unverified here (until it is, `apply` fails after the rest,
  at `runner-tokens`). Whether this project's nightly schedule 4547285 is on is not recorded: the hub's
  closing comments do not say, and no looper has a GitLab token to see it. The `ci` NetworkPolicy holds only where
  NetworkPolicy is enforced (Dataplane V2: tacplus-dev/cloud's `dev` cluster has it).
  `runner-images` needs tacplus-dev/cloud's `apply:dev` to have created `ci-images` (cloud#45, landed) before it
  can push on main (README, What the hub does, 9); nothing has pushed or pulled our images yet.
  No pipeline has run: the hub owes the runner (tag `cluster`), the project's variables and
  environment (now deployable by the account whose merges start main's pipelines too, for the automatic `apply`),
  the cluster grant, and the drift issue's app permission and KMS binding (README, What the hub does); the hub
  re-pins the GitLab copy for #3, #4, #7, #12 and #19 (the drift job's key: its first mint through `tacplus-ci` is
  the proof tacplus-dev/cloud#30 waits on to revoke the app's old key), after setting `GCP_WIF_PROVIDER` to `dev`'s provider (README, What the
  hub does, the move from `tacplus` to `dev`). The cluster-scoped objects a fleet's chart needs have no
  place in the render yet.
- **Known vulnerabilities:** 10 accepted in `security-exceptions.yaml` until 2026-12-04 (#5), none with a fixed
  release of its tool: kubectl v1.34.13 (x/net, x/text, otel) and gke-gcloud-auth-plugin 0.5.21 (x/net/html), and
  x/crypto/openpgp (GO-2026-5932) in our runner images. gitleaks, OSV-Scanner, crane and trivy (v0.76.2, x/net v0.62.0
  its own, #23) are built with the fixed modules instead (`ci/tools.sh`, #10, #23): GO-2026-6865 (compress v1.20.2)
  and GO-2026-6888 (brotli v1.2.7), and gitleaks' xz (v0.5.15), none accepted.
  Our runner and helper images (#21): only GO-2026-5932 (x/crypto/openpgp, no fixed release), in its
  entry; #9's, #11's, #15's and #21's 17 entries for upstream's images are gone. GO-2026-6859
  (net/http, Trivy's CVE-2026-97054) accepted until 2026-11-25 in kubectl v1.34.13 and gke-gcloud-auth-plugin 0.5.21
  only, no release of either with the fix (PROPOSALS.md). Every Go tool `ci/tools.sh` builds, Trivy too since #21,
  is built with go1.27.4. deploymentproxy
  0.2.2's image (#22): only GO-2026-6859 (Trivy's CVE-2026-97054, its go1.27.3), with no severity, so not failing the
  policy (2026-11-15). The CI image `build:2.6` (2.6.12 since #24, also `gitlab-runner/pin.yaml`'s `job:`, #12): only
  GO-2026-5932 in its gh and docker-buildx, in its entry; #15's CVE-2026-78661 entry went when its gh got x/net v0.62.0 (tacplus-dev/tacplus#350, #32); 2.6.10's six linux-libc-dev CVEs went with the move to 2.6.12 (#24), and #16's zlib1g
  exceptions with 2.6.10, which had the fix. #8's 7 Debian CVEs in `build:2.5` went with the move to 2.6. The job has not run in GitLab yet (no runner).
  Trivy's config checks (looper-scan's nightly, on the tree): KSV-0109 accepted until 2026-12-31 on GitLab Runner chart
  0.94.3's entrypoint ConfigMap, which names the secret files it reads and holds no secret, and its two KSV-01010 in
  `security-baseline.json` (#30); re-check both when the chart moves. KSV-0053 and KSV-0056 accepted until 2026-12-31
  on the RBAC granted by design (#28): the runners' `gitlab-runner-*` (exec, attach, services), `fleet-deploy`
  (services, networkpolicies) and deploymentproxy's ClusterRole (networkpolicies delete). The entries match by id, so
  `ci/grants.sh` (`tests/grants_test.sh`) fails any other Role granting them, until tacplus-dev/looper#182 scopes
  them by file; their KSV-0048, -0049 and -0113 in `security-baseline.json`. KSV-0014 (HIGH) on the chart's template,
  upstream's defaults, still fails the nightly (#33). The render's runners have a read-only root (#29,
  `tests/render_test.sh`). The hub decided to fix the scan, with no exception: the vendored releases are left out
  of Trivy's config scan and the render is still scanned. That needs looper-scan to read a repository's vendored
  paths (tacplus-dev/looper#190), and #33 waits on it. The runners have a 500m CPU limit (KSV-0011, #34);
  KSV-0125 (our registries), the runners' KSV-0020/-0021 (the image's user 100) and the vendored releases'
  templates' MEDIUM/LOW findings are in `security-baseline.json` per file (#34).
- **Expected, not a fault:** a build pod is `Unschedulable` (`Insufficient memory`, the normal pool's nodes not
  matching) while the spot pool scales up from 0; the node comes up in minutes and `poll_timeout = 900` waits for it
  (#20).
- **Blocked on:** the hub's re-pin of the cluster to a commit with `gitlab-runner/runners/kick.yaml` and the runner
  managers' PriorityClass (#39's, or later: on 6dcbdf7, pipeline 3092313841, `gitlab-runner-kick` stayed Pending), then tacplus-dev/looper#197 (`.control` tagged `arm64, kick`; in that order, or `.control` jobs find no
  runner), for #36's runner reserved for the looper's kicker and plan, so they never wait behind reports;
  tacplus-dev/tacplus#315 (rootless BuildKit in the build image), for unpausing the in-cluster `build`
  runner 58541760 only; tacplus-dev/looper#190 (looper-scan leaving vendored paths out of Trivy's config scan), for
  a green nightly (#33). Nothing else in this repository waits.
