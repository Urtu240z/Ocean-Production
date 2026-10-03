# PHYS-GPU-1.1 — robust GPU warm inversion and contact stress

**Status: PARTIAL. GPU authoritative contact-query path: NOT READY for PHYS-GPU-2.**

The persistent contact state, bounded continuation, per-contact failure ABI and asynchronous lifetime contract are implemented and validated. All 1,280 matched physical oracle samples and the legacy parity regression passed. The two known folded roots remained distinct for 360 controlled updates; the validated CPU Contact API and GPU both had zero failures and zero root mismatches there.

The acceptance gate is still open: the full trajectory suite captured **1,742 warm failures and 1,284 cold failures**. Of the warm failures, 1,735 are at the authored folded-mask trajectory and seven are lateral motion near a degenerate horizontal Jacobian in the high-choppiness state. No failed target has been proved physically rootless. Full-stress silent branch-jump freedom is not certified. These cases are not averaged away or called invalid ocean targets.

No buoyancy, damping, drag, force/torque reduction, Jolt integration, pose prediction, latency extrapolation, PHYS-GPU-2 or PHYS-4 work is included.

## Scope and reproducible evidence

Starting branch: `wip/phys-gpu-1`; starting commit: `4942b58629200fe8c0ce8cdea8598a97c3ee65a2`, verified before edits. Implementation milestone: `b3765e1` (Keep ocean contact history and bounded continuation on GPU). The evidence/report milestone follows this commit. Only this branch is committed/pushed; protected branch refs are not modified.

Development system: Intel i7-5820K, NVIDIA GTX 970, Godot 4.7.1 official `a13da4feb`, Forward+, D3D12. **All timings are DEVELOPMENT ONLY — NON-TARGET.** The i7-13650HX / RTX 4070 Laptop target has not been measured.

Reviewable files:

- [Contact contract](PHYS-GPU-1.1-CONTACT-CONTRACT.md): state, ABI, identity, ownership, bounded recovery and lifetime.
- [Measurements](PHYS-GPU-1.1-MEASUREMENTS.json): baseline replay, every layout, combined counts, probe records, final focused oracle/benchmarks, telemetry-off resources and reload regression.
- [Every failed active contact](PHYS-GPU-1.1-FAILURES.csv): all 3,026 final stress failures, including superseded callbacks.
- [Earlier radius-bound diagnosis](PHYS-GPU-1.1-BOUND-DIAGNOSTICS.json): intermediate four-metre bound experiment, not final acceptance data.
- `phys_gpu11_baseline_runner.gd`: unchanged legacy solver/generator diagnostic replay.
- `phys_gpu11_runner.gd`: deterministic persistent query proof with full, focused and telemetry-off modes.

The raw main runner JSON's `aggregate` is its last trajectory only. The checked-in measurements' `combined_trajectory_counts` explicitly combines all eight short matrix cases and both long cases. No final count is inferred from that last-case aggregate.

Use the desktop console executable with actual Forward+ rendering, not `--headless`:

```powershell
$gpu11Godot = 'C:\Users\Eric\Desktop\Godot_v4.7.1-stable_win64_console.exe'
& $gpu11Godot --path . --log-file .godot/phys_gpu11_baseline.log --script validation/physics/phys_gpu11_baseline_runner.gd
& $gpu11Godot --path . --log-file .godot/phys_gpu11_final.log --script validation/physics/phys_gpu11_runner.gd
& $gpu11Godot --path . --log-file .godot/phys_gpu11_focused.log --script validation/physics/phys_gpu11_runner.gd -- --focused-only
& $gpu11Godot --path . --log-file .godot/phys_gpu11_resource.log --script validation/physics/phys_gpu11_runner.gd -- --resource-only
& $gpu11Godot --path . --log-file .godot/phys_gpu11_legacy_matrix.log --script validation/physics/phys_gpu1_runner.gd -- --matrix-only
& $gpu11Godot --path . --log-file .godot/phys_gpu11_lifecycle.log --script validation/physics/phys_gpu1_lifecycle_runner.gd
```

Raw JSON/logs and the inspected viewport PNG remain under ignored `.godot/`. The checked-in JSON/CSV preserve the reviewable results without relying on those local files. Tests completed with exit code zero. Main full status was PARTIAL; final focused checks were empty; legacy matrix and reload tests were PASS. Sandbox startup certificate/MCP registry-write warnings are distinct from query, shader and D3D12 execution errors.

