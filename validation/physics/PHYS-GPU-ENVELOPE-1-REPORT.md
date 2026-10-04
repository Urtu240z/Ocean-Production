# PHYS-GPU-ENVELOPE-1 — GPU upper-envelope seed atlas

**BLOCKED. NOT READY FOR PHYS-GPU-2.** Godot can build and consume the GPU atlas coherently. The tested uniform q grid cannot select the physical upper sheet reliably at the tested practical densities. Increasing the grid to 2048² and the atlas to 2048² still leaves six current-field-confirmed wrong-lower results in 16 retained counterexamples. No configuration is accepted. Phase C, target-performance validation and forces remain gated.

Measurements ran on **Intel i7-5820K / NVIDIA GTX 970 / Godot 4.7.1 stable / Forward+ / D3D12**. Engine hash: `a13da4feb8d8aefc283c3763d33a2f170a18d541`. These are development-PC results, not RTX 4070 Laptop measurements.

## Starting source and delivery

| Item | Value |
|---|---|
| Source branch | `wip/phys-gpu-1` |
| Verified source HEAD | `98928f170aa53023c83215376c85990d9cf8a2b4` |
| New branch / sole push destination | `wip/phys-gpu-envelope-1` / `origin/wip/phys-gpu-envelope-1` |
| Worktree | `C:\Users\Eric\Desktop\Ocean-Production` |
| Implementation commit | `8a91c8864bb8d76dd20dd425bddd11e67e93d56c` — Add GPU upper-envelope seed atlas |
| History-contract correction | `cfc4ee277a8e0e29229a056bc8d7db25663e9ceb` — Restrict history to atlas hysteresis window |
| Validation commit | This report's containing commit — Validate rasterized physical ocean envelope |

The source branch, `wip/phys-opt-2` and `master` were preserved. Their recorded heads are respectively `98928f170aa53023c83215376c85990d9cf8a2b4`, `df4f5eca68c1d5918cd6bfd4e6f6cfb08c1260e7`, and `fe6df4d4ce8dcafe05d176f1f312eaa4c9332dbf`. No merge or force work was performed.

## RenderingDevice feasibility — Phase A

**PASS for the required API and GPU ordering.** The native probe used the global RD, a render pipeline, framebuffer, RGBA32F color, D32_SFLOAT depth, instanced drawing, compute sampling and asynchronous output-buffer readback. It drew a high-depth triangle first and a lower-depth triangle second; the latter did not replace the winner. Compute read back `[0, 0.800000011920929, 37, 1]`. Both format-support queries succeeded. Probe errors: **0**; resources after shutdown: **0**.

The running engine's actual method signatures are included in the measurements. The [RenderingDevice documentation](https://docs.godotengine.org/en/4.7/classes/class_renderingdevice.html) and [depth-state documentation](https://docs.godotengine.org/en/4.7/classes/class_rdpipelinedepthstencilstate.html) describe these APIs; the hardware probe establishes availability on this installation. There is no Godot API blocker, CPU atlas roundtrip or full-device synchronization requirement.

## Physical envelope implementation

Mode **5 — PHYSICAL_ENVELOPE_ATLAS** is an explicit opt-in path with its own persistent contact state and readback ring. Historical modes 0–4 remain available. The frozen historical shader is byte-identical to the starting source: SHA-256 `a7608f750628550e877b7e004d53f0f4eaebb2dd05b44d758f12fa6aeb5280ba`.

The dedicated static grid covers a local q patch. Raster and exact query compile the authoritative texture sampling, Coastal transform, derivatives and FP64 refinement functions **verbatim from that shader**. They use the existing LONG/MID/SHORT and Coastal textures on the same global RD. BreakerCarrier is excluded. Neither visual clipmap geometry nor camera state supplies the physical topology. Validation uses a native CPU mirror to reproduce fixtures and measure parity; production mode 5 does not evaluate a CPU ocean.

