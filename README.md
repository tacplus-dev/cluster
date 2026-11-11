# cluster

The only holder of cluster-admin on the shared GKE cluster `dev` (us-central1-a, arm64; the project `tacplus-dev` in
seabeam.net, built by tacplus-dev/cloud; #7). It owns everything cluster-scoped. Fleets deploy their own workloads
into their own namespace, with their own namespace-only account, and never get cluster privilege
(`tacplus-dev/roadmap:decisions/deploymentproxy-2026-11-02.md`).

Design and decision: `tacplus-dev/roadmap:decisions/cluster-pipeline-2026-11-02.md` (tacplus-dev/roadmap#1, approved
by Jody 2026-11-02).

## What it manages

- **deploymentproxy:** its namespace, CRDs, ClusterRole and Deployment, pinned to a release line.
- **`deployments.yaml`:** one entry per deployment. For each, it applies:
  - the namespace `tac-<deployment>`, labelled `tacplus.dev/deployment=<deployment>`;
  - deploymentproxy's per-deployment Role, if the deployment has an operator;
  - the fleet deploy account's namespace-scoped Role and RoleBinding;
  - the fleet `operator` service account's binding, if it has one (`operator` is optional: test-idp has none).
- **CI in the cluster** (the namespace `ci`): GitLab Runner with the Kubernetes executor, one runner for builds
  (spot pool) and one for control work (normal pool), registered to the tacplus-dev group ([CI in the
  cluster](#ci-in-the-cluster)).
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
| `deploymentproxy/bump.sh` | A bump to a release of the line, from its tag: the pin, the release, the render fixture. |
| `gitlab-runner/pin.yaml` | GitLab Runner's chart (version, archive digest) and its images, the runner's, the helper's and the jobs' default, by digest. |
| `gitlab-runner/release/` | The chart as fetched (`gitlab-runner/fetch.sh`), with its `SHA256SUMS`. Never edited. |
| `gitlab-runner/values.yaml` | The chart's values every runner shares: the runner manager's pod, its Role in `ci`, its placement. |
| `gitlab-runner/runners/<runner>.yaml` | One runner each (`build`, `control`): its tags, its token's Secret Manager version, its jobs' `config.toml`. |
| `render.sh` | The render: `out/00-deploymentproxy.yaml`, `out/10-deployment-<name>.yaml` for each entry, `out/20-ci.yaml`. |
| `ci/gitlab-project.gitlab-ci.yml` | The GitLab project's `.gitlab-ci.yml`, with `CLUSTER_COMMIT` set (`ci/pin.sh`). |
| `ci/*.sh` | The jobs' scripts: `policy`, `validate`, `security`, `plan`, `apply` (with `runner-tokens`), `delete-deployment`, `drift`; `lib.sh` (credentials); `tools.sh` (the pinned tools). |
| `build.lock`, `gates.yaml` | The build image by digest (the CI image), and the gates run in it (How a change reaches the cluster, below). |
| `security-exceptions.yaml` | The security findings accepted, each until its expiry (Security checks, below). |
| `tests/` | The tests (`ci/checks.sh` runs them all), their fixtures and stubs. |

## How it runs

The code lives here. CI runs on GitLab, in the project `tacplus-dev/cluster` (88422580), the fleet-seatrials
pattern: the project carries only its `.gitlab-ci.yml`, which is `ci/gitlab-project.gitlab-ci.yml` from here with
`CLUSTER_COMMIT` set to the commit of this repository it renders and applies. Every job fetches this repository at
that commit (it is public: no credential).

- **Identity:** the Google service account `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com`, through
  Workload Identity Federation (pool `gitlab-com`, provider `tacplus-dev-cluster`, in the project `tacplus-dev`:
  `attribute.project_path` = `tacplus-dev/cluster`, protected `main` only). No keys.
- **Runner:** a project runner locked to the GitLab project, tag `cluster`, with a fresh VM per job and no GCP
  account on the VM. Every job is tagged for it.

| Job | When | What |
|---|---|---|
| `render` | every push and merge request | Builds or fetches the pinned tools (`ci/tools.sh`: yq, kubeconform, helm, kubectl, gke-gcloud-auth-plugin, gitleaks), checks the project's `.gitlab-ci.yml` is this repository's with only `CLUSTER_COMMIT` set (`ci/pin.sh --check`), renders into `out/`. |
| `validate` | every push and merge request | kubeconform and `ci/policy.sh` on `out/`, `deploymentproxy/release` against its release and `gitlab-runner/release` against its chart and images (each `fetch.sh --check`), the tests. |
| `security` | every pipeline: every push and merge request, and the nightly schedule | The security checks (below). Fails the pipeline on a secret or an unaccepted HIGH or CRITICAL finding with a fix; `plan`, so `apply`, waits for it. Its report is the artifact `src/security/`. |
| `plan` | main (push, web, API) | `kubectl diff` against `dev`, then per unit (deploymentproxy, each deployment, `ci`) what is added, changed or removed; a deployment whose entry is gone is listed as kept. Saves the render it diffed and its summary (`plan.txt`). |
| `apply` | main, **automatically** once `plan` succeeds, protected environment `cluster`; not in a deletion pipeline | Applies the render `plan` saved: plans again, then applies server-side, then writes the runners' tokens from Secret Manager (`ci/runner-tokens.sh`), then waits for deploymentproxy and the runners. Never deletes or prunes. A failed apply fails the pipeline. |
| `DELETE deployment: removes tac-<DELETE_DEPLOYMENT> and every tenant namespace (data loss)` | a deletion pipeline only (below), **manual**, protected environment `cluster` (Jody only) | Deletes the deployment `DELETE_DEPLOYMENT`: `tac-<name>` and its tenant namespaces (`ci/delete-deployment.sh`). |
| `drift` | the nightly schedule | `plan`; if anything differs, an issue here (one open at a time; a new drift is a comment). Never applies. |

The cluster jobs run only on main, because Workload Identity Federation admits only this project's protected main:
a merge request gets `render`, `validate` and `security`, and its `plan`, then `apply`, run once it is merged.
Until the hub's steps below are done, `plan` stops with `kube: no cluster grant yet` (or GCP's refusal, saying so).

### How a change reaches the cluster

1. A pull request here (to `deployments.yaml`, the pin, the render); the tests run as its gates (the looper's land, or
   `gates.yaml`'s `full`: `ci/tools.sh`, the render, `ci/validate.sh out` and `ci/checks.sh`). They run in the image
   `build.lock` pins by digest, the CI image, with no Docker: tacplus-dev/build builds a commit only from that pin
   (looper#71). To move it, change `build.lock` and `gitlab-runner/pin.yaml`'s `job:` together, of the CI file's
   line (`tests/ci_test.sh` refuses them apart): a new digest is a change like any other, landed on the full gates.
2. Once it is merged, a merge request in the GitLab project setting `.gitlab-ci.yml` to `ci/pin.sh <commit>`'s
   output, for that commit of main: `render` and `validate` run on it.
3. Merged there, the pipeline on main runs `plan`, then `apply` of what it planned. Nobody plays it.

Outside production nothing waits for a person (Jody, `tacplus-dev/roadmap:decisions/deterministic-deployments-2026-11-02.md`,
addendum): this cluster is not production, so `apply` has no manual gate; the review is the pull request's, and the
plan is in the pipeline's log for anyone to read. The production cluster (`PRODUCTION.md`) will have its own
pipeline, where `apply` is a protected manual job that only Jody plays. Deleting a deployment is not an approval but
intent: it stays a deletion pipeline, started on purpose (below), never automatic.

### Adding a deployment

A pull request adding its entry to `deployments.yaml` (the file says what each field is):

```yaml
  - name: <deployment>            # at most 16 characters of [a-z0-9-], starting with a letter
    deployAccount: <name>-deploy@tacplus-dev.iam.gserviceaccount.com
    operator: operator            # optional: none, no deploymentproxy Role and no operator binding
    gitlabProject: tacplus-dev/fleet-<fleet>
    quota: {}                     # deploymentproxy's default; or e.g. {pods: "50"}, quantities quoted
```

`tests/render_test.sh` and `ci/policy.sh` check it. Then the pin (above), the plan and the apply. The fleet's
deploy account also needs, in IAM, to get the cluster's credentials (`roles/container.clusterViewer`): that is the
fleet's setup, not this pipeline's.

### Deleting a deployment

Removing its entry deletes nothing: `plan` lists it as removed and kept. Deleting it, and its tenants' data with it,
takes a pipeline of its own, a **deletion pipeline**: no push, merge request, schedule or plain run has the deletion
job, and a deletion pipeline has no `apply`.

1. The entry removed from `deployments.yaml`, the pin, and the `apply` of it (the job refuses a deployment
   `deployments.yaml` still lists: the next apply would recreate it).
2. Jody runs a pipeline on `main` with two variables, both the deployment's name: `DELETE_DEPLOYMENT=<name>` and
   `DELETE_CONFIRM=<name>`, the second typed again to confirm. From the web form (Build > Pipelines > Run pipeline,
   branch `main`, the two variables), or the API:

   ```sh
   glab api -X POST projects/88422580/pipeline -f ref=main \
     -f 'variables[][key]=DELETE_DEPLOYMENT' -f 'variables[][value]=<name>' \
     -f 'variables[][key]=DELETE_CONFIRM' -f 'variables[][value]=<name>'
   ```

3. That pipeline runs `render`, `validate` and `plan`, and has the manual job `DELETE deployment: removes
   tac-<DELETE_DEPLOYMENT> and every tenant namespace (data loss)`, in the protected environment `cluster`. With
   `DELETE_CONFIRM` missing or different, it has no such job. Jody plays it: it deletes `tac-<name>`, then whatever
   tenant namespace of it deploymentproxy left.

`ci/delete-deployment.sh` checks again that `DELETE_CONFIRM` is `DELETE_DEPLOYMENT`, and refuses a namespace not
labelled as that deployment's. Never set either variable as a project or group variable.

### Bumping deploymentproxy

Run `deploymentproxy/bump.sh <tag>` (a release of the pinned line, e.g. `v0.2.2`), and nothing else. From the tag
alone it resolves the commit and the image's digest, refuses an image not built from that commit (its
`org.opencontainers.image.revision` and `version` labels), rewrites `tag`, `commit` and `image` in `pin.yaml`, runs
`deploymentproxy/fetch.sh` (which checks both again and rewrites `release/` and its `SHA256SUMS`) and regenerates
the render fixture (`tests/fixtures/render/out`), which has the release's manifests in it. On any refusal it leaves
the tree as it was. Its diff (`pin.yaml`, `release/`, the fixture) is the pull request; review it there, where the
checks run as its gates (`tests/bump_test.sh` tests the script against a fixture release).

### What the hub does

Before the first pipeline:

1. **The runner:** a project runner registered to `tacplus-dev/cluster` only, tag `cluster`, VMs used once, with
   no Google account; group runners off on the project.
2. **The project:** `main` protected; the protected environment `cluster`, deployable by Jody and by the account
   whose merges start the pipelines on main (the hub's): GitLab runs an automatic job in a protected environment only
   for a pipeline started by one of its deployers, so `apply` fails for anyone else's; pipeline variables allowed to the Owner role only (Settings > CI/CD > Variables, "Minimum role to use pipeline
   variables"), for a deletion pipeline's two; `.gitlab-ci.yml` from `ci/pin.sh <commit of main>`;
   `tacplus-looper-bot` a member with the Reporter role, so the looper's recap reads this project's pipelines and
   jobs (it gets a 404 without it; #18).
3. **Its variables** (protected, never group variables): `GCP_WIF_PROVIDER`
   (`projects/1038314073791/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-cluster`), and
   for `drift`, `TACPLUS_READER_APP_ID` and `TACPLUS_READER_INSTALLATION_ID`.
4. **The cluster grant:** `cluster-admin-pipeline` may get the cluster's credentials (IAM
   `roles/container.clusterViewer` on `tacplus-dev`, tacplus-dev/cloud's) and is cluster-admin on `dev` (a
   ClusterRoleBinding of `cluster-admin` to the User `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com`).
5. **The drift issue:** the tacplus-reader app installed on `tacplus-dev/cluster` with Issues read and write, and
   this project's federated principal allowed to sign with its KMS key `tacplus-reader` (`roles/cloudkms.signer`),
   or `TACPLUS_READER_SA` set to a service account that may. Until then `drift` fails, saying which refused.
6. **The schedule:** nightly, on main.
7. **The in-cluster runners** ([CI in the cluster](#ci-in-the-cluster)): each runner of `gitlab-runner/runners/`
   created in GitLab as a **group runner of tacplus-dev** with its `tacplus.tags` and "run untagged jobs" off, its
   authentication token (`glrt-...`) stored as the version of the Secret Manager secret its `tacplus.token` names
   (`gitlab-runner-build` and `gitlab-runner-control` in `tacplus-dev`, version 1), and `cluster-admin-pipeline`
   allowed to read those two secrets (`roles/secretmanager.secretAccessor` on each). The runners are GitLab's
   58541760 (`build`) and 58541761 (`control`), registered paused (#18); tacplus-dev/build's scheduled jobs need
   `build` unpaused once `apply` has written its token. A new token is a new version
   and a pull request moving `tacplus.token` to it. Until both are readable, `apply` fails after applying the rest,
   saying `runner-tokens: Secret Manager refused <version>`.
8. **The pools:** the spot pool labelled `spot=true` and tainted `spot=true:NoSchedule` (tacplus-dev/cloud#7's
   answer; tacplus-dev/cloud's `dev` stack makes them so), the normal pool neither; Workload Identity on the cluster and its pools (`GKE_METADATA`), and NetworkPolicy enforced (Dataplane V2, as
   tacplus-dev/cloud's `dev` cluster has), for the `ci` namespace's NetworkPolicy to hold.

Then a pipeline on main: `render`, `validate`, `security`, `plan` and `apply` green.

**The move from `tacplus` to `dev`** (#7; `tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`,
addendum "a new cluster in seabeam.net"), in order: the hub sets `GCP_WIF_PROVIDER` to the provider above; the
change retargeting this repository (`GCP_PROJECT`, `CLUSTER`, `GCP_DEPLOY_SA`, seatrials' `deployAccount`, the
runners' tokens) lands; the hub re-pins `.gitlab-ci.yml`; the pipeline on main applies to `dev`. The old cluster
`tacplus` in `jody1-328023` is then unused, and Jody deletes it. The drift job's KMS key stays in `jody1-328023`
until it moves (tacplus-dev/cloud#15).

### The first apply

1. The `plan` of the pipeline on main: deploymentproxy (namespace, CRD, RBAC, ConfigMap, Deployment) and
   `seatrials` (`tac-seatrials`, its two Roles and RoleBindings), all added; nothing else.
2. `apply`, after it: it plans again on the cluster as it is, applies, and waits for deploymentproxy to roll out.
3. Run the pipeline again (web): `plan` says `no difference`, and `apply` changes nothing.

### Locally

```sh
ci/tools.sh && export PATH=$PWD/bin:$PATH   # the pinned tools into bin/ (needs go, curl)
./render.sh && ci/validate.sh out           # the render, kubeconform, the policy, deploymentproxy's release
ci/checks.sh                                # the tests
ci/tools.sh security && ci/security.sh . ghcr.io/tacplus-dev/tacplus/build:2.6 bin/*   # the security checks
```

## CI in the cluster

The tacplus-dev group's CI jobs run in the cluster, each as a pod of GitLab Runner's Kubernetes executor, in the
namespace `ci` (Jody, `tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md` and its addendum; #6).
This pipeline applies it like the rest, from `out/20-ci.yaml`: GitLab's own chart (`gitlab-runner/release`, chart
0.94.3, GitLab Runner 19.5.3), rendered by `helm template` with `gitlab-runner/values.yaml` and one file per runner.
The chart is pinned by the SHA-256 of its archive, and the runner, helper and default job images by digest
(`gitlab-runner/pin.yaml`); nothing resolves a moving tag or "latest".

| Runner | Tags | Its jobs' pods | Default requests / limits | Ceiling a job may raise them to |
|---|---|---|---|---|
| `build` | `arm64`, `build` | the spot pool only: node selector `spot=true`, toleration `spot=true:NoSchedule` | CPU 1 / 3, memory 4Gi / 8Gi | CPU 3500m, memory 12Gi (a c4a-standard-4) |
| `control` | `arm64`, `control` (the looper's kicker, reports, managers, scans) | the normal pool: no spot toleration, a required node affinity refusing `spot=true` and `cloud.google.com/gke-spot=true` | CPU 250m / 1, memory 512Mi / 2Gi | CPU 1500m, memory 4Gi |

A job raises its own with GitLab's variables (`KUBERNETES_CPU_REQUEST`, `KUBERNETES_MEMORY_LIMIT` and the rest) up
to the ceiling; the helper container has its own small defaults. It may override nothing else: not its node
selector, tolerations, namespace, service account or pod annotations (the policy refuses any
`*_overwrite_allowed`). The runner managers (one Deployment per runner, in `ci`) run on the normal pool too. A spot
node from 0 takes minutes, so a build job waits up to 15 minutes for its pod (`poll_timeout`); preemption is
handled the GitLab way, with `retry:` in the pipeline files (`runner_system_failure`, `stuck_or_timeout_failure`).

- **No privileged pod, no host path, no Docker socket.** Image builds use rootless BuildKit in the build job's own
  container (tacplus-dev/tacplus#315): every container of a build pod runs as uid 1000, and the build container
  alone is `Unconfined` for seccomp and AppArmor, as rootless BuildKit needs (GitLab's docs: "Set seccomp and
  AppArmor profiles"), with no capability added. Control jobs run with seccomp `RuntimeDefault` and no privilege
  escalation. Besides the policy on the render, the cluster itself refuses any pod in `ci` that is privileged, has
  a host path, the host's network, PID or IPC, a host port or an added capability (the admission policy
  `ci-pods`), whoever creates it.
- **Namespace-scoped RBAC.** Each runner's service account holds a Role in `ci` only, with what the Kubernetes
  executor needs (pods, their exec, attach and logs, secrets, services, service accounts read, events read), every
  verb named. No ClusterRole, no ClusterRoleBinding.
- **No credentials for jobs.** Job pods run as `ci-job`, which has no role and no token in the pod. The
  NetworkPolicy `ci-no-metadata-server` keeps every pod in `ci` off the metadata server (169.254.169.254, and
  169.254.169.252 under Workload Identity), so no pod gets the node's service account or a workload identity. A job
  that needs Google Cloud federates its own GitLab id_token (WIF), as today.
- **The tokens.** Each runner's authentication token is a Secret Manager version named in its file
  (`tacplus.token`, `projects/<project>/secrets/<secret>/versions/<n>`, never "latest"), and on its pods as an
  annotation. At apply, `ci/runner-tokens.sh` reads that version as `cluster-admin-pipeline` and writes it into the
  Secret its pods mount (`gitlab-runner-<runner>` in `ci`); a new version restarts the runner. The token is never in
  this repository, in a GitLab variable or in the job's log.

`ci/policy.sh` checks all of it on the render (each runner's `config.toml` included): the pinned images, the
namespace-scoped RBAC, the absence of privileged pods, host paths and the Docker socket, and that build pods land
only on the tainted spot pool and other jobs never, and that no runner takes a VM runner's tag;
`tests/policy_test.sh` breaks each rule and `tests/render_test.sh` checks the render.

**A bump** of the chart: its version, url and digest and the three images in `gitlab-runner/pin.yaml` together, then
`gitlab-runner/fetch.sh` (which refuses an archive or an image that is not the pinned digest, and a chart whose
appVersion is not the images') and `UPDATE=1 tests/render_test.sh`; review the diff of `release/` and the fixture.

**Moving jobs over** is tacplus-dev/looper's (tacplus-dev/looper#84): a job moves here by switching its tags to
`arm64, control` or `arm64, build`, these runners' own; no in-cluster runner holds a VM runner's tag (`autoscale`,
`autoscale-16`, `gce`; `ci/policy.sh` refuses one), so a job still tagged for the VMs never lands here (#13). The
GitLab runners' tags follow `tacplus.tags` (the hub's step 7); `control` stays paused until tacplus-dev/looper#84
gives its pod what the looper's jobs need. The spot pool's size waits on tacplus-dev/cloud#7; this uses whatever
pool exists.

## Security checks

tacplus-dev/looper#49's deterministic floor, as a job of this pipeline (tacplus-dev/build's checks never reach it:
this pipeline has its own GitLab project and identity), for the pipeline that holds cluster-admin. The `security`
job (`ci/security.sh`) runs in every pipeline, so on every push and merge request, and nightly on the schedule:

| Tool | On |
|---|---|
| OSV-Scanner | the tree's dependency manifests and lock files (none today: shell and YAML) |
| `govulncheck -mode=binary` | every pinned tool binary the pipeline runs, `bin/`: yq, kubeconform, helm, kubectl, gke-gcloud-auth-plugin, gitleaks, osv-scanner, govulncheck, trivy |
| gitleaks | the tree, and every commit of its history (the job fetches it whole) |
| Trivy | the CI image the jobs run in (`CI_JOB_IMAGE`, `ghcr.io/tacplus-dev/tacplus/build:2.6`), for the runner's platform; and each image the commit deploys, by the digest its pin names, for linux/arm64 (the cluster's): `gitlab-runner/pin.yaml`'s `runner`, `helper` and `job`, `deploymentproxy/pin.yaml`'s `image` (#9) |

The tools are pinned in `ci/tools.sh`, each by its version and a SHA-256: the Go ones built at their module's
version with a pinned Go toolchain, the module checked against its go.sum hash (h1:, a SHA-256) and the checksum
database, and with the fixed release of any dependency an advisory names that the tool's own release does not have
yet (gitleaks and OSV-Scanner, #10: instead of an exception); kubectl, gke-gcloud-auth-plugin and Trivy downloaded from their releases and checked against the
SHA-256 of the file for linux/amd64 or linux/arm64. The vulnerability databases are each tool's of the day.

**The policy**, looper-scan's: the job fails on any secret, and on any HIGH or CRITICAL finding with a fixed version,
unless an unexpired entry of `security-exceptions.yaml` accepts it (by its id or an alias, a CVE or GHSA); a
govulncheck finding (a vulnerable symbol in the binary) counts HIGH, govulncheck giving no severity. A tool that
cannot run fails it, and so does an exception that has expired or says less than its four fields:

```yaml
exceptions:
  - id: GO-2026-6860            # the finding's id, or an alias
    reason: "why it is accepted, and what fixes it"
    decided_by: Jody Scott
    expires: 2026-12-04         # YYYY-MM-DD; the job fails from the day after
```

Exactly those fields, which looper-scan reads too. The summary lists the entries no finding needs any more, to
remove. **The report:** the job's artifact `src/security/`, kept 30 days, pass or fail: `findings.json` (every
finding: tool, id, aliases, severity, fix, where, and whether an exception accepts it or it fails the job),
`summary.md` (also in the job's log), `verdict`, and `raw/`, each tool's own JSON. `tests/security_test.sh` tests the
job: a planted secret, in the tree or the history only, fails it; an expired exception fails it; a clean tree passes.

## Never

- Deploys a fleet's workloads.
- Touches letsencrypt's certificates, or restarts it.
- Holds tenant data.
- Deletes a deployment namespace when an entry is removed. That is a separate manual job, Jody's, named as such, in
  a deletion pipeline only.

Work arrives as issues; see github.com/tacplus-dev/looper.
