# PHYS-2 — MID + SHORT + Combined Three-Band Native Physics

## Result

**PHYS-2-A.** The native evaluator matches the final Production LONG, MID and SHORT spectra at grid lattice samples, periodic edges, and a later moving-time packet. The combined native evaluator agrees with the sum of the three single-band native evaluators. Continuous combined material and world-XZ queries, batching, and physical normals were exercised. No Coastal path was enabled or added.

The GPU comparison distinguishes the continuous spectral field from Production's filtered texture samples. Exact continuous-vs-filtered differences are reported as rendered interpolation difference; interpolation-matched bilinear comparisons are below 1.4 mm in the combined packet.

## A. Band contracts

All three bands were `N=256`, sourced from the exact final RGBA32F H0 bytes retained from the Production solver upload (1,048,576 bytes each). Production initialized them with `wave_height_scale=1`, per-band scales of 1, MID fill 1, and choppiness LONG 3 / MID 1 / SHORT 1. The final H0 already includes the configured seed derivation, relative band amplitude, MID fill, and common scale; the adapter copied those bytes and did not regenerate spectra.

| Band | N | L (m) | dx (m) | material→FFT offset (m) | Choppiness | Effective scale | Gravity | H0 / Production displacement RID |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| LONG | 256 | 512 | 2 | 255 | 3 | 1 | 9.81 | 1,048,576 B / `RID(3921305141311)` |
| MID | 256 | 137 | 0.53515625 | 68.232421875 | 1 | 1 | 9.81 | 1,048,576 B / `RID(4002909519944)` |
| SHORT | 256 | 37 | 0.14453125 | 18.427734375 | 1 | 1 | 9.81 | 1,048,576 B / `RID(4084513898577)` |

For each band independently, `offset = L/2 - L/(2N)` and `fft_q = wrap(material_q + offset, L)`, with canonical interval `[-L/2,+L/2)`. The conversion is owned by the native cascade adapter/core boundary and is applied once for each cascade. World inversion retains one common `material_q` unknown; it does not convert the externally visible variable to FFT-q.

The GPU probe read the final per-band displacement RIDs on the **global** RenderingDevice. Format was RGBA32F, 256²; R/G/B are X/Y/Z displacement and A is the per-band Jacobian. The validation shader used exact integer texel reads for lattice tests and a repeat + linear sampler for off-grid tests. Readback was only the tiny result storage buffer via `buffer_get_data_async()`; no full texture readback or global `submit()`/`sync()` was used. The Production material samples with `world_uv=q/L+0.5`, repeat + linear filtering.

## B. Individual band parity

Every 64-sample, 16-wrap, and 16-moving packet was valid, same-time matched, and used 2–3 async latency frames. The four-sample smoke packet also passed for each band.

Grid-aligned 64-sample component error, GPU minus native (meters):

| Band / component | Mean absolute | P95 absolute | Max absolute | Mean signed |
|---|---:|---:|---:|---:|
| LONG X | 5.53e-6 | 1.50e-5 | 1.76e-5 | +2.51e-7 |
| LONG Y | 2.42e-6 | 5.19e-6 | 7.21e-6 | -1.67e-7 |
| LONG Z | 3.14e-6 | 8.61e-6 | 1.02e-5 | -5.64e-8 |
| MID X | 4.86e-7 | 1.20e-6 | 1.42e-6 | +4.07e-8 |
| MID Y | 5.49e-7 | 1.31e-6 | 1.56e-6 | -9.49e-8 |
| MID Z | 3.00e-7 | 6.78e-7 | 9.76e-7 | -3.34e-9 |
| SHORT X | 9.52e-8 | 2.18e-7 | 2.97e-7 | -1.65e-8 |
| SHORT Y | 1.13e-7 | 2.48e-7 | 2.82e-7 | +5.24e-9 |
| SHORT Z | 7.38e-8 | 1.70e-7 | 2.59e-7 | -1.64e-8 |

| Band / packet | Samples | Vector mean | Vector P95 | Vector max |
|---|---:|---:|---:|---:|
| LONG lattice | 64 | 7.69e-6 | 1.60e-5 | 1.81e-5 |
| LONG wrap | 16 | 1.18e-5 | 2.30e-5 | 2.30e-5 |
| LONG moving | 16 | 7.16e-6 | 1.66e-5 | 1.66e-5 |
| MID lattice | 64 | 9.00e-7 | 1.58e-6 | 1.87e-6 |
| MID wrap | 16 | 9.27e-7 | 1.55e-6 | 1.55e-6 |
| MID moving | 16 | 8.46e-7 | 1.62e-6 | 1.62e-6 |
| SHORT lattice | 64 | 1.93e-7 | 3.24e-7 | 3.42e-7 |
| SHORT wrap | 16 | 2.98e-7 | 4.17e-7 | 4.17e-7 |
| SHORT moving | 16 | 1.36e-7 | 2.56e-7 | 2.56e-7 |

Each wrap contract passed at `-L`, `-L/2`, just below `-L/2`, `-epsilon`, 0, `+epsilon`, just below `+L/2`, `+L/2`, `+L`, and multiple domains away. Periodicity error after adding two domains was ≤5.7e-14 m.

## C. Off-grid / interpolation

Production uses repeat + linear filtering. For 16 off-grid samples per band, GPU filtered vs native exact vector error (mean / p95 / max, meters) was LONG `0.01525 / 0.05553 / 0.05553`, MID `0.00263 / 0.00740 / 0.00740`, SHORT `0.00169 / 0.00393 / 0.00393`. This is the expected difference between filtered texture sampling and a continuous spectral evaluation, not the lattice parity result.