## Original 3.28% population: diagnosis before runtime edits

PHYS-GPU-1 retained the aggregate original failures, not enough per-contact historical records to reconstruct the exact 18,665-member population retrospectively. This limitation is explicit. Before changing runtime/solver code, the diagnostic runner replayed the original generator and unchanged legacy inversion on the same development hardware for 10,000 ticks. Its comparable population was **18,447 / 564,632 world queries = 3.2671%**.

| Replay class | Queries | Failures | Failure rate |
| --- | ---: | ---: | ---: |
| cold | 329 | 10 | 3.0395% |
| warm | 564,303 | 18,437 | 3.2672% |
| region/open | 115,154 | 0 | 0.0000% |
| region/interior | 113,914 | 5 | 0.0044% |
| region/boundary | 113,914 | 0 | 0.0000% |
| region/mask | 110,210 | 18,442 | 16.7335% |
| region/wrap | 111,440 | 0 | 0.0000% |
| folded_final | 12,023 | 8,240 | 68.5353% |
| nonfolded_final | 552,609 | 10,207 | 1.8471% |
| transition | 18,696 | 933 | 4.9904% |
| steady | 545,936 | 17,514 | 3.2081% |

Classifications overlap: warm/cold, region, final determinant and weather are separate views of the same population. “Folded final” is the determinant at the terminal iterate, not proof of which physical branch the target owned.

Almost all replay failures were at the mask: 18,442 of 18,447. Open, boundary and wrap groups had none; five were in Coastal interior. This was predominantly warm-history failure, not a cold-only problem: 18,437 warm versus ten cold. The original generator alternates material/world queries and batch sizes; warm CPU seeds can be old, and the generator keeps its warm flag after failure. Warm seed age across all warm inputs was mean 6.153 ticks, p50 4, p95 8, p99 56, max 952. This is not a continuously updated GPU history at every executed 60 Hz contact query.

Replay failure residual: mean 0.307871 m, p50 0.140935 m, p95 1.108174 m, p99 1.780028 m, max 4.210681 m. Iterations: mean 5.535, p50 5, p95/p99/max 12. Calm/storm/returned-calm configurations contributed 1,897 / 12,562 / 3,988 failures respectively.

Five representative failure classes were tested with 18 nearby legacy GPU seeds at the same reconstructed snapshot. They found 2, 4, 8, 5 and 3 valid roots respectively. This establishes numerical/seed-basin failures for those probes, not physically invalid targets. It does not prove all failed targets have a reachable owned branch. The evidence motivated GPU-owned history and guarded continuation rather than a tolerance or ocean-quality concession.

## GPU contact state and generation safety

The new opt-in API is `pack_contacts` / `submit_contacts`. Legacy material/world inputs and 96/64-byte outputs remain compatible.

One zero-initialized GPU SSBO contains 1,024 stable slots, **80 bytes/slot**:

| State | Meaning |
| --- | --- |
| FP64 q | Owned/last-good material coordinate |
| FP64 previous target | World target at previous executed query |
| owner uvec4 | Vehicle, contact, occupant generation, active |
| stamp uvec4 | Ocean epoch, last request generation, status, valid |
| motion vec4 | Previous horizontal water velocity, sample time, local Jacobian |

Identity is independent of packet order. The caller changes occupant generation on reuse/removal; vehicle/contact IDs also participate in matching. Ocean epoch changes invalidate old ownership. Weather changes alone do not.

Activation with no valid ownership is cold. An inactive descriptor clears ownership and preserves only a non-owned hint. Absence from a packet does not mean deactivation. Teleport/reset clears ownership. Same-occupant hint retention uses the GPU-held q; a new occupant cannot inherit another vehicle's hint. Known-root initialization is explicit `owned_seed` for validation/import and is not ordinary cold activation.

Invalid input fails only its contact. Duplicate slots, out-of-capacity slots, malformed persistent modes, missing control buffers and production use of the reserved timing lane are rejected before dispatch. Allocation checks include the control buffers. Rich persistent output is 128 bytes/contact, compact 96; status/recovery diagnostics append to the original payload. Statuses are CONTINUED, REACQUIRED_LOCAL, COLD_ACQUIRED, FAILED. FAILED always has validity zero and clears ownership; there is no “best invalid” success.

