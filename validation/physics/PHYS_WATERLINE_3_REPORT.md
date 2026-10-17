# PHYS-WATERLINE-3 — One-Shot Oracle Seed and Temporal Contact Tracking

## Implementation

- Extended the native LocalSurface hit row with source-space `q.x/q.z`, interpolated from the selected upper triangle using the same hit barycentrics as height and vertical velocity.
- Contact-tracked startup/reset seeding now builds LocalSurface once for the actual persistent contact positions and derives the ±0.4 m normal-probe seeds from each center contact's `q`.
- Added contact invalidation for vehicle resets and a bounded one-frame previous-height fallback. Persistent failures can request a new oracle seed, rate-limited to one attempt per second.
- Added an FFT spectrum-generation counter. When the Production FFT queues a dynamic spectrum rebuild, the provider refreshes the CPU spectrum and invalidates contact histories before reseeding.
- Normal mode remains DIRECT. LocalSurface is not built in DIRECT mode.

## Build and checks

- Rebuilt the Windows x86_64 `template_release` native extension successfully. MSVC emitted an existing `double` to `real_t` conversion warning in LocalSurface wireframe generation; the build completed and linked.
- Godot script checks passed for `cpu_fft_water_provider.gd` and `open_ocean_fft.gd`.
- Startup smoke after restart: DIRECT mode, experimental queries off, LocalSurface build tick `-1`, 0 invalid samples, finite vehicle transform/velocities, no editor runtime errors. Instantaneous FPS estimate was about 332.
- A five-second throttle smoke stayed in DIRECT mode with no LocalSurface build and finite body state.

## Validation results

The persistent contact path was exercised at wind 40 m/s with moving throttle, steering, and rider-shift input. These are diagnostic runs; they did not satisfy the acceptance gate.

| Wave-time scale | Oracle seeds | Failed solver queries | Branch switches | Max temporal height jump | Solver-iteration p95 | Height difference p95 |
|---:|---:|---:|---:|---:|---:|---:|
| 1.0 | 38 | 11,722 | 170 | 4.398 m | 64 | 0.525 m vs direct |
| 0.5 | 32 | 6,118 | 34 | 1.331 m | 64 | 2.350 m vs direct |

Both runs had zero oracle seed failures and zero LocalSurface missed/multi-hit queries. The high seed counts show repeated recovery reseeds during these short runs, so LocalSurface work was not limited to a single startup build. The maximum observed instantaneous FPS estimates were above 190, but the repeated query failures and branch jumps fail the activation gate regardless of frame rate.

A separate 25-point static comparison at the observed phase found the valid contact-tracked results within 8.1 mm mean, 18.2 mm p95, and 24.4 mm maximum of LocalSurface. Direct mode was 139.9 mm mean, 276.0 mm p95, and 320.2 mm maximum from LocalSurface. This confirms that successful tracked roots are accurate while temporal tracking remains unstable in motion. The one LocalSurface validation patch took 18.3 ms to build; it is not included in normal DIRECT gameplay.

## Decision

The activation gate failed due to thousands of moving-query failures, repeated oracle reseeds, branch switches, and meter-scale temporal jumps. The scene was restored to **DIRECT** and is left running in that mode. No gameplay tuning, recovery-radius change, commit, or scene-file mode change was made.

The long acceptance sweep was short-circuited after both 30-second moving passes clearly failed the required failure/continuity thresholds. Oracle-versus-tracked error was checked separately at a static phase; moving-run height differences above are versus DIRECT, not versus a simultaneous oracle capture.

## Files changed for PHYS-WATERLINE-3

- `addons/ocean/fft/open_ocean_fft.gd`
- `addons/ocean/physics/native/ocean_query/src/ocean_query_native.cpp`
- `gameplay/water/cpu_fft_water_provider.gd`
- `validation/physics/PHYS_WATERLINE_3_REPORT.md`