Bilinearly interpolating native lattice values reduced that residual to LONG `0.000398 / 0.001240 / 0.001240`, MID `0.0000524 / 0.0001138 / 0.0001138`, and SHORT `0.0000214 / 0.0000553 / 0.0000553` m (mean / p95 / max).

## D. Combined material-q

For 64 frozen samples, GPU filtered raw three-band sum vs continuous native combined vector error was mean `0.01798`, p95 `0.04163`, max `0.06924` m. Component errors:

| Component | Mean absolute | P95 absolute | Max absolute | Mean signed GPU minus native |
|---|---:|---:|---:|---:|
| X | 0.01319 | 0.04065 | 0.06168 | +0.00221 |
| Y | 0.00551 | 0.01453 | 0.02295 | -0.00005 |
| Z | 0.00689 | 0.02059 | 0.03141 | +0.00039 |

These off-grid values quantify filtered-render vs continuous-field difference. Against bilinear interpolation of the native lattice, the combined vector residual was mean `0.000440`, p95 `0.001155`, max `0.001395` m. The native combined evaluator vs summing the three individual native outputs was mean `4.23e-8`, p95 `1.33e-7`, max `1.69e-7` m. The 16-sample moved-time combined packet had a `0.000887 m` maximum bilinear-matched residual and `1.19e-7 m` maximum native-sum residual.

## E. Physical vs rendered surface, world-XZ, and normals

**Physical contract:** continuous, camera-independent raw LONG + MID + SHORT spectra evaluated at one common material coordinate. Coastal is disabled. Native physical normals are analytic normals of the combined continuous geometry.

**Rendered contract:** the vertex shader linearly samples all three displacement textures, weights them with camera-distance fades (default ranges SHORT 0–55 m, MID 96–280 m, LONG 768–2500 m), then applies `clipmap_geometry_scale` horizontally and `ocean_surface_scale` vertically. Those camera-dependent render weights and visual optical detail are not included in canonical physics. Production exposes per-band finite-difference geometry normal textures; they are not treated as a replacement for the continuous physical normal.

The world-XZ harness separately checked rendered filtered targets and targets generated from the continuous physical spectrum. For 64 static rendered targets: zero failed inversions; mean / p95 / max iterations `2.30 / 3 / 3`; q recovery error `0.01681 / 0.04243 / 0.07515 m`; horizontal residual `0.000187 / 0.000780 / 0.000985 m`; displacement difference vs filtered target `0.01868 / 0.04263 / 0.07584 m`; height difference `0.00614 / 0.01560 / 0.02350 m`. This is the rendered interpolation difference at the inverse-mapping stage, not a failed continuous inversion.

For the 64 corresponding continuous physical targets: zero failed inversions; q recovery error `0.000202 / 0.000861 / 0.001029 m`; horizontal residual `0.000189 / 0.000820 / 0.000936 m`; displacement error `0.000045 / 0.000189 / 0.000289 m`. The 16 moving physical targets also had zero failures and max q error `0.000865 m`. Inversion used one material-q unknown and per-band conversion once per evaluation. No pathological foldover occurred in these representative packets.

Analytic combined physical normals vs finite differences of combined displacement (64 samples, epsilon 0.01 m) had mean / p95 / max error `0.000106 / 0.000178 / 0.000312`; moving packet max was `0.000284`.

## F. Batch, timing, and runtime

64-sample scalar material-q vs batch vector error was exactly zero. Scalar world-XZ vs batch was exactly zero for both rendered and continuous physical packets (64 static, 16 moving). No per-query GPU readback was used by native queries.

Provisional timing only; hardware was i7-5820K / GTX 970. Values are total scalar / batch microseconds:

| Bands | 1 query | 4 queries | 16 queries | 64 queries |
|---|---:|---:|---:|---:|
| LONG | 12,899 / 5,473 | 10,570 / 10,302 | 55,894 / 50,248 | 207,790 / 231,846 |
| LONG+MID | 23,863 / 5,398 | 28,067 / 40,275 | 153,883 / 173,566 | 412,201 / 395,511 |
| LONG+MID+SHORT | 40,345 / 8,312 | 30,742 / 31,050 | 153,538 / 187,665 | 711,953 / 642,023 |

These timings are **PROVISIONAL ONLY** and are not performance acceptance; final acceptance remains on i7-13650HX / RTX 4070 Laptop.

Godot 4.7.1 loaded the GDExtension, registered `OceanQueryNative`, and instantiated it. No script, GDExtension, or native errors/crashes appeared. Godot printed `Failed to read the root certificate store`, unrelated to native loading.

Clock packet: Production advanced 1x from `0.552651` to `0.561826`; speed 0 held at `0.561826`; resume advanced to `0.571523`. The native evaluator received these explicit caller times; it owns no phase clock. The moving GPU/native packet used the later frozen time `0.579247` after advancing at 1x.

## G. Regression / classification

LONG lattice max vector error remained `1.81e-5 m`, consistent with PHYS-1.3. No TIME-1 code or fixed-step lifecycle was changed. Coastal was not configured, added, or tested in PHYS-2. The harness required a correction to associate combined static packets with the post-resume frozen texture timestamp; no Production physics or rendering math was changed.

**Classification: PHYS-2-A.** The result establishes spectral equivalence, not equality between the continuous physical field and camera-weighted/discretely filtered rendered surface at arbitrary off-grid positions.
