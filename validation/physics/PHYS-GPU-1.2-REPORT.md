# PHYS-GPU-1.2 — Folded-surface continuation / ownership closure

**PARTIAL. NOT READY for PHYS-GPU-2.**

Starting HEAD: **4da4c7ef769b3b45dd9e765e07aa3deb76fe0d76**. Work is confined to
**wip/phys-gpu-1**. Validation date: 2026-10-04. Final runtime code tested:
**0be65a5**. Godot 4.7.1 official a13da4feb, D3D12 Forward+, GTX 970,
i7-5820K. These are non-target performance measurements.

The bounded exceptional correction improves matched GPU replay from **16/49 to
30/49 valid**, and from **3/12 to 10/12** on sampled surviving continuations.
Ordinary trajectories, controlled two-root ownership, physical parity, async
delivery and resource retirement pass their existing checks. Two demonstrated
surviving cases still fail the orientation guard. Other warm failures remain
unclassified, and folded cold acquisition lacks a validated physical sheet
selection contract. Neither PASS outcome is satisfied. No later physics phase,
force behavior, Jolt integration or merge is started.

## CPU Contact API audit

[Actual-source audit](PHYS-GPU-1.2-CPU-CONTACT-AUDIT.md) covers
`DynamicOceanContact` and its native wrapper, rather than the legacy simple
world query. CPU oracle source is unchanged.

The CPU Contact API keeps a complete 27-double previous row: physical sample,
q, status, previous world target/time/config/generation, radius, q delta,
determinant and continuation-step count. Its connected attempt starts at
previous q, uses a 1 cm Jacobian, clips steps to half the smallest FFT texel,
and backtracks up to ten times. Target-motion-dependent continuation budgets
are bounded. A current-snapshot Newton prediction supplies another local seed;
it is not an exact physical-time predictor.

Local recovery tries the anchor, predictor and two eight-direction rings.
It drops the connected attempt's orientation guard and scores candidates by
distance to old/predicted q. Global recovery then uses the broad legacy cold
search. Consequently CPU LOCAL/GLOBAL success is a valid residual candidate,
not proof of ownership continuity. GLOBAL may choose another sheet.

GPU ordinary inversion uses a 0.1 mm local Jacobian, separate from the 1 cm
physical normal/determinant convention. GPU state keeps a scalar local
determinant, not the four previous Jacobian entries. Both implementations keep
q unwrapped while FFT sampling is periodic. Coastal LONG confidence/warp/shoal
and MID/SHORT sampling remain unchanged.

Structural graph tools were unavailable during the initial audit; actual
source was read. Final coverage responded, but reported changed metadata for
all eleven relied source paths and partial shader/runner parsing. Reported
missed lines were read directly. Conclusions rely on source and executions,
not a claim of complete graph coverage.

## Exact failure replay

[CPU replay](PHYS-GPU-1.2-CPU-REPLAY.json) processes all **3,026** original
PHYS-GPU-1.1 failed observations with the actual Contact API. Current time,
configuration, weather alpha, target and recorded previous FP32 q match the
CSV. The old CSV does not contain the full previous 27-double row or executed
predecessor time; the exhaustive CPU replay reconstructs the preceding nominal
tick. It is an exact match of recorded inputs, not a literal replay of missing
historical GPU state.

| Original GPU failures | CPU succeeds | CPU fails |
|---|---:|---:|
| All 3,026 | 2,745 | 281 |
| Warm 1,742 | 1,642 | 100 |
| Cold 1,284 | 1,103 | 181 |
| Original lateral seven | 7 | 0 |

CPU statuses across all rows: CONTINUED **49**, LOCAL **758**, GLOBAL **1,938**,
FAILED **281**. Warm successes comprise 49 CONTINUED, 758 LOCAL and 835 GLOBAL.
There are **454 warm** successful CPU candidates over one metre from old q
(1,100 including cold). This is a distance flag, not a branch-jump certificate.
The seven lateral GLOBAL candidates are 3.5–7.24 m away and differ from the
locally tracked pair after it disappears. CPU success alone cannot close
these ownership failures.

