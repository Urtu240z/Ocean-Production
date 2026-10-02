# Dynamic ocean contact branch ownership

PHYS-OPT-2H adds an opt-in contact API alongside the existing cold/warm world queries. It does not change the ocean surface, the direct spectral oracle, weather velocity, or gameplay forces.

## State and API

The gameplay contact owns its previous result. The ocean has no contact registry or position-keyed cache.

```gdscript
var contact_rows := PackedFloat64Array() # First acquisition has no history.

# The four positions and the four history rows retain the SAME contact order.
contact_rows = ocean_native.sample_dynamic_contact_batch(world_positions, contact_rows)

# On contact loss, teleport or change of ocean instance:
contact_rows = ContactContract.invalidate(contact_rows, contact_index)
```

`ContactContract` is `addons/ocean/physics/dynamic_ocean_contact_contract.gd`.

- Scalar: `sample_dynamic_contact(wx, wz, previous_row)`.
- Batch: `sample_dynamic_contact_batch(world_positions, previous_rows)`.
- A scalar row contains 27 doubles. A batch concatenates those rows.
- Empty/wrong-sized history starts a cold acquisition. A row with `VALID=0` explicitly invalidates that contact only.
- Each batch pins one immutable published snapshot once. All contacts use the same LONG/MID/SHORT, time, configuration and generation.
- Native solve scratch and seed sets use the stack. There are no per-contact native heap allocations, worker jobs or locks. The Godot binding creates one packed result array per batch, as the other query APIs do.
- Identical snapshot and target preserve the owned q. A clock rewind invalidates temporal history and causes explicit cold acquisition.
- Reset caller history on scene/ocean replacement. A configuration version change alone does not invalidate a contact: weather evolves the same surface identity.

| Index | Meaning |
|---:|---|
| 0–14 | Existing physical sample: valid, height, displacement, normal, total velocity, determinant, foldover, residual, iterations |
| 15, 16 | Solved, unwrapped material q X/Z |
| 17 | Status |
| 18, 19 | Previous/current target world X/Z |
| 20 | Actual field simulation time, seconds |
| 21, 22 | Configuration version and publication generation |
| 23 | Derived local search radius, metres |
| 24 | Distance from the previous owned material q, metres |
| 25 | Final physical horizontal Jacobian determinant |
| 26 | Accepted continuation/reacquisition path steps |

| Status | Meaning |
|---|---|
| `CONTINUED = 0` | Previous q solved on the current field with local orientation/path checks. |
| `REACQUIRED_LOCAL = 1` | Warm continuation failed; a bounded local search selected a valid root. It can change sheet and must not be reported as continuity. |
| `REACQUIRED_GLOBAL = 2` | No valid local acquisition, invalid history or first contact; existing cold solver acquired a root. No unique branch is promised. |
| `FAILED = 3` | No accepted root or invalid target. Do not use the returned q/forces; contact state is invalid. |

Residual acceptance remains `oq::POSITION_TOLERANCE_M = 0.001 m`. `ITERATIONS` reports total candidate solver work, including failed candidates, rather than only the winning root.

## Continuation and reacquisition

1. Sample the current field at the previous q. If it already meets the existing residual and orientation checks, return it unchanged.
2. Start damped Newton at the previous q. Limit individual steps to half the smallest band lattice spacing. Check endpoint and midpoint orientation against the owned branch. Accept only residual-decreasing backtracked steps.
3. The new contact tangent uses the existing **1 cm final physical derivative convention**. The legacy world/cold solver still uses its original **5 cm Newton stencil**, 12 iterations, 10 backtracking trials and original failure-only global seeds. A 5 cm derivative can span both sides of a much narrower Coastal fold; the local tangent avoids that failure without changing displacement or normal equations.
4. Compute a current-field predictor `p = previous_q + J^-1(target - F_current(previous_q))`. Thus it includes target motion and the actual current weather/wave displacement change.
5. Bound local candidates with `radius = 2 * (|p - previous_q| + |target - previous_target| + min_band_dx)`. Fast target motion expands the bound. Warm iteration budget is 12 plus the target motion in half-cell steps, capped at 64; each local seed has 12 iterations.
6. If warm continuation fails, try previous q, the predictor, and two fixed eight-direction rings at 1/4 and 1/2 radius. Select passing roots with score `|q - previous_q| + 0.25 * |q - predictor|`, then residual as a tie-breaker. Local reacquisition may accept a new determinant sign and explicitly reports that loss/change of sheet.
7. An unchanged q is the global minimum of that score by the triangle inequality. When it passes local acquisition there is no reason to run the remaining seeds.
8. Only after local failure invoke the unchanged cold/global world solver. A cold root may differ substantially from another valid root; its small residual does not establish uniqueness.

