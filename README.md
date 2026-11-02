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
- **Cluster-scoped objects a fleet's chart needs** (CRDs, ClusterRoles), and only from here. None yet: the render
  has no place for them until a fleet needs one (PROPOSALS.md).

The fleet deploy account's Role (`fleet-deploy`) is what a fleet's helm release needs inside `tac-<deployment>`:
its ConfigMaps, Secrets (helm's release state), Services, ServiceAccounts, PVCs, Deployments, StatefulSets, Jobs,
CronJobs, NetworkPolicies, PodDisruptionBudgets, Roles, RoleBindings and Leases; pods read and deleted, events, logs
and quotas read. Nothing cluster-scoped, no `*`, no quota or limit changes, no exec, attach or port-forward
(`ci/policy.sh` refuses any render that breaks that). GKE names the Google account by its email, so the binding's
subject is the User `<account>@<project>.iam.gserviceaccount.com`.

## Layout

| Path | What |
|---|---|
| `deployments.yaml` | The deployments, one entry each. |
| `deploymentproxy/pin.yaml` | deploymentproxy's release: line `0.2`, tag, commit, image by digest, the manifests it applies. |
| `deploymentproxy/release/` | Those manifests as fetched (`deploymentproxy/fetch.sh`), with their `SHA256SUMS`. Never edited. |
| `render.sh` | The render: `out/00-deploymentproxy.yaml` and `out/10-deployment-<name>.yaml` for each entry. |
| `ci/gitlab-project.gitlab-ci.yml` | The GitLab project's `.gitlab-ci.yml`, with `CLUSTER_COMMIT` set (`ci/pin.sh`). |
| `ci/*.sh` | The jobs' scripts: `policy`, `validate`, `plan`, `apply`, `delete-deployment`, `drift`; `lib.sh` (credentials). |
| `tests/` | The tests (`ci/checks.sh` runs them all), their fixtures and stubs. |

## How it runs

The code lives here. CI runs on GitLab, in the project `tacplus-dev/cluster` (88422580), the fleet-seatrials
pattern: the project carries only its `.gitlab-ci.yml`, which is `ci/gitlab-project.gitlab-ci.yml` from here with
`CLUSTER_COMMIT` set to the commit of this repository it renders and applies. Every job fetches this repository at
that commit (it is public: no credential).

- **Identity:** the Google service account `cluster-admin-pipeline`, through Workload Identity Federation (pool
  `gitlab-tacplus-dev`, `attribute.project_path` = `tacplus-dev/cluster`, protected `main` only). No keys.
- **Runner:** a project runner locked to the GitLab project, tag `cluster`, with a fresh VM per job and no GCP
  account on the VM. Every job is tagged for it.

| Job | When | What |
|---|---|---|
| `render` | every push and merge request | Builds yq and kubeconform (`ci/tools.sh`), checks the project's `.gitlab-ci.yml` is this repository's with only `CLUSTER_COMMIT` set (`ci/pin.sh --check`), renders into `out/`. |
| `validate` | every push and merge request | kubeconform and `ci/policy.sh` on `out/`, `deploymentproxy/release` against its release (`fetch.sh --check`), the tests. |
| `plan` | main (push, web, API) | `kubectl diff` against `tacplus`, then per unit (deploymentproxy, each deployment) what is added, changed or removed; a deployment whose entry is gone is listed as kept. |
| `apply` | main, **manual**, protected environment `cluster` (Jody only) | Plans again, then applies server-side. Never deletes or prunes. |
| `delete-deployment` | main, **manual**, protected environment `cluster` (Jody only) | Deletes the deployment `DELETE_DEPLOYMENT`: `tac-<name>` and its tenant namespaces. |
| `drift` | the nightly schedule | `plan`; if anything differs, an issue here (one open at a time; a new drift is a comment). Never applies. |

The cluster jobs run only on main, because Workload Identity Federation admits only this project's protected main:
a merge request gets `render` and `validate`, and its `plan` runs once it is merged, before anyone plays `apply`.
Until the hub's steps below are done, `plan` stops with `kube: no cluster grant yet` (or GCP's refusal, saying so).

### How a change reaches the cluster

