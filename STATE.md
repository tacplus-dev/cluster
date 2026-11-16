# State: cluster

Overwritten to stay current (loopers and agents). Last updated: 2026-11-16 by the looper (#25).

- **Version / line:** unreleased (main); no tacplus floor (shell and yq, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.6` (#12; tacplus' latest line).
- **Target (#7):** tacplus-dev/cloud's cluster `dev` (us-central1-a) in the project `tacplus-dev` (seabeam.net), as
  `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com`; seatrials' deploy account and the runners' token
  secrets (`gitlab-runner-build`, `gitlab-runner-control`, version 1; `gitlab-runner-infra`, #25, not made yet:
  tacplus-dev/cloud#64) in `tacplus-dev` too. The old `tacplus` in
  `jody1-328023` is no longer the target; Jody deletes it once the pipeline applies to `dev`.
- **Works:** the cluster pipeline (#1): `deployments.yaml` (`seatrials`; `test-idp`, #17, without an operator: `operator` optional, no deploymentproxy Role or operator binding then, the policy requiring both or neither); deploymentproxy v0.2.2 (#22) fetched
  and pinned by commit, checksum and image digest, bumped by one command (`deploymentproxy/bump.sh <tag>`, #4: the
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
  cloud's `ci-images`, the security job scans its OCI layouts, the gates build them when their recipe changes) as three
  runners, `build` (tags `arm64, build`, jobs on the spot pool only), `control` (`arm64, control`, #13;
  no VM runner's tag, the policy refuses one; the normal pool) and `infra` (#25, for cloud#11: `cloud, cluster, deploy`,
  the three infrastructure pipelines', protected refs only (`tacplus.protected`, on every runner's pods as
  `tacplus.dev/runner-protected`), the normal pool as control, no token in the pod; the policy admits those three tags
  to `infra` alone, refuses it any other tag and an `infra` not protected), per-runner requests, limits and ceilings; each job's HOME `/tmp/home`, an emptyDir (#20: uid 1000 has no home in
  the job image, and `git config --global` failed on `//.gitconfig`); Roles in `ci` only; jobs as `ci-job`
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
- **Released / deployed:** the GitLab project runs pipelines on main: #2 reports Jody playing `apply` in pipeline
  3019831835 (job 17680247127) on 2026-11-02; its outcome is not recorded here yet. The lines below predate it.
- **Known gaps:** `infra` (#25) is rendered but not registered, and its token secret `gitlab-runner-infra` does not
  exist yet (tacplus-dev/cloud#64, opened by #25's run, approved by the hub 2026-11-16 with the registration in its
  scope): until cloud's `dev` stack makes it and cloud's `gitlab` stack has registered `infra` (group runner,
  `cloud, cluster, deploy`, untagged off, `ref_protected`, paused) and written its token as version 1 (no person or
  agent copies a token), a re-pin of `.gitlab-ci.yml` to a commit with #25 makes `apply` fail after applying the rest
  (`runner-tokens: Secret Manager refused .../gitlab-runner-infra/versions/1`), so the hub re-pins to #25 only after
  cloud#64 has applied; then the switch-over (README, The infra runner: unpause `infra`, pause cloud's `cluster` and `deploy` pool
  runners in one step, one cloud and one cluster pipeline green on `infra`), then cloud#11 removes the VMs.
  The in-cluster runners are not registered or applied yet: the hub registers them as tacplus-dev
  group runners and stores their tokens as the Secret Manager versions the runner files name (README, What the hub
  does, 7; in `tacplus-dev`, #7), the spot pool labelled and tainted by tacplus-dev/cloud's `dev` stack; until the tokens are readable, `apply` fails after the rest,
  saying so. Rootless BuildKit is not in the build image yet (tacplus-dev/tacplus#315), and the looper's jobs move
  over in tacplus-dev/looper's switch issue. The `ci` NetworkPolicy holds only where NetworkPolicy is enforced
  (Dataplane V2: tacplus-dev/cloud's `dev` cluster has it).
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
  and GO-2026-6888 (brotli v1.2.7), and gitleaks' xz (v0.5.15), none accepted. 14 accepted until 2026-12-05 (#9, #11, #15), in GitLab
  Our runner and helper images (#21): only GO-2026-5932 (x/crypto/openpgp, no fixed release), in its
  entry; #9's, #11's, #15's and #21's 17 entries for upstream's images are gone. CVE-2026-78661 (x/net/html, fixed in
  v0.62.0) accepted until 2026-12-06 (#15) in the CI image's `gh`, until tacplus-dev/tacplus#350. GO-2026-6859
  (net/http, Trivy's CVE-2026-97054) accepted until 2026-11-25 in kubectl v1.34.13 and gke-gcloud-auth-plugin 0.5.21
  only, no release of either with the fix (PROPOSALS.md). Every Go tool `ci/tools.sh` builds, Trivy too since #21,
  is built with go1.27.4. deploymentproxy
  0.2.2's image (#22): only GO-2026-6859 (Trivy's CVE-2026-97054, its go1.27.3), with no severity, so not failing the
  policy (2026-11-15). The CI image `build:2.6` (2.6.12 since #24, also `gitlab-runner/pin.yaml`'s `job:`, #12): only gh's CVE-2026-78661,
  accepted above (#15); 2.6.10's six linux-libc-dev CVEs went with the move to 2.6.12 (#24), and #16's zlib1g
  exceptions with 2.6.10, which had the fix. #8's 7 Debian CVEs in `build:2.5` went with the move to 2.6. The job has not run in GitLab yet (no runner).
- **Expected, not a fault:** a build pod is `Unschedulable` (`Insufficient memory`, the normal pool's nodes not
  matching) while the spot pool scales up from 0; the node comes up in minutes and `poll_timeout = 900` waits for it
  (#20).
- **Blocked on:** a green `apply` on main (#18); for #25's done criteria, cloud#64 (the secret, and cloud's `gitlab`
  stack's registration of `infra` with its token), then the switch-over above. The hub's by-hand steps are done (checked by the hub, 2026-11-15):
  project runners, `main` and the environment `cluster` protected, the three protected variables,
  `tacplus-looper-bot` a Reporter, runners 58541760 (`build`) and 58541761 (`control`) tacplus-dev group runners
  (`arm64, build` and `arm64, control`, untagged off, still paused), and both token secrets' version 1 readable by
  `cluster-admin-pipeline`. main's last pipeline before #14 and #24 (3057232314, 2026-11-12) was red in `security`,
  so `plan` and `apply` never ran; main's security run at 0f72a6b is clean. After a green `apply`: unpause `build`,
  keep `control` paused until tacplus-dev/looper#84, turn on the nightly schedule 4547285.
