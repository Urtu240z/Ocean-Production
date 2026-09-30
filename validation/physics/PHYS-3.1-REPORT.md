# PHYS-3.1 — Coastal warp sampler diagnosis

Status: **PHYS-3-B retained**. The prior 12.717 mm outlier is explained as finite subtexel precision in the GPU hardware linear filter at a valid/invalid mask edge. The CPU bake source and GPU texture data are identical. The unchanged PHYS-3 gate still rejects the GPU-vs-CPU filtered sample maximum (2 mm criterion); no threshold was changed and no GPU-specific approximation was added to native physics.

## Probe contract

- Samples: 8,192 deterministic stratified UVs plus the original 64 lattice positions; detail packet covers top Warp R/G and 16 clamp probes.
- Rendering device: global Production RenderingDevice. No submit/sync, no full texture readback, no texture usage changes. Only tiny SSBO results were read asynchronously.
- Dimensions: CPU bake, ImageTexture and GPU descriptor all 353×354; RGBA32F; origin (-168.2814, -1217.282), extent (1408.0, 1412.0), cell spacing 4×4 m; UV=(material_q-origin)/extent.
- Generation: runtime=1, CPU snapshot=1, same active/resident bake=True, cache dirty=False, build count=1.

## Worst broad-packet Warp G samples (sorted by |GPU−CPU G|)

| # | material q | warp UV | GPU Warp RGBA | CPU Warp RGBA | abs error RGBA | region |
|---:|---|---|---|---|---|---|
| 1 | (517.5652, -884.0754) | (0.487107, 0.235982) | (327.2804, -418.2777, -1.199525, 0.472656) | (325.0497, -415.4495, -1.191882, 0.469455) | (2.230652, 2.828247, 0.007643, 0.003201) | mask transition (invalid/valid) |
| 2 | (895.8522, -864.209) | (0.755777, 0.250052) | (978.4639, -851.7461, -0.767348, 0.984375) | (981.1182, -854.0409, -0.76954, 0.987033) | (2.654297, 2.2948, 0.002191, 0.002658) | mask transition (invalid/valid) |
| 3 | (398.511, -809.5662) | (0.402551, 0.28875) | (362.4459, -350.8995, -0.710683, 0.433594) | (360.3108, -348.8325, -0.706497, 0.43104) | (2.13504, 2.067047, 0.004186, 0.002554) | mask transition (invalid/valid) |
| 4 | (742.1432, -957.9003) | (0.646608, 0.183698) | (355.0481, -454.3558, 0.732808, 0.472656) | (353.7547, -452.6983, 0.73027, 0.470932) | (1.293427, 1.657501, 0.002538, 0.001724) | mask transition (invalid/valid) |
| 5 | (879.3444, -885.1555) | (0.744052, 0.235217) | (147.107, -135.0078, -0.099279, 0.152344) | (145.3363, -133.3866, -0.098026, 0.150513) | (1.770691, 1.621216, 0.001253, 0.001831) | mask transition (invalid/valid) |
| 6 | (920.3995, -780.9189) | (0.773211, 0.309039) | (484.7571, -345.0345, -0.658543, 0.441406) | (486.9967, -346.6379, -0.661573, 0.443451) | (2.239532, 1.603424, 0.00303, 0.002045) | mask transition (invalid/valid) |
| 7 | (958.4236, -502.9404) | (0.800217, 0.505907) | (717.8806, -287.8454, -0.575007, 0.574219) | (721.7778, -289.408, -0.578129, 0.577336) | (3.897217, 1.562653, 0.003122, 0.003117) | mask transition (invalid/valid) |
| 8 | (206.3029, -944.7876) | (0.26604, 0.192985) | (23.42757, -103.8277, 0.195851, 0.109375) | (23.10496, -102.3979, 0.193154, 0.107869) | (0.322609, 1.429756, 0.002697, 0.001506) | mask transition (invalid/valid) |
| 9 | (255.7834, -994.174) | (0.301182, 0.158008) | (146.0492, -564.8666, 0.751638, 0.566406) | (145.7082, -563.5085, 0.750107, 0.565044) | (0.340988, 1.358154, 0.00153, 0.001362) | mask transition (invalid/valid) |
| 10 | (321.9404, -983.3141) | (0.348169, 0.165699) | (292.2353, -831.3315, 0.19585, 0.84375) | (291.77, -830.0047, 0.195825, 0.842403) | (0.465332, 1.326782, 0.000025, 0.001347) | mask transition (invalid/valid) |
| 11 | (928.7883, -656.4403) | (0.779169, 0.397197) | (63.43305, -33.17447, 0.095626, 0.050781) | (60.91734, -31.85879, 0.091833, 0.048767) | (2.515705, 1.315674, 0.003792, 0.002014) | mask transition (invalid/valid) |
| 12 | (850.2501, -923.0669) | (0.723389, 0.208367) | (871.4137, -888.2473, -0.265455, 0.960938) | (872.6863, -889.5273, -0.266052, 0.962328) | (1.272644, 1.280029, 0.000597, 0.001391) | mask transition (invalid/valid) |
| 13 | (681.4706, -859.3835) | (0.603517, 0.253469) | (339.368, -393.2108, 0.711762, 0.457031) | (340.4422, -394.463, 0.71425, 0.458481) | (1.074219, 1.252197, 0.002487, 0.00145) | mask transition (invalid/valid) |
| 14 | (150.6489, -651.4403) | (0.226513, 0.400738) | (84.03107, -351.3784, 1.008067, 0.539063) | (84.31798, -352.5846, 1.011539, 0.540909) | (0.286903, 1.206116, 0.003472, 0.001846) | mask transition (invalid/valid) |
| 15 | (986.8197, -621.8892) | (0.820384, 0.421666) | (119.1011, -58.33891, -0.127154, 0.09375) | (121.5146, -59.50874, -0.129863, 0.095642) | (2.413483, 1.16983, 0.00271, 0.001892) | mask transition (invalid/valid) |
| 16 | (196.5636, -940.4316) | (0.259123, 0.19607) | (23.83446, -110.6658, 0.194683, 0.117188) | (24.07776, -111.7481, 0.196568, 0.118331) | (0.243299, 1.082314, 0.001884, 0.001143) | mask transition (invalid/valid) |

