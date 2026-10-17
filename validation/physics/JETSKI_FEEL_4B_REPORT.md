# JETSKI-FEEL-4B — Contact Spring and Damping

## Scope and method

Kept the PHYS-WATERLINE-5 clock, interpolation, DIRECT query, PHYSICS_ALIGNED visual profile, FFT and spectrum unchanged. Normal influence remained `0.50`. The A/B changed only the shallow Water Race contact stiffness and depth-faded contact damping. Deep support, force caps, wet angular damping, draft, mass, COM, inertia, drive, takeoff cleaner, rider controls, and global body damping were not changed.

At wave-speed multiplier `0.5`, ten cases (stationary, small/medium lateral, medium/large head-on, diagonal, high-speed crossing, and three landings) ran at a shared captured ocean phase (`0.775000`). The authoritative clock was held after capture so all 30 candidate trials saw the same field phase. Each trial used the same transform, velocities, and inputs across stiffness candidates. Each scenario ran 1.5 seconds. A second phase-locked selected-candidate check ran small-lateral, large-head-on, and landing cases at multipliers `1.0` and `2.0`.

## Matched damping and immersion

At static equilibrium, each of four contacts supports `300 × 9.81 / 4 = 735.75 N`. Predicted raw support depths are force divided by stiffness. The existing damping fades by `depth / 0.8`; matching its effective damping ratio near equilibrium gives `C(K) = 2500 × (K / 5500)^1.5`.

| Contact stiffness | Contact damping | Predicted equilibrium depth | Measured stationary raw depth | COM relative to waterline |
|---:|---:|---:|---:|---:|
| 5500 N/m | 2500 N·s/m | 0.134 m | 0.148 m | -0.220 m |
| 4250 N/m | 1698.2 N·s/m | 0.173 m | 0.185 m | -0.257 m |
| 3500 N/m | 1269.1 N·s/m | 0.210 m | 0.220 m | -0.293 m |

The corresponding near-equilibrium damping ratio is about `0.33` for all three. Measured stationary effective support depth equals raw depth because no draft offset was active.

## Wave response at multiplier 0.5

Means below cover the six moving-wave cases only. Rates and accelerations are case p95 values averaged across those cases; torque and contact-force spread are also averaged per-case p95 values.

| K / C | Pitch rate | Roll rate | Pitch accel. | Roll accel. | Buoyancy torque | Contact-force spread | 2 cm-to-peak-accel delay | Max raw depth |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5500 / 2500 | 2.29 rad/s | 1.08 rad/s | 31.36 rad/s² | 20.61 rad/s² | 6292 N·m | 4309 N | 1.094 s | 0.655 m |
| 4250 / 1698.2 | 2.55 rad/s | 1.17 rad/s | 31.81 rad/s² | 20.98 rad/s² | 6404 N·m | 4393 N | 0.947 s | 0.675 m |
| 3500 / 1269.1 | 2.31 rad/s | 1.17 rad/s | 31.90 rad/s² | 18.53 rad/s² | 5736 N·m | 3846 N | 0.930 s | 0.744 m |

The response-delay proxy is measured from the first contact-height change of at least 2 cm to peak pitch/roll angular acceleration. It did **not** increase with softer springs, and the six-case average angular accelerations stayed nearly flat. The medium-lateral case did improve pitch rate/acceleration at 4250 (`3.035 → 2.858 rad/s`; `37.90 → 34.91 rad/s²`), while roll acceleration rose (`26.63 → 31.07 rad/s²`). Medium head-on pitch rate improved (`1.859 → 1.729 rad/s`), but pitch acceleration rose slightly (`28.06 → 29.11 rad/s²`). The 4250 result is a mixed compromise rather than a uniform response reduction.

Large-wave authority remained strong at 4250: large head-on p95 pitch/roll rates were `3.153 / 1.682 rad/s`, p95 buoyancy torque was `7419 N·m`, and total buoyancy force peaked at `11.0 kN`. The same case at 5500 measured `1.032 / 0.983 rad/s`, `5232 N·m`, and `9.65 kN`; softer response did not weaken the large wave. The 3500 candidate reached `0.744 m` maximum raw depth in the 0.5 suite and added the most immersion.

## Landing and speed checks

Three repeated landing/re-entry cases used a `-4 m/s` initial vertical velocity. The sampled downward speed is taken after the first integrated physics frame, so it does not preserve the exact initial impact speed. Across those cases:

| K | Mean max raw depth | Worst max raw depth | Peak total buoyancy force | Mean time to `|vy|, |ω| < 0.2` |
|---:|---:|---:|---:|---:|
| 5500 | 0.306 m | 0.404 m | 5.13 kN | 1.02 s |
| 4250 | 0.343 m | 0.404 m | 4.98 kN | 1.06 s |
| 3500 | 0.374 m | 0.404 m | 4.90 kN | 1.16 s |

The 4250 candidate was separately phase-locked at wave multipliers `1.0` and `2.0`; all six verification trials passed. Its maximum measured raw depth was `1.009 m` in the speed-1 small-lateral case, so that sample reached the existing deep-support onset. It did not show a landing collapse; deep support was left untouched.

## Recommendation and runtime state

Use **4250 N/m and 1698.2 N·s/m** as the selected SOFTER setting. It is the intermediate change, improves medium-lateral pitch response and medium head-on pitch rate, keeps the damping ratio near the old value, and retains large-wave authority. The measurements show its trade-offs clearly: it increases equilibrium immersion by about 3.9 cm, does not improve the average angular acceleration or response-delay proxy, and increases large-head-on angular rates. Keep F5 as the manual toggle:

- **RAW:** normal influence `1.0`, `5500 / 2500`
- **SOFTER:** normal influence `0.50`, selected `4250 / 1698.2`

The selected runtime was confirmed at mass `300 kg`, COM `(0, -0.22, 0)`, inertia `(208.087, 172.687, 62.884) kg·m²`, takeoff cleaner ON, DIRECT query, PHYSICS_ALIGNED visual, and zero invalid samples. The F5 A/B was exercised in both directions and restored to SOFTER. No additional FFT, query path, LocalSurface, or root solver was added. Contact query comparison calls were zero; CPU field tick mismatches and visual clock residual were zero.

The 5-second runtime capture reported `69 FPS` mean / `170 FPS` p95, `5.04 ms` mean / `9.19 ms` p95 physics time, `3.83 ms` p95 CPU field update, `36 µs` p95 sample time, and `108 µs` p95 query-batch time. The playtest was unfocused during this capture; the matched trial runner reported `289 FPS` at the end of the 0.5-speed suite and `369 / 327 FPS` at the end of the 1.0 / 2.0 checks. Existing wet angular damping stayed `20 / 15 / 80 N·m·s/rad` (pitch/yaw/roll); no global body damping was added.
