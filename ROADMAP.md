# Roadmap: cluster

Owned by Jody; changed only by an agent at Jody's request. Loopers propose in PROPOSALS.md.

## Now
Nothing built yet. The design is approved (tacplus-dev/roadmap#1, 2026-11-02).

## Next
- The cluster pipeline: manifests for deploymentproxy and `deployments.yaml`, GitLab CI with `plan` on every change, `apply` as Jody's protected manual job, and a nightly drift check; first entry `seatrials` (#1). Agent, at Jody's request, 2026-11-02 (`tacplus-dev/roadmap:decisions/cluster-pipeline-2026-11-02.md`).
- Apply automatically on main after a successful plan; outside production nothing waits for a person (#3). Agent, at Jody's request, 2026-11-02 (`tacplus-dev/roadmap:decisions/deterministic-deployments-2026-11-02.md`).
- Security job in the pipeline: OSV-Scanner, govulncheck on pinned binaries, gitleaks, Trivy on the CI image, an enforced security-exceptions.yaml (#5). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:suggestions/2026-11-04-the-deterministic-security-checks-in-the-pipelines-that-apply-infrastructure.md`).

## Later
- A reconciler (GKE Config Sync or Argo CD) instead of a manual apply, if standing privilege becomes acceptable (roadmap#1, alternative ii).

## Not doing
- Fleet workloads: fleets deploy themselves into their own namespace.
- Cluster-admin for any fleet pipeline, or for the hub.
