# State: cluster

Overwritten to stay current (loopers and agents). Last updated: 2026-11-07 by the looper (#10, #11, #12).

- **Version / line:** unreleased (main); no tacplus floor (shell and yq, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.6` (#12; tacplus' latest line).
- **Target (#7):** tacplus-dev/cloud's cluster `dev` (us-central1-a) in the project `tacplus-dev` (seabeam.net), as
  `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com`; seatrials' deploy account and the runners' token
  secrets (`gitlab-runner-build`, `gitlab-runner-control`, version 1) in `tacplus-dev` too. The old `tacplus` in
  `jody1-328023` is no longer the target; Jody deletes it once the pipeline applies to `dev`.
- **Works:** the cluster pipeline (#1): `deployments.yaml` (first entry `seatrials`); deploymentproxy v0.2.1 fetched
  and pinned by commit, checksum and image digest, bumped by one command (`deploymentproxy/bump.sh <tag>`, #4: the
  pin, the release and the render fixture); `render.sh`; `ci/policy.sh` (no cluster-scoped resource or `*`
  in a deployment's Roles); `ci/tools.sh` pinning every tool by version and SHA-256 (#5: kubectl v1.34.13 and
  gke-gcloud-auth-plugin 0.5.21 pinned, no longer the CI image's gcloud components); the GitLab jobs `render`, `validate`,
  `security` (#5: OSV-Scanner, govulncheck on `bin/`, gitleaks on the tree and history, Trivy on the CI image and,
  #9, on each image the pins deploy by digest for linux/arm64 (GitLab Runner's runner, helper and job, deploymentproxy's);
  `security-exceptions.yaml` enforced; every pipeline, nightly too; `plan` waits for it), `plan`, `apply` (#3: automatic on main once `plan`
  succeeds, applying the render `plan` saved; protected `cluster`, never deletes; not in a deletion pipeline), the
  deletion job (#2: only in a deletion pipeline, run on main from the web form or the API with `DELETE_DEPLOYMENT` and `DELETE_CONFIRM` both the deployment's name; manual, protected,
  named for what it destroys), `drift` (nightly, files an issue, never applies). CI in the cluster (#6):
  `out/20-ci.yaml`, the namespace `ci` with GitLab Runner's chart 0.94.3 (runner 19.5.3, #11; chart by archive digest,
  images by digest, `gitlab-runner/`, rendered by `helm template`, helm v4.3.1 pinned in `ci/tools.sh`) as two
  runners, `build` (tags `arm64, build`, jobs on the spot pool only) and `control` (`arm64, autoscale,
  autoscale-16`, the normal pool), per-runner requests, limits and ceilings; Roles in `ci` only; jobs as `ci-job`
  with no token, kept off the metadata server (NetworkPolicy); the admission policy `ci-pods` refusing privileged,
  host path, host namespaces, host ports and added capabilities in `ci` (checked against a real kube-apiserver
  1.35, envtest, by hand); the tokens from Secret Manager by version at apply (`ci/runner-tokens.sh`); all of it in
  `ci/policy.sh`. Tests green (`ci/checks.sh`), here and in the CI image.
- **Released / deployed:** the GitLab project runs pipelines on main: #2 reports Jody playing `apply` in pipeline
  3019831835 (job 17680247127) on 2026-11-02; its outcome is not recorded here yet. The lines below predate it.
- **Known gaps:** the in-cluster runners are not registered or applied yet: the hub registers them as tacplus-dev
  group runners and stores their tokens as the Secret Manager versions the runner files name (README, What the hub
  does, 7; in `tacplus-dev`, #7), the spot pool labelled and tainted by tacplus-dev/cloud's `dev` stack; until the tokens are readable, `apply` fails after the rest,
  saying so. Rootless BuildKit is not in the build image yet (tacplus-dev/tacplus#315), and the looper's jobs move
  over in tacplus-dev/looper's switch issue. The `ci` NetworkPolicy holds only where NetworkPolicy is enforced
  (Dataplane V2: tacplus-dev/cloud's `dev` cluster has it).
  No pipeline has run: the hub owes the runner (tag `cluster`), the project's variables and
  environment (now deployable by the account whose merges start main's pipelines too, for the automatic `apply`),
  the cluster grant, and the drift issue's app permission and KMS binding (README, What the hub does); the hub
  re-pins the GitLab copy for #3, #4, #7 and #12, after setting `GCP_WIF_PROVIDER` to `dev`'s provider (README, What the
  hub does, the move from `tacplus` to `dev`). The cluster-scoped objects a fleet's chart needs have no
  place in the render yet.
- **Known vulnerabilities:** 10 accepted in `security-exceptions.yaml` until 2026-12-04 (#5), none with a fixed
  release of its tool: kubectl v1.34.13 (x/net, x/text, otel), gke-gcloud-auth-plugin 0.5.21 and trivy 0.76.1
  (x/net/html; trivy's x/crypto/openpgp). GO-2026-6865 (klauspost/compress, fixed in v1.20.2) accepted in trivy
  0.76.1 until 2026-12-06 (#10), no trivy release with it. gitleaks and OSV-Scanner are built with the fixed modules
  instead (`ci/tools.sh`, #10): GO-2026-6865 and GO-2026-6888 (brotli v1.2.7), and gitleaks' xz (v0.5.15), none
  accepted. 13 accepted until 2026-12-05 (#9, #11), in GitLab
  Runner 19.5.3's runner and helper images, its latest release (libexpat, four with CVE-2026-115506, #11; go-jose/v4,
  x/net; the helper's miniperl, two CRITICAL, which the helper never runs); the bump to 19.5.3 (#11) cleared curl's
  and docker-machine's, and their 8 entries are gone. Not accepted, so failing the job (2026-11-07): Trivy's
  CVE-2026-123158 (the runner's openssh 10.3_p1-r1) and CVE-2026-78661 (x/net/html: the runner, the helper, the CI
  image's gh), published since (#15). deploymentproxy
  0.2.1's image: none (2026-11-05). The CI image `build:2.6` (2.6.1, also `gitlab-runner/pin.yaml`'s `job:`, #12): only gh's CVE-2026-78661 above (#15);
  #8's 7 Debian CVEs in `build:2.5` went with the move. The job has not run in GitLab yet (no runner).
- **Blocked on:** the hub's steps above (no issue).
