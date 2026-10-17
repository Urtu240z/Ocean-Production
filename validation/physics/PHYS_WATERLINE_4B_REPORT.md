# PHYS-WATERLINE-4B — Moving-Time Coherence Audit

Date: 2026-10-12

## Scope and runtime state

Audited the render/physics wave-time handoff with the gameplay scene running. No water profile, spectrum, force law, or physics tuning was changed. Wave-speed settings were temporarily sampled at 0.5, 1.0, and 2.0, then restored to 2.0.

Final runtime state: visual profile `PHYSICS_ALIGNED`, horizontal multipliers `(0, 0, 1)`, CPU query mode `DIRECT`, `physics_min_wavelength_m = 1.0`, debug validation off, invalid samples 0, field update failures 0, and FPS 337 at the final snapshot. The final HUD reports Water Race, GAMEPLAY SURFACE, mass 300 kg, and DRIVE: RACE.

## Wave-time path

- `OpenOceanFFT._process(delta)` advances its single `_wave_time` by `delta * _wave_speed_multiplier`, sets the rendered surface time, and dispatches the FFT solvers with that same time.
- `CpuProvider.begin_gameplay_contacts()` reads `OpenOceanFFT.get_wave_time()` and builds CPU Lite fields from that value once per physics tick. Direct physics samples use this cached field.
- Thus visual FFT and CPU Lite do not have independent clocks. They share one clock, sampled at different points in the render/physics schedule. There is no clear synchronization bug to fix, so no source gameplay code was changed.

## Live clock and transform snapshots

Six runtime snapshots per speed setting compared the visual FFT clock with the last CPU field clock, and the body physics transform with its interpolated render transform. These are small observational samples, not a full distribution trace.

| Wave speed | Clock delta mean / p95 / max (ms) | Physics vs interpolated XZ mean / p95 / max (cm) |
|---:|---:|---:|
| 0.5 | 3.91 / 6.75 / 6.75 | 0.96 / 2.48 / 2.48 |
| 1.0 | 6.84 / 13.45 / 13.45 | 0.34 / 0.82 / 0.82 |
| 2.0 | 13.46 / 29.74 / 29.74 | 0.98 / 2.39 / 2.39 |

The clock delta is visual time minus the CPU field snapshot. At 2×, the observed maximum is about 30 ms (0.0297 simulation seconds), consistent with a render/physics snapshot gap at the configured speed. Per-sample surface-height time derivatives were not captured, so this time delta cannot be converted reliably into centimeters.

## Same-time surface checks

At 2×, a single same-time direct-vs-LocalSurface validation produced. Its 225 grid positions are fixed world points for that snapshot, arranged around the vehicle; the runner did not keep a separate fixed-world trace across time:

- 225-point fixed grid: mean 2.58 cm, p95 6.83 cm, max 16.48 cm.
- Four Jetski contacts: mean 3.35 cm, p95/max 5.13 cm.
- Invalid samples: 0.

During the debug-only contact validation window, 3,656 valid contact comparisons measured mean 2.27 cm, p95 7.11 cm, max 15.70 cm. The debug flag was turned off afterward.

These compare the direct CPU query with the CPU LocalSurface visual-equivalent oracle built from the same CPU field time. They are same-time oracle results, not a GPU readback of the exact surface pixels visible during each render frame. The earlier PHYS-WATERLINE-4 moving trace recorded mean 7.61 cm, p95 18.37 cm, max 33.12 cm, but its rows did not include the visual clock time; it cannot be phase-paired with this audit’s same-time samples.

## Error classification

- **Temporal:** measured schedule offset is 3.8–29.7 ms across the sampled points. It is the clear moving-time freshness difference, but its height contribution was not isolated in centimeters. Same-time residuals fall to 6.83 cm p95 on the grid and 5.13 cm p95 at the four contacts.
- **Spatial/interpolation:** physics-to-interpolated body-origin XZ offset was at most 2.48 cm in the six-snapshot-per-setting sample. Contact-specific height impact was not separately measured.
- **Cascade weights:** the shader applies camera-distance weights to each cascade’s displacement. At the Jetski contacts near the camera, all three vertical cascade weights are 1.0 (short fades only beyond 55 m, mid begins at 96 m, long at 768 m). GAMEPLAY_SURFACE band weights are `(1, 1, 1)`. PHYSICS_ALIGNED’s `(0, 0, 1)` setting scales horizontal displacement only; shader source preserves vertical FFT height. No close-contact height-weight mismatch is indicated.
- **Wavelength filter:** GAMEPLAY_SURFACE still excludes wavelengths below 1 m. This audit did not isolate their height contribution. The same-time residual is below the 18 cm p95 stop criterion, but cannot be attributed solely to the sub-1 m filter because LocalSurface approximation/interpolation also contributes.
- **Remaining/unknown:** the exact live GPU-vs-CPU per-contact height delta at each paired timestamp, time-derived height contribution, fixed-world live-vs-same-time time trace, and isolated sub-1 m spectral contribution remain unmeasured. The existing validation API does not expose those paired values; the earlier moving trace lacks the timestamp data needed to reconstruct them.

## Conclusion

The moving-only regression is consistent with the render/physics update schedule: CPU Lite samples the shared FFT clock on physics ticks while the rendered surface advances on render frames. This is not a split-clock synchronization defect, and the measured same-time error is below the request’s 18 cm p95 stop threshold. No timing or physics changes were made. A phase-paired height-error decomposition would require additional diagnostic instrumentation; this audit stops without starting another surface-query experiment.
