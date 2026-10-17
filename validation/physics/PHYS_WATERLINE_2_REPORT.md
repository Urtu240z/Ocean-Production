# PHYS-WATERLINE-2 — Contact-Tracked Displaced Query

## Outcome

The new query is implemented as an opt-in CPU Lite mode, but it does **not** meet the default-wind cold-start grid gate yet. Normal gameplay was returned to `DIRECT`; the candidate mode was not left active. No vehicle feel, ocean, spectrum, buoyancy, or draft values were tuned. No commit was made.

The PHYS-WATERLINE-AUDIT-1 FFT/H0 refresh fix remains in `cpu_fft_water_provider.gd`. Runtime wind edits refreshed the provider spectrum; prior audit hashes matched the visual FFT snapshots.

## Solver candidate

- Native bounded 2D Newton solve for `q + D(q) = world_xz`, using finite-difference displacement Jacobians, up to four iterations, 0.75 m step clamp, residual-improving line search, and a 5 mm solve tolerance.
- Persistent per-query q history predicts from previous q plus contact movement. Normal probes are seeded from the current center-contact solution.
- The source now contains a 9×9 cold-start forward-map search over a ±12 m region, refining its 12 best seeds. Warm recovery stays near the temporal solution. Among recovered roots, the highest surface is selected, with a 5 cm continuity tie band.
- LocalSurface remains validation-only. It is not called by the candidate gameplay query.

## Validation

Each grid used the same field time for DIRECT, candidate, and LocalSurface oracle: 7×7 points, 1 m spacing, 3 m half extent. Waterline errors below are metres.

| Wind | Wave rate | DIRECT vs oracle mean / p95 / max | Candidate vs oracle mean / p95 / max | Candidate valid |
|---:|---:|---:|---:|---:|
| 12 m/s | 0.5 | 0.346 / 0.804 / 0.952 | 0.0097 / 0.0247 / 0.0374 | 49/49 |
| 12 m/s | 1.0 | 0.140 / 0.361 / 0.510 | 0.0072 / 0.0171 / 0.0298 | 49/49 |
| 40 m/s | 0.5 | 0.915 / 1.817 / 2.136 | 0.0739 / 0.0120 / 0.478* | 7/49 |
| 40 m/s | 1.0 | 1.210 / 1.743 / 1.891 | 0.0158 / 0.0260 / 0.164* | 28/49 |

`*` Candidate percentiles/max use only valid rows; the high invalid count makes those statistics non-passing. The same default-wind runtime also produced a five-point real-contact batch with all points valid and a maximum error of 1.6 cm, but this does not offset the cold-start failures or replace a moving-drive trace.

The oracle built its LocalSurface patch only during the explicit validation calls; observed build durations ranged 8.2–20.8 ms. Normal gameplay had been restored to DIRECT after the tests. A full moving-drive temporal trace, query-batch p95, and FPS benchmark were not completed because the latest native DLL could not be linked while the Godot editor held the DLL open. The C++ translation unit compiled; linking ended with Windows `Access denied`. The currently running editor therefore still has the earlier native build, without the latest expanded 12 m cold-start search.

The contact telemetry recorded recovery/failure and temporal-jump counts during the exploratory run; those cumulative figures were contaminated by the repeated cold-grid validations and are not representative of a normal drive. No reliable normal-drive recovery rate or branch-switch rate is claimed.

## Files changed for this task

- `gameplay/water/cpu_fft_water_provider.gd` — new mode, per-contact history, telemetry, and validation comparison helpers.
- `addons/ocean/physics/native/ocean_query/src/ocean_query_native.h` — native batch API declaration.
- `addons/ocean/physics/native/ocean_query/src/ocean_query_native.cpp` — CPU Lite Newton contact query and bounded recovery.
- `validation/physics/PHYS_WATERLINE_2_REPORT.md` — measurements, acceptance status, and build limitation.

## PHYS-WATERLINE-2B — 12 m cold-start recovery validation

### Build and runtime

