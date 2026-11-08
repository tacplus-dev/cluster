# History: cluster

Append-only: add entries at the end, never edit or remove one (CI enforces it). One line each:
`- <YYYY-MM-DD> <who: looper|agent|jody> <kind: issue|decision|release|deploy> <one line> (<links>)`

- 2026-11-02 looper issue Build the cluster pipeline: deploymentproxy + deployments.yaml, plan on every change, apply only by Jody, nightly drift (#1, d1d2442)
- 2026-11-02 looper issue delete-deployment appears next to apply in every pipeline; Jody clicked it by mistake (the guard held): show it only in a deletion pipeline (#2, bf4f13f)
- 2026-11-03 looper issue Apply automatically on main after a successful plan (not production): no manual gate (#3, cdfb623)
- 2026-11-03 looper issue deploymentproxy bump fails validate: the README procedure doesn't regenerate the render fixture (v0.2.1 not deployed) (#4, ae56d94)
- 2026-11-04 looper issue Security job in the pipeline: OSV-Scanner, govulncheck on pinned binaries, gitleaks, Trivy on the CI image, with an enforced security-exceptions.yaml (#5, e58a7ca)
- 2026-11-04 looper issue CI in the cluster: GitLab Runner (Kubernetes executor) via the cluster pipeline; builds on the spot pool, control jobs on the normal pool; no privileged pods (#6, 276d1f8)
- 2026-11-05 looper issue Retarget the cluster pipeline to the new cluster in seabeam.net (project tacplus-dev, cluster dev); runners' token secrets there (#7, fbcc43a)
- 2026-11-05 looper issue GitLab Runner 19.5.2's pinned images carry fixed HIGH/CRITICAL findings (helper: miniperl CRITICAL; libexpat, curl, go-jose, x/net), unscanned by the security job (#9, a9fdb76)
- 2026-11-07 looper issue security fails on main: GO-2026-6865 (klauspost/compress) in gitleaks, osv-scanner, trivy and GO-2026-6888 (brotli) in gitleaks; no tool release has the fix (#10, 167746d)
- 2026-11-07 looper issue security fails on main: CVE-2026-115506 (libexpat 2.9.0-r0) in GitLab Runner 19.5.2's runner and helper; 19.5.3 still has it (#11, f6bb117)
- 2026-11-07 looper issue Control runner on tags of its own (arm64, control), not the VM runners' autoscale tags (#13, 144a786)
- 2026-11-07 looper issue CI image and runners' default job image pinned to build:2.5; tacplus 2.6 is the latest line (and build:2.6 has none of #8's CVEs) (#12)
- 2026-11-07 looper issue security fails on main: CVE-2026-123158 (openssh) in GitLab Runner 19.5.3's runner and CVE-2026-78661 (x/net/html) in the runner, helper and CI image's gh (#15)