1. A pull request here (to `deployments.yaml`, the pin, the render); the tests run as its gates.
2. Once it is merged, a merge request in the GitLab project setting `.gitlab-ci.yml` to `ci/pin.sh <commit>`'s
   output, for that commit of main: `render` and `validate` run on it.
3. Merged there, the pipeline on main runs `plan`. Jody reads it and plays `apply`.

### Adding a deployment

A pull request adding its entry to `deployments.yaml` (the file says what each field is):

```yaml
  - name: <deployment>            # at most 16 characters of [a-z0-9-], starting with a letter
    deployAccount: <name>-deploy@jody1-328023.iam.gserviceaccount.com
    operator: operator
    gitlabProject: tacplus-dev/fleet-<fleet>
    quota: {}                     # deploymentproxy's default; or e.g. {pods: "50"}, quantities quoted
```

`tests/render_test.sh` and `ci/policy.sh` check it. Then the pin (above), the plan, and Jody's apply. The fleet's
deploy account also needs, in IAM, to get the cluster's credentials (`roles/container.clusterViewer`): that is the
fleet's setup, not this pipeline's.

### Deleting a deployment

Removing its entry deletes nothing: `plan` lists it as removed and kept. To delete it, and its tenants' data with
it, Jody runs `delete-deployment` with `DELETE_DEPLOYMENT=<name>`: as the manual job's variable when it is played, or,
if the project refuses job variables, as a protected project variable scoped to the environment `cluster`, removed
afterwards. It refuses a deployment `deployments.yaml` still lists, and a namespace not labelled as that deployment's.

### Bumping deploymentproxy

Change `tag`, `commit` and `image` in `deploymentproxy/pin.yaml` together, then run `deploymentproxy/fetch.sh`: it
refuses a tag that does not name the commit, or an image tag without that digest, and rewrites `release/` and its
`SHA256SUMS`. Run the checks and review the release's diff.

### What the hub does

Before the first pipeline:

1. **The runner:** a project runner registered to `tacplus-dev/cluster` only, tag `cluster`, VMs used once, with
   no Google account; group runners off on the project.
2. **The project:** `main` protected; the protected environment `cluster`, deployable by Jody only; pipeline
   variables forbidden, as in the group; `.gitlab-ci.yml` from `ci/pin.sh <commit of main>`.
3. **Its variables** (protected, never group variables): `GCP_WIF_PROVIDER` (the provider of the pool
   `gitlab-tacplus-dev`), and for `drift`, `TACPLUS_READER_APP_ID` and `TACPLUS_READER_INSTALLATION_ID`.
4. **The cluster grant:** `cluster-admin-pipeline` may get the cluster's credentials (IAM
   `roles/container.clusterViewer` on `jody1-328023`) and is cluster-admin on `tacplus` (a ClusterRoleBinding of
   `cluster-admin` to the User `cluster-admin-pipeline@jody1-328023.iam.gserviceaccount.com`).
5. **The drift issue:** the tacplus-reader app installed on `tacplus-dev/cluster` with Issues read and write, and
   this project's federated principal allowed to sign with its KMS key `tacplus-reader` (`roles/cloudkms.signer`),
   or `TACPLUS_READER_SA` set to a service account that may. Until then `drift` fails, saying which refused.
6. **The schedule:** nightly, on main.

Then a pipeline on main: `render`, `validate` and `plan` green, and the plan read.

### The first apply (Jody)

1. Read the `plan` of the pipeline on main: deploymentproxy (namespace, CRD, RBAC, ConfigMap, Deployment) and
   `seatrials` (`tac-seatrials`, its two Roles and RoleBindings), all added; nothing else.
2. Play `apply`. It plans again on the cluster as it is, applies, and waits for deploymentproxy to roll out.
3. Run the pipeline again (web): `plan` says `no difference`.

### Locally

```sh
ci/tools.sh && export PATH=$PWD/bin:$PATH   # yq and kubeconform into bin/ (needs go)
./render.sh && ci/validate.sh out           # the render, kubeconform, the policy, deploymentproxy's release
ci/checks.sh                                # the tests
```

## Never

- Deploys a fleet's workloads.
- Touches letsencrypt's certificates, or restarts it.
- Holds tenant data.
- Deletes a deployment namespace when an entry is removed. That is a separate manual job, Jody's, named as such.

Work arrives as issues; see github.com/tacplus-dev/looper.
