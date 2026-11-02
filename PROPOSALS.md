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

## Promoted / declined
