# OceanWaveArea3D and Local Sea States — final audit
Base: `234c1f4917e94d9acecb24171a12a3847206c926`. Windows Godot 4.7.1, D3D12 Forward+, RTX 4070 Laptop GPU.

The verified reductions are repeated GDScript synchronization, querying unaffected contacts, GDScript/native packing, and repeated GPU sampling of the **same slot**. The exterior FFT, Jet Ski physics, Planar, tsunami, saved scenes/resources and their numeric defaults are unchanged by these commits. CPU field resolution stays 128/128/128. Two distinct local seas still cost two native field builds and two GPU FFT dispatch groups when active.

## Measurement contract
One Godot process at a time; no agents. Same 1280×720 uncapped/vsync-off camera, 60 Hz, real 1/4/6 boats on the same controlled sinusoidal path. 180 warmup physics ticks; at least 300 measured ticks **and 240 frames** per final case. Baseline ran forward/reverse; final ran forward/reverse. All distributions and per-tick/per-frame counts are retained in linked JSON.

These are diagnostic water/boat scenes with unrelated reflections/coastal/spindrift/underwater features held off equally. They do not reproduce the user's full scene at its 144 FPS cap. No production feature was disabled or retuned to obtain an improvement. Additional independent render/physics bypasses live only in validation fixtures.

WALL is independently measured frame interval. TIME_PROCESS and TIME_PHYSICS_PROCESS are separately sampled engine monitors, retaining their literal meanings; neither is used as a substitute for the other. Viewport GPU is total viewport rendering. Local FFT labels bracket GPU elapsed dispatch regions, not a perfect isolated shader-kernel budget. Inclusive function times must not be added together.

## Before / after by component
Six boats, two overlapping areas on separate slots, reverse-order runs. Times are inclusive **sum per physics tick**, ms; counts are median calls/tick.

| Component | Calls before → after | Before p50/p95 ms | After p50/p95 ms |
|---|---:|---:|---:|
| get_runtime | 13 → 13 | 5.264 / 6.967 | 0.674 / 0.847 |
| synchronize | 13 → 1 | 5.207 / 6.894 | 0.657 / 0.830 |
| apply | 12 → 12 | 4.651 / 5.483 | 4.552 / 5.126 |
| slot0.sample | 12 → 12 | 1.907 / 2.301 | 1.808 / 2.019 |
| slot1.sample | 12 → 12 | 1.830 / 2.186 | 1.752 / 1.991 |
| slot0.build_128_128_128 | 1 → 1 | 1.151 / 1.476 | 1.147 / 1.327 |
| slot1.build_128_128_128 | 1 → 1 | 1.138 / 1.441 | 1.137 / 1.322 |

84 input contacts/tick, 84 affected in each slot in this worst-case overlap. Each slot builds its field once/tick both before and after. Synchronization is 13→1 calls/tick (3→1 with one boat, 9→1 with four). Stable layouts perform no inverse/list rebuilds in the measured interval. Getters remain callable at any frequency.

Mixed-contact experiment, fields already built, two separated zones: with 84 input contacts, base queries **84/slot**, optimized **42/slot**, restoring each result at its original index. Full apply p50/p95 1.943/2.866→1.273/2.030 ms; maximum HEIGHT/NORMAL/VY difference 0. This includes subset/weight reuse and native bridge changes, not field creation. Smaller 14/56-contact cases and exact counts are in the subset JSON.

Native isolated 84-contact DISPLACED sample: 0.565/0.681→0.527/0.604 ms in one measured case. It retains five independent queries and horizontal inversions. Actual 128/128/128 field builds remain approximately 1.0 ms in CPU-only tests and 1.1–1.2 ms under the vehicle/render load, about 13.14 MiB reported field memory per state.

GPU fragment kernel, large same-slot overlap: 0.293/0.295→0.153/0.155 ms (p50/p95). One area: 0.152→0.152 ms p50; separate slots: 0.296→0.296 ms. This benefit applies to shared-slot overlap. It does **not** make the two different seas' FFTs cheaper. Low-load local FFT dispatch regions remain about 0.29 ms/slot. Under catch-up/contention they are substantially longer; all per-case timestamp distributions are preserved.

