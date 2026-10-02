# PHYS-OPT-2H — Folded-surface branch continuity

**Result: PARTIAL. No commit or push. PHYS-4 remains blocked.**

Date: 2026-10-02. Development machine: Intel i7-5820K / GTX 970 / Godot 4.7.1, Forward+, D3D12. All timings below are measurements on this machine.

Branch: `wip/phys-opt-2`. Starting and final HEAD: `520769a4988b18b0d8ab179de39a185569fe3009`, `Correct ocean velocity during runtime weather transitions`. The remote branch still contains that same commit.

## 1. What passed and what prevents closure

The new contact API preserves independently owned roots in the tested real folded ocean. The controlled suite completed **9,360 contact updates with zero detected branch jumps, zero global reacquisitions and zero failures**. Four contacts share one immutable snapshot without sharing their branch state. Warm N4 queries remain inexpensive.

Two gates prevent a PASS:

1. A sustained live Production-clock run produced **four failed acquisitions at the left Coastal coverage boundary**. Independent one-sided sampling proves a horizontal geometry discontinuity there, with measured jumps of approximately **8–29 mm** across 2 micrometres of material X. The failed world targets lie between the boundary limits. A dense independent local search found no accepted root. A continuation solver cannot manufacture a root across that gap without changing geometry or accepting a larger residual. Neither change was made.
2. The unchanged PHYS-3 suite returned **PHYS-3-B** because one legacy direct world scalar/batch comparison measured `2.23847e-8 m`, above its existing `1e-8 m` gate. An exact-time, exact-input replay with the previous validated baseline DLL and this candidate returned **identical results**. This is a pre-existing numerical gate issue, not a changed direct solver, but it still prevents claiming the required PHYS-3-A regression gate.

The implementation, tests and diagnosis are preserved as related uncommitted work. No ocean geometry, spectrum, resolution, weather envelope, inversion tolerance, gameplay force or production renderer was changed.

## 2. Existing inversion audit

The legacy dynamic world query remains available and unchanged:

| Property | Existing behavior |
|---|---|
| Seed | Caller-supplied q when warm start is enabled; otherwise target world XZ |
| Newton budget | 12 iterations per candidate |
| Tangent | Central differences of final dynamic displacement, 5 cm stencil |
| Backtracking | Up to 10 residual-decreasing trials |
| Singular tangent | Rejects non-finite determinant or magnitude below `1e-6` |
| Acceptance | Existing horizontal position tolerance: `0.001 m` |
| Global fallback | Failure-only deterministic 8-direction seeds at four fractions of the displacement-derived bound; at most 32 alternate seeds |
| Output | Existing 15-field physical sample, including validity, displacement, normal, total velocity, determinant/fold diagnostic, residual and iterations |
| Branch ownership | No persistent contact identity; a successful cold root does not establish uniqueness |

The direct spectral oracle and its scalar/AVX2 paths were also preserved. The new API is opt-in alongside the old query methods.

## 3. Branch ownership model and API

The caller owns one previous result row per contact. There is no global contact registry or cache keyed by world position. A batch retains the caller's contact order and pins one coherent published LONG/MID/SHORT snapshot once.

```gdscript
history = native.sample_dynamic_contact_batch(world_positions, history)
history = ContactContract.invalidate(history, contact_index)
```

Scalar equivalent: `sample_dynamic_contact(wx, wz, previous_row)`.

Input state contains previous material q, validity, target, field time, configuration version, generation and local orientation. Empty or invalid history means explicit cold acquisition. Backward field time invalidates temporal history. Weather configuration changes preserve ownership because they evolve the same ocean. The caller must invalidate history on contact loss, teleport or ocean-instance replacement.

The returned row contains **27 doubles**:

| Indices | Output |
|---|---|
| 0–14 | Existing physical sample layout |
| 15–16 | Solved material q X/Z |
| 17 | Continuation status |
| 18–19 | Current target world X/Z |
| 20 | Actual published field simulation time |
| 21–22 | Coherent configuration version and publication generation |
| 23 | Derived local search radius |
| 24 | Distance from previously owned q |
| 25 | Final physical horizontal Jacobian determinant |
| 26 | Accepted solver path steps |