| Contract | Implementation |
|---|---|
| Output footprint | 16×16 m initial sweep/replay; 8×8 m denser tests |
| Tile pixel resolution tested | 64, 128, 256, 512, 1024, 2048 per axis |
| Static q grid tested | 64, 128, 256, 512, 1024, 2048 cells per axis; two triangles/cell |
| q overscan | World half-footprint plus current GPU displacement bound on each axis |
| Bound derivation | Texture maxima, band sum, Coastal confidence/mixing/shoaling, physical scale and upward slack |
| Atlas content | `(q.x, q.z, world_surface_y, valid)` — RGBA32F, **16 bytes/pixel** |
| Depth | D32_SFLOAT; clear **0**, compare **GREATER_OR_EQUAL**, depth writes enabled |
| Y mapping | `(displacement_y + B.y + 1) / (2 × (B.y + 1))` |
| Supported Y | Sea level ± `(B.y + 1)` m; outside this range clips and would violate the conservative-bound contract |
| Fast query | Nearest actual atlas texel; one exact solve |
| Boundary / failed-fast query | Up to four actual 2×2 texel seeds; no q interpolation across texels |
| Previous q | Optional fifth candidate at a discontinuity, only for 2 mm hysteresis/continuity |
| Solve limits | **≤5 solves/contact; ≤16 iterations/solve**; FP64 unchanged |
| Final world residual | **≤1 mm**, unchanged |
| Final authority | Current-field sample at refined q; raster Y is diagnostic only |
| Signed depth | Final selected surface Y − contact world Y |
| Status | CONTINUED / SHEET_HANDOFF / COLD_ACQUIRED / FAILED, classified after selection |
| Current capacity | **One tile only.** Phase C initialization is gated |

The bound is computed on GPU before rasterization. It does not use a statistical Hs estimate or CPU field readback. For the 49-case dense sweep, bound extrema ranged from `[3.034, 2.346, 2.231]` to `[6.546, 4.029, 5.474]` m across X/Y/Z. With an 8 m tile and q2048, q spacing was **6.87–10.30 mm in X and 6.08–9.25 mm in Z**. The largest sampled `abs(displacement_y)/(B.y+1)` was **0.4321** in that sweep. The five-profile new-mode parity matrix reached **0.1619**. These samples remain well within the depth range; this is a measured subset plus a conservative bound, not a claim that every possible profile was tested.

GPU order is FFT LONG/MID/SHORT → bounds → raster → optional validation-only hole count → exact query → async output readback. Tile descriptors carry query generation, configuration, ocean epoch, time, vehicle identity and occupant generation. The output ABI is **208 bytes rich / 176 bytes compact**, with the prior physical layout followed by atlas diagnostics. No new production root-search rings, expanded iteration budget or historical brute-force fallback is invoked.

## Resolution and q-grid sweeps — Phase B

The initial **15-fixture** set includes archived 7/11/17/34-root examples, wrong-lower, cold, handoff and all lateral seven. Rows below use the same 16 m footprint. Every row had **0 empty atlas pixels and 0 upper-reference-q overscan misses**. Timing is GPU milliseconds.

| Pixels/axis | q cells/axis | Wrong lower | Explicit fail | Raster mean / p95 / max | Query mean |
|---:|---:|---:|---:|---:|---:|
| 64 | 64 | 2 | 1 | 0.071 / 0.087 / 0.087 | 1.779 |
| 64 | 128 | 4 | 0 | 0.241 / 0.300 / 0.300 | 1.203 |
| 64 | 256 | 1 | 0 | 1.020 / 1.431 / 1.431 | 1.059 |
| 64 | 512 | 1 | 0 | 3.642 / 4.553 / 4.553 | 0.884 |
| 128 | 64 | 3 | 0 | 0.073 / 0.088 / 0.088 | 1.536 |
| 128 | 128 | 2 | 0 | 0.244 / 0.307 / 0.307 | 1.016 |
| 128 | 256 | 1 | 0 | 1.097 / 1.772 / 1.772 | 0.925 |
| 128 | 512 | 0 | 0 | 3.645 / 4.557 / 4.557 | 0.899 |
| 256 | 64 | 4 | 0 | 0.082 / 0.097 / 0.097 | 1.326 |
| 256 | 128 | 3 | 1 | 0.254 / 0.332 / 0.332 | 0.831 |
| 256 | 256 | 1 | 0 | 1.087 / 1.494 / 1.494 | 0.745 |
| 256 | 512 | 0 | 0 | 3.658 / 4.574 / 4.574 | 0.697 |
| 512 | 64 | 3 | 2 | 0.107 / 0.123 / 0.123 | 0.766 |
| 512 | 128 | 4 | 1 | 0.270 / 0.345 / 0.345 | 0.695 |
| 512 | 256 | 1 | 0 | 1.125 / 1.626 / 1.626 | 0.658 |
| 512 | 512 | 1 | 0 | 3.690 / 4.635 / 4.635 | 0.507 |

