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
- **A security report of the pipeline's own** (2026-11-04, nightly scan): no job checks the Go tools `ci/tools.sh`
  builds (yq v4.54.1, kubeconform v0.7.0) for known vulnerabilities, and the README has no "Security checks"
  section, so the nightly scan has no build report to read and runs the auditor itself. Tonight's
  `govulncheck -mode=binary bin/yq` and `bin/kubeconform` found none reachable (yq: 2 in imported packages and 5 in
  required modules, uncalled; kubeconform: 2 in required modules, uncalled). A step in `validate` running
  govulncheck on `bin/`, and a README section saying where its report is, would make that a gate. Links:
  tacplus-dev/looper#49 (the scans), tacplus-dev/roadmap:items/tacplus-security-sweep.md (tacplus's equivalent).

## Promoted / declined
