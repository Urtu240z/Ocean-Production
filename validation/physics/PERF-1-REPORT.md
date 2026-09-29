# PERF-1 — P0 GPU cost attribution

Status: **PERF-1-B (provisional)**. The roughly 35.7 ms P0 GPU baseline is attributable to enabled Ocean and scene features, not to BreakerCarrier or a second Ocean/viewport. B1 runtime telemetry also recorded a 30 Hz lifecycle-time discrepancy (730 steps against 600 expected from Production wave time). Its cause is not isolated, so no production change was made.

Hardware: Intel i7-5820K / NVIDIA GTX 970. Godot 4.7.1 stable, debug build, Forward+ / D3D12, 1920×1080, VSync off, unlimited FPS, dynamic resolution/upscaling off, `Engine.time_scale=1`. All figures are provisional and are not RTX 4070 acceptance results.

## A. G0 vs P0

| | G0 historical reference | Controlled P0 |
|---|---|---|
| Scene | `validation/ocean_benchmark.tscn` | `validation/p0_open_ocean.tscn` |
| Camera | `(0,8,16)`, pitch −12° | `(0,8,16)`, pitch −12° |
| Viewport | 1920×1080 | 1920×1080 exact, borderless |
| Renderer | Forward+ / D3D12 | Forward+ / D3D12 |
| Environment | BG color, Filmic; ambient .35/.48/.60 × .8; sun energy 3, shadows on | HDRI panorama, AGX, SSAO/SSIL, glow, fog; P0 sun energy .5, shadows on |
| Ocean | Full LONG/MID/SHORT FFT, optional systems off, breaker off | Same bands; optional P0 features configured on; B0 turns breaker system off |

The P0 runtime tree has one window viewport, no SubViewport, one active camera, one WorldEnvironment, one Ocean, and one OpenOceanFFT owner. The controlled P0 camera transform matches the G0 transform. The P0 test island is additional geometry absent from G0; P0 full-frame primitive count was 3,701,253. Hiding the island reduced this to 574,848.

The controlled core/environment pair used the same P0 scene, camera, ocean and hidden island. P0 environment measured 8.04 ms GPU mean / 8.17 p95; changing to the G0 environment measured 7.11 / 7.27 ms. Both runs were in `TRANSITION` with the medium fullscreen fallback active and no valid waterline readback. This isolates the environment change within that path, but it is not a valid AIR_SAFE G0-vs-P0 core comparison. The historical G0 result was 3.907 / 4.128 ms. That residual cross-scene difference remains unaccounted for; it does not explain the optional-feature deltas below.

## B. Breaker OFF semantics

| Subsystem in B0 | State |
|---|---|
| Lifecycle/detector compute | Inactive; lifecycle resource unpublished/retired |
| Candidate detection/probe/readback | Inactive; probe flag false |
| Carrier node/mesh draw | No Carrier node in P0 tree; zero Carrier draws |
| Suppression/replacement shader path | Runtime breaker uniform/variant inactive; guarded shader branch remains compiled |
| Breaker VDM | Support resource is initialized, but no B0 per-frame breaker evaluation was found |
| Lateral lifecycle/handoff | Inactive with lifecycle |
| Spindrift tied to breakers | Disabled; configured live-particle capacity 0 |
| Breaker validation | Not instantiated by normal P0 scene |
| Waterline | Separate asynchronous 32-byte camera-state readback remains active in AIR_SAFE |
| Crest and surface foam | Separate Ocean features remain active in B0 |

B1 enables lifecycle infrastructure, then disables the visible surface breaker path. B2 uses the normal autonomous breaker request and suppression/replacement route. There is no Carrier node in this P0 scene, so the B2−B1 delta measures that active surface route, not Carrier mesh rendering.

## C. GPU pass inventory

Counts below are from source dispatch sites and runtime feature state. Godot exposes no GPU dispatch counter here; cadence is inferred from the owning process/update code, except for lifecycle steps, which are reported by the dispatch loop's lifecycle-time counter.