The query reads the existing authoritative LONG/MID/SHORT Production displacement/velocity/derivative textures and Coastal field/warp. No second ocean FFT, physics ocean, runtime CPU solver or blocking readback is introduced. The native shared-spectrum producer used in the existing validation fixture supplies Production FFT input and the CPU oracle; it is not an independently evolved runtime physics-weather path. CPU FFT Mirror, DirectSpectral and CPU Contact API sources remain unchanged.

## Warm continuation, local recovery and cold acquisition

For each executed query, the primary warm seed comes from GPU state. Readback/CPU consumption never updates it. Primary iteration limit is 16; backtracking has 12 trials; local horizontal derivative stencil is 0.0001 m. Physical residual remains **1 mm**, with the existing displacement/velocity/normal contracts preserved.

The warm radius accounts for inverse-Jacobian amplification, target motion, water velocity/time delta, current displacement and previous displacement, with a 0.1 m minimum. Newton candidates remain in that local guard and preserve the owned Jacobian orientation at candidate/midpoint. There is no projection/clamping of q, residual forgiveness, reduced choppiness, changed Coastal feather or global smallest-q selection.

An early fixed four-metre ceiling incorrectly lost ordinary roots more than four metres away. Diagnostic probes found roots at approximately 4.01–4.36 m and a lateral root much farther away. The final radius has no arbitrary four-metre ceiling; ordinary acceleration/fast-motion failures disappeared in the final run. The remaining seven lateral failures approach a singular Jacobian despite radius about 9–16 m. This is a guarded continuation/caustic problem, not a demonstrated radius-bound rejection.

On primary failure, four cardinal seeds are tried. Warm seeds are at min(radius/2, 0.25 m) around previous q and retain ownership guards. Among valid local roots, the closest q to previous ownership wins. Cold seeds use the target with radius clamp(|D(target).xz|/2, 0.25 m, 1.5 m). Maximum five solves/contact; recovery never scans globally.

Reason codes are numerical facts: 1 nonfinite, 2 near-singular Jacobian, 3 no accepted guarded descent, 4 iteration limit, 5 owned orientation changed, 6 inactive. Reason 3 can combine descent and branch-guard rejection; it does not distinguish them perfectly. Neither these codes nor a bounded seed probe prove no physical root exists. Candidate/midpoint orientation guards are also not a mathematical certificate of global branch uniqueness.

## Trajectories, layouts and 60 Hz evolution

Historical four-point hull layout remains XZ (-0.45,-1.15), (0.45,-1.15), (-0.50,1.05), (0.50,1.05). Synthetic 8/16-point validation layouts use two rails ±0.48 m with evenly spaced longitudinal samples from -1.15 to 1.05 m. Production hull/force source is not changed.

All packets contain the full contact set in **one query dispatch**, 64 invocations/workgroup. No dispatch is issued per vehicle. Capacity is reused when layout/count changes.

| Vehicles x contacts | Physics ticks | Executed batches | Active contact results | Warm inputs | Warm failed | Cold failed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1x4 | 240 | 240 | 960 | 956 | 0 | 0 |
| 1x8 | 240 | 240 | 1,920 | 1,912 | 0 | 0 |
| 1x16 | 240 | 240 | 3,840 | 3,824 | 0 | 0 |
| 4x8 | 240 | 240 | 7,680 | 7,648 | 0 | 0 |
| 6x8 | 240 | 240 | 11,520 | 11,472 | 0 | 0 |
| 10x8 | 240 | 238 | 19,040 | 18,898 | 18 | 44 |
| 10x16 | 240 | 147 | 23,520 | 23,317 | 32 | 13 |
| 16x16 | 240 | 85 | 21,728 | 21,435 | 29 | 9 |
| 10x8 | 10000 | 9741 | 779,280 | 778,025 | 574 | 601 |
| 16x16 | 10000 | 3205 | 816,224 | 813,495 | 1089 | 617 |

Single-vehicle short cases exercise stationary hulls; larger cases mix scenarios by vehicle. The 16x16 long case covers all scenarios, including reentry. “Physics ticks” counts submissions; latest-mailbox coalescing means not every submitted pose executes on this instrumented development run.

Simulation time advances by exact 1/60 s, stopping for ticks 5000–5199 in both long runs. Target poses are generated from that simulation time. Scenarios include stationary, 2 m/s slow, 24 m/s fast, sinusoidal acceleration/deceleration, yaw/turning, lateral motion, crest crossing, Coastal interior, authored feather boundary, known folded mask, periodic wrap crossings, combined translation/yaw and simulated airborne reentry. The wrap path crosses the nested LONG/MID/SHORT periodic domains during the long sequence.