## Frame results, matching reverse-order runs
FPS below is the distribution of instantaneous 1000/WALL; p95 FPS is the fast tail. p95 WALL describes slow frames. This is not a claim about full-project throughput or a promise of the same FPS on the user's scene.

| Boats | Case | Before FPS p50/p95 | After FPS p50/p95 | Before WALL p50/p95 ms | After WALL p50/p95 ms |
|---|---|---:|---:|---:|---:|
| 1 | none | 693.0 / 746.3 | 694.9 / 733.1 | 1.443 / 4.911 | 1.439 / 4.923 |
| 1 | one_outside | 666.2 / 724.1 | 654.9 / 711.7 | 1.501 / 5.718 | 1.527 / 5.415 |
| 1 | one_inside | 543.2 / 652.7 | 529.7 / 641.0 | 1.840 / 7.488 | 1.888 / 7.102 |
| 1 | two_same | 492.9 / 589.3 | 512.6 / 621.1 | 2.029 / 7.525 | 1.951 / 7.253 |
| 1 | two_separate | 411.7 / 576.0 | 404.5 / 569.5 | 2.429 / 9.432 | 2.472 / 9.080 |
| 4 | none | 414.4 / 621.5 | 356.6 / 598.1 | 2.411 / 9.684 | 2.804 / 10.020 |
| 4 | one_outside | 307.9 / 359.2 | 349.7 / 589.3 | 3.248 / 12.965 | 2.858 / 10.350 |
| 4 | one_inside | 64.8 / 316.2 | 264.7 / 413.9 | 15.428 / 17.907 | 3.778 / 14.588 |
| 4 | two_same | 66.3 / 323.8 | 81.8 / 343.3 | 15.093 / 17.336 | 12.222 / 14.370 |
| 4 | two_separate | 20.5 / 30.7 | 64.6 / 306.1 | 48.675 / 78.277 | 15.471 / 17.415 |
| 6 | none | 76.9 / 325.1 | 80.8 / 340.0 | 13.003 / 14.100 | 12.376 / 14.158 |
| 6 | one_outside | 58.5 / 62.6 | 70.8 / 303.2 | 17.080 / 33.436 | 14.126 / 15.915 |
| 6 | one_inside | 15.4 / 20.4 | 60.6 / 63.2 | 64.894 / 114.344 | 16.510 / 27.465 |
| 6 | two_same | 9.8 / 12.4 | 59.2 / 61.6 | 101.131 / 141.671 | 16.887 / 30.207 |
| 6 | two_separate | 5.9 / 6.5 | 20.0 / 30.0 | 168.652 / 194.894 | 49.868 / 79.377 |

For the six-boat/two-slot reverse case, TIME_PROCESS p50/p95 is 5.275/7.159→4.521/5.213 ms; TIME_PHYSICS_PROCESS is 27.275/35.184→19.499/23.992 ms; viewport GPU is 9.100/12.269→3.842/4.866 ms. These scopes are separate, not additive.

Baseline caught up at roughly 8 physics ticks/frame; final averaged about 3.2 in that overloaded case. Therefore GPU dispatches and wave-responsive VFX per rendered frame also differ. The separate-slot shader kernel itself is unchanged in cost: the viewport GPU reduction must **not** be attributed to a faster distinct-slot shader. CPU synchronization has its own measured reduction of about 4.55 ms/tick; the remainder of whole-frame changes is not causally isolated.

The forward final pass gave 36.170/79.444 ms p50/p95 in the same six-boat/two-slot case, versus 49.868/79.377 in reverse. One-boat/two-slot median FPS was 427 forward, 405 reverse, versus baseline reverse 412. Some low-load frame statistics regress slightly or vary across runs. No uniform FPS gain is claimed. Catch-up thresholds, engine monitor cadence, clocks and boat/VFX response remain material sources of variation.

