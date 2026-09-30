# PHYS-3.3 — Deterministic Coastal Geometry Sampling

**Result: PHYS-3-A.** The old maximum final displacement discrepancy of 0.1186 m came from Production's hardware-filtered interpolation of large absolute `Warp.xy` coordinates. Replacing only vertex-path Warp sampling with explicit texelFetch bilinear interpolation brought the 8,192-point scan maximum to 3.141 mm. An interpolation-matched FFT/bake reconstruction agrees with native within 35.7 µm.

## A. Root cause and trace

The retained CPU bake data and GPU raw texels are identical. GPU manual bilinear and CPU manual bilinear also agree to the previously measured float precision envelope. The divergence occurred only when the renderer's hardware linear sampler filtered large absolute world coordinates at valid/invalid transitions. Neighboring Warp coordinates can be hundreds to over a thousand metres apart, so small hardware interpolation-weight differences produce large intermediate coordinates and, where confidence is substantial, real Coastal LONG displacement errors.

At the original worst point from PHYS-3.2, `q=(681.4706, -859.3835)`, confidence was about `0.2095`. Hardware Warp was `(339.3680, -393.2108)` while deterministic bilinear Warp was `(340.4422, -394.4630)`. The old hardware path's final vector error was 118.834 mm. Manual Warp reduced it to 1.196 mm; the interpolation-matched FFT/bake reference residual was 1.94 µm. At the PHYS-3.3 final scan maximum (`q=(153.9007, -282.4335)`, confidence `0.4039`), the post-change final vector residual was 3.140 mm; matching FFT lattice interpolation as well reduced it to 7.92 µm.

The complete top-16 trace from the original final-geometry scan is summarized below. `Field` is RGBA; Warp coordinates are RG in metres; `LONG0` is original LONG displacement; warped LONG values are the previous hardware result and deterministic result. `Total H → M` is old hardware total error followed by post-change manual-Warp error against native. `Exact` is manual Coastal plus interpolation-matched FFT residual.