| Status | Meaning |
|---|---|
| `CONTINUED = 0` | Owned q continued with local path/orientation checks |
| `REACQUIRED_LOCAL = 1` | Warm continuation failed; bounded local acquisition selected a passing root. A change of sheet is explicit. |
| `REACQUIRED_GLOBAL = 2` | Local acquisition failed, or history was invalid; the unchanged cold solver acquired a root. Uniqueness is not promised. |
| `FAILED = 3` | No accepted root or invalid input; returned contact validity is false |

Native candidates and scratch use fixed stack storage. There are no per-contact native heap allocations or worker jobs. The binding allocates one packed output array per batch, as the existing query APIs do.

### Continuation policy

1. Preserve previous q immediately if it already satisfies the unchanged residual budget and orientation checks.
2. Otherwise start damped Newton at previous q. Check endpoint and midpoint orientation. Limit each step to half the smallest runtime band lattice spacing.
3. The new contact path uses the existing **1 cm final physical derivative convention** for its tangent. The old 5 cm cold/world stencil is unchanged. A 5 cm tangent can span both sides of a narrow Coastal fold.
4. Predict q from the current field and target: `p = q_previous + J^-1(target - F_current(q_previous))`.
5. Set `radius = 2 * (|p - q_previous| + |target - previous_target| + min_band_dx)`. Target motion and actual field evolution enlarge the bound; there is no fixed universal metre cutoff.
6. Warm budget is 12 iterations plus motion measured in half-cell steps, capped at 64. If it fails, try previous q, predictor and two deterministic eight-direction rings at one-quarter and one-half radius. Each local seed has 12 iterations.
7. Select passing local candidates primarily by `|q - previous_q| + 0.25 * |q - p|`, with residual as the tie-breaker. A local reacquisition can change determinant sign and explicitly reports that event.
8. Only after local failure invoke the unchanged global/cold solver. Failure remains visible.

These numerical checks are bounded continuation tests, not exhaustive topology proofs. Singular or disappearing sheets can require explicit reacquisition. Cold acquisition remains ambiguous.

### Periodic coordinates

Contact q is stored **unwrapped in world/material coordinates**. Each band applies its own authoritative material-to-FFT conversion and periodic wrapping only when sampled. Coastal coverage is nonperiodic world-space data.

Wrapping stored q by LONG's period would change other band phases and potentially move the contact out of its Coastal bake. It would also change the equation `world = q + D(q)`. Ordinary motion across a texture seam therefore keeps q unwrapped and local. Validation separately logs signed wrapped phase distances for each band in `[-L_band/2, L_band/2)`; a seam crossing is not treated as a domain-sized branch jump. Large world teleports require explicit invalidation.

## 4. Known real multi-root case

The test uses the real Production spectrum and Coastal bake, not a toy equation. At storm field time **2.25 s**:

| Quantity | Value |
|---|---|
| Common target world XZ | `(176.017364501953, -915.585205078125)` |
| Root A material q | `(175.653472900391, -915.525329589844)` |
| Root B material q | `(175.491363525391, -915.664794921875)` |
| Separation | `0.213845804334 m` |
| A discovery residual | `0 m` at its manufactured source target |
| B discovery residual | `0.000701149990 m` |
| A physical horizontal determinant | `-17.8945677816` |
| B physical horizontal determinant | `15.0681480912` |

Both roots satisfy the existing sub-mm horizontal budget. Opposite determinant signs establish distinct local sheets. A/B/A/B contacts initialized at the **same target** remain independent: batch q error is exactly zero and all four report CONTINUED.

### Continuation tests A and B

These tests make 600 small moving-target updates on the frozen field, starting once from each root. They are query updates, not 600 advancing ocean snapshots.

| Metric | A | B |
|---|---:|---:|
| Updates | 600 | 600 |
| Continued | 600 | 600 |
| Local/global reacquisitions | 0 / 0 | 0 / 0 |
| Failures | 0 | 0 |
| Detected branch jumps | 0 | 0 |
| Iterations mean / p95 / max | 1.0567 / 2 / 2 | 1.0500 / 1 / 2 |
| Residual mean / p95 / max, m | 0.000502792 / 0.000954628 / 0.000999447 | 0.000479983 / 0.000945539 / 0.000998181 |
| Maximum q step, m | 0.00306428 | 0.00709821 |