## Worst broad-packet Warp R samples (sorted by |GPU−CPU R|)

| # | material q | warp UV | GPU Warp RGBA | CPU Warp RGBA | abs error RGBA | region |
|---:|---|---|---|---|---|---|
| 1 | (958.4236, -502.9404) | (0.800217, 0.505907) | (717.8806, -287.8454, -0.575007, 0.574219) | (721.7778, -289.408, -0.578129, 0.577336) | (3.897217, 1.562653, 0.003122, 0.003117) | mask transition (invalid/valid) |
| 2 | (895.8522, -864.209) | (0.755777, 0.250052) | (978.4639, -851.7461, -0.767348, 0.984375) | (981.1182, -854.0409, -0.76954, 0.987033) | (2.654297, 2.2948, 0.002191, 0.002658) | mask transition (invalid/valid) |
| 3 | (885.2693, -248.8779) | (0.74826, 0.685838) | (174.6845, -44.07406, 0.0, 0.179688) | (177.2985, -44.73359, 0.0, 0.182376) | (2.613968, 0.659523, 0.0, 0.002689) | mask transition (invalid/valid) |
| 4 | (928.7883, -656.4403) | (0.779169, 0.397197) | (63.43305, -33.17447, 0.095626, 0.050781) | (60.91734, -31.85879, 0.091833, 0.048767) | (2.515705, 1.315674, 0.003792, 0.002014) | mask transition (invalid/valid) |
| 5 | (937.605, -490.4153) | (0.785431, 0.514778) | (220.2558, -86.00655, 0.0, 0.175781) | (222.6802, -86.95327, 0.0, 0.177716) | (2.424469, 0.946716, 0.0, 0.001935) | mask transition (invalid/valid) |
| 6 | (986.8197, -621.8892) | (0.820384, 0.421666) | (119.1011, -58.33891, -0.127154, 0.09375) | (121.5146, -59.50874, -0.129863, 0.095642) | (2.413483, 1.16983, 0.00271, 0.001892) | mask transition (invalid/valid) |
| 7 | (920.3995, -780.9189) | (0.773211, 0.309039) | (484.7571, -345.0345, -0.658543, 0.441406) | (486.9967, -346.6379, -0.661573, 0.443451) | (2.239532, 1.603424, 0.00303, 0.002045) | mask transition (invalid/valid) |
| 8 | (517.5652, -884.0754) | (0.487107, 0.235982) | (327.2804, -418.2777, -1.199525, 0.472656) | (325.0497, -415.4495, -1.191882, 0.469455) | (2.230652, 2.828247, 0.007643, 0.003201) | mask transition (invalid/valid) |
| 9 | (398.511, -809.5662) | (0.402551, 0.28875) | (362.4459, -350.8995, -0.710683, 0.433594) | (360.3108, -348.8325, -0.706497, 0.43104) | (2.13504, 2.067047, 0.004186, 0.002554) | mask transition (invalid/valid) |
| 10 | (965.1672, -542.2316) | (0.805006, 0.478081) | (963.2596, -401.7325, -0.44697, 0.742188) | (961.2023, -400.8736, -0.446015, 0.740601) | (2.057312, 0.858978, 0.000956, 0.001587) | mask transition (invalid/valid) |
| 11 | (985.0264, -637.4869) | (0.819111, 0.41062) | (807.3834, -411.1074, -0.750459, 0.644531) | (809.2517, -412.0645, -0.752184, 0.646027) | (1.868347, 0.957123, 0.001725, 0.001495) | mask transition (invalid/valid) |
| 12 | (985.9142, -603.58) | (0.819741, 0.434633) | (1123.645, -523.6428, -1.438209, 0.867188) | (1125.502, -524.5099, -1.440598, 0.868622) | (1.857544, 0.867126, 0.002389, 0.001434) | mask transition (invalid/valid) |
| 13 | (879.3444, -885.1555) | (0.744052, 0.235217) | (147.107, -135.0078, -0.099279, 0.152344) | (145.3363, -133.3866, -0.098026, 0.150513) | (1.770691, 1.621216, 0.001253, 0.001831) | mask transition (invalid/valid) |
| 14 | (971.7095, -676.4385) | (0.809653, 0.383033) | (1122.643, -632.1966, -0.501801, 0.933594) | (1124.339, -633.1378, -0.503106, 0.934992) | (1.695801, 0.941162, 0.001305, 0.001399) | mask transition (invalid/valid) |
| 15 | (912.1234, -660.1566) | (0.767333, 0.394565) | (453.8491, -242.5488, -0.511177, 0.367188) | (455.499, -243.4431, -0.513186, 0.36853) | (1.649902, 0.894318, 0.002009, 0.001343) | mask transition (invalid/valid) |
| 16 | (881.4628, -230.7418) | (0.745557, 0.698683) | (892.4935, -217.196, 0.00765, 0.945313) | (894.1191, -217.5914, 0.007694, 0.947035) | (1.62561, 0.395355, 0.000043, 0.001723) | mask transition (invalid/valid) |

