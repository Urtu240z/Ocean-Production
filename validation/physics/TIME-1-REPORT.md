# TIME-1 — Breaker/Crest fixed-step time conservation

Date: 2026-09-29
Engine: Godot 4.7.1 stable
Fixed cadence: `STEP = 1/30 s`

## A. Before fix

The original 10 s wall-time / 2× wave-speed case reproduced. Solver dispatch input totaled 20.090492 s; production `wave_time` advanced about 20.093 s (the difference is the audit boundary). Crest began with 0.031074 s already accumulated.

| Counter | Before fix |
| --- | ---: |
| Simulation delta input | 20.090492 s |
| Crest time returned/consumed | 24.309119 s |
| Final Crest remainder | 0.021566 s |
| Initial Crest remainder | 0.031074 s |
| Conservation error: consumed + final − input − initial | **+4.209119 s** |
| Lifecycle time advanced | 24.233333 s |
| Lifecycle fixed steps | 727 |

Expected was about 600 lifecycle steps for about 20.1 s of simulation time. The instrumentation directly showed time being consumed twice; this was not inferred from frame count alone.

## B. Root cause and fix

`_prepare_crest_update()` added the incoming delta, returned the entire accumulator, and retained `fmod(accumulator, STEP)`. The fractional remainder therefore went both to Crest/lifecycle consumers and into the next update.

The accumulator now returns only `floor(accumulator / STEP) * STEP`, subtracts exactly that amount, and retains the sub-step remainder. Crest and the existing lifecycle loop continue to receive the same `crest_delta`; the lifecycle's second accumulator and catch-up loop remain in place. The fixed cadence remains 30 Hz.

## C. After fix — original case

| Wall | Wave-time delta | Simulation input | Crest consumed | Initial + final remainder | Lifecycle time | Steps | Expected | Difference |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10.0068 s | 20.080468 s | 20.080468 s | 20.100000 s | 0.020930 + 0.001398 s | 20.066667 s | 602 | 602 | 0 |

The Crest conservation residual is within float accumulation noise. Lifecycle's runtime-observed interval is within one 1/30 s boundary step of wave time.

## D. Wave-speed matrix

Each run accumulated at least about 300 lifecycle steps. Expected count is `round(wave_time_delta * 30)`; observed lifecycle count differs by at most one step.

| Multiplier | Wall | Wave delta | Lifecycle delta | Steps | Expected | Difference |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.5× | 20.01 s | 10.02 s | 10.03 s | 300 | 301 | -1 |
| 1.0× | 10.01 s | 10.06 s | 10.07 s | 301 | 302 | -1 |
| 2.0× | 5.01 s | 10.08 s | 10.07 s | 302 | 302 | 0 |
| 3.0× | 3.35 s | 10.18 s | 10.17 s | 306 | 305 | +1 |

Across runs, `Crest consumed + final remainder` matched `simulation input + initial remainder` within float precision; no cumulative drift was observed.

## E. FPS matrix

Validation-only window/render settings were used to reach the requested frame rates while keeping FFT, Crest and lifecycle active. Optional presentation effects were disabled for this load-control run. Each sample spans approximately 10 simulation seconds.

| FPS cap | Measured FPS | Wave delta | Lifecycle delta | Steps | Expected | Difference |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 30 | 30.00 | 10.13 s | 10.13 s | 304 | 304 | 0 |
| 45 | 45.00 | 10.04 s | 10.07 s | 301 | 301 | 0 |
| 60 | 60.00 | 10.07 s | 10.07 s | 302 | 302 | 0 |
| 90 | 90.00 | 10.04 s | 10.07 s | 301 | 301 | 0 |
| 144 | 144.01 | 10.01 s | 10.00 s | 300 | 300 | 0 |
| Uncapped | 220.08 | 10.02 s | 10.03 s | 301 | 300 | +1 |

Lifecycle progression remained within one boundary step across render rates.

## F. Pause and resume

- At 1×, wave and lifecycle advanced about 3.04 s / 91 steps; Crest conservation held.
- At 0×, wave delta, Crest input/consumption and lifecycle delta were all zero; the existing fractional accumulator remained unchanged.
- After returning to 1×, both clocks resumed on the same timeline, with 91 lifecycle steps for about 3.06 s. No duplicated catch-up burst occurred.

## G. Regression checks

- `validation/breaker_lifecycle_contract_test.gd`: **PASS**; lifecycle duration, refractory boundary (2.99 s blocked / 3.00 s allowed), and score arbitration passed.
- Live Production P0 breaker/event smoke at 2×: Crest publication was active; detector readbacks were valid; an event was observed with seed time 25.1000 s, acquisition time 25.3000 s, age 0.2000 s, score 0.6808. This confirms the autonomous event path still generated and aged a real event.
- The 0.5×–3× matrix exercised simulation-time scaling (G0.4 behavior) with lifecycle enabled.
- `validation/spindrift_h1_contract_runtime.gd` did not pass: it reports that Crest G is not visibly clamped to its documented 0..1 range. This is outside the TIME-1 diff and was not changed here; it is recorded as an existing contract discrepancy, not attributed to the accumulator fix.
- P3D.1 travelling phase and P3E handoff were not independently runtime-validated in the initialized carrier scene during this pass. A detached carrier-report attempt was invalid because those reports require an owning Ocean scene; it produced no usable result. No carrier, shader, or handoff code changed.
- FFT kernels, spectrum, lifecycle shader, detector cadence, thresholds and authoring parameters were not changed. The P0 event smoke completed without a TIME-1 runtime error. Godot also emitted its existing Windows root-certificate-store warning.

## H. Classification

**TIME-1-A** — the original over-consumption reproduced and was directly measured, the isolated accumulator correction restored time conservation, the original 10 s / 2× case returned to 602 steps, all requested multiplier/FPS/pause checks passed within the one-step boundary tolerance, and a live breaker event still advanced. The separate Crest clamp contract discrepancy and the unrun scene-dependent P3D/P3E checks are disclosed above.

## I. Repository scope

TIME-1 code change: `addons/ocean/fft/gpu_stockham_fft.gd`.
Validation report: `validation/physics/TIME-1-REPORT.md`.
No physics parameters, wave/FFT math, shaders, or production rendering behavior were changed.