Combined active result accounting:

| Scenario | Updates | Continued | Local recovered | Cold acquired | Failed | Failure rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| stationary | 198,024 | 197,884 | 0 | 140 | 0 | 0.0000% |
| slow | 191,304 | 191,192 | 0 | 112 | 0 | 0.0000% |
| fast | 138,664 | 138,584 | 0 | 80 | 0 | 0.0000% |
| acceleration | 138,664 | 138,584 | 0 | 80 | 0 | 0.0000% |
| turning | 136,744 | 136,672 | 0 | 72 | 0 | 0.0000% |
| lateral | 136,744 | 136,657 | 1 | 79 | 7 | 0.0051% |
| crest | 134,824 | 134,760 | 0 | 64 | 0 | 0.0000% |
| interior | 134,824 | 134,760 | 0 | 64 | 0 | 0.0000% |
| boundary | 134,824 | 134,760 | 0 | 64 | 0 | 0.0000% |
| fold | 134,824 | 127,259 | 2751 | 1795 | 3019 | 2.2392% |
| wrap | 52,640 | 52,608 | 0 | 32 | 0 | 0.0000% |
| combined | 52,640 | 52,608 | 0 | 32 | 0 | 0.0000% |
| reentry_cold | 50,496 | 50,080 | 0 | 416 | 0 | 0.0000% |
| reentry_hint | 50,496 | 50,080 | 0 | 416 | 0 | 0.0000% |

Across all ten cases: **1,685,712 active results**, 1,680,982 warm inputs, 1,676,488 continued, 2,752 locally recovered, 3,446 cold acquired, 3,026 failed. Warm success is 1,679,240 / 1,680,982; warm failure rate 0.1036%. This rate is reported alongside every failure class, not used to excuse them. Outside the folded-mask scenario, seven of 1,549,237 warm inputs failed. The 1,651 non-fold cold attempts all succeeded; folded-mask cold attempts succeeded 1,795 / 3,079. Overall cold success is 3,446 / 4,730 (72.854%). That mask cold failure population remains material and unresolved.

## Every failure, explicitly classified

| Region/path | Termination | Count |
| --- | --- | ---: |
| Fold, cold acquisition | No accepted descent (3) | 1,148 |
| Fold, cold acquisition | Iteration limit (4) | 136 |
| Fold, warm + attempted local recovery | No accepted guarded descent (3) | 1,708 |
| Fold, warm + attempted local recovery | Orientation changed (5) | 23 |
| Fold, warm + attempted local recovery | Iteration limit (4) | 4 |
| Lateral, warm + attempted local recovery | No accepted guarded descent (3) | 7 |

All other active trajectory classes have zero observed failures. Intentional inactive outputs and the focused NaN input are separately tested and are not counted as failed active physical queries.

The CSV captures case/layout, request generation, vehicle/contact/slot, tick/simulation time, target world XZ, previous/final q, residual, total iterations/solve count, reason, owned input, scenario/region, configuration/alpha/weather, pause flag, local radius and terminal determinant. Coordinates are FP32 readback diagnostics; internal history is FP64. Warm failed residual range is 0.0010386–0.3871344 m, maximum total iterations 49. Cold failed range is 0.0025375–3.5493119 m, maximum total iterations 75. These are explicit invalid outputs, never silently accepted.

The final diagnostic suite selects 26 scenario/ownership/reason/config classes and tries 18 unguarded legacy GPU seeds per selected failure at a reconstructed matched weather snapshot, plus the CPU warm world solver. Seventeen classes find at least one valid root. Nine bounded probes find none; this is insufficient evidence of no root. Example: the lateral failure at t=133.633333 s, config 6, has nine valid legacy seeds, nearest root 4.235387 m from previous q, and a valid CPU warm result with residual 0.273038 mm. The persistent guard cannot establish ownership of that root. Terminal lateral Jacobians are near zero (about 0.000047–0.00247, with one negative terminal value), so no physically-invalid-target classification is claimed.

Probes diagnose classes, not every exact failed target independently. All 1,742 warm failures remain unresolved with respect to physical owned-branch availability; 1,284 cold mask failures remain unresolved acquisition cases. There is no proof permitting PASS.

## Weather and pause/resume