The provisional 128/q512 configuration passed that small subset and therefore entered full replay. Full replay disqualified it. A second sweep used **49 fixtures**, an 8 m footprint, and retained failures from the first replay:

| Pixels | q grid | Wrong / fail | Raster mean / p95 / max, ms | Query mean / max, ms |
|---:|---:|---:|---:|---:|
| 256 | 512 | 8 / 0 | 4.354 / 5.129 / 5.635 | 0.644 / 2.458 |
| 256 | 1024 | 0 / 0 | 17.267 / 18.481 / 18.744 | 0.637 / 3.517 |
| 256 | 2048 | 0 / 0 | 71.449 / 82.652 / 93.236 | 0.577 / 3.672 |
| 512 | 512 | 9 / 0 | 4.306 / 4.610 / 4.632 | 0.572 / 3.588 |
| 512 | 1024 | 2 / 0 | 17.228 / 18.420 / 18.446 | 0.526 / 4.042 |
| 512 | 2048 | 0 / 0 | 71.468 / 81.953 / 93.250 | 0.470 / 4.422 |

Again, holes and upper-q overscan misses were **0** throughout. The zero-wrong 256/q1024 subset entered full replay and failed it. Higher pixel resolution was not monotonically better.

**Selected configuration: none.** Neither a small passing subset nor a sub-millimetre residual proves that the selected sheet is physically correct.

## Triangle approximation and retained counterexamples

At 512 pixels / q2048 in the 49-case sweep, maximum nearest-seed q error against reference upper q was **0.27336 m**, raster Y error **0.13323 m**, final Y error **0.67955 mm**, and valid world residual **0.79545 mm**. Exact refinement removes geometric approximation from final sampling when the seed reaches the right sheet. It cannot recover a higher sheet that the sampled winning texels fail to provide.

Sixteen unique wrong-sheet records from the denser full replay were recentered individually and tested with q2048:

| Pixels | Cases | Wrong / fail | Holes | Raster mean / p95 / max, ms |
|---:|---:|---:|---:|---:|
| 512 | 16 | 2 / 0 | 0 | 76.446 / 85.154 / 85.154 |
| 1024 | 16 | 5 / 0 | 0 | 77.668 / 94.508 / 94.508 |
| 2048 | 16 | 6 / 0 | 0 | 76.007 / 76.374 / 76.374 |

An independent confirmation evaluated every archived candidate q in these 16 records using the **current GPU material-sampling mode**, without root discovery. The atlas result was obtained first; candidate q/Y were never supplied to mode 5. The confirmation used matching field time/configuration and accepted only candidate roots with ≤1 mm world residual. It confirmed **all six wrong-lower results at 2048 pixels / q2048**.

For example, at T=1.3666667 and target `[393.938934, -991.259766]`, the atlas selected q `[394.105316, -991.293762]`, Y **−0.608956993 m**, with a **0.0201 mm** exact residual. Current-field evaluation confirmed upper q `[392.152252, -991.989990]`, Y **0.176120862 m**, with **0.0610 mm** residual. The selected surface is **0.785077855 m lower**. Raster seed Y was −0.608157098 m and the neighborhood appeared smooth, so the fast path made one solve. Other confirmed gaps were **0.78187, 0.10062, 0.51628, 0.00604 and 0.02171 m**.

This is evidence of lost upper-sheet selection in the tested triangulation/texel representation. It is an inference about the failure mechanism, not a proof that every possible raster representation is impossible. The tested dense representation is already expensive and still fails; increasing heuristic Newton seeds or invoking old discovery would violate this phase's decision.

