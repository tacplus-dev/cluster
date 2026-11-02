# State: cluster

Overwritten to stay current (loopers and agents). Last updated: 2026-11-02 by the looper (#1).

- **Version / line:** unreleased (main); no tacplus floor (shell and yq, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.5`.
- **Works:** the cluster pipeline (#1): `deployments.yaml` (first entry `seatrials`); deploymentproxy v0.2.0 fetched
  and pinned by commit, checksum and image digest; `render.sh`; `ci/policy.sh` (no cluster-scoped resource or `*`
  in a deployment's Roles); the GitLab jobs `render`, `validate`, `plan`, `apply` (manual, protected `cluster`, never
  deletes), `delete-deployment` (manual, protected, named), `drift` (nightly, files an issue, never applies). Tests
  green (`ci/checks.sh`), here and in the CI image.
- **Released / deployed:** nothing applied yet. The GitLab project has no `.gitlab-ci.yml` from here yet.
- **Known gaps:** no pipeline has run: the hub owes the runner (tag `cluster`), the project's variables and
  environment, the cluster grant, and the drift issue's app permission and KMS binding (README, What the hub does);
  then Jody's first apply. The cluster-scoped objects a fleet's chart needs have no place in the render yet.
- **Blocked on:** the hub's steps above (no issue).
