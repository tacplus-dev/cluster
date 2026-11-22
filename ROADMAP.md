# Roadmap: cluster

Owned by Jody; changed only by an agent at Jody's request. Loopers propose in PROPOSALS.md.

## Now
Nothing built yet. The design is approved (tacplus-dev/roadmap#1, 2026-11-02).

## Next
- The cluster pipeline: manifests for deploymentproxy and `deployments.yaml`, GitLab CI with `plan` on every change, `apply` as Jody's protected manual job, and a nightly drift check; first entry `seatrials` (#1). Agent, at Jody's request, 2026-11-02 (`tacplus-dev/roadmap:decisions/cluster-pipeline-2026-11-02.md`).
- Apply automatically on main after a successful plan; outside production nothing waits for a person (#3). Agent, at Jody's request, 2026-11-02 (`tacplus-dev/roadmap:decisions/deterministic-deployments-2026-11-02.md`).
- Security job in the pipeline: OSV-Scanner, govulncheck on pinned binaries, gitleaks, Trivy on the CI image, an enforced security-exceptions.yaml (#5). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:suggestions/2026-11-04-the-deterministic-security-checks-in-the-pipelines-that-apply-infrastructure.md`).
- CI in the cluster: GitLab Runner, Kubernetes executor, builds on the spot pool, control jobs on the normal pool, no privileged pods (#6). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).
- Retarget the pipeline to the new cluster in seabeam.net (project tacplus-dev, cluster dev), the runners' token secrets there (#7). Agent, at Jody's request, 2026-11-05 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).
- The in-cluster control runner on tags of its own, `arm64, control`, and never the VM runners' (#13). Agent, at Jody's request, 2026-11-06 (`tacplus-dev/roadmap:suggestions/2026-11-06-the-in-cluster-control-runner-on-tags-of-its-own-or-registered-paused.md`).
- deployments.yaml: the test-idp deployment, operator optional (#17). Agent, at Jody's request, 2026-11-09 (fleet-seatrials#27).
- The tacplus-reader key moves to tacplus-ci: TACPLUS_READER_KMS_KEY (#19). Agent, at Jody's request, 2026-11-11 (tacplus-dev/cloud#30).
- The `infra` runner: an in-cluster runner for the cloud, cluster and deploy pipelines, protected refs only, so the runner VMs can go (#25; for tacplus-dev/cloud#11). Hub, under Jody's cluster-only goal, 2026-11-16.
- The build runner's concurrent counted from the spot pool's room, as control's is (#41; the cluster half of tacplus-dev/looper#204). Hub, on Jody's standing authority, 2026-11-22 (`tacplus-dev/roadmap:suggestions/2026-11-22-an-issue-an-accepted-suggestion-names-in-another-repository-is-approved-with-it-tacplus-892-cluster-41-and-cluster-42-wait-unapproved.md`).
- A report-build runner entry whose pods a land's build preempts, by PriorityClass (#42; the cluster half of tacplus-dev/looper#209). Hub, on Jody's standing authority, 2026-11-22 (`tacplus-dev/roadmap:suggestions/2026-11-22-an-issue-an-accepted-suggestion-names-in-another-repository-is-approved-with-it-tacplus-892-cluster-41-and-cluster-42-wait-unapproved.md`).
- A nightly runner entry on the normal pool (`arm64, build-nightly`), concurrent from the pool's room, for the nightly security fan-out (#46; the cluster half of tacplus-dev/looper#220). Hub, on Jody's standing authority, 2026-11-22 (`tacplus-dev/roadmap:suggestions/2026-11-22-the-nightly-security-floor-runs-where-a-node-is-free-its-security-jobs-on-a-nightly-runner-entry-of-the-normal-pool-and-a-nightly-that-publishes-nothing-is-red-not-last-night-s-report-read-as-tonight-s.md`).
- The control runner's job pods overflow onto the looper pool (0 to 2) and its concurrent counts that pool's max room (#47; tacplus-dev/cloud#95). Hub, at Jody's request, 2026-11-22 (`tacplus-dev/roadmap:decisions/cluster-node-pools-2026-11-03.md`, addendum 2026-11-22).

## Later
- A reconciler (GKE Config Sync or Argo CD) instead of a manual apply, if standing privilege becomes acceptable (roadmap#1, alternative ii).

## Not doing
- Fleet workloads: fleets deploy themselves into their own namespace.
- Cluster-admin for any fleet pipeline, or for the hub.