These are bounded numerical continuation checks, not exhaustive root enumeration or a proof that every possible fold can be continued. A singular/disappearing sheet may require explicit reacquisition. The runner independently searches for a nearby continuable root with the legacy warm solver and path checks; it fails if the contact chooses a different root while that branch remains available.

## Periodic coordinates

The unknown is one **unwrapped world/material q**. Band sampling alone applies each band's material-to-FFT offset and periodic wrapping. Coastal coverage/warp remains in authored world coordinates.

Wrapping the contact q by LONG's domain would move the MID/SHORT phases (different periods) and possibly move it outside its Coastal bake. Wrapping world targets would also change `world = q + D(q)`. Therefore gameplay stores the unwrapped q, and ordinary motion across any texture seam remains local.

Validation logs phase-distance diagnostics independently for each band:

`delta_band = wrap_signed(q_new - q_previous, L_band)` in `[-L_band/2, L_band/2)`.

This is distinct from the physical q distance used for ownership. Large world teleports require explicit invalidation, not periodic reinterpretation of the target.

## Validation

Run Godot 4.7.1 after building the native extension:

```powershell
& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 `
  --script res://validation/physics/phys_branch_continuity_runner.gd
```

`-- --smoke` runs multi-root discovery, two 600-query frozen-field moving-target histories, lifecycle, A/B/A/B batch ownership and focused N4 timing. The full run additionally tracks stationary-world contacts, slow/fast targets, folded/Coastal/border paths, each band seam, calm/storm/direction ramps, 30 paused physics frames and rapid latest-version requests. It uses real Production H0 generation and the real Coastal bake, not a toy fold.

Generated `.godot/phys_branch_continuity.json` and `.godot/phys_branch_trace.json` remain ignored. Traces record targets, previous/solved q, per-band wrapped distances, residual, iterations, status and actual snapshot metadata. Source-q error is a diagnostic; after explicit reacquisition it is not evidence of a silent branch jump. Stationary-world tests have no prescribed source q.

`run_dynamic_physics_validation.ps1` includes this runner with the existing weather, total-velocity, freshness and optional PHYS-3 suites.

`phys_branch_live_runner.gd` additionally runs 1,200 actual Production physics ticks with four contacts, four runtime weather requests and a 30-tick pause. It reports failed acquisitions honestly and saves CPU-only snapshots of failures under `.godot/branch_failure_*.bin`. `phys_branch_boundary_runner.gd` replays those captures with dense seeds, an independent fine-tangent Newton diagnostic and one-sided Coastal boundary limits. These generated captures are not repository content.

The current sustained test exposes a pre-existing Coastal coverage discontinuity for some moving-weather states. It is deliberately a failing acceptance gate: the runner must not label unresolved acquisition failures as success. See `PHYS-OPT-2H-REPORT.md` before using this API for gameplay.

## Scope and pending work

No PHYS-4 forces or jetski integration. No spectrum, FFT size, Coastal geometry, producer/scheduler or old solver change.

- Crest G / Spindrift clamp discrepancy remains open.
- P3D.1 travelling phase: revalidate after TIME-1 in an initialized Ocean/Carrier scene.
- P3E handoff: revalidate after TIME-1 in an initialized Ocean/Carrier scene.
- Decide whether TIME-1 audit instrumentation is removed, moved to validation/debug, or intentionally retained.

The current result is **PARTIAL**. Resolve the explicit Coastal-boundary failures and the unchanged PHYS-3 numerical gate before target-machine validation. PHYS-4 remains blocked until those gates and target validation pass.
