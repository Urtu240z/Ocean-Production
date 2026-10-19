# Local sea performance audit — phase 1
Base: `234c1f4917e94d9acecb24171a12a3847206c926`. Instrumentation only; no wave, vehicle, exterior FFT, Planar or tsunami behavior/settings changed.

## Reproduction and measurement contract
Godot 4.7.1-stable (official), d3d12, NVIDIA GeForce RTX 4070 Laptop GPU; 13th Gen Intel(R) Core(TM) i7-13650HX. 1280×720, uncapped, vsync off, 60 Hz physics. One Godot instance, sequential cases, no agents. Real 1/4/6 production Jet Skis with forces/queries enabled; a diagnostic driver resets their pose/velocity onto the same sinusoidal path before each step. One fixed camera. Unrelated coastal/reflections/spindrift/underwater systems held off in this fixture only; the exterior spectrum is unchanged. No saved scene/resource modifications.

First matrix: 180 physics ticks warmup, 300 ticks measured. Repeated in reverse case/boat order with at least 240 rendered frames **and** 300 physics ticks per case. Both matrices are attached as JSON. This fixture is intentionally uncapped and differs from the user's full scene; its FPS must not be presented as a reproduction of the reported 144/90–110/70 FPS.

Timers: integer microseconds; per-tick and per-process-frame call counts and inclusive durations. Nested get_runtime/synchronize/apply/sample/build/query times **cannot be added together**. Counts/metrics aggregate; no contact logging. Monitor collection, timestamp readback and file writing are outside timed functions. Enabled instrumentation still has overhead in WALL; before/after must use the same instrumentation. TIME_PROCESS and TIME_PHYSICS_PROCESS retain their literal engine meanings and are not substituted for one another. Their values update at engine monitor cadence; WALL is independently sampled every rendered frame.

Local FFT timestamp begin/end labels are read on the render thread **every rendered frame**, deduplicated by captured GPU frame. Reading only on the next physics dispatch misses frames when render FPS exceeds physics Hz. Viewport GPU/CPU timers are read on their owning thread, deferred to main. Local FFT GPU durations and viewport durations have separate scopes, not an additive frame GPU decomposition.

## Reverse-order matrix
WALL is frame interval in ms. FPS p50 is median instantaneous 1000/WALL, not total throughput. Sync is inclusive sum per physics tick. Viewport includes boats and water; not isolated water.

| Boats | Case | WALL p50 / p95 ms | FPS p50 | Sync p50 ms/tick | Viewport GPU p50 ms |
|---|---|---:|---:|---:|---:|
| 1 | none | 1.443 / 4.911 | 693.0 | 0.045 | 0.965 |
| 1 | one_outside | 1.501 / 5.718 | 666.2 | 0.837 | 0.996 |
| 1 | one_inside | 1.840 / 7.488 | 543.2 | 0.872 | 1.145 |
| 1 | two_same | 2.029 / 7.525 | 492.9 | 0.841 | 1.300 |
| 1 | two_separate | 2.429 / 9.432 | 411.7 | 1.444 | 1.332 |
| 4 | none | 2.411 / 9.684 | 414.4 | 0.093 | 0.971 |
| 4 | one_outside | 3.248 / 12.965 | 307.9 | 1.998 | 1.720 |
| 4 | one_inside | 15.428 / 17.907 | 64.8 | 2.122 | 2.836 |
| 4 | two_same | 15.093 / 17.336 | 66.3 | 2.117 | 2.965 |
| 4 | two_separate | 48.675 / 78.277 | 20.5 | 3.690 | 6.280 |
| 6 | none | 13.003 / 14.100 | 76.9 | 0.120 | 2.207 |
| 6 | one_outside | 17.080 / 33.436 | 58.5 | 2.793 | 3.561 |
| 6 | one_inside | 64.894 / 114.344 | 15.4 | 2.757 | 6.199 |
| 6 | two_same | 101.131 / 141.671 | 9.8 | 2.840 | 8.710 |
| 6 | two_separate | 168.652 / 194.894 | 5.9 | 5.207 | 9.100 |

The overloaded 4/6-boat cases accumulate multiple physics ticks per frame (up to the engine catch-up limit); this explains why frame WALL can greatly exceed one tick's TIME_PHYSICS_PROCESS. The two repetitions also show scheduling/clock/load variance. A component regression must be judged using its own counters/timers, not a causal claim from raw FPS.

## Measured component observations
- get_runtime/synchronize: 3 / 9 / 13 calls per physics tick for 1 / 4 / 6 boats.
- One inside, one boat: native 128/128/128 field is built once per tick; 14 incoming/affected contacts, 70 native positions (five per contact), two native query batches per tick. First matrix field p50 1.114 ms, query batches total p50 0.102 ms/tick.
- Two same-slot areas still use one field/state; two distinct slots use two fields/states. Builds do not multiply by the boat count within a tick.
- One area outside produces no local CPU field/query contacts, yet synchronization and GPU dispatch remain active. This isolates those costs from local contact sampling.
- Separate water-only fixture (zero boats), visible versus hidden water, simulation left active: viewport GPU p50 differences are 0.87 ms no areas, 0.90 ms one outside, 1.05 ms one inside, 1.21 ms two same slot, 1.24 ms two distinct slots. These are controlled **difference estimates**, including water rendering and any renderer work caused by visibility, not exact per-draw hardware timestamps.
- Local GPU FFT p50 in the first matrix is approximately 0.290 ms per active slot/dispatch. See JSON for sample counts and tails.
- Isolated production fragment composition kernel, 1280×720, actual local FFT textures: control 0.014 ms, small footprint 0.032 ms, large one area 0.151 ms, large two same slot 0.293 ms, large two slots 0.294 ms. These include the canvas pass; they do not include complete water shading. The code uses 5 × 3 band texture fetches per positive area in compose (plus separate vertex displacement).
- The repeated same-slot sampling in the shader and the repeated synchronization on CPU are optimization candidates; the measurements above do not establish that either alone explains the user's full-scene slowdown.

## Validation and limits
`validation/local_sea_equivalence.gd`: 1,120 comparisons against exact base source fixtures, DIRECT and DISPLACED, two overlapping slots, interior/feather/exterior, five times. HEIGHT/NORMAL/VY/signed_depth maximum difference **0**. GPU kernel fixture and full matrix exit without script/render errors after the initial instrument smoke fixes. Base fixture source differs only in its LocalFFT preload path.

This is phase 1 evidence. No optimization has been applied. Native batch, high chop/fast transition/lifecycle coverage, underwater/hull visual validation and final before/after conclusions belong to later phases.

