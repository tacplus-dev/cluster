# State: cluster

Overwritten to stay current (loopers and agents). Last updated: 2026-11-02 by the looper (#2).

- **Version / line:** unreleased (main); no tacplus floor (shell and yq, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.5`.
- **Works:** the cluster pipeline (#1): `deployments.yaml` (first entry `seatrials`); deploymentproxy v0.2.0 fetched
  and pinned by commit, checksum and image digest; `render.sh`; `ci/policy.sh` (no cluster-scoped resource or `*`
  in a deployment's Roles); the GitLab jobs `render`, `validate`, `plan`, `apply` (manual, protected `cluster`, never
  deletes; not in a deletion pipeline), the deletion job (#2: only in a deletion pipeline, run on main from the web
  form or the API with `DELETE_DEPLOYMENT` and `DELETE_CONFIRM` both the deployment's name; manual, protected,
  named for what it destroys), `drift` (nightly, files an issue, never applies). Tests green (`ci/checks.sh`), here
  and in the CI image.
- **Released / deployed:** the GitLab project runs pipelines on main: #2 reports Jody playing `apply` in pipeline
  3019831835 (job 17680247127) on 2026-11-02; its outcome is not recorded here yet. The lines below predate it.
- **Known gaps:** no pipeline has run: the hub owes the runner (tag `cluster`), the project's variables and
  environment, the cluster grant, and the drift issue's app permission and KMS binding (README, What the hub does);
  then Jody's first apply. The cluster-scoped objects a fleet's chart needs have no place in the render yet.
- **Blocked on:** the hub's steps above (no issue).