| idx | material q | confidence | Field RGBA | Warp hardware → manual (RG) | LONG0 | warped LONG hardware → manual | shoal | total error H → M | exact residual |
|---:|---|---:|---|---|---|---|---:|---:|---:|
| 2125 | (681.4706, -859.3835) | .2095 | (11.2765, 1, .4998, .4570) | (339.368,-393.211) → (340.442,-394.463) | (.222,.140,.347) | (-1.198,-.805,-.312) → (-.627,-.837,-.366) | 1.0000 | 118.834 → 1.196 mm | 1.94 µm |
| 6097 | (733.3755, -164.7822) | .4245 | (2.2792,1.0112,.6020,.6523) | (483.964,-106.336) → (482.770,-106.075) | (-1.331,-.103,.879) | (-.179,-.327,-.448) → (-.432,-.305,-.457) | 1.0112 | 110.212 → 1.875 mm | 5.36 µm |
| 6101 | (767.4834, -162.9583) | .6853 | (5.1826,1.0189,.6799,.8281) | (649.308,-133.561) → (648.862,-133.468) | (-1.432,.089,-.508) | (.288,-.277,.220) → (.131,-.271,.258) | 1.0189 | 109.630 → 1.493 mm | 28.76 µm |
| 5806 | (341.4120, -206.9197) | .3308 | (1.6076,1.0337,.6308,.5742) | (199.167,-117.877) → (199.807,-118.256) | (-.017,.019,-.511) | (.040,.923,-.710) → (-.248,.932,-.640) | 1.0337 | 98.565 → .987 mm | .77 µm |
| 2511 | (701.3289, -795.7135) | .3347 | (23.7559,1.0112,.5159,.5781) | (465.409,-460.163) → (466.101,-460.841) | (-1.243,.570,-.282) | (.836,-.660,.354) → (1.081,-.657,.349) | 1.0112 | 83.570 → 1.026 mm | 20.39 µm |
| 2897 | (723.8741, -718.0542) | .6853 | (50.8614,1,.5714,.8281) | (728.847,-595.124) → (728.283,-594.663) | (.853,.172,.082) | (-.372,.104,.127) → (-.333,.111,.052) | 1.0000 | 58.467 → .745 mm | 4.78 µm |
| 1324 | (321.9404, -983.3141) | .2417 | (8.2912,1.0193,.6853,.8438) | (292.235,-831.332) → (291.770,-830.005) | (2.270,-.193,-.329) | (.595,-.604,-.227) → (.415,-.642,-.216) | 1.0193 | 42.977 → 1.004 mm | 2.22 µm |
| 1318 | (255.7834, -994.1740) | .3200 | (.6403,1,.4653,.5664) | (146.049,-564.867) → (145.708,-563.509) | (-1.292,-.184,.213) | (.546,-.354,.438) → (.530,-.317,.535) | 1.0000 | 33.697 → 1.454 mm | 2.00 µm |
| 1868 | (676.6662, -891.3358) | .4403 | (11.7053,1.0241,.6399,.6641) | (478.527,-592.617) → (477.768,-591.678) | (-.271,-.267,.097) | (.283,-.304,.497) → (.325,-.302,.561) | 1.0241 | 33.684 → .187 mm | 7.19 µm |
| 1490 | (742.1432, -957.9003) | .2226 | (1.5683,1,.4919,.4727) | (355.048,-454.356) → (353.755,-452.698) | (.248,-.182,.189) | (-.330,-.161,.096) → (-.431,-.149,.201) | 1.0000 | 31.881 → .837 mm | 1.83 µm |
| 5582 | (695.4825, -249.4535) | .8939 | (4.3128,1,.5518,.9453) | (668.654,-235.118) → (668.839,-235.175) | (-.780,.346,-.039) | (-.083,.586,.029) → (-.118,.588,.022) | 1.0000 | 31.629 → .508 mm | 5.76 µm |
| 4636 | (142.0972, -419.4024) | .4682 | (1.9418,1.0156,.6298,.6836) | (100.455,-286.517) → (100.649,-287.076) | (-.701,.340,.085) | (.189,-.191,.354) → (.139,-.207,.308) | 1.0156 | 31.500 → .696 mm | 4.23 µm |
| 3228 | (150.6489, -651.4403) | .2916 | (1.7285,1.0123,.5796,.5391) | (84.031,-351.378) → (84.318,-352.585) | (.232,1.127,.290) | (-.558,-.098,.223) → (-.500,-.134,.304) | 1.0123 | 31.110 → 1.511 mm | 4.29 µm |
| 5405 | (153.9007, -282.4335) | .4039 | (2.1345,1.0146,.6135,.6367) | (102.038,-179.097) → (101.656,-178.429) | (-1.272,-.120,-.885) | (.180,.672,-.041) → (.234,.654,-.085) | 1.0146 | 28.443 → 3.071 mm | 7.61 µm |
| 4943 | (707.7141, -371.4039) | .7725 | (20.473,1,.4590,.8789) | (674.152,-326.080) → (674.212,-326.109) | (.062,-.403,-.029) | (-1.296,.999,.288) → (-1.327,.992,.284) | 1.0000 | 26.029 → 1.349 mm | 14.5 µm |
| 4381 | (153.7794, -453.0923) | .4764 | (3.4824,1.0158,.6325,.6914) | (113.767,-313.402) → (113.388,-312.357) | (1.056,.384,.482) | (1.020,-.017,.516) → (1.016,-.004,.565) | 1.0158 | 24.454 → .560 mm | 2.08 µm |

## B. Validation matrix and geometry parity

The 8,192 positions are the same stratified scan used for PHYS-3.2. Each row compares final displacement against the native deterministic physical query; the additional manual-FFT result isolates Coastal sampling from expected FFT texture interpolation.

| Path | Vector mean | p95 | p99 | max |
|---|---:|---:|---:|---:|
| Previous hardware Warp baseline | 0.942670 mm | 2.219886 mm | 3.876974 mm | 118.517235 mm |
| Deterministic Warp only (Field remains hardware) | 0.457545 mm | 1.122664 mm | 1.583663 mm | 3.140205 mm |
| Manual Field + Warp diagnostic | 0.455346 mm | 1.117042 mm | 1.573261 mm | 2.325095 mm |
| Manual Coastal + interpolation-matched FFT lattice | 0.0000679 mm | 0.0001192 mm | 0.001301 mm | 0.035602 mm |

The primary production change is Warp only. Manual Field sampling improved the maximum by about 0.815 mm on this scan; it did not justify further shader fetches. Manual Field + Warp is retained as a diagnostic path only.

| Confidence bucket | count | max raw old hardware Warp RG error | post-change final mean / p95 / max |
|---|---:|---:|---:|
| 0 | 1,932 | 3.891663 m | .461482 / 1.160260 / 2.033394 mm |
| (0,.01] | 18 | 2.520588 m | .461380 / 1.219953 / 1.219953 mm |
| (.01,.1] | 31 | 1.485352 m | .396221 / 1.299159 / 1.857705 mm |
| (.1,.5] | 112 | 1.654724 m | .511713 / 1.443085 / 3.140205 mm |
| >=.5 | 6,099 | .566101 m | .455603 / 1.102385 / 2.325095 mm |
| >=.9 | 5,944 | .080139 m | .456572 / 1.104342 / 2.325095 mm |