A separate **120 advancing-field ticks at the same world target**, starting from B, returned 117 CONTINUED, 3 LOCAL, zero GLOBAL, zero FAILED and zero detected branch jumps. Maximum residual was `0.000997579 m`. An independently continuable old-warm branch was available for 93 of those comparisons.

## 5. Controlled trajectory, weather and wrap suite

Twelve contacts each ran **780 field ticks at exact 1/60 s simulation intervals**: **9,360 updates**. The fixture uses authoritative Production H0 generation, the real Coastal CPU bake and coherent async mirror snapshots. This isolates solver correctness from live render scheduling.

| Trajectory | Continued | Local | Global | Failed | Jumps |
|---|---:|---:|---:|---:|---:|
| Stationary material source | 780 | 0 | 0 | 0 | 0 |
| Slowly moving target, 0.5/0.2 m/s source motion | 780 | 0 | 0 | 0 | 0 |
| Fast target, 15/3 m/s source motion | 780 | 0 | 0 | 0 | 0 |
| Coastal interior motion | 780 | 0 | 0 | 0 | 0 |
| Fold A through changing fields | 774 | 6 | 0 | 0 | 0 |
| Coastal border crossing | 774 | 6 | 0 | 0 | 0 |
| Stationary world target, open | 780 | 0 | 0 | 0 | 0 |
| Stationary world target, Coastal | 780 | 0 | 0 | 0 | 0 |
| Stationary world target, folded | 777 | 3 | 0 | 0 | 0 |
| LONG seam | 780 | 0 | 0 | 0 | 0 |
| MID seam | 780 | 0 | 0 | 0 | 0 |
| SHORT seam | 780 | 0 | 0 | 0 | 0 |
| **Total** | **9,345** | **15** | **0** | **0** | **0** |

Aggregate every-tick measurements:

| Metric | Mean | p95 | Max |
|---|---:|---:|---:|
| Solver iterations, including losing candidates | 2.207799 | 5 | 117 |
| Horizontal residual, m | 0.0000446933 | 0.000255775 | 0.000997676 |
| Physical q step, m | 0.0282303 | 0.254921 | 0.255545 |

The largest ordinary q steps belong to the fast-moving target, not branch hopping. Its maximum error against the known manufactured source q was `0.000545915 m`.

The independent nearby-branch oracle was available for **8,420/9,360** updates. Its q-difference mean/p95/max was `0.0000336449 / 0.000172633 / 0.002757411 m`. In ill-conditioned folds, two solves satisfying the same 1 mm horizontal tolerance can differ by millimetres in q. The controlled jump detector uses a separately documented **3 cm distinct-root diagnostic**, far below the measured 21.38 cm A/B separation; it does not change the residual acceptance threshold. This test does not prove absence of all smaller root separations. Fast-motion cases beyond the oracle's local search use their known source q as an additional check.

Contact scalar/batch output maximum difference: **0**. All compared batches were coherent. No source-q discrepancy after an explicit reacquisition is counted as a silent jump.

### Weather, rapid requests and lifecycle

- Controlled calm-to-storm, storm-to-calm and direction changes passed without mixed snapshots or ownership thrashing.
- Rapid A→B→C request test published the newest coherent version **6**; returned field time was `15.266666666667 s`, status CONTINUED.
- Thirty paused physics frames preserved q, actual field time and generation: zero changes and zero reacquisitions. Resume starts from the same caller-owned history.
- First contact and explicitly invalidated reentry returned GLOBAL, as specified. Non-finite input returned FAILED and invalid state.
- Existing corrected PHYS-OPT-2G weather velocity remains intact. A final focused velocity smoke measured fixed-state XYZ velocity error **0**, geometry control error `3.15303e-14 m`, isolated choppiness-ramp finite-difference vector error `4.74335e-6 m/s`, and duration-scaling error `5.77316e-15`. The full 2G matrix was not rerun in this phase.

## 6. Sustained live Production-clock test

The live runner uses **Ocean.get_wave_time()**, actual Production physics ticks, Production runtime weather requests and four independent contacts. It ran 1,200 advancing ticks plus a 30-tick pause. Weather requests at ticks 0/300/600/900 use 3-second ramps through calm, storm, calm and a changed direction.