## Complete old-failure replay

Both full configurations replayed **52,054 records in 8,144 batches**: all 33,017 main wrong-lower records, all 1,145 main misses, all 16,973 supplemental wrong-lower records, all 504 supplemental misses, plus 415 formerly correct cold-fold records. The original compressed archives were reused.

| Configuration | Cases | Correct upper/root match | Wrong lower | Explicit fail | Valid unmatched |
|---|---:|---:|---:|---:|---:|
| 16 m, 128 pixels, q512 | 52,054 | 46,758 | 4,517 | 522 | 429 |
| 8 m, 256 pixels, q1024 | 52,054 | 50,692 | **1,021** | 21 | 434 |

“Correct” means valid, within the 2 mm upper-sheet criterion, and matching a discovered root within 2 cm q / 2 mm Y. **Unmatched can overlap wrong-lower; these columns are not a disjoint partition.** Wrong-lower means valid final Y more than 2 mm below reference upper Y. Explicit failure is preferable, but the atlas cannot identify every lost higher sheet from its own sampled neighborhood; the known incorrect configurations remain unaccepted.

| Old cohort | Cases | Corrected by 128/q512 | Remaining wrong | Fail | Corrected by 256/q1024 | Remaining wrong | Fail |
|---|---:|---:|---:|---:|---:|---:|---:|
| Main wrong-lower | 33,017 | 29,661 | 2,923 | 272 | **32,159** | **648** | **12** |
| Main misses | 1,145 | 1,037 | 56 | 46 | **1,124** | **8** | **1** |
| Supplemental wrong-lower | 16,973 | 15,235 | 1,491 | 163 | 16,502 | 360 | 8 |
| Supplemental misses | 504 | 447 | 29 | 26 | 498 | 3 | 0 |

In the denser replay, main cohorts including formerly correct cold records had **657 wrong / 13 fail**; supplemental cohorts had **364 wrong / 8 fail**. Both full replays recorded **0 atlas holes**, **0 upper-q coverage misses**, maximum **4 solves** and **61 total iterations/contact**. Source caps enforce ≤16 iterations per solve.

All replay contacts reset ownership. This tests acquisition at the old failure targets, including targets originally generated by warm motion, and does not claim to reproduce each old contact's owned ancestry. Separate persistent two-root and coalescing checks test the new history path. Groups have coherent configuration/time/alpha, ≤256 contacts, and lie within 0.4×tile width of their first target. Tile centers use target positions only. Archived upper q is used after the result for evaluation/coverage checks.

The reference is the prior bounded 802-seed/fine GPU discovery evidence, not a global mathematical maximum certificate. Fixture fields are reconstructed at coherent archived time/configuration; old texture bytes are not replayed literally. The independent current-field confirmation above strengthens the decisive counterexamples.

## Cold fold, lateral seven, two-root and depth

The dedicated 8 m / 256 pixel / q1024 cold replay measured all **1,204 main ownerless attempts** plus **511 supplemental** attempts. Its grouping/centers are recomputed from the cold subset, so its outcomes need not equal the corresponding rows inside a mixed full replay.

| Cold cohort | Attempts | Correct envelope/root match | Wrong lower | Fail | Valid unmatched |
|---|---:|---:|---:|---:|---:|
| Main | **1,204** | **1,175** | **18** | **0** | 12 |
| Supplemental | 511 | 502 | 6 | 0 | 3 |

The old main cold result was 334 wrong / 559 fail. The new cold wrong-lower gate still fails.

The lateral seven passed at 8 m / 512 pixels / q2048: **7 correct / 0 wrong / 0 fail**, against the old 5 handoffs / 2 failures. This is a successful fixture subset, not an accepted global configuration.

The persistent physical two-root track at T=2.25, 8 m / 512 pixels / q2048 ran **360 updates** and was rerun after the final history guard. Both cold contacts selected the higher sheet immediately: **0 wrong, 0 failures, initial upper selection true**. This track observed **0 handoffs and 0 immediate A/B/A reversals**; maximum one solve / one iteration. It establishes no chatter on this track, not a general chatter guarantee across all envelope boundaries.