Old hardware Warp residuals remain a diagnostic and are not the physical parity authority. The post-change actual vertex geometry has no 0.1186 m class error. The exact reconstruction's maximum is 35.6 µm, consistent with float precision and the GPU's FFT lattice sampling. High-confidence Coastal regions remain within 2.326 mm on the actual GPU/native comparison and 29.1 µm on the interpolation-matched reference.

The raw texel identity check was rerun after the shader change: zero Warp and Field texel mismatches. GPU manual bilinear vs CPU manual maximum was 61.04 µm for Warp and 3.81 µm for Field in the focused probe; this is within the previously established precision envelope. Warp RGBA is sampled from the actual 353×354 RGBA32F resource with clamp-to-edge behavior. No UV quantization, fractional-coordinate snapping, sampler-weight emulation, or GTX970/backend-specific path was added.

## C. Production change

`ocean_surface.gdshader` now computes the Warp texel-space position from normalized UV and `textureSize`, clamps four integer coordinates, fetches the four RGBA texels, then bilinearly mixes them. It replaces the vertex Coastal Warp lookup only. Field sampling, Coastal formula, bake content, textures, thresholds, FFT, and rendered parameters are unchanged. The native/CPU query continues to use deterministic mathematical bilinear interpolation and does not emulate renderer-specific filtering precision.

## D. PHYS-3 regression suite

| Test | Result |
|---|---|
| Production source vs retained CPU bake | Exact texel identity; no full texture GPU readback |
| Frozen LONG Coastal smoke, 4 samples | max vector residual 0.636 mm |
| Combined inside Coastal, 64 points | max vector residual 0.636 mm |
| 16 border points | max vector residual 0.464 mm |
| Request-time-matched moving packet | max vector residual 0.431 mm; association valid |
| Open-ocean fallback | exact, max 0 m |
| World-XZ inversion | 64/64; 0 failures; mean/max 2.3125/3 iterations; max q recovery 1.020 mm; max horizontal residual .826 mm |
| Physical normals | 16 checks; centered 1 cm differences; mean/max normal error 1.14e-5 / 9.68e-5 |
| Scalar vs batch | 64 material and 64 world queries; exact agreement in captured result |
| Clock | Production `Ocean.get_wave_time()` only; 1x advances, 0x freezes, resume advances on the same timeline |

Validation used the existing global RenderingDevice path on the render thread. The result buffer used async readback (2-frame latency for the 8,192-point scan; 288 bytes/sample). No global `submit()`/`sync()`, local RenderingDevice, full texture download, Production texture readback flag, or per-frame texture readback was used.

## E. P0 cost and visual comparison

Same P0 scene/configuration on i7-5820K / GTX 970, 1920×1061, 3 s warmup and 5 s measurement:

| Measurement | Before | After | Delta |
|---|---:|---:|---:|
| Full P0 | 34.685 ms | 34.639 ms | -0.046 ms |
| Coastal-off baseline | 33.237 ms | 33.138 ms | -0.099 ms |
| Marginal Coastal cost | 1.448 ms | 1.501 ms | +0.053 ms |

No shader penalty was measurable above run variation. The deterministic helper performs four `texelFetch` operations instead of one filtered lookup: net +3 fetches per Coastal vertex. These GTX 970 numbers are **PROVISIONAL ONLY**; final performance remains for i7-13650HX / RTX 4070 Laptop.

The before/after screenshots used the same P0 camera, resolution, frozen simulation time (`wave_time=0`), and settling frames. Inspection found no visible change to shoreline wave shape, shoaling, propagation direction, Coastal boundary transition, or high-warp/breaker-source regions.

## F. Classification and pending closure

**PHYS-3-A.** The old 118.6 mm geometry outlier is explained and removed by deterministic Production Warp sampling. No Coastal formula or bake behavior was changed; fallback, border, inversion, normals, batch, and clock regressions pass.

Mandatory future items, unchanged in this phase:

1. Crest G / Spindrift clamp discrepancy.
2. Revalidate P3D.1 travelling phase after TIME-1 in a fully initialized Ocean/Carrier scene.
3. Revalidate P3E handoff after TIME-1 in a fully initialized Ocean/Carrier scene.
4. Decide whether to remove, move, or retain TIME-1 audit instrumentation in `gpu_stockham_fft.gd`.

**Next: PHYS-TARGET-READY. Do not begin PHYS-4 yet.**

## G. Git

The PHYS-3 source and validation documentation are being staged by explicit path. Generated DLL/build output, godot-cpp checkout, benchmark output, `.godot`, `.codebase-memory`, generated `.uid` files, and unrelated user benchmark edits are excluded. The final commit hash and push result are reported with the task completion.