| Metric | Measured result |
|---|---:|
| Contact updates | 4,800 |
| Continued / local / global / failed | **4,785 / 6 / 5 / 4** |
| Mixed snapshots | 0 |
| Backward field time | 0 |
| Iterations mean / p95 / p99 / max | 2.37146 / 2 / 3 / 407 |
| Residual mean / p95 / max, m, including failures | 0.0000621338 / 0.000284875 / **0.0123789233** |
| q-step mean / p95 / max, m, including reacquisition | 0.0127346 / 0.0384385 / 1.9455434 |
| N4 query mean / p95 / p99 / max, ms | 0.162922 / 0.182 / 0.547 / **18.691** |
| Worker build mean / p95 / p99 / max, ms | 11.77697 / 14.893 / 17.202 / 19.902 |
| Field age mean / p95 / p99 / max, ticks | 0.331596 / 1 / 1.144747 / **8.91812** |

The live test includes startup and rare expensive failure/reacquisition paths and has no standard producer warmup. Its age tail is therefore not directly comparable to the earlier warmed producer benchmark. It is nevertheless an observable end-to-end tail that cannot be omitted from readiness reporting. No producer or scheduling changes were made here.

All four failures belong to the contact crossing the left Coastal coverage edge:

| Physics tick | Actual field time, s | Failed residual, m |
|---:|---:|---:|
| 10 | 0.373441666667 | 0.003330606 |
| 992 | 16.878984888890 | 0.008951349 |
| 993 | 16.893429333334 | 0.012378923 |
| 1,186 | 20.127938666667 | 0.001569063 |

GLOBAL/reentry events are explicit. The live timed loop does not run the expensive independent branch oracle, so its global event count must not be presented as a separate zero-jump proof.

### Why these failures are not solved by a different Newton seed

CPU-only failure captures retain exact H0, choppiness, Coastal bake metadata and snapshot time. An independent replay scanned a 61×61 local seed grid over ±1.5 m, refined the 32 lowest-residual candidates with a 0.3125 mm diagnostic tangent and 40 Newton iterations, and found no passing local root. That diagnostic tangent is **validation only**; it is not used by gameplay queries.

One-sided sampling at `q.x = field_origin.x ± 0.000001 m` then solves q.z independently so both sides match the same target world Z. A representative captured state at **16.890250649352 s** gives:

| Quantity | Outside | Inside |
|---|---:|---:|
| Material q X | -168.281373070313 | -168.281371070313 |
| Material q Z | -652.157312948965 | -652.169364995964 |
| Resulting world X | -168.087064820617 | -168.058095240081 |
| World X minus target, m | -0.019590455383 | +0.009379125153 |

Common target: `(-168.067474365234, -652.0693359375)`.

The X limits differ by **0.028969580536 m** while world Z matches to approximately `1e-12 m`. The target lies between these limits. Other captured states show jumps of **0.016921734 m**, **0.008050049 m** and **0.028662233 m**. A more aggressive global polishing experiment did not eliminate the failures and was reverted. Its CPU captures remain useful because it changed inversion only, not displacement geometry.

The source explains the discontinuity:

- `ocean_query_core.cpp`, Coastal sampling: outside the authored UV rectangle it returns no Coastal authority immediately; inside it uses sampled validity/confidence, which need not approach zero at the rectangle edge.
- `ocean_surface.gdshader`, Coastal geometry: the same inclusive UV rectangle applies Coastal-modified LONG inside and unmodified LONG outside.

The independent scan is a bounded search, **not an exhaustive proof that no remote root exists anywhere**. It does prove a local geometry discontinuity and failure of the expected nearby continuation. Flattening, smoothing coverage, clamping displacement or accepting a larger residual would change the forbidden physical contract. No such correction was applied.

## 7. Performance and rejected experiments

Focused final v3 timings use 1,000 N4 batches per case, with the required final physical sampling and branch checks included:

| N4 workload | Mean ms | p95 ms | p99 ms | Max ms |
|---|---:|---:|---:|---:|
| Ordinary, stationary target | 0.051236 | 0.083 | 0.095 | 0.190 |
| Coastal, stationary target | 0.042230 | 0.045 | 0.051 | 0.091 |
| Folded, stationary target | 0.053236 | 0.115 | 0.136 | 0.259 |
| Ordinary, moving target | 0.111140 | 0.269 | 0.415 | 0.511 |
| Coastal, moving target | 0.131132 | 0.308 | 0.319 | 0.500 |
| Folded, moving target | 0.052758 | 0.048 | 0.307 | 0.309 |

Every moving focused case reported 4,000 CONTINUED contacts and zero reacquisitions/failures. Means satisfy the requested ordinary/folded development goals; moving ordinary p95 does not meet a stronger universal 0.2 ms bound, which was not the stated acceptance requirement.

Artificially perturbing stored q produced explicit local reacquisitions costing **4.450, 5.802 and 7.321 ms** per tested scalar recovery. Ordinary warm attempts in that diagnostic cost 0.123–0.252 ms. Recovery is significantly more expensive than continuation.

Global reacquisition was not isolated into its own timing distribution. The live N4 mixed failure/global tail reached **18.691 ms**; that is a measured batch bound, not a fabricated per-global cost. This remains a gameplay-readiness concern.

| Experiment | Outcome |
|---|---|
| Use old 5 cm tangent in contact continuation | Folded moving N4 mean approximately 0.539 ms, maximum 28.168 ms; excessive local recoveries. Replaced only in the new API with the existing 1 cm physical tangent convention. |
| Reject determinant-sign changes during all local recovery | Rejected: local recovery must explicitly accommodate a disappearing/changing sheet rather than force a distant global root. Warm continuation retains orientation checks. |
| Polish global failures using a finer contact tangent | Rejected: Coastal edge failures remained. Final DLL is v3; the experiment was reverted. |
| Unchanged-anchor fast acceptance | Accepted: retains already-valid owned q and avoids unnecessary candidate work. |
| Displacement-only tangent/path sampling | Accepted: evaluates the same displacement and total velocity without calculating unused normals during each solver probe. Legacy query defaults are unchanged. |

## 8. PHYS-3 regression gate

The original runner was executed without test/tolerance modifications. Its formal result is **PHYS-3-B**:

| Check | Result |
|---|---:|
| Material scalar/batch max | `3.38528e-12 m` |
| World scalar/batch max | **`2.238473229e-8 m`**, above unchanged `1e-8 m` gate |
| World inversion | 64/64 valid |
| World horizontal residual mean / p95 / max | `0.000165843 / 0.000775204 / 0.000863356 m` |
| Open-ocean fallback | Exactly 0 difference |
| Physical normal finite-difference max | `0.000068593` |
| Manual Field + Warp + interpolation-matched FFT reconstruction max vector | `0.0000382601 m` |
| Combined current render-filtered reconstruction max vector | `0.002879187 m`, reported separately from continuous/manual parity |
| Production clock 1× / 0× / resume | Passed |

The historical hardware-Warp diagnostic remains separate and is not misreported as current Production geometry. Production continues to use the deterministic Warp sampling established in PHYS-3.3.

### Baseline comparison

The failing direct comparison was replayed at exactly `t = 0.473258666666665 s` and the same four material points. The worst point is `(37.13506, 81.04028)`:

| Metric | Previous baseline DLL | Final v3 DLL |
|---|---:|---:|
| World scalar/batch max, m | `2.23847251845655e-8` | **Identical** |
| Material scalar/batch max, m | `5.95492825514708e-14` | **Identical** |
| Batch world residual, m | `0.000487571603190158` | **Identical** |
| Scalar world residual, m | `0.000487678233625823` | **Identical** |

The baseline build identifier is `PHYS-RECOVERY-3-band-weather-v2`; the final candidate is `PHYS-OPT-2H-contact-continuity-v3`. Recorded results are identical apart from their build identifier. No thresholds were relaxed and no favorable time was substituted to obtain an A.

## 9. Build and reproducibility

Final native source compiled and linked successfully with MSVC 19.44 x64 and Windows SDK 10.0.26100.0. DLL size: **692,224 bytes**. Generated descriptor and native loading passed. Final DLL build guard: **`PHYS-OPT-2H-contact-continuity-v3`**. No native crash was observed.