Both long runs use current, current→calm, calm→storm, storm→calm, calm→direction and direction→choppiness sequences. Transitions last three simulation seconds. Choppiness reaches 2.5 in the stress fixture; production profiles/surface geometry are not reduced to obtain these results. Configuration versions 1–6 refer to those successive segments, including their steady endpoints.

| Configuration segment | Active updates | Local recovered | Failed | Failure rate |
| --- | ---: | ---: | ---: | ---: |
| config/1 | 255,872 | 387 | 500 | 0.1954% |
| config/2 | 159,088 | 209 | 83 | 0.0522% |
| config/3 | 319,344 | 394 | 484 | 0.1516% |
| config/4 | 321,376 | 543 | 218 | 0.0678% |
| config/5 | 316,672 | 644 | 771 | 0.2435% |
| config/6 | 313,360 | 575 | 970 | 0.3095% |

There are 301 failures / 122,720 active results during non-endpoint weather blends and 2,725 / 1,562,992 at steady alpha endpoints. Counts overlap the region/path categories above. No history reset is issued at weather changes.

During both pauses, captured central-pause samples remain at **83.3333333333299 s** (14,080 and 17,792 active samples respectively). Zero failure records are paused. No pause reset is issued and GPU history is retained for resume. The harness records frozen physical time and active validity, but does not retain a separate per-slot pause-status trace proving every q was bit-identical; do not infer a stronger global branch certificate from pause validity.

## Reentry, ownership and per-contact isolation

Cold policy and retained non-owned GPU hint policy both pass explicit 1/5/30-tick inactive intervals in the focused test. Each reentry returns valid COLD_ACQUIRED, with owned-input false. Cold reentry residual was 0.0009864 mm; hint results were at most 0.086808 mm. Both policies are exposed rather than silently treating airborne history as owned.

In asynchronous gameplay stress, observed reentry counts for each policy are 112 after one tick, 96 after five ticks, 80 after thirty ticks; **zero failures in all six categories**. Some reentry submissions coalesce; the counts are executed/captured events. Slot reuse, changed vehicle/contact generation and same-identity teleport reset all reacquire without old ownership. In a mixed packet, an inactive contact is invalid and its active neighbour remains valid. A NaN contact reports FAILED/reason 1 while the neighbour succeeds. Duplicate slots and persistent packets missing controls are rejected.

Use explicit reset for teleport and occupant generation changes for reuse. Hint policy preserves a useful acquisition seed; it does not preserve branch ownership. Cold policy is the conservative option when movement invalidates that hint. No force consumer policy is implemented in this phase.

## Branch continuity and CPU oracle parity

A known folded target at (393.4588,-992.3107), wave time 2.25 s, starts GPU and CPU Contact API on the same two independently initialized material roots. For 360 controlled updates with small target motion: **GPU failures 0, branch jumps 0; CPU Contact API failures 0, root mismatches 0**. Minimum root separation is 0.343925 m. GPU final roots stay on their respective branches. The older simple CPU world API fails 137 of those controlled updates; when it succeeds, it agrees. The validated Contact API is the appropriate branch comparison and is reported separately.

The complete weather/trajectory stress does not have a certified root label for every contact after a caustic/fold degeneracy. Full-stress silent branch jumps are **unproven**, not reported as zero. Nearest-q recovery and orientation guards reduce branch switching but do not establish a global topological guarantee.

The final focused ordinary oracle matrix has 1,280 samples (16 contacts x 16 successive 1/60 s times x five states), using eight open and eight Coastal-interior material seeds. CPU and GPU start on the same known root and thereafter maintain independent histories. Exact matched snapshots are awaited only by the validation harness. CPU outputs are not used to advance runtime GPU contact state.

Physical bounds are 1 mm displacement, 1 mm/s velocity, 0.5° normal, 1 mm world residual. No bounds were loosened. Table entries are maxima, using vector norm for displacement/velocity and degrees for normal:

| State | Samples | q GPU–CPU mm | q known mm | Displacement mm | Velocity mm/s | Normal deg | GPU residual mm | Invalid GPU/CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| current | 256 | 1.0448 | 0.8878 | 0.0190 | 0.0515 | 0.0198 | 0.8509 | 0/0 |
| calm | 256 | 0.2289 | 0.4151 | 0.0030 | 0.0159 | 0.0280 | 0.4058 | 0/0 |
| storm | 256 | 0.3146 | 0.2879 | 0.0299 | 0.0397 | 0.0198 | 0.3802 | 0/0 |
| direction | 256 | 1.0573 | 0.2289 | 0.0253 | 0.0223 | 0.0280 | 0.1924 | 0/0 |
| choppiness | 256 | 0.6291 | 0.2730 | 0.0330 | 0.0275 | 0.0280 | 0.1911 | 0/0 |