| Pass | Cadence / work | G0 | P0 B0 | Notes |
|---|---|---|---|---|
| LONG, MID, SHORT Stockham FFT | 18 dispatches per active band per rendered frame: evolve + 16 Stockham stages + assemble; N=256, 32×32 groups of 8×8 | On | On | 54 base dispatches/frame total |
| Crest foam/history | Two 256² passes per active band when its 30 Hz simulation accumulator advances | Off | On | Separate from breaker lifecycle |
| Coastal | Baked textures are cached/resident; `OceanCoastalRuntime` contains no per-frame RenderingDevice dispatch | Off | On | About 1.07 ms shader-feature attribution; textures are sampled by the material |
| SSPR | Project depth, project source, resolve, temporal if enabled, plus mip downsample dispatches; output follows 1920×1080 viewport | Off | On | About 2.5 ms GPU mean attribution |
| Surface detail / optics | Ocean surface shader features | Off | On | Optics-off delta about 9.66 ms; surface-detail-off about 1.49 ms |
| Surface foam | 512² source, 1024² field, 512² topology; 30 Hz incremental job, pass budget 24 | Off | On | About 4.49 ms in a paired off/on sample; restore row ran ~1.4 ms below initial baseline |
| Waterline camera state | 1×1 compute and 32-byte async buffer result; no full texture readback | Off in historical G0 | On in P0 AIR_SAFE | Callbacks measured at 125–126 per 10 s in stable B1 samples (~12.5/s); no synchronous readback |
| Underwater full-screen medium | Viewport/8 dispatch when transition/underwater path is active | Off | Normally inactive in AIR_SAFE | Invalid readback/off toggles can enter TRANSITION and activate fallback; contaminated rows excluded from isolated deltas |
| Underwater bubbles | 96×32×96 volume, 4×4×4 workgroups | Off | Configured on; runtime inactive while dry | No observed active dispatch while AIR_SAFE |
| Caustics | Screen-sized compute path gated by underwater conditions | Off | Configured on | Its isolated OFF row followed a state transition and is not treated as a valid delta |
| Breaker lifecycle | One 512² dispatch per 1/30-s lifecycle step; 64×64 workgroups of 8×8 | Off | Off in B0; on in B1/B2 | Measured counter disagreed with Production wave-time cadence; see F/I |
| Carrier support / spindrift / validation probes | No P0 Carrier node; spindrift and probe disabled in tested states | Off | Off in B0 | No validation GPU dispatch/readback leakage found |

The SSPR and waterline paths use the global renderer's existing command ordering. No local RenderingDevice, synchronous global `submit()`/`sync()`, or PHYS GPU probe was used in these runs.

## D. Runtime tree and render counters

P0 runtime audit: Oceans 1; OpenOceanFFT owners 1; BreakerCarrier 0; Camera3D 1; root Viewports 1; SubViewports 0; ReflectionProbes 0. No spectator/reflection camera or duplicate renderer was found.

| State | Draw calls / objects | Primitives | Video / texture / buffer memory (approx.) |
|---|---:|---:|---:|
| P0 B0 full | 15 / 15 | 3,701,253 | 606 / 438 / 86 MB |
| P0 full, island shadows off | 11 / 11 | 1,200,129 | 600 / 432 / 86 MB |
| P0 core, island hidden | 10 / 10 | 574,848 | 496 / 345 / 75 MB |

The island is at `(-445.245, 400, -25.284)`, casts shadows, and is outside the camera view. Disabling its mesh shadows reduced full P0 GPU time by 1.07 ms and primitives by 2.50 M; hiding it in the core state reduced GPU time by about 2.06 ms versus core with island shadows enabled. G0 had no island.

## E. Feature attribution

Every sample used 5 s warmup and 10 s sampling. B0/B1/B2 used three repetitions; other rows are within-process attribution captures, not repeated acceptance benchmarks.

| P0 state | GPU mean / p95 ms | CPU mean ms | Attribution / caveat |
|---|---:|---:|---|
| B0 full, breakers completely off | 35.75 / ~36.5 | 1.21 | Reference P0 |
| Debug UI and cascade gate processing off | 35.84 / 36.56 | 1.13 | No material GPU delta |
| SSPR/reflections off | 33.25 / 33.79 | 0.85 | −2.59 ms in matrix; refinement run confirmed roughly −2.5 ms |
| Underwater owner off after SSPR off | 32.96 / 33.48 | 0.57 | Enters TRANSITION; not a clean W0 delta |
| Caustics off after transition | 32.69 / 33.37 | 0.52 | State already TRANSITION; no isolated conclusion |
| Optics off (stable AIR_SAFE refinement) | 25.72 / 26.27 | 1.17 | −9.66 ms versus restored optics sample |
| Surface detail off | 34.07 / 34.77 | 1.16 | −1.49 ms versus restored sample |
| Coastal off | 34.53 / 35.63 | 1.16 | −1.07 ms versus restored sample |
| Crest foam off | 34.95 / 35.58 | 1.17 | ~−0.63 ms; runtime RID warnings from toggling mean this remains provisional |
| Surface foam off | 29.70 / 30.30 | 1.18 | ~−4.49 ms; restored sample was 34.19 ms, below initial baseline |
| Cumulative P0 core | 10.32 / 10.53 | 0.32 | Transition/fallback active; not comparable directly with historical G0 |