A final **240-update natural-history boundary audit** at 64 pixels / q512 exercised **79 ambiguous owned contacts / 79 fifth solves**, with **nine** previous candidates outside the ±2 mm atlas tie window. They were excluded, including a previous candidate above the atlas maximum. Maximum five solves / 18 total iterations; no explicit query failures or tie-window/budget violations. This deliberately coarse configuration is not an accepted envelope selector. Its exact-field comparison against the native mirror at the returned FP32 q had **two accuracy failures**: maximum displacement **1.03878 mm**, velocity **1.06493 mm/s**, normal **0.30002°**, residual **0.99623 mm**. These exceed the unchanged displacement/velocity gates and remain recorded as failures; the test exits 1. No tolerance or FP64 math was changed to remove them.

Signed depth used 10 cm above / at / 10 cm below the reference upper surface in rich and compact output:

| Region | Samples | Maximum error against −0.10 / 0 / +0.10 m |
|---|---:|---:|
| Open | 6 | 0.00159 mm |
| Coastal | 6 | 0.00179 mm |
| Fold | 6 | 0.08562 mm |
| Handoff fixture | 6 | 0.01661 mm |

All **24** depth outputs were valid and passed 1 mm. The handoff fixture tests physical depth at an archived handoff location; it is not a new moving-handoff stress run.

## Accuracy regressions

| Test | Samples | Displacement max | Velocity max | Normal max | World residual max | Result |
|---|---:|---:|---:|---:|---:|---|
| New mode 5 focused matrix | 1,280 | 0.03213 mm | 0.04367 mm/s | 0.02798° | 0.99887 mm | PASS numerical accuracy |
| Historical focused mode 2 | 1,280 | 0.03305 mm | 0.05148 mm/s | 0.02798° | 0.85095 mm | PASS regression |
| Historical material matrix | 6,912 | ≤0.06276 mm | ≤0.05321 mm/s | 0.02798° | Material coordinates; see world test | PASS regression |
| Historical world matrix | 3,072 | — | — | — | 0.99865 mm | Existing GPU gates pass |

The new-mode matrix uses the same five profiles/times/targets as the historical focused matrix, acquired from atlas seeds without CPU q hints. Its two distant spatial groups run sequentially on one tile. This is exact-field parity, not a multi-vehicle proof or exhaustive upper-envelope oracle. The 6,912 legacy vector limits are conservative bounds from the maxima of the recorded component errors. The legacy world comparison still reports **87 CPU/GPU validity differences and one CPU branch mismatch**, with zero GPU failures/owned-branch mismatches; these historical branch diagnostics are retained rather than reclassified as a new envelope pass.

## GTX 970 performance — non-target

Full-replay measurements split the existing ocean FFT, envelope bounds, raster and query. Values are **mean / p95 / max in ms**:

| Stage | 128/q512 full replay | 256/q1024 full replay |
|---|---:|---:|
| Existing ocean FFT | 2.455 / 2.780 / 2.893 | 2.469 / 2.786 / 3.118 |
| Current-field bounds | 0.088 / 0.089 / 0.098 | 0.094 / 0.096 / 0.114 |
| One-tile raster | 4.582 / 4.610 / 5.142 | 18.424 / 18.592 / 22.886 |
| Exact query | 2.277 / 5.321 / **10.588** | 1.023 / 2.983 / **9.167** |
| Sum of measured production-stage means | **6.947** | **19.542** |

The full runs captured 8,143 query/raster/bounds timestamps for 8,144 requests; the final timestamp was not drained before aggregation. Ocean timestamp arrays reached their 16,384-sample retention cap. Combined full-replay p95/max are not available from the stored separate distributions; adding their p95 values would not produce a measured combined p95.

The dedicated cold replay drains timestamps and joins stages by request generation. For **1,127 batches**, combined incremental bounds+raster+query was **19.282 / 20.857 / 26.435 ms**. Its existing ocean FFT was **2.478 / 2.796 / 3.127 ms**. CPU submit cost was **34.456 / 54 / 294 µs**, and consume calls **8.365 / 21 / 36 µs** (2,254 calls, including empty polls). The validation-only hole-count pass is outside these production-stage timestamps; it is disabled in production.