Both solvers can accept different q within their individual world-residual tolerance; q GPU–CPU max is 1.057270 mm, while known-root error is below 0.888 mm. This is not reported as exact q equality. All displacement/velocity/normal/residual checks and validity comparisons pass.

Legacy parity regression: PASS, 135 grouped rows / 6,912 material samples, steady and transition snapshots; maximum displacement components 0.044214 / 0.022520 / 0.038427 mm, velocity components 0.031517 / 0.020464 / 0.037671 mm/s, normal 0.027977°. Open without Coastal and legacy multiple-root continuation also pass the scene lifecycle runner. Legacy solver/material-surface blocks and the CPU/native oracle implementations are unchanged in this phase.

## Cold acquisition and recovery measurements

The final focused cold benchmark uses an ordinary open cluster at current weather/time 2.25 s, resets ownership on every query and checks all outputs. All **14,640 / 14,640** cold contacts succeed. Warm and forced-local samples at the same cluster are also all valid; forced-local results are REACQUIRED_LOCAL, warm results CONTINUED. The local timing lane is validation-only and deliberately bypasses primary continuation; it is not a measured natural recovery frequency.

| Contacts/batch | Cold valid / tested | Iterations mean / max | Residual mean / max mm |
| --- | ---: | ---: | ---: |
| 4 | 80 / 80 | 3.000 / 3 | 0.0093 / 0.0913 |
| 8 | 160 / 160 | 3.000 / 3 | 0.0142 / 0.2916 |
| 32 | 640 / 640 | 3.019 / 4 | 0.0489 / 0.8662 |
| 64 | 1280 / 1280 | 3.027 / 4 | 0.0647 / 0.9839 |
| 80 | 1600 / 1600 | 3.024 / 4 | 0.0882 / 0.9839 |
| 128 | 2560 / 2560 | 3.026 / 4 | 0.0973 / 0.9839 |
| 160 | 3200 / 3200 | 3.030 / 4 | 0.1017 / 0.9839 |
| 256 | 5120 / 5120 | 3.002 / 4 | 0.1035 / 0.9904 |

Iteration summaries count accepted Newton steps and sum work across seeds; zero iterations means an already acceptable seed. Cold success here does not remove the unresolved mask acquisition population. Natural local recovery succeeded 2,752 times in the trajectory suite, almost entirely at the folded-mask scenario.

## GTX 970 performance — DEVELOPMENT ONLY, NON-TARGET

Twenty repetitions per size and mode after warm pre-acquisition where appropriate; timings are query timestamp intervals, excluding the preceding authoritative FFT. CPU submit/consume values measure wrapper calls, excluding contact packet construction, oracle work and CSV/JSON/histogram capture. Consume distributions include polling calls, not only successful decodes. Full distributions and sample counts are in the measurements.

