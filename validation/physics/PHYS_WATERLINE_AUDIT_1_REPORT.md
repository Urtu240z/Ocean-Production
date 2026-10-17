# PHYS-WATERLINE-AUDIT-1 — Runtime Waterline Audit

## Finding

Two separate issues were measured:

1. Runtime spectrum edits rebuilt the visual ocean but left `PhysicalWater.fft` pointing at the freed pre-edit `OpenOceanFFT`. CPU Lite kept sampling its previously imported H0. This synchronization bug is fixed in `cpu_fft_water_provider.gd`.
2. A large waterline mismatch remains after synchronization. The direct gameplay query evaluates the height at world XZ; the visible-equivalent LocalSurface follows the horizontally displaced, forward-mapped ocean. At some positions the resulting vertical difference exceeds 1 m. This is not a constant draft error.

No buoyancy, damping, normal influence, inertia, mass, or draft values were changed.

## Runtime parameter path

- `wind_speed_mps`, `wind_direction_degrees`, `significant_wave_height_m`, `wave_height_scale`, `long_wave_spacing`, `mid_fill_amount`, and the LONG/MID/SHORT band scales request a debounced Ocean rebuild (0.15 s). The rebuild preserves wave time, shuts down the old `OpenOceanFFT`, then initializes a new FFT and H0 from the current Ocean parameters and seed.
- `wave_speed_multiplier` is forwarded directly to the live FFT and does not rebuild H0. CPU Lite reads that same FFT’s wave time and simulation time scale each physics contact phase.
- The visual snapshot API exposes the final H0 byte arrays used by its FFT solvers. Before this audit, the CPU provider copied those arrays only in `configure()`; a later Ocean rebuild did not refresh the provider’s stored FFT reference or native spectrum.
- The provider now checks the current `OpenOceanFFT` child during contact setup. It imports the three snapshots only when the FFT instance changes, then builds the next CPU field from that instance’s wave time. H0 is not copied each physics tick.
- The other rebuild inputs were source-traced through the same `Ocean.initialize()` call into `OpenOceanFFT.initialize()`; only Wind Speed was varied live in this audit. Runtime Direction, Significant Wave Height, and LONG/MID/SHORT edits were not individually exercised.

## Wind-speed synchronization test

The live Remote-equivalent property path was used: 40 → 12 → 24 → 40 m/s. For the matched-phase 40→12 comparison, wave speed was temporarily set to zero; both grids used the same 7×7 positions, 1 m spacing, and exact wave time 212.185759 s. The test values were restored afterward.

| Band | H0 hash at 40 m/s | H0 hash at 12 m/s |
|---|---:|---:|
| LONG | 2770334873 | 2419220705 |
| MID | 1709276678 | 4209287694 |
| SHORT | 1122654252 | 2530801071 |

At both states, all three CPU-imported-snapshot hashes matched the corresponding visual FFT snapshot hashes. The exact snapshot byte arrays are passed to `set_production_spectrum`; each CPU diagnostic row also reported the selected wind speed. The FFT instance changed and the provider refresh counter advanced once per rebuild. Visual and CPU wave times were exactly equal at the matched sample (212.185759 s).

Before the fix, changing wind to 12 m/s left the CPU provider’s FFT reference invalid while the visual FFT had rebuilt at 12 m/s. Its previous field remained marked ready and continued rebuilding without an error, so it could silently use stale H0.

## Wave-clock test

The CPU field time was sampled against `OpenOceanFFT.get_wave_time()` at 1.0 and 0.5 wave-speed multipliers over two intervals each.

- At 1.0: differences were 0 and 10.7 ms.
- At 0.5: differences were 2.5 ms and 0 ms.

No accumulating phase drift was observed. The original runtime multiplier of 2.0 was restored.

## Height parity

`LocalSurface` is used as the visual-equivalent CPU oracle. It is built only by an explicit audit call or while both F4 advanced diagnostics and F3 waterline overlay are enabled. It uses the same imported CPU Lite spectrum, so it isolates the difference caused by querying the forward-mapped surface at world XZ; it does not reproduce the full GPU FFT’s omitted sub-1 m detail.

Static 7×7 grid, 1 m spacing, centered near the initial craft position at the default 40 m/s wind, wave time 26.280871 s:

- Absolute height error: mean 33.5 cm, p50 23.5 cm, p95 100.4 cm, max 115.8 cm.

Matched-position, matched-wave-time wind comparison at the fixed grid around `(-68.397, -66.852)` XZ, wave time 212.185759 s:

| Wind | Mean | p50 | p95 | Max |
|---:|---:|---:|---:|---:|
| 40 m/s | 16.0 cm | 10.6 cm | 34.2 cm | 65.6 cm |
| 12 m/s | 16.0 cm | 10.6 cm | 34.7 cm | 65.7 cm |

All 49 samples were valid. This matched test shows that changing wind changes H0 correctly but does not materially change the direct-versus-forward-mapped height error at that fixed phase and location.

At low wind (12 m/s), one live four-contact snapshot at wave time 111.992041 s measured:

| Contact | GAMEPLAY_SURFACE | LocalSurface | Gameplay − visible-equivalent |
|---|---:|---:|---:|
| FL | 57.2 cm | 15.9 cm | +41.3 cm |
| FR | 52.3 cm | 6.6 cm | +45.8 cm |
| RL | 82.8 cm | −9.8 cm | +92.6 cm |
| RR | 82.9 cm | −11.7 cm | +94.6 cm |

For this sample, absolute contact error was mean 68.6 cm, p95 94.6 cm, max 94.6 cm. Hull-point Y was 60.9, 88.3, 143.4, and 165.3 cm above the LocalSurface heights. The craft was moving at about 0.93 m/s, so this snapshot includes genuine airborne/dynamic immersion as well as the surface mismatch.

In a later default-wind debug frame, the four signed height errors were −60.2, +46.8, +103.7, and −112.8 cm. Thus the largest observed apparent support-above-visible-water error was +103.7 cm; the largest opposite-direction discrepancy was 112.8 cm. Spatial and temporal variation rules out a constant draft offset.

## Error sources and limits

- **Direct XZ versus horizontal choppiness:** dominant measured source. At the low-wind contact snapshot, the native FULL_DISPLACED query differed from DIRECT by −34.3, −38.1, −97.2, and −44.9 cm. LocalSurface was the rendered-geometry reference for the reported waterline deltas.
- **Inverse-query / LocalSurface reconstruction remainder:** LocalSurface versus FULL_DISPLACED differed by about 7.0, 7.6, 4.7, and 49.7 cm at those same contacts. The rear-right residual is large and should be treated as unresolved inverse/reconstruction error, not as a separately validated GPU effect.
- **Wavelength filtering and omitted short modes:** not isolated against the GPU in this audit. LocalSurface uses the CPU Lite spectrum with the gameplay 1 m minimum wavelength, so it cannot measure GPU-only sub-1 m detail.
- **Distance fade, scale, and sign:** the query contract supplies the current geometry/height scales and fade ranges to the displaced path. Errors change sign across contacts and vary across the grid; the data does not support a fixed scale/sign offset as the primary cause. Their individual contributions were not isolated from the contact capture.

The measured contact and grid discrepancies exceed the practical 20 cm threshold. A runtime H0 synchronization bug was fixed, but the remaining large error is primarily the intentional DIRECT-versus-forward-mapped surface difference, with a separate sizeable RR reconstruction residual. This audit does not change gameplay to compensate for either.

## Debug view and runtime health

- F4 enables advanced diagnostics; F3 enables the waterline overlay. GREEN marks LocalSurface, RED marks GAMEPLAY_SURFACE, WHITE marks the hull point, and CYAN joins the two water heights. The HUD reports FL/FR/RL/RR signed errors, hull offsets to both surfaces, and direct-query Vy.
- The overlay was left enabled in the running scene. At capture it showed 71 FPS and about 16.9 ms physics time. LocalSurface patch generation averaged 15.0 ms with p95 21.1 ms in the debug view; direct query batches averaged 0.045 ms. Normal gameplay does not build LocalSurface unless the debug overlay or explicit validation is used.
- Final runtime settings restored: wind 40 m/s, direction 210°, wave-speed multiplier 2.0, seed and all spectrum controls as loaded from the gameplay scene.
- CPU field failures: 0. Invalid gameplay samples: 0. Invalid LocalSurface samples in tested grids: 0. Editor error console: 0 errors. No NaN state was observed in the sampled body/query telemetry.

## Files changed

- `gameplay/water/cpu_fft_water_provider.gd` — refresh CPU Lite spectrum after FFT replacement; expose H0 identity diagnostics; correct explicit query-mode validation and add grid audit statistics.
- `gameplay/jet_ski_ocean.gd` — add F4/F3-only waterline HUD and GREEN/RED/WHITE markers with vertical connectors.
- `validation/physics/PHYS_WATERLINE_AUDIT_1_REPORT.md` — this report.