Maximum measured raster dispatch in the dense sweep: **93.250 ms**; counterexample sweep: **94.508 ms**. Any envelope/query dispatch >8 ms: **YES**. Query solve limits do not guarantee cheap FP64 execution on GTX 970. These costs cannot justify accepting a physically incorrect configuration.

**Phase C was not started.** Layouts 1×4, 1×8, 1×16, 4×8, 6×8, 10×8, 10×16 and 16×16 are **unmeasured/gated**. Raster costs for 4/10/16 tiles, query-count benchmarks 4/8/32/64/80/160/256, and the 16-tile/256-contact combined mean/p95/max are **not available**. The full replay's batches of up to 256 are one-tile oracle cohorts, not a vehicle-capacity performance proof. No measured one-tile cost is presented as a measured 16-tile cost.

## Async, coalescing and resources

Production `rd.sync()`: **NO**. Blocking `buffer_get_data()`: **NO**. CPU atlas readback: **NO**. Callback errors / generation mismatch in accepted test outputs: **0 / 0**. Tile/query stamp mismatch observed in coherent requests: **0**. An intentionally mismatched tile-occupant assignment returned **FAILED, reason 10**.

Twenty immediate submissions with moving centers coalesced **19** packets. The final result used request generation **181**, final tile occupant generation **25**, final target `[-239.544006, -1299.848022]`, and matching current time **0.6100000143**. Mutating the original tile descriptor after submission did not change the copied pending tile. An inactive middle submission still cleared ownership, so the final result cold-acquired rather than inheriting old history. This establishes single-tile recentering/coalescing safety for the tested sequence; the broader motion/weather/vehicle matrix remains gated.

Known GPU payload sizes, excluding opaque driver shader/pipeline storage and alignment:

| Pixel / q configuration | Color bytes | Depth bytes | Mesh bytes | Tile + extrema | Query buffers | Total added payload bytes |
|---|---:|---:|---:|---:|---:|---:|
| 128 / 512 | 262,144 | 65,536 | 8,396,808 | 128 | 933,888 | **9,658,504** |
| 256 / 1024 | 1,048,576 | 262,144 | 33,570,824 | 128 | 933,888 | **35,815,560** |
| 512 / 2048 | 4,194,304 | 1,048,576 | 134,250,504 | 128 | 933,888 | **140,427,400** |
| 2048 / 2048 | 67,108,864 | 16,777,216 | 134,250,504 | 128 | 933,888 | **219,070,600** |

The static mesh is `(N+1)²×8 + N²×24` bytes. The atlas attachments use 20 bytes/pixel together. The new token's three-slot input/output/control ring plus persistent contact state owns **10 buffers / 933,888 bytes**. Persistent targets, meshes and framebuffer are reused; no per-tick texture/framebuffer/mesh allocation occurs. Source uniform sets rebuild only when borrowed texture RIDs change.

Resource lifetime checks passed: all sweep configurations retired to zero resources; **three** query-token retirement cycles began with one readback in flight; **three scene reloads plus three ocean reinitializations** also began with one readback in flight. Every tested retirement ended at **0 owned envelope resources, 0 query buffers, 0 in-flight callbacks, 0 callback errors and 0 generation mismatches**. An active-tile 1→0→1 sequence preserved **20 owned envelope resources / 10 buffers** throughout and returned valid→failed→valid. Changes above one active tile are Phase C and were not run.

Runtime shader hot reload is unsupported. Source changes require retiring and recreating the query token; resources are never silently swapped under in-flight work. Compilation/recreation was exercised by the configuration and reload tests. Accepted runs reported no invalid RID or GPU shader errors. Startup certificate-store and MCP registry write/lock warnings are unrelated environment messages. Early harness parse/fixture errors were fixed and rerun; they are not counted as physical measurements.

## Evidence and reproduction