For the 49 CPU-CONTINUED cases, predecessor candidates one through eight ticks
back were inspected and the best residual history used in matched GPU replay.
All 49 replay starts are valid/owned; **48/49** retain the original serialized
FP32 q exactly. Internal GPU q was FP64 and was not archived. The
[before/after GPU replay](PHYS-GPU-1.2-GPU-REPLAY.json) documents these limits;
its 16-to-30 improvement is a controlled comparison using the same reconstructed
history, not a claimed reproduction of every original execution.

## Root study and fine continuation

[Representative studies](PHYS-GPU-1.2-ROOT-STUDIES.json) select the first case
per scenario/ownership/reason/configuration class and include all seven lateral
cases. [Expanded studies](PHYS-GPU-1.2-CONNECTED-STUDIES.json) add all 49
CPU-CONTINUED cases. Their union contains **80 unique cases: 68 warm, 12 cold**.

There are **415 distinct discovered roots**, **1–17 per case**, after
deterministic dense seed sampling and stricter CPU refinement. Discovery is
not an exhaustive global root count. Every root record includes q, residual,
local/physical determinant, distance from previous q and world Y.

The continuation experiment first refines the recorded approximate q to a
1 micrometre residual, then walks the reconstructed time/target path with a
1 micrometre local Jacobian. Weather alpha at the failed snapshot is matched.
The prior weather evolution and executed predecessor are not fully archived
for the old corpus. Endpoint success counts over the 68 warm studies are:

| Time step | Valid endpoint candidates |
|---|---:|
| 1/60 s | 18 |
| 1/120 s | 16 |
| 1/240 s | 12 |
| 1/480 s | 12 |

These non-monotonic counts are evidence that finite Newton stepping is not a
termination oracle. Five recorded approximate starting points could not be
refined: ordinals 114, 331, 610, 1957 and 2555. A 1 mm accepted point does not
necessarily certify an exact root.

The twelve 480 Hz endpoint continuations are ordinals **19, 165, 277, 368,
396, 424, 1095, 1384, 1576, 1805, 1926 and 2007**. Final GPU correction matches
ten, with maximum q distance **1.106 mm** from the stricter reference endpoint;
q error can exceed world residual near conditioning problems.

The two remaining demonstrated numerical failures are:

| Ordinal | Previous q | Tracked endpoint q | Minimum sampled abs(detJ) | Maximum 480 Hz q step |
|---|---|---|---:|---:|
| 1926 | (393.034668, -991.837036) | (393.078187, -991.874628) | 0.9014 | 3.459 mm |
| 2007 | (394.528015, -993.112366) | (394.409533, -992.913585) | 0.7220 | 9.462 mm |

Both refined paths have zero recorded orientation changes. Reconstructed
predecessors are three/four nominal ticks back. The old anchor is on the
opposite side of a moving caustic in the final field, so the fixed-current-field
guard rejects a surviving time-connected root. Their final reason is
ORIENTATION (5). They are **not classified as termination**. Globally removing
the guard would leave ownership unproven.

Within the 68 warm studies: twelve have sampled surviving endpoint
continuations, seven have the stronger local pair-loss evidence below, and
**49 remain unclassified**. The other **1,674 old warm failure records** were
CPU-replayed but not individually classified by this fine root study. No
classification is automatically transferred to the new full-run failures.

## Root termination and the original lateral seven

[Lateral studies](PHYS-GPU-1.2-LATERAL-STUDIES.json) contain adaptive paths,
rejected frames, complete local cell-root enumeration and terminal pair boxes
for ordinals **1028–1032, 2521 and 2522**. These cases are outside Coastal.

On the union of the three FFT texel-centre partitions, the reconstructed
horizontal map is piecewise bilinear. Each cell's roots are obtained
analytically from the quadratic equations. Midpoint interpolation error is
at most **2.274e-13 m**, and no degenerate cells were encountered. Tracking
starts at 480 Hz, halves time steps down to 2 microseconds, and selects the
isolated nearest root with at most 3 cm q motion.

Terminal boxes contain **both approaching opposite-orientation roots with an
interior margin**. Local root counts at offsets 0, 2, 5, 10, 20, 50 and
100 microseconds after the last accepted frame are:

| Ordinal | Local root counts |
|---|---|
| 1028, 1029, 1030, 2521, 2522 | 2, 0, 0, 0, 0, 0, 0 |
| 1031 | 2, 2, 0, 0, 0, 0, 0 |
| 1032 | 2, 2, 2, 2, 0, 0, 0 |

Every terminal pair box is also rootless at the failed target/time. A separate
root survives elsewhere. This provides strong sampled evidence of **local
owned-pair loss in the reconstructed authoritative CPU field**, beyond Newton
failure or exhausted seeds. It is not a proof that all roots disappear globally.
An initial arbitrary box could lose a root by box exit; the final enumeration
uses the approaching pair and margin to avoid that inference.

Some losses occur at FFT interpolation cell kinks. One-sided determinants can
remain nonzero there; a smooth detJ-to-zero narrative does not describe every
sampled loss. Finite-difference determinant sign is neither a universal
termination test nor a sheet identity.

Original lateral failures before: **7**. Final exact recorded-input replay:
**7 FAILED**, all owned on input; no arbitrary reacquisition. Their residuals
are 6.31–387.13 mm. The independently tracked pair-loss classification is
conditional on reconstructed predecessor/time and CPU FFT representation:
the precise original history and rendered GPU caustic field were not archived.
That qualification prevents declaring unconditional runtime TERMINATED.

Runtime TERMINATED outputs: **0**. FAILED remains invalid and clears ownership;
retained q is a hint for later cold acquisition. Explicit TERMINATED semantics
are deferred until the corresponding runtime evidence and policy are validated.
The new full run contains **six lateral warm failures**; asynchronous coalescing
changes the observations, so seven-to-six is not evidence of one numerical fix.

## GPU solver change and near-singular policy

[Contact contract](PHYS-GPU-1.2-CONTACT-CONTRACT.md) specifies the final bounded
algorithm. Only the query shader changes at runtime.

1. Ordinary warm primary: previous GPU q, 16 iterations, 0.1 mm local stencil,
   twelve strict-descent backtracks and existing radius/orientation guards.
   A success executes exactly one solve.
2. After owned primary failure: restart from previous q and try a 128-iteration
   correction with the ordinary stencil, then a 128-iteration correction with
   a 1 micrometre stencil. Clip each Newton step to half the smallest active
   FFT cell; the validated bands give **0.072265625 m**. Each has sixteen
   backtracks and the same anchor/radius/orientation.
3. If those fail: try two then four target segments in the **current field**,
   starting at F_now(previous q) and ending at the requested target. Each
   segment uses the guarded fine correction. Partial segments are not published.
4. Retain the existing four cardinal recovery seeds. Maximum owned attempts:
   **13 solves**, bounded by **1,104 iterations**; cold remains at most five
   solves. New successful recovery reports REACQUIRED_LOCAL.

The fine stencil addresses Coastal derivative averaging across interpolation
kinks. Acceptance stays **1 mm**; physical normals and reported determinant
stay at **1 cm**. No spectrum, FFT dispatch, Coastal field or query ABI changes.

[Offline corrector comparison](PHYS-GPU-1.2-CORRECTOR-COMPARISON.json) yields
11/49 strict valid endpoints with the guarded ordinary stencil, 14/49 with
the fine stencil, and 16/49 with clamped velocity prediction. Among the twelve
tracked survivors, the fine stencil and predictor each solve eight; prediction
helps one case and hurts another. No time predictor is adopted. Offline
prediction reconstructs the full prior Jacobian, which runtime state lacks.
[Target-substep investigation](PHYS-GPU-1.2-SUBSTEP-INVESTIGATION.json) records
the validation-only two/four-segment comparison before the internal change.

Target segmentation is a residual correction homotopy, **not physical-time
continuation**. Runtime does not synthesize historical FFT snapshots. Radius
and orientation checks remain at current q, trial q and midpoint. Status LOCAL
is a recovered candidate, not proof of an owned continuous time path.