| Contacts | Mode | GPU µs mean / p95 | Submit µs mean / p95 | Consume µs mean / p95 | Async ms mean / p95 | Ticks mean / p95 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 4 | warm | 329.7 / 341.5 | 20.9 / 35.0 | 8.8 / 21.0 | 16.01 / 16.47 | 0.95 / 1 |
| 4 | local (forced) | 1049.1 / 1091.3 | 18.5 / 33.0 | 8.5 / 22.0 | 16.63 / 16.91 | 1.00 / 1 |
| 4 | cold | 328.6 / 289.8 | 25.1 / 36.0 | 10.2 / 23.0 | 15.89 / 16.51 | 1.00 / 1 |
| 8 | warm | 329.7 / 341.8 | 28.9 / 42.0 | 10.1 / 21.0 | 16.17 / 16.47 | 1.00 / 1 |
| 8 | local (forced) | 1059.6 / 1192.7 | 23.8 / 36.0 | 8.6 / 21.0 | 16.53 / 16.96 | 1.00 / 1 |
| 8 | cold | 327.8 / 289.5 | 22.9 / 37.0 | 8.8 / 21.0 | 15.87 / 16.48 | 1.00 / 1 |
| 32 | warm | 343.0 / 443.9 | 49.3 / 72.0 | 10.0 / 22.0 | 15.26 / 15.85 | 1.00 / 1 |
| 32 | local (forced) | 1084.7 / 1195.8 | 42.4 / 93.0 | 9.8 / 22.0 | 16.28 / 16.87 | 1.00 / 1 |
| 32 | cold | 361.8 / 334.6 | 45.9 / 92.0 | 9.4 / 23.0 | 15.31 / 16.05 | 1.05 / 1 |
| 64 | warm | 334.4 / 408.3 | 86.3 / 108.0 | 11.9 / 23.0 | 14.87 / 15.44 | 1.00 / 1 |
| 64 | local (forced) | 1074.8 / 1145.6 | 70.2 / 104.0 | 10.4 / 23.0 | 15.76 / 16.57 | 1.00 / 1 |
| 64 | cold | 360.4 / 329.2 | 83.3 / 157.0 | 11.0 / 26.0 | 14.45 / 15.40 | 1.00 / 1 |
| 80 | warm | 327.3 / 405.2 | 93.2 / 125.0 | 10.6 / 22.0 | 14.58 / 15.27 | 1.00 / 1 |
| 80 | local (forced) | 1072.9 / 1142.3 | 96.6 / 192.0 | 10.8 / 25.0 | 15.29 / 16.05 | 1.05 / 1 |
| 80 | cold | 346.1 / 325.4 | 85.8 / 124.0 | 9.4 / 17.0 | 14.43 / 15.26 | 1.00 / 1 |
| 128 | warm | 328.3 / 407.3 | 147.8 / 281.0 | 11.0 / 23.0 | 13.54 / 14.57 | 1.00 / 1 |
| 128 | local (forced) | 1070.9 / 1138.9 | 152.6 / 183.0 | 12.3 / 24.0 | 13.69 / 15.26 | 1.05 / 1 |
| 128 | cold | 348.7 / 325.6 | 133.4 / 186.0 | 12.3 / 23.0 | 13.39 / 14.66 | 1.00 / 1 |
| 160 | warm | 343.7 / 411.6 | 189.5 / 348.0 | 11.9 / 24.0 | 12.92 / 14.59 | 1.05 / 1 |
| 160 | local (forced) | 1105.0 / 1262.8 | 119.9 / 197.0 | 8.0 / 14.0 | 14.65 / 15.62 | 1.00 / 1 |
| 160 | cold | 348.2 / 324.1 | 134.4 / 223.0 | 7.5 / 14.0 | 13.81 / 14.55 | 1.00 / 1 |
| 256 | warm | 356.0 / 419.3 | 185.3 / 497.0 | 7.3 / 17.0 | 12.92 / 13.79 | 1.00 / 1 |
| 256 | local (forced) | 1124.3 / 1260.5 | 182.3 / 290.0 | 7.1 / 19.0 | 13.56 / 14.45 | 1.05 / 1 |
| 256 | cold | 343.5 / 325.4 | 180.7 / 329.0 | 7.1 / 20.0 | 12.76 / 13.84 | 1.00 / 1 |

Warm incremental query mean is about 0.327–0.356 ms. Forced four-seed local recovery is about 1.049–1.124 ms. Cold mean is about 0.328–0.362 ms on this open cluster. Existing ocean GPU interval in the full instrumented run averages 2.477 ms (capped metric history). GPU timings are not the complete render frame or an RTX 4070 Laptop prediction.

The long 80-contact run executes 9,741 of 10,000 submissions; callback latency mean 25.920 ms, p95 34.805 ms; consumed latency mean 1.901 ticks, p95 2, max 4. The instrumented 256-contact run executes 3,205; callback latency mean 55.166 ms, p95 69.144 ms, max 114.090 ms; consumed latency mean 4.126 ticks, p95 5, max 7.

Full per-contact capture, native validation-spectrum publication and CPU histograms strongly affect throughput/coalescing on this machine. With telemetry disabled, the separate 256-contact resource run executes 9,517 of 10,000 submissions. Do not attribute the instrumented coalescing entirely to query GPU time or claim a reliable one-tick pipeline. PHYS-GPU-3 latency/prediction is not started.

## Asynchronous delivery, renderer and lifetime

Production global sync: **NO**. Blocking per-tick buffer readback: **NO**. Persistent q CPU round trip: **NO**. Query commands follow authoritative ocean work on the global RenderingDevice; successive GPU invocations read the previous state writes. Readback callbacks only deliver bytes.

