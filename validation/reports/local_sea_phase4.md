# Local sea performance audit — phase 4
Parent: `2c56b09`.

The surface include now caches the exact sampled displacement and finite-difference surface per slot, within each vertex/fragment invocation. Area ordering, positive influence tests, feather derivative and composition are unchanged. Overlapping areas of the same slot use 3 vertex / 15 fragment band fetches per slot rather than per area. Two different active slots still need 6 / 30 fetches. No new textures, normal approximation, LOD or underwater change.

## Measured fragment kernel, 1280×720
Actual FFT textures; 120 warmup frames and 360 measured frames per case. Original include retained as a validation fixture. Separate sequential control run on the same GPU. Values include canvas raster overhead; disabled case quantifies that overhead.

| Coverage / state arrangement | Original GPU p50/p95 ms | Optimized GPU p50/p95 ms |
|---|---:|---:|
| disabled | 0.014 / 0.016 | 0.014 / 0.016 |
| small_one | 0.032 / 0.034 | 0.031 / 0.033 |
| large_one | 0.152 / 0.153 | 0.152 / 0.154 |
| large_two_same | 0.293 / 0.295 | 0.153 / 0.155 |
| large_two_slots | 0.296 / 0.299 | 0.296 / 0.299 |

Same-slot full-screen overlap falls about 48%. Separate slots and one-area cost remain within approximately 1–2 µs of the control. A preliminary implementation with multiple inlined kernel copies regressed significantly and was discarded; the committed version has one sampling block with cached values.

Full water viewport, zero boats, optimized p50 ms: no areas 0.917, one outside 0.955, one inside 1.106, two same slot 1.165, two slots 1.301. The phase-1 visible-water values were approximately 0.91 / 0.94 / 1.09 / 1.25 / 1.28. This is a smaller whole-water benefit than the isolated repeated kernel: the rest of the water shading remains. Whole-water differences include driver/load variance and are not exact per-draw timestamps.

## Independent diagnostic toggles
One boat, two slots, same camera/path/resolution. Flags exist only in `validation/fixtures/local_sea_diagnostic_runtime.gd`; both local FFT dispatches remain active in all cases. Production exposes no render/physics bypass.

| Local render | Local physics | TIME_PHYSICS_PROCESS p50 ms | Viewport GPU p50 ms | Local field builds |
|---|---|---:|---:|---|
| on | on | 7.078 | 1.329 | 1/slot/tick |
| off | on | 7.326 | 0.984 | 1/slot/tick |
| on | off | 4.189 | 1.346 | none |
| off | off | 4.361 | 0.983 | none |

These scopes distinguish local field/query CPU cost from visual composition cost. TIME_PROCESS remains a separate engine monitor in the JSON. Driver GPU scheduling, engine monitor cadence and wave-responsive vehicle VFX prevent treating the differences as a perfect additive frame decomposition.

## Numerical / visual validation
Twelve HDR image comparisons, 393,216 pixels: full-chop and aligned horizontal scales, same/separate-slot overlap, feather edges, rotated boxes, spheres and cylinders at chop×2. Every image is **byte-identical**, maximum RGB height/slope encoding error 0.

FFT normal-texture substitution was not adopted: the current contract derives normals from four displaced neighbours, including horizontal Jacobian and distance fade. Retaining exactly those samples while eliminating repeated slot evaluations gives a measurable optimization without introducing that approximation. Underwater inputs and shader ABI are untouched. Full underwater/hull regressions and final matrices follow in phase 5.