Near-singular division is rejected at **abs(detJ) < 1e-8**, the existing
deterministic floor. Above it, ill-conditioned attempts receive clipped,
backtracked steps and finite budgets; failure remains explicit. Regular primary
successes bypass recovery. The determinant floor is not a calibrated condition
number boundary, and this phase does not claim a validated universal
regular/ill-conditioned/near-singular taxonomy. That numerical-policy closure
is still incomplete. In particular, the existing starting-point residual check
precedes the Jacobian/orientation test: an approximate accepted point is not
an exact-root/orientation certificate.

## Final fold trajectory and full matrix

The final uninterrupted matrix reruns all eight 240-tick layouts
(1×4, 1×8, 1×16, 4×8, 6×8, 10×8, 10×16, 16×16) and both 10,000-submission
80/256-contact stress layouts, with the original pause, withholding, weather
and reentry fixture. No other GPU diagnostic ran concurrently.

[Measurements](PHYS-GPU-1.2-MEASUREMENTS.json) sum every matrix/stress case;
the scratch runner's top-level aggregate describes only its last stress case.
Verification errors: **0**. All active observed contact updates: **1,230,304**.

| Fold result | Count |
|---|---:|
| Active observed updates | 96,176 |
| Warm inputs | 93,559 |
| CONTINUED | 89,218 |
| REACQUIRED_LOCAL | 2,728 |
| TERMINATED | 0 |
| Warm FAILED | 1,613 |
| Conservatively unclassified warm FAILED | 1,613 |
| Cold attempts | 2,617 |
| Cold successes | 1,671 |
| Cold failures | 946 |

Fold warm reasons: no-descent **1,580**, orientation **29**, iteration limit **4**.
Cold reasons: no-descent **836**, iteration limit **110**. Full-matrix warm
failures including lateral: **1,619**; total failures including cold: **2,565**.
Full fold branch jumps: **not independently measured**. The controlled
two-root test is zero-jump; it does not certify every full-trajectory recovery.

All new warm failures have a matched captured executed predecessor: generation,
time, target, q, physical determinant, water velocity, configuration, alpha,
spectrum/GPU times and target motion. Executed gaps range from **1/60 s to
8/60 s**. [All failed records](PHYS-GPU-1.2-FAILURES.json) preserve this ledger.
These are diagnostics only; no captured q is fed back into runtime packets.

Old and new full runs observe different contacts/gaps because of asynchronous
coalescing. Old warm failures were 1,742/1,680,982; new are
1,619/1,226,005. The rate is **0.1036% versus 0.1321%**. Raw failure-count
reduction is not evidence of improvement. The matched 49-case and twelve
survivor comparisons provide the controlled numerical evidence.

## Fold cold acquisition and sheet semantics

Cold numerical acquisition is unchanged: target/hint seed and bounded
cardinal seeds, first accepted valid residual, without inherited ownership.
This ordering is deterministic numerically but is **not a validated physical
sheet-selection rule**.

Original cold ordinal 0 has three refined roots at the same XZ target, with
world Y **0.272432, -0.103228 and 0.241624 m**. The nearest q to the target is
the third (0.321484 m away); the highest is the first (0.703911 m away).
The first and third both have positive local determinant. Thus nearest,
highest and positive orientation are distinct selection criteria.

The query specifies neither intended Y intersection nor ray direction, and
the authoritative rendering contract supplies no highest-sheet policy.
Warm continuity has priority while the owned branch exists. Cold physically
intended sheet remains unresolved. Inventing a height or gameplay policy would
not satisfy this phase; cold ownership closure is blocked pending that contract.

## Ordinary and controlled ownership regressions

| Ordinary scenario | Observed active updates | Failures |
|---|---:|---:|
| stationary | 147,728 | 0 |
| slow | 141,008 | 0 |
| fast | 100,016 | 0 |
| acceleration | 100,016 | 0 |
| turning | 98,096 | 0 |
| crest | 96,176 | 0 |
| interior | 96,176 | 0 |
| boundary | 96,176 | 0 |
| wrap | 40,992 | 0 |
| combined | 40,992 | 0 |
| reentry cold | 39,328 | 0 |
| reentry hint | 39,328 | 0 |