Main instrumented totals: 22,789 submissions, 15,485 executed/completed batches, 7,304 coalesced pending submissions, 1,398 superseded completed results, 14,087 consumed results. Max in-flight 2 within ring capacity 3; final pending/in-flight zero. Generation/config mismatches, query errors, target-time rejections and validation capture overflows are all zero. Validation capture includes every coherent persistent completion even if normal latest consumption supersedes it. CPU consumption is deliberately withheld for ten ticks every thousand without inserting q from readback into normal packets.

The 256-contact long case has 816,224 active outputs: 810,787 continued, 1,619 locally recovered, 2,112 cold acquired, 1,706 failed. Its warm failures are 1,089; cold failures 617. Data is not whole-batch invalidated by an individual failed contact.

Actual Production ocean rendering ran during both long cases. No query shader errors, D3D12 runtime errors, generation corruption or oracle evidence of FFT texture corruption occurred. The inspected viewport image shows the rendered ocean/horizon, but is dark and is not a quantitative full-feature visual acceptance test. No automated frame-by-frame flicker analysis was performed. The proof fixture disables breakers/crest/surface foam; it therefore does not certify those downstream features. Borrowed authoritative textures remain alive for rendering, and no global synchronization is added.

At fixed capacity there are three 32-byte input / 32-byte control / 128-byte output triplets plus an 80 KiB state buffer: **10 storage buffers, 656 KiB total**. Count changes allocate no new query buffers. Uniform sets can be rebound for new texture generations; they are released with the token. Callback lifetime holds a RefCounted token, not an Ocean node. Shutdown retires the token and frees GPU resources only after in-flight callbacks drain.

Telemetry-off 256-contact resource proof:
- 10,000 submissions, 9,517 completed, 483 pending submissions coalesced.
- 7,280 consumed, 2,237 superseded results; max in-flight 2.
- Errors/mismatches/overflow zero; buffer count remains 10 / one state buffer.
- Static memory 145,885,713 bytes initially, 155,265,129 after warm-up at tick 1000. Ticks 1000–9000 range 155,265,129–155,281,853 bytes: 16,724-byte spread. This shows a plateau over this run, not a proof of lifetime-wide zero CPU allocation.
- Rich telemetry, trace and completion capture disabled; metric arrays empty. Numerical contact failures and latency were **not measured** by this resource-only run.
- After shutdown: zero query buffers, zero state buffers, zero in-flight callbacks.

Four additional scene reload/retirement cycles each retire with one callback in flight, then end with zero buffers/in-flight, no errors/mismatches, no telemetry/trace accumulation. Static memory rises only 5,900 bytes across the four reload samples. Instrumented stress memory grows with the intentionally retained failure/diagnostic evidence; it is not presented as normal runtime memory. Live shader hot replacement is not certified; retirement/recreation is the documented reload contract.

## Files, commits and disposition

Runtime changes are confined to `addons/ocean/physics/gpu/ocean_surface_query.gd` and `ocean_surface_query.glsl`. The added validation runner, baseline replay, contact contract, radius diagnosis, measurement bundle, complete CSV and this report form the evidence milestone. CPU Mirror/DirectSpectral/native/contact, Production ocean spectrum/Coastal source, historical hull source and prior phase reports remain unchanged. Structural graph tools were unavailable (Transport closed); actual source reads/diffs and runtime regressions were used, so no completeness claim is based on the unavailable graph.

Commit 1: `b3765e1`, GPU-owned contact history and bounded continuation.
Commit 2: evidence/report milestone, `Stabilize GPU ocean contact continuation`; its hash is available in branch history. The requested delivery is `origin/wip/phys-gpu-1`, with a clean worktree after commit/push verification. No merge or protected-branch push is authorized or performed.

**Architectural status: NOT READY for PHYS-GPU-2.** The asynchronous authoritative architecture works, but the contact robustness gate remains PARTIAL. Before forces, resolve the folded-mask ownership/acquisition loss and the seven high-choppiness lateral caustic failures, or establish physical non-continuability for specific targets with stronger branch evidence. Preserve explicit FAILED outputs while those cases remain unresolved; do not silently produce forces from them.

PHYS-GPU-2 is the next phase only after that gate closes and the user requests it: GPU contact forces, per-vehicle force/torque reduction and one batch. PHYS-GPU-3 one-tick pipeline/pose prediction remains later. Existing Crest G / Spindrift clamp disposition and P3D.1/P3E after TIME-1 remain separate roadmap work; no unrelated physics or ocean-quality concession is included here.
