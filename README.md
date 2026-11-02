# cluster

The only holder of cluster-admin on the shared GKE cluster `tacplus` (us-central1-a, arm64). It owns everything
cluster-scoped. Fleets deploy their own workloads into their own namespace, with their own namespace-only account,
and never get cluster privilege (`tacplus-dev/roadmap:decisions/deploymentproxy-2026-11-02.md`).

Design and decision: `tacplus-dev/roadmap:decisions/cluster-pipeline-2026-11-02.md` (tacplus-dev/roadmap#1, approved
by Jody 2026-11-02).

## What it manages

- **deploymentproxy:** its namespace, CRDs, ClusterRole and Deployment, pinned to a release line.
- **`deployments.yaml`:** one entry per deployment. For each, it applies:
  - the namespace `tac-<deployment>`, labelled `tacplus.dev/deployment=<deployment>`;
  - deploymentproxy's per-deployment Role;
  - the fleet deploy account's namespace-scoped Role and RoleBinding;
  - the fleet `operator` service account's binding.
- **Cluster-scoped objects a fleet's chart needs** (CRDs, ClusterRoles), and only from here.

## How it runs

The code lives here. CI runs on GitLab, in project `tacplus-dev/cluster`, as for every tacplus-dev repository.

- **Identity:** the Google service account `cluster-admin-pipeline`, through Workload Identity Federation (pool
  `gitlab-tacplus-dev`, `attribute.project_path` = `tacplus-dev/cluster`, protected `main` only). No keys.
- **Runner:** a project runner locked to the GitLab project, with a fresh VM per job and no GCP account on the VM.
- **`plan`** runs on every change: `kubectl diff`, plus what each deployment gains or loses.
- **`apply`** is a protected manual job that only Jody can play.
- **Nightly drift check:** `plan` on a schedule. On drift it files an issue. It never applies.

## Never

- Deploys a fleet's workloads.
- Touches letsencrypt's certificates, or restarts it.
- Holds tenant data.
- Deletes a deployment namespace when an entry is removed. That is a separate manual job, Jody's, named as such.

Work arrives as issues; see github.com/tacplus-dev/looper.