All top-16 R and G positions are interior (not near any texture edge) and fall on invalid/valid mask transitions. The texel rows and columns vary; there is no shared row/column pattern.

## Original 64-sample packet

Warp G absolute error: mean 0.000234909472055733 m, p95 0.0001220703125 m, max 0.0140576437115669 m.
Warp R absolute error: mean 5.62464629183523E-05 m, p95 6.103515625E-05 m, max 0.00288261054083705 m.

### Exact maximum G trace

- q: (180.7271, -916.1349); warp origin/extent: (-168.2814, -1217.282) / (1408.0, 1412.0)
- raw/clamped UV: (0.247875, 0.213277) / (0.247875, 0.213277); texture size: 353×354
- texel coordinate: (87.0, 74.99998); x0/x1/y0/y1: 87 88 74 75; fx/fy: (0.0, 0.999985)
- GPU texels (t00,t10,t01,t11): (188.9148, -921.2817, 1.771774, 1.0); (0.0, 0.0, 0.0, 0.0); (0.0, 0.0, 0.0, 0.0); (0.0, 0.0, 0.0, 0.0)
- CPU texels at the same indices: (188.9148, -921.2817, 1.771774, 1.0); (0.0, 0.0, 0.0, 0.0); (0.0, 0.0, 0.0, 0.0); (0.0, 0.0, 0.0, 0.0)
- GPU manual / GPU hardware / CPU bilinear: (0.002883, -0.014058, 0.000027, 0.000015) / (0.0, 0.0, 0.0, 0.0) / (0.002884, -0.014038, 0.000027, 0.000015)
- GPU nearest-1/256 manual candidate: (0.0, 0.0, 0.0, 0.0)
- Absolute hardware-vs-CPU errors R/G/B/A: 0, 0, 0, 0

