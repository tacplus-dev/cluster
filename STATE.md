# State: cluster

Overwritten to stay current (loopers and agents). Last updated: 2026-11-04 by the looper (#5).

- **Version / line:** unreleased (main); no tacplus floor (shell and yq, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.5`.
- **Works:** the cluster pipeline (#1): `deployments.yaml` (first entry `seatrials`); deploymentproxy v0.2.1 fetched
  and pinned by commit, checksum and image digest, bumped by one command (`deploymentproxy/bump.sh <tag>`, #4: the
  pin, the release and the render fixture); `render.sh`; `ci/policy.sh` (no cluster-scoped resource or `*`
  in a deployment's Roles); `ci/tools.sh` pinning every tool by version and SHA-256 (#5: kubectl v1.34.13 and
  gke-gcloud-auth-plugin 0.5.21 pinned, no longer the CI image's gcloud components); the GitLab jobs `render`, `validate`,
  `security` (#5: OSV-Scanner, govulncheck on `bin/`, gitleaks on the tree and history, Trivy on the CI image;
  `security-exceptions.yaml` enforced; every pipeline, nightly too; `plan` waits for it), `plan`, `apply` (#3: automatic on main once `plan`
  succeeds, applying the render `plan` saved; protected `cluster`, never deletes; not in a deletion pipeline), the
  deletion job (#2: only in a deletion pipeline, run on main from the web form or the API with `DELETE_DEPLOYMENT` and `DELETE_CONFIRM` both the deployment's name; manual, protected,
  named for what it destroys), `drift` (nightly, files an issue, never applies). Tests green (`ci/checks.sh`), here
  and in the CI image.
- **Released / deployed:** the GitLab project runs pipelines on main: #2 reports Jody playing `apply` in pipeline
  3019831835 (job 17680247127) on 2026-11-02; its outcome is not recorded here yet. The lines below predate it.
- **Known gaps:** no pipeline has run: the hub owes the runner (tag `cluster`), the project's variables and
  environment (now deployable by the account whose merges start main's pipelines too, for the automatic `apply`),
  the cluster grant, and the drift issue's app permission and KMS binding (README, What the hub does); the hub
  re-pins the GitLab copy for #3, and for #4 (v0.2.1, whose arm64 toleration the deploymentproxy pod on `tacplus`
  waits for: it is Pending on the arm64 taint until then). The cluster-scoped objects a fleet's chart needs have no
  place in the render yet.
- **Known vulnerabilities:** 11 accepted in `security-exceptions.yaml` until 2026-12-04 (#5), none with a fixed
  release of its tool: kubectl v1.34.13 (x/net, x/text, otel), gke-gcloud-auth-plugin 0.5.21 and trivy 0.76.1
  (x/net/html; trivy's x/crypto/openpgp), gitleaks v8.30.1 (xz). The CI image's Trivy scan: no HIGH or CRITICAL
  with a fix (2026-11-04). The job has not run in GitLab yet (no runner).
- **Blocked on:** the hub's steps above (no issue).
