# PHYS-GAMEPLAY-BASE-1.1 — Water Query Latency Closure

**Outcome: PARTIAL.** The direct GPU water query remains numerically sound, but the current async readback path does not meet its usable 0–2 physics-tick age budget on the tested system. Stage telemetry isolates the bottleneck to host delivery of the asynchronous readback callback. The measured GPU query itself takes about 0.10 ms; the callback arrives about 36–38 ms after dispatch on the heavy Coastal workload.

## Scope and setup

This work continues `wip/phys-gameplay-base-1` from `80b46dc3d56c1f367da548f306dc67885d7b2e32` on `wip/phys-gameplay-base-1.1`. Tests ran on Godot 4.7.1 official, Forward+ / D3D12, Intel Core i7-5820K and NVIDIA GeForce GTX 970 at 960×540 and 60 Hz.

The full gameplay regression covered calm, normal and storm seas; restoring ±10° tilts; throttle and steering; landing; weather transition; pause/resume; and three Coastal centers, including 3,000 ticks at the historical heavy Coastal location. Dedicated ring-size runs each used the same validated storm transition and 3,000-tick Coastal workload at `(393.939, -991.260)`. Ring sizes 3, 4, 6 and 8 were compared in separate clean processes.

## What the measurements show

| Stage or signal | Heavy Coastal result | Meaning |
|---|---:|---|
| Contact capture to submission | 68–105 μs mean | Small CPU preparation cost |
| Submission to FFT query enqueue | 1.6–2.6 ms mean | Most of the pre-dispatch wait; still below a physics tick |
| Enqueue to render dispatch | 43–72 μs mean | No material render-queue wait |
| Query GPU execution | 99–107 μs mean; roughly 100–118 μs p95 | Not the bottleneck |
| Async readback request to callback | 35.7–37.5 ms mean; 39.1–42.5 ms p95 | Dominant latency stage |
| Callback to CPU publication | 60–80 μs mean; 104–133 μs p95 | Small relative to callback delivery |
| Publication to consumption | Exactly 1 tick p95/max | Consumer adds one predictable tick |
| Field/contact age at consumption | p95 3 ticks | Exceeds the 2-tick acceptance limit |

The field tick is captured before wave time advances. The three authoritative solver dispatches and the query are queued in FIFO order, so the measured dispatch age is zero for the field the query actually evaluates. GPU timestamps and host callback timestamps use separate clock domains; their values are reported separately and are not subtracted from one another.

### Ring-size comparison

| Ring | Usable ticks / 3,000 | Usable | Readback callback mean / p95 | GPU query mean / p95 | Field-age p95 | Coalesced | No-free-slot | Max in flight | Slots used |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 3 | 2,022 | 67.4% | 37.50 / 40.67 ms | 98.9 / 99.8 μs | 3 | 489 | 0 | 2 | 0, 1 |
| 4 | 2,104 | 70.1% | 35.72 / 39.06 ms | 99.2 / 100.1 μs | 3 | 448 | 0 | 2 | 0, 1 |
| 6 | 2,013 | 67.1% | 37.09 / 41.62 ms | 106.9 / 117.5 μs | 3 | 493 | 0 | 2 | 0, 1 |
| 8 | 1,964 | 65.5% | 37.48 / 42.47 ms | 106.6 / 117.2 μs | 3 | 518 | 0 | 2 | 0, 1 |

No run encountered a no-free-slot dispatch attempt. In-flight work never exceeded two; the extra slots in larger rings were unused. Ring growth did not bring the field-age p95 into budget and did not improve the usable-tick rate consistently. Keep the production default at three slots. A slot occupies 229,376 bytes, so larger rings also reserve additional memory without measured benefit.

### Current production sea

The separate 3,000-tick run on the current Production sea provided 2,544 usable ticks (84.8%). There were 454 stale-water rejections and two startup ticks without a result. Field age was mean 2.15 ticks and p95 3. Readback callback time was 34.00 ms mean / 35.60 ms p95; GPU query time was 99.0 μs mean / 99.8 μs p95. This is better than the heavy Coastal scene but still misses the p95 age target.

### Full gameplay regression

The 11,417-tick, three-slot regression completed all requested scenarios and issued 10,489 query batches for 41,956 contacts. There were zero invalid contacts, query errors, mismatches, or blocking reads added. Weather transition completed without an epoch change; paused body and wave time remained unchanged. Query result age in the full run was mean 2.03 ticks, p95 3 and p99 3; the maximum of 62 ticks occurred in setup/reset phases and does not describe the steady heavy Coastal phase. Across the run, the consumer recorded 1,354 unavailable ticks, mostly because results were stale. The primary acceptance failure is therefore the usable-age budget, not query correctness or resource cleanup.

Each isolated ring run shut down with zero owned buffers, in-flight requests, pending results, callback errors or mismatches, and reported `retired=true`.

## Disposition

The evidence does not support shader, surface-math, physics, scheduling, or ring-size changes in this closure. GPU execution is roughly two orders of magnitude smaller than asynchronous callback delivery; callback publication and consumption add little, and the render queue is not congested. Larger rings cannot make the callback arrive sooner and did not improve age acceptance. Keep ring size three and preserve the existing asynchronous, non-blocking behavior.

The report is **PARTIAL** because the measured async callback path misses the 0–2 tick target on this setup despite correct query results and clean shutdown. Any future architecture evaluation should investigate whether force integration can avoid depending on current-tick CPU readback. This report does not assert that a GPU-side path will solve the latency, and no subsequent architecture was started.

## Artifacts and validation

The consolidated machine-readable measurements are in [PHYS-GAMEPLAY-BASE-1.1-MEASUREMENTS.json](PHYS-GAMEPLAY-BASE-1.1-MEASUREMENTS.json). The five per-run measurement files referenced there retain the raw current-sea and ring-size outputs. The instrumented runner supports validation-only ring-size diagnostics; production defaults remain at three. The last superseded-completion counter split was reporting-only and was included in all four dedicated ring runs; the full regression ran before that counter-only change.