Reentry-specific observations: **256**, zero failures. All ten dedicated
lifecycle-policy observations satisfy their expected ownership/status behavior.
The controlled two-root test preserves two distinct roots through **360
updates**, with GPU failures **0**, branch jumps **0**, CPU **Contact API**
failures **0**, Contact root mismatches **0**, minimum separation
**0.343925 m**. The separate legacy simple CPU world query fails 137 times;
these are not Contact API failures.

## CPU oracle parity

Existing bounds remain displacement ≤1 mm, velocity ≤1 mm/s, normal ≤0.5°,
world residual ≤1 mm.

| Measurement | Focused 1,280 samples | Legacy 6,912 material samples |
|---|---:|---:|
| Displacement error | max 0.033049 mm (vector) | axis max 0.044213 mm; vector upper bound 0.062758 mm |
| Velocity error | max 0.051472 mm/s (vector) | axis max 0.037671 mm/s; vector upper bound 0.053208 mm/s |
| Normal angle | max 0.027976° | max 0.027976° |
| GPU world residual | max 0.850949 mm | companion 3,072 world queries: max 0.998640 mm |
| CPU focused world residual | max 0.908158 mm | material parity does not invert XZ |

Both regressions pass unchanged checks. The legacy companion world comparison
retains its known simple-CPU limitations: 87 validity disagreements and one
CPU branch mismatch, while GPU failures and owned-branch mismatches are zero.
The required persistent Contact API comparison is the zero-failure controlled
test above. No bounds were relaxed.

## GTX 970 performance — non-target

| Workload | Samples | Mean | p95 |
|---|---:|---:|---:|
| 80 ordinary warm contacts | 20 dispatches | 0.316723 ms | 0.326400 ms |
| 256 ordinary warm contacts | 20 dispatches | 0.328563 ms | 0.412672 ms |
| Matched folded LOCAL recovery | 19 one-contact dispatches | 18.594654 ms | 40.121088 ms |
| Tracked surviving LOCAL recovery subset | 7 one-contact dispatches | 15.890213 ms | 27.383040 ms |
| Original seven near-singular lateral FAILED attempts | 7 one-contact dispatches | 33.877943 ms | 39.182848 ms |

Fold/near-singular timings execute the actual Coastal/critical geometry and
the complete exceptional attempt. They are not multiplied out of the
ordinary benchmark, and are not a target-hardware acceptance result.
Before replay timestamps were unavailable, so no before/after recovery
speedup is claimed. Recovery is expensive even though bounded.

The reserved forced-cardinal validation lane bypasses the new corrections:
80/256 means **1.013056/1.019379 ms**, p95 **1.053440/1.059328 ms**.
It measures the historical lane, not the new folded recovery path.
Ordinary warm means remain in the previous ~0.327/~0.356 ms class.

Across the final observed warm inputs, **99.6454%** succeed with one solve.
Exceptional warm observations are **4,347/1,226,005 (0.3546%)**; within fold,
**4,341/93,559 (4.6399%)**. All ordinary scenario observations use one solve.
The long 80-contact case dispatches 6,525 of 10,000 submissions; the
256-contact case dispatches 2,498. Coalescing is respectively 3,475/7,502.
These counts and latency distributions are preserved in the measurements.
Expensive fold recovery can enlarge executed time gaps; this remains a
material limitation of the proof, not an optimization exercise.

## Async and resource regression

Production rd.sync: **NO**. Blocking readback: **NO**. GPU-owned q history,
one asynchronous buffer readback per result, three ring slots, generation
safety, per-contact validity and the 1,024-slot capacity are unchanged.
No CPU q roundtrip, packet/state expansion or force code is introduced.
Observed generation mismatches, callback errors and dropped validation
captures: **0**. Paused clock remains 83.33333333333 s in both long fixtures.

Owned query buffers remain **10**: three input/control/output slots and one
persistent state buffer. State is **80 bytes/slot**, rich output 128 bytes,
compact output 96 bytes; maximum rich query allocation stays **656 KiB**.
Full-run shutdown: **0 owned buffers, 0 pending, 0 in-flight**.

