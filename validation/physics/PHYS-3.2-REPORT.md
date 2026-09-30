# PHYS-3.2 — Coastal hardware-filter geometric effect

Result: **PHYS-3-B**. The raw hardware-filter residual is explained, but the 8,192-point final-geometry scan found Coastal displacement differences up to 0.119 m. The residual is not geometrically harmless at all valid Coastal points, so PHYS-3 does not close.

## Validation contract

- Production Coastal shader, bake data, texture formats, sampler state, FFT, native Coastal formula, confidence formula, and detJ threshold were not changed.
- The native query remains deterministic CPU bilinear sampling. No hardware-filter quantization, UV snapping, or GPU-specific behavior was added.
- Probe work used the existing global RenderingDevice on its render thread. No global `submit()`/`sync()`, full texture download, texture readback flag, or per-frame Production readback was used.
- The 8,192-point probe read back 1,179,648 bytes asynchronously (144 bytes per requested point; 3-frame latency in the focused capture).
- Focused Godot run: Godot 4.7.1, D3D12, NVIDIA GTX 970. The 8,192 positions and seed match the PHYS-3.1 stratified scan. Frozen scan time: 0.340624333 s. The separate complete PHYS-3 regression packet also ran at frozen time and a matched moving packet.

## A. Hardware-filter diagnosis

| Check | Result |
|---|---:|
| GPU `texelFetch` vs retained CPU bake texels | Exact; zero mismatches in all detailed Warp and Field channels |
| GPU manual bilinear vs CPU manual bilinear, Warp | max 0.00006104 m; mean 0.00000550 m; p95 0.00006104 m |
| GPU manual bilinear vs CPU manual bilinear, Field | max 0.00000381; mean 0.00000012; p95 0.00000048 |
| Hardware vs CPU manual Warp R | mean 0.012481 m; p95 0.007706 m; max 3.891663 m |
| Hardware vs CPU manual Warp G | mean 0.010111 m; p95 0.007446 m; max 2.837128 m |

The raw source and ideal bilinear sampler agree. The residual exists only in the hardware-filtered sample. The previously isolated 14.058 mm trace had `fy=0.999985`: the ideal bilinear path retained a roughly 0.000015 contribution from a valid texel while the hardware path selected the adjacent invalid texel. At the coordinate magnitude of that trace, float32 ULP was 0.0001221 m; the observed 14.058 mm was about 115 ULP, so direct stored-value rounding does not explain it.

The 8,192-point Warp maxima cluster at interior valid/invalid mask transitions. The normalized texture coordinates are interior; this is not a texture-border or row/column-indexing issue. Neighboring Warp texels can be separated by hundreds to more than a thousand metres. The measured ratio `|hardware−ideal Warp.xy| / max pairwise neighbor-coordinate span` is an effective weight-error estimate, not a claim about a GPU API precision guarantee.

## B. Worst raw Warp samples

Both samples have zero Production confidence, so their large intermediate coordinate errors leave only sub-millimetre final displacement differences.

| Channel maximum | material q | hardware / CPU Warp.xy (m) | abs error R/G (m) | confidence | neighbor span (m) | estimated weight delta | final geometry error (m) |
|---|---|---|---:|---:|---:|---:|---:|
| Warp R: 3.891663 m | (958.4236, -502.9404) | (717.8806, -287.8454) / (721.7723, -289.4058) | 3.891663 / 1.560425 | 0 | 1346.941 | 0.003113 | 0.000175 |
| Warp G: 2.837128 m | (517.5652, -884.0754) | (327.2804, -418.2777) / (325.0428, -415.4406) | 2.237640 / 2.837128 | 0 | 1123.927 | 0.003215 | 0.001084 |

The full top-16 R and G records include q, Field.a, Warp.z/w, both channel errors, neighbor span, estimated weight delta, and final geometry effect in the temporary capture [PHYS-3.2-REPORT.json](C:/Users/Eric/AppData/Local/Temp/PHYS-3.2-REPORT.json).

## C. Confidence buckets

Confidence uses the actual Production expression:

`field.a * smoothstep(0, detj_safe, warp.z) * warp.w`