Separately, a W1 full medium/waterline-on capture was 35.69 ms GPU / 1.17 ms CPU, AIR_SAFE. W0 disabled the owning medium system and measured 35.73 / 0.90 ms, but changed to TRANSITION with fullscreen fallback active. GPU difference (+0.04 ms) is noise and not a clean isolated waterline result; CPU fell about 0.27 ms. Disabling only asynchronous readback is invalid because it invalidates the state and changes render path. The dry-camera AIR_SAFE state reports no waterline raster pass, while the 1×1 query/readback continues.

The P0 feature costs explain the high P0 GPU baseline as a combination: optics, surface foam, SSPR, coastal/surface-detail/crest paths, environment passes, and the offscreen shadowing island. These deltas are nonlinear and should not be summed as if they were independent. The P0 core vs historical G0 residual remains a separate scene/state comparison issue.

## F. Breaker decomposition and cadence

| State (3 × 10 s) | GPU mean ms (replicate means) | Median replicate GPU ms | CPU mean ms (replicate means) |
|---|---:|---:|---:|
| B0 complete breaker off | 35.746 | 35.732 | 1.207 |
| B1 lifecycle only; carrier/suppression off | 35.468 | 35.473 | 1.188 |
| B2 normal full breaker request | 35.709 | 35.689 | 1.171 |

Derived deltas: B1−B0 = −0.278 ms GPU / −0.020 ms CPU; B2−B1 = +0.241 ms GPU / −0.017 ms CPU; B2−B0 = −0.037 ms GPU / −0.036 ms CPU. These are within run-to-run noise; no measurable breaker GPU cost explains the 35 ms baseline. B0 correctly removes lifecycle/detector dispatch, candidate probe/readback, spindrift and active shader suppression. B1 enables lifecycle only. B2 enables the production breaker route with zero Carrier nodes in the runtime scene.

The configured cadence is 30 Hz of the same simulation delta passed to the FFT solver. In a 10.0 s sample, Production `wave_time` advanced 20.0023 s (wave speed 2.0), so expected lifecycle updates are 600. The solver's lifecycle runtime counter advanced 24.3333 s / 730 fixed 1/30-s steps (about 21.7% above expectation). An earlier harness version's per-frame rounding also reported 724; that count was discarded. The corrected measurement uses start/end lifecycle time. Since lifecycle time is advanced inside the loop that records lifecycle compute dispatches, this is a real cadence discrepancy, but its cause is not isolated. It blocks PERF-1-A. No cadence or physics code was changed.

## G. Validation leakage and measurement integrity

Normal P0 scene/autoload inspection found no PHYS Stage A, GPU probe runner, PHYS benchmark, breaker benchmark or spectator validation instantiated. Normal Production has zero PHYS validation dispatches, readbacks and callbacks. The P0 debug panel and FFT cascade gate are scene children; disabling their visibility/process produced no material GPU delta. P0's existing waterline async readback is not PHYS validation leakage.

The dynamic `crest_foam=false` harness toggle emitted invalid-RID / null-format renderer errors in some refinement captures. Those were caused only during the validation toggle/rebuild, not at P0 startup; affected toggles are provisional and no Production cleanup was attempted. Godot's startup certificate-store warning was unrelated to GPU sampling. No MCP performance investigation was performed.

## H–J. Diagnosis and fix

Primary 35 ms cost classification: **A — expected feature cost** in this P0 authoring configuration; quantified optional Ocean/environment work and island shadows account for the majority. No duplicate viewport, Ocean or PHYS validation work was found. Waterline readback has not shown measurable GPU cost in the dry AIR_SAFE state, but the on/off pair was not a clean GPU-isolated comparison.

Separate lifecycle finding: **H — cause unknown; cadence discrepancy observed**. The runtime's intended 30 Hz step is counted 730 times against 600 expected from the same wave-time interval. It is not yet classified as duplicate solver dispatch, renderer-queue timing, or another cause. Because the source says the accumulator receives the same `simulation_dt`, this needs a targeted render-thread/counter trace before a code fix. No Production behavior, quality, FFT resolution, physics, spectrum or breaker parameter changed.

No fix was made. Validation-only changes are confined to `validation/physics/perf1_cost_attribution.gd`; this report records their limits. No before/after Production fix exists.

## K. Hardware status

Current: i7-5820K / GTX 970 — provisional attribution only. Final acceptance remains deferred to i7-13650HX / RTX 4070 Laptop. No absolute FPS acceptance judgment was made.

## L. Result

**PERF-1-B** — the large P0 cost is attributed and breakers are exonerated as its cause, but the verified lifecycle cadence discrepancy remains unresolved. The historical G0 baseline is not a fully matched P0-core comparison because the P0 core probe fell into TRANSITION.

## M. Git

Files changed by PERF-1: validation-only runner and this report. Pre-existing PHYS modifications remain untouched. Commit: NONE. Push: NOT NEEDED.
