# Local sea performance audit — phase 3
Parent: `9db6d19`. Windows native batch built with pinned godot-cpp `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`, MSVC 14.44, template_release. Windows DLL included; Linux DLL is unchanged and uses the existing GDScript bridge through capability detection.

## Exact native batch
New `sample_dynamic_lite_local_sea_batch` returns PackedVector4Array [height, slope X, slope Z, VY]. It moves offset construction/result packing across the GDScript bridge into C++; it deliberately retains all five independent world-space surface queries. It calls the existing `sample_dynamic_lite_surface_queries` implementation with the same interpolation, surface scales, query mode and horizontal inverse/fallback rules. Each displaced neighbour performs its own inverse; direct gradients have **not** replaced displaced finite differences. E=0.1 and velocity multiplier are preserved.

Native/GDScript bridge spans differ in packing scope; compare complete sample times below, not a sum of nested timers. These samples exclude field construction (field time held fixed) and compare the exact base bridge with the native batch, interleaved order over 240 iterations after warmup. This primarily measures bridge/packing savings; it does not remove inverse work.

| Slot | Mode | Contacts | Base p50/p95 ms | Native batch p50/p95 ms |
|---|---|---:|---:|---:|
| 1 | DIRECT | 14 | 0.049 / 0.056 | 0.043 / 0.047 |
| 1 | DIRECT | 56 | 0.198 / 0.237 | 0.172 / 0.210 |
| 1 | DIRECT | 84 | 0.290 / 0.363 | 0.257 / 0.336 |
| 1 | DISPLACED | 14 | 0.089 / 0.112 | 0.082 / 0.096 |
| 1 | DISPLACED | 56 | 0.378 / 0.425 | 0.356 / 0.400 |
| 1 | DISPLACED | 84 | 0.565 / 0.681 | 0.527 / 0.604 |
| 2 | DIRECT | 14 | 0.050 / 0.059 | 0.043 / 0.051 |
| 2 | DIRECT | 56 | 0.197 / 0.232 | 0.173 / 0.195 |
| 2 | DIRECT | 84 | 0.290 / 0.385 | 0.256 / 0.320 |
| 2 | DISPLACED | 14 | 0.089 / 0.116 | 0.083 / 0.097 |
| 2 | DISPLACED | 56 | 0.362 / 0.463 | 0.337 / 0.416 |
| 2 | DISPLACED | 84 | 0.550 / 0.694 | 0.517 / 0.638 |

All 24 slot/chop/mode/contact cases pass, including 14/56/84 contacts, chop multipliers 1/2 and 20 positional shifts of 0.75 m (45 m/s at 60 Hz). Max height/slopeX/slopeZ/VY error **0**. Runtime zone composition/reference/lifecycle test also passes 1,120 points with HEIGHT/NORMAL/VY/signed_depth max error **0**.

## CPU fields
Actual builds, 30 warmup + 240 measured iterations, separate native object per resolution. Timings include build invocation; field memory is the native reported field working set, **not** process RSS or total spectrum/GPU memory.

| Slot | Chop multiplier | Resolution | Build p50/p95 ms | Field memory MiB |
|---|---:|---|---:|---:|
| 1 | 1 | 128/128/128 | 1.020 / 1.315 | 13.14 |
| 1 | 1 | 128/128/64 | 0.743 / 0.967 | 9.86 |
| 1 | 2 | 128/128/128 | 0.978 / 1.232 | 13.14 |
| 1 | 2 | 128/128/64 | 0.728 / 0.997 | 9.86 |
| 2 | 1 | 128/128/128 | 1.033 / 1.320 | 13.14 |
| 2 | 1 | 128/128/64 | 0.754 / 1.248 | 9.86 |
| 2 | 2 | 128/128/128 | 0.977 / 1.298 | 13.14 |
| 2 | 2 | 128/128/64 | 0.726 / 0.934 | 9.86 |

The default remains **128/128/128**, around 1.0 ms and 13.14 MiB per state in this CPU-only fixture. Runtime matrix field times were closer to 1.1–1.2 ms under the render/vehicle workload. There is still only one field build per state per tick; the native batch does not change that cost.

## Rejected resolution experiment
128/128/64 saved approximately 0.25–0.28 ms and 3.28 MiB per state. It is **not adopted**. At slot 2/chop×2, this sample set observed max HEIGHT error 0.257 m, slope X 1.401, slope Z 1.137, VY 0.381 m/s. Even lower-chop cases differed. JSON retains every result. No saved settings, exterior FFT, Jet Ski physics, Planar or tsunami changed.

Limits: CPU-only benchmark runs headless and makes no GPU/FPS claim. The native batch offers a modest query improvement, not a large total-frame speedup. Full-scene before/after remains the final validation task.
