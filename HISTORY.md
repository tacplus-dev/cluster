# History: cluster

Append-only: add entries at the end, never edit or remove one (CI enforces it). One line each:
`- <YYYY-MM-DD> <who: looper|agent|jody> <kind: issue|decision|release|deploy> <one line> (<links>)`

- 2026-11-02 looper issue Build the cluster pipeline: deploymentproxy + deployments.yaml, plan on every change, apply only by Jody, nightly drift (#1, d1d2442)
- 2026-11-02 looper issue delete-deployment appears next to apply in every pipeline; Jody clicked it by mistake (the guard held): show it only in a deletion pipeline (#2, bf4f13f)
- 2026-11-03 looper issue Apply automatically on main after a successful plan (not production): no manual gate (#3, cdfb623)
- 2026-11-03 looper issue deploymentproxy bump fails validate: the README procedure doesn't regenerate the render fixture (v0.2.1 not deployed) (#4, ae56d94)