Telemetry-off resource run: **10,000 submitted**, 6,402 dispatched,
3,598 coalesced; delivery error/mismatch counters are zero. Contact outcomes
are not captured in this run; their regression counts come from the instrumented
full matrix. Metric sample counts stay zero, buffer/state-buffer counts stay 10/1 throughout, and shutdown
returns 0/0. Godot static memory grows during warm-up from 146,190,638 bytes,
then from 155,566,974 at tick 1,000 to 155,648,203 at tick 9,000
(**81,229 bytes**, about 79.3 KiB). This is a finite observed process-memory
trend; it is not a mathematical proof of asymptotic allocation behavior.
No query RID growth is observed.

**Four retirement/reload cycles PASS.** Each deliberately retires with one
in-flight query, then reaches zero owned buffers and zero in-flight work.
Errors/mismatches and retained metric/trace records are zero in every cycle.
Post-retirement static memory is 124,351,774 / 124,354,890 / 124,356,270 /
124,357,674 bytes. Dedicated occupant/inactivity tests and the controlled
two-root continuation pass; no state leakage is observed.

Runtime startup emits certificate-store and sandboxed MCP registry warnings.
Those are unrelated to the physics checks. Final shader import and all
reported GPU runs complete successfully; interrupted development runs are
excluded from these measurements.

## Files changed, commits and delivery

Runtime:
- `addons/ocean/physics/gpu/ocean_surface_query.glsl`.

Validation:
- `validation/physics/phys_gpu12_runner.gd` and
  `validation/physics/phys_gpu12_diagnostics.gd`.
- `PHYS-GPU-1.1-FAILURES.csv.import`: keep the diagnostic CSV from being
  imported as translations; the original CSV remains unchanged.
- `PHYS-GPU-1.2-CPU-CONTACT-AUDIT.md`, `CONTACT-CONTRACT.md`,
  `CPU-REPLAY.json`, `ROOT-STUDIES.json`, `CONNECTED-STUDIES.json`,
  `CORRECTOR-COMPARISON.json`, `GPU-REPLAY.json`, `LATERAL-STUDIES.json`,
  `SUBSTEP-INVESTIGATION.json`, `FAILURES.json`, `MEASUREMENTS.json`
  and this report, all under `validation/physics` with the full phase prefix.

Logical commits:

- **3bf3831** — Replay folded contacts and capture execution history.
- **0be65a5** — Stabilize folded GPU contact correction.
- **Validate folded ocean contact ownership** — final report/evidence milestone.

Final delivery: pushed to **origin/wip/phys-gpu-1**, worktree clean,
remote HEAD matches local HEAD. Verification follows the final report milestone.
Protected `wip/phys-opt-2` remains
`df4f5eca68c1d5918cd6bfd4e6f6cfb08c1260e7`; master remains
`fe6df4d4ce8dcafe05d176f1f312eaa4c9332dbf`. No merge is performed.

## Architectural status and remaining closure

**NOT READY for PHYS-GPU-2.** Numerical correction makes measurable progress,
but ownership closure is incomplete. Required next work is to resolve the two
regular tracked failures without permitting sheet jumps, classify the remaining
warm failures using executed histories and sufficiently strong local topology
evidence, calibrate the conditioning policy, and establish the intended cold
physical sheet contract. Historical time-varying field/branch evidence and full
previous Jacobian are absent from normal GPU state; current-snapshot homotopy
cannot by itself certify time ownership.

Only a later PASS would authorize proposing PHYS-GPU-2. No PHYS-GPU-2,
PHYS-GPU-3 or PHYS-4 work is included here.

## Reproduction

Run sequentially with the same real renderer, after importing the shader:

```powershell
& $godot --headless --editor --path . --import
& $godot --path . --script validation/physics/phys_gpu12_runner.gd
& $godot --path . --script validation/physics/phys_gpu12_runner.gd -- --resource-only
& $godot --path . --script validation/physics/phys_gpu1_runner.gd -- --matrix-only
& $godot --path . --script validation/physics/phys_gpu1_lifecycle_runner.gd
```

Here `$godot` is the Godot 4.7.1 console executable. Raw scratch JSON/logs
remain under ignored `.godot/`; the checked-in evidence above preserves the
reviewable results. Diagnostic replay modes are implemented in
`phys_gpu12_diagnostics.gd`; before/after data must use the corresponding
shader commits and the same reconstructed predecessor inputs.