## Validation
- Exact base GDScript reference: 1,120 default + 1,120 high-chop/independent-scale comparisons. HEIGHT, NORMAL, VY, signed_depth maximum error **0**, including interior/feather/exterior/overlap and moving sample positions.
- Native batch: 24 cases, 24,640 position comparisons, DIRECT/DISPLACED, chop×1/×2, 14/56/84 contacts and 45 m/s positional shifts. Height/slopes/VY maximum error **0**.
- GPU: 12 HDR comparisons, 393,216 pixels, full-chop/aligned scales, rotated boxes/spheres/cylinders and edges/overlap. References are explicitly required to be ready and non-flat. All images byte-identical, maximum encoded height/slope error **0**.
- Existing `local_fft_states_check.gd`: passes CPU/GPU height, calm and rough underwater cameras, independent Ocean Space/full chop waterline sensor, identical exterior H0, local clock/speed freeze and slot cleanup. Reported CPU/GPU height error 0.009840 m (the existing tolerance/grid comparison), H0 relative error 0.
- Existing `wave_area_foam_render_check.gd`: passes exterior/calm/local geometry through the foam material. Variances 0.008873 / approximately 0 / 0.000795.
- Existing `hull_wave_continuity_check.gd`: passes cadence, reverse motion, two-boat superposition and slopes. Cadence max error 0.000488 m, slope RMS 0.007068, two-boat error 0.
- Lifecycle: same-tick area edit, same-tick resource edit, slot change, null/removal/restoration, shared resource in both slots, hot sea settings, pause/resume, movement of cached child shapes, World3D change, removing all areas. Old generations retire and displacement/normal textures are invalid in RenderingDevice after render completion. SceneTree/resource signals disconnect on shutdown.
- Final validation found and fixed explicit resource-change invalidation, including distinct callbacks when slots share a resource. Normal unedited operation still synchronizes once/tick. Defaults remain byte-for-byte equivalent declarations.
- No tests or performance runs used simultaneous agents or multiple Godot processes. Graph discovery used the Production index; stale/partial coverage was followed by exact source reads in the isolated checkout. Graph completeness was not assumed.

## Rejected experiment and remaining limits
128/128/64 saved approximately 0.25–0.28 ms and 3.28 MiB per state, but high-chop slot 2 showed HEIGHT error 0.257 m, slope X 1.401, slope Z 1.137 and VY 0.381 m/s. It remains an experiment, **not a default**.

Native Windows binary was rebuilt and validated. Existing Linux binary uses capability detection and the equivalent GDScript bridge; no Linux/Vulkan/Metal performance claim is made. Replacing finite-difference displaced normals with FFT normal textures was not adopted. CPU field creation and separate-slot GPU sampling remain real costs. Full gameplay with all visual features at the user's resolution needs its own hardware run; this report does not infer it from diagnostic FPS.

## Artifacts / reproduction
- [Phase 1](local_sea_phase1.md): instrumentation and actual base matrices.
- [Phase 2](local_sea_phase2.md): GDScript changes and per-case component data.
- [Phase 3](local_sea_phase3.md): native batch and resolution experiment.
- [Phase 4](local_sea_phase4.md): fragment kernel, water viewport and independent toggles.
- [Final forward](local_sea_phase5_final.json), [final reverse](local_sea_phase5_repeat.json), [mixed contacts](local_sea_phase5_subset.json), [GPU equality](local_sea_phase5_gpu_validation.json).

Run one process at a time, using the console binary: `--path . --script validation/local_sea_performance_audit.gd -- --phase=run_name --minframes=240`, then the same command with `--reverse=true`. CPU experiments: `--headless --path . --script validation/local_sea_native_audit.gd` and `validation/local_sea_subset_audit.gd`. GPU kernel: `validation/local_sea_gpu_audit.gd` (add `-- --reference` for the base include). Validation: `local_sea_equivalence.gd` (also `-- --high-chop`), `local_sea_gpu_equivalence.gd` and the three existing regressions listed above.