[PHYS-GPU-ENVELOPE-1-MEASUREMENTS.json](PHYS-GPU-ENVELOPE-1-MEASUREMENTS.json) is the compact review artifact. It contains all sweep aggregates, complete replay counters, selected comparisons, current-field-confirmed roots, parity summaries, depth and lifecycle records. It records scratch SHA-256/size, per-job source hashes where captured, final source hashes and existing reference-file hashes. The old 214 MiB archive is referenced in place and unchanged. New raw results/logs remain under `.godot`; no duplicate exhaustive archive is committed.

The dense/full replay ran before the final inactive-instance early return and one-tile capacity restriction. Both were already using one active tile, so those changes do not alter their active geometry or query math. Later native parity, cold, resource and current-field-confirmation runs exercised those changes. The subsequent source audit restricted previous-q eligibility to ±2 mm of the atlas-derived maximum, preventing history from introducing a separate higher sheet. Full replay and confirmation reset ownership, so that final guard is unreachable in those tests and does not change their cold counters. The final two-root rerun and natural-history boundary audit exercised the final query source, including fifth candidates. Initial sweep/baseline jobs predate automatic per-job source-hash capture; their raw files are hashed, and their counts are reported as those runs, not relabeled as a later source snapshot.

Use the native console executable, sequentially, with unique log paths. All GPU proof commands use `--rendering-method forward_plus --rendering-driver d3d12`; never headless:

```powershell
$godotEnvelope = 'C:\Users\Eric\Desktop\Godot_v4.7.1-stable_win64_console.exe'
& $godotEnvelope --path . --log-file .godot/envelope_A.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_feasibility.gd
& $godotEnvelope --path . --log-file .godot/envelope_sweep.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd
& $godotEnvelope --path . --log-file .godot/envelope_replay.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --replay
& $godotEnvelope --path . --log-file .godot/envelope_dense.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --dense
& $godotEnvelope --path . --log-file .godot/envelope_replay_dense.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --replay --dense-replay
& $godotEnvelope --path . --log-file .godot/envelope_closure.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --closure
& $godotEnvelope --path . --log-file .godot/envelope_confirm.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --confirm
& $godotEnvelope --path . --log-file .godot/envelope_cold.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --cold-replay
& $godotEnvelope --path . --log-file .godot/envelope_atlas_parity.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --atlas-parity
& $godotEnvelope --path . --log-file .godot/envelope_focused.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --focused-parity
& $godotEnvelope --path . --log-file .godot/envelope_legacy.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu1_runner.gd -- --matrix-only
& $godotEnvelope --path . --log-file .godot/envelope_resources.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --resources
& $godotEnvelope --path . --log-file .godot/envelope_owned_boundary.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu_envelope_runner.gd -- --owned-boundary
# Export only: no GPU measurement is performed by this headless command.
& $godotEnvelope --headless --path . --log-file .godot/envelope_export.log --script res://validation/physics/phys_gpu_envelope_export.gd
```

The runner's empty `checks` and zero exit code mean its checks completed. Physical sheet outcomes are separate counters; they do not imply an envelope PASS. The owned-boundary run exits 1 for the two additional accuracy failures. The exporter preserves these failures, requires complete corpus/parity counts and current-field-confirmed wrong-sheet evidence, and refuses unexpected protocol/lifetime/budget failures before writing the **BLOCKED** aggregate.

Files changed: `open_ocean_fft.gd` and `ocean_surface_query.gd` gain opt-in integration/hooks; eight new `ocean_envelope_*` files implement atlas resources, runtime source composition, bounds, raster, holes and exact query. Validation adds the contract, feasibility runner, atlas runner, compact exporter, measurements and this report. The historical GLSL and legacy runners are unchanged.

## Architectural conclusion

**BLOCKED for the tested uniform q-grid atlas proof; NOT READY FOR PHYS-GPU-2.** The GPU API/order/async architecture works and the requested numerical regression matrices pass. The representation still loses upper sheets even at q2048/pixel2048, where one-tile raster costs are already far beyond the development target. The additional coarse boundary audit also reports two accuracy-budget failures. This is a correctness blocker, not merely a slower physically correct PARTIAL result.

Stop here. No automatic atomic-scatter replacement, renewed heuristic discovery, Phase C, TARGET-ENVELOPE-1, PHYS-GPU-2/3/4, forces or master merge was started. A subsequent user-directed decision is needed before further architecture work.