- Rebuilt the existing Windows `template_release` extension without changing solver source. SCons completed compilation and linking successfully; the DLL timestamp is 2026-10-11 21:38:07 local system time, size 855,552 bytes.
- Reopened and ran `gameplay/jet_ski_ocean.tscn`. The extension loaded, the native field was ready, and the active query mode was DIRECT with experimental queries disabled after validation.
- The final startup had no editor-console errors. A preliminary attempt to call the provider's field-build helper directly exceeded its one-build-per-physics-tick guard; that playtest stopped. The scene was restarted successfully before final state verification.

### Matched cold-start grids

Both runs used wind 40 m/s, 7×7 points, 1 m spacing, 3 m half extent, and the same origin-centered coordinates `(x, 1, z)` for x,z = -3…3. The DIRECT, contact-tracked, and LocalSurface oracle samples were evaluated against the same native field time within each run. The wave times match the recorded PHYS-WATERLINE-2 phases: 325.3514 s at rate 0.5 and 15.3626933333333 s at rate 1.0.

The earlier PHYS-WATERLINE-2 report did not preserve the exact 0.5-rate grid center (the earlier run was centered on a live contact). Therefore that case reproduces its documented grid size and phase, but its exact prior coordinates cannot be confirmed. The 1.0-rate origin-centered coordinates and phase match the recorded run.

| Wave rate | Valid | Waterline error vs LocalSurface, valid points (mean / p95 / max) | Solver residual, recovered points (mean / p95 / max) | Selected q correction, recovered points (mean / p95 / max) | Warm/normal | Entered 12 m recovery | Recovered | Failed | Wrong branch |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.5 | 45/49 | 0.000282 / 0.000655 / 0.000943 m | 0.000845 / 0.003083 / 0.004883 m | 10.096 / 11.478 / 11.713 m | 0 | 49 | 45 | 4 | 0 |
| 1.0 | 43/49 | 0.000704 / 0.001369 / 0.001461 m | 0.000967 / 0.004473 / 0.004825 m | 6.266 / 7.815 / 8.123 m | 0 | 49 | 43 | 6 | 0 |

Residual and waterline statistics exclude failed solves. For every valid recovery, no case had residual ≤5 mm together with height error >20 cm. The failed-root response does not export its best attempted q/residual: its zero residual and zero correction fields are sentinels, not measurements. Failure positions below therefore have no trustworthy best-correction or best-residual value.

Failed 0.5-rate points (grid coordinates relative to the origin center):

- `(1, -3)`: 55 iterations; direct height 0.4259 m, oracle -0.3405 m.
- `(2, -2)`: 55 iterations; direct height 0.6354 m, oracle -0.3178 m.
- `(2, -1)`: 52 iterations; direct height 0.7545 m, oracle -0.2591 m.
- `(0, 3)`: 49 iterations; direct height 0.9247 m, oracle -0.0731 m.

Failed 1.0-rate points:

- `(2, -2)`: 64 iterations; direct height -0.8942 m, oracle -1.7308 m.
- `(2, -1)`: 64 iterations; direct height -0.8374 m, oracle -1.6359 m.
- `(1, 0)`: 64 iterations; direct height -0.7077 m, oracle -1.4689 m.
- `(2, 0)`: 64 iterations; direct height -0.7906 m, oracle -1.5181 m.
- `(1, 1)`: 64 iterations; direct height -0.6790 m, oracle -1.3187 m.
- `(2, 1)`: 64 iterations; direct height -0.7562 m, oracle -1.3742 m.

### Decision

The 12 m cold-start gate fails at both rates (45/49 and 43/49). The valid recoveries are accurate and no wrong-branch success was observed, but 10 cold starts still fail. Their large direct-vs-oracle height differences are consistent with a fold/ambiguous region or a root outside the search envelope; the available failed-solve diagnostics cannot distinguish those causes. No moving-contact or performance testing was started. Normal gameplay remains DIRECT. Do not activate this candidate or enlarge its search radius based on these results.