Cause: texel coordinate Y is 74.999985, so the mathematically bilinear CPU path retains a 0.000015 contribution from the adjacent valid texel; the hardware filter snaps that subtexel weight to the endpoint and returns the neighboring invalid texel value (zero). The retained bake and GPU raw texels agree exactly. The candidate nearest-1/256 reconstruction also returns the hardware value for this trace.

## Raw texel and manual-filter split

- GPU texelFetch vs retained CPU bake: exact for all detailed raw Warp and Field texels; mismatch counts Warp R/G/B/A = 0, 0, 0, 0, Field = 0, 0, 0, 0.
- GPU manual bilinear vs CPU manual bilinear: Warp max 6.103515625E-05, mean 5.50149883510488E-06; Field max 3.814697265625E-06, mean 1.20561804633877E-07.
- GPU hardware vs GPU manual: Warp max 3.89727783203125, p95 2.61396789550781; Field max 0.437507629394531, p95 0.2410888671875.
- Float32 ULP at max bake coordinate: 0.0001220703125 m; the 14.058 mm trace residual is 115.2 ULP, so it is not simple stored-value quantization.
- Edge/clamp probes u/v below 0, 0, epsilon, half texel, 1−half texel, 1−epsilon, 1 and above 1 matched GPU manual to hardware exactly in the sampled clamp packet. The width/height mapping is width for X and height for Y.

## Field control

Broad-packet hardware-vs-CPU Field max errors R/G/B/A: 0.437507629394531, 0.000526785850524902, 0.00214117765426636, 0.00320148468017578; raw source texels match exactly. Field uses the same RGBA32F texture construction/filter path; its channels have different ranges/gradients.

## PHYS-3 regression rerun

- Result from unchanged runner: PHYS-3-B (exit 1 because its existing sampler maximum gate remains 2 mm).
- Frozen 64 material-q: GPU-lattice-interpolation reconstruction max vector 0.00172033323906362 m; direct continuous max 0.0628605484962463 m.
- Boundary reconstruction max vector 0.000454399298178032 m; outside fallback max 0 m.
- World inversion: 64/64, failures=0, residual max 0.000983405403660926 m.
- Normals: 16 samples, max error 9.84559010248631E-05; scalar/batch material/world max 0/0 m.
- Clock: 1× advances=True, 0× freezes=True, resume=True, request-time association=True.
- Performance remains provisional only: i7-5820K / GTX 970.

## Changes and disposition

- Production Coastal shader, bake authoring, physics formulas, thresholds, and native sampler were not changed.
- Validation-only sampler detail decoder was corrected to compute the four-texel bilinear interpolation in standard x-then-y order; the original PHYS-3 scalar CPU sampler was already using that interpolation order.
- No commit or push. PHYS-3 remains B under the unchanged runner gate; do not start PHYS-4.

## Pending closure checklist

- Spindrift spindrift_h1_contract_runtime.gd: Crest G clamp [0,1] discrepancy.
- P3D.1 travelling phase: revalidate after TIME-1 in initialized Ocean/Carrier scene.
- P3E handoff: revalidate after TIME-1 in initialized Ocean/Carrier scene.
- TIME-1 instrumentation in gpu_stockham_fft.gd: remove, move to validation/debug, or retain intentionally at PHYS/debug closure.