| Production confidence | Samples | Max raw Warp RG error (m) | Final geometry error mean / p95 / max (m) |
|---|---:|---:|---:|
| 0 | 1,932 | 3.891663 | 0.000462 / 0.001158 / 0.002037 |
| 0–0.01 | 18 | 2.520588 | 0.000495 / 0.001214 / 0.001214 |
| 0.01–0.1 | 31 | 1.485352 | 0.001944 / 0.013306 / 0.022675 |
| 0.1–0.5 | 112 | 1.654724 | 0.007673 / 0.034363 / 0.118597 |
| >0.5 | 6,099 | 0.566101 | 0.000968 / 0.002384 / 0.109310 |
| >0.9 | 5,944 | 0.080139 | 0.000932 / 0.002369 / 0.009593 |

The max geometry case in the 0.1–0.5 bucket is at q=(681.4706, -859.3835): confidence 0.208878, Warp R/G errors 1.073151/1.250946 m, neighbor span 1136.925 m, estimated weight delta 0.001450, and final vector error 0.118597 m (X/Y/Z absolute errors 0.117602/0.009254/0.012229 m).

The highest-confidence scan maximum is q=(739.0181, -526.2), confidence 0.953674: Warp R/G errors 0.080139/0.027161 m and final vector error 0.009593 m. The maximum at confidence ≥0.5 is q=(767.4834, -162.9583), confidence 0.685791: Warp R/G errors 0.438354/0.091949 m and final vector error 0.109122 m. These are not meter-scale Warp errors, but the remaining final displacement differences are centimetric.

For confidence ≥0.5, raw Warp R CPU-vs-hardware error is mean/p95/max 0.004176/0.007690/0.566101 m; G is 0.004141/0.007446/0.536621 m. For confidence ≥0.9, R is 0.003907/0.007629/0.080139 m; G is 0.003930/0.007446/0.027161 m.

## D. 8,192-point final geometry scan

Production GPU hardware-filtered Coastal geometry was compared with a validation reconstruction using CPU/manual Coastal bake bilinear sampling and interpolation-matched FFT lattice samples fetched only for the requested points.

| Final absolute displacement error | mean (m) | p95 (m) | p99 (m) | max (m) |
|---|---:|---:|---:|---:|
| X | 0.000741 | 0.002024 | 0.003649 | 0.118 |
| Y | 0.000259 | 0.000761 | 0.001263 | 0.0132 |
| Z | 0.000329 | 0.000877 | 0.001404 | 0.0506 |
| Vector | 0.000943 | 0.002222 | 0.003875 | 0.1186 |

These outliers exceed the numerical/millimetric envelope despite the small overall mean. This scan therefore does not prove the raw Warp difference harmless.

## E. PHYS-3 regression rerun

| Check | Result |
|---|---|
| Frozen 64-sample LONG Coastal vs native lattice reconstruction | max vector error 0.001785 m |
| Frozen 64-sample combined Coastal vs native lattice reconstruction | max vector error 0.001767 m |
| 16 boundary samples, combined reconstruction | max 0.000478 m |
| Moving request-matched packet, combined reconstruction | max 0.000431 m |
| Open-ocean fallback vs PHYS-2 | exact; max 0 m |
| World-XZ inversion | 64/64; zero failures; mean/max iterations 2.266/3; q recovery max 0.001437 m; horizontal residual max 0.000960 m |
| Physical normals | 16 samples; mean/max error 0.00000988/0.00009256 |
| Scalar vs batch | material/world max difference 0 m |
| Time | 1× advances; 0× freezes; resume advances; moving packet time matched |

No Production rendering or physics behavior changed. The acceptance gate now ignores raw hardware-filter Warp error as a failure by itself, but still requires exact raw texel parity, numerical manual-bilinear parity, and acceptable final geometry. The geometric gate fails on the measured 0.1186 m outlier. No sampler quantization was introduced.

## F. Result and disposition

**PHYS-3-B.** The hardware interpolation mechanism is explained, but confidence suppression is insufficient to make its geometric effect negligible over the complete scan. Do not start PHYS-4. No commit or push.

Pending closure items retained:

1. Crest G / Spindrift clamp discrepancy.
2. P3D.1 travelling phase revalidation after TIME-1 in an initialized Ocean/Carrier scene.
3. P3E handoff revalidation after TIME-1 in an initialized Ocean/Carrier scene.
4. Decide whether to remove, move, or retain TIME-1 audit instrumentation in `gpu_stockham_fft.gd`.