The known `godot_cpp_path` unknown-variable warning remains build hygiene debt; the build uses the existing pinned sibling dependency. No dependency version changed.

From the native build directory, with the MSVC x64 environment initialized:

```powershell
python -m SCons platform=windows target=template_release godot_cpp_path=../godot-cpp build_library=no -j 6
```

`build_library=no` reuses the already validated godot-cpp static library. It still compiles/links the native extension; it is not a clean dependency bootstrap command.

Validation entry points:

```powershell
& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 `
  --script res://validation/physics/phys_branch_continuity_runner.gd

& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 `
  --script res://validation/physics/phys_branch_live_runner.gd

# Replays CPU-only failure captures generated by the live runner.
& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 `
  --script res://validation/physics/phys_branch_boundary_runner.gd
```

The final rebuilt DLL also passed the branch smoke, boundary replay and focused weather-velocity smoke. No full GPU readback or global RenderingDevice submit/sync was introduced. Native contact queries do not depend on rendering resources.

Evidence is local and ignored under `.godot/`: `branch_final.stdout.log` contains the full v3 controlled result; `branch_live.stdout.log` contains the v3 sustained result; `phys3_2h.json` contains the unchanged PHYS-3 run; the `phys2g_direct_2h_baseline/current.json` pair contains the exact baseline comparison. Later smoke/experimental runs overwrite some default JSON paths, so their output must not be substituted for these full-run logs. CPU failure captures and compiler outputs are not repository content.

## 10. Files, Git and remaining gates

Related source changes only:

| File | Purpose |
|---|---|
| `addons/ocean/physics/native/ocean_query/src/dynamic_ocean_contact.h` | Separate bounded continuation/reacquisition solver |
| `addons/ocean/physics/native/ocean_query/src/ocean_query_native.cpp` | Bind scalar/batch contact queries, snapshot ownership, light sampling, build guard |
| `addons/ocean/physics/native/ocean_query/src/ocean_query_native.h` | API declarations |
| `addons/ocean/physics/dynamic_ocean_contact_contract.gd` | Caller-owned row/status constants and explicit invalidation |
| `validation/physics/phys_branch_continuity_runner.gd` | Real-root discovery, controlled trajectories, independent oracle and focused performance |
| `validation/physics/phys_branch_live_runner.gd` | Actual Production-clock weather, pause and sustained failure capture |
| `validation/physics/phys_branch_boundary_runner.gd` | Independent local root search and one-sided Coastal edge diagnosis |
| `validation/physics/phys_native_build_contract.gd` | Accept current build guard |
| `validation/physics/run_dynamic_physics_validation.ps1` | Include branch validation |
| `validation/physics/DYNAMIC-CONTACT-BRANCHES.md` | API and numerical ownership contract |
| `validation/physics/PHYS-OPT-2H-REPORT.md` | This measured report |

**Commit: NONE. Push: NOT PERFORMED. Worktree: related WIP changes only; initially clean.** `git diff --check` is clean. The branch and remote HEAD are unchanged. Generated DLLs, captures, logs and `.godot` files remain ignored. No master merge or unrelated user changes.

Before closure:

1. Decide separately how Production's hard Coastal coverage boundary should handle an actual geometry gap. This is outside the permitted geometry-preserving 2H scope. Until then FAILED must remain explicit; silently returning another sheet or an over-tolerance point is unacceptable.
2. Resolve the reproduced legacy direct scalar/batch PHYS-3 gate without weakening its tolerance.
3. Re-run the controlled and live suites after those blockers are resolved; quantify recovery tails and re-establish PHYS-3-A before committing the candidate.

**Next gate is closure of these blockers, then target validation. PHYS-4 forces remain blocked until target validation passes. No target-machine test or gameplay integration was performed.**

## 11. Mandatory pending roadmap

- **Crest G / Spindrift:** clamp `[0,1]` contract discrepancy remains open.
- **P3D.1 travelling phase:** revalidate after TIME-1 in a fully initialized Ocean/Carrier scene.
- **P3E handoff:** revalidate after TIME-1 in a fully initialized Ocean/Carrier scene.
- **TIME-1 instrumentation:** decide whether to remove, move to validation/debug, or retain intentionally.

None of these items was changed or closed in PHYS-OPT-2H.
