# PHYS-WATERLINE-5 — Physics-Authoritative Interpolated Ocean Time

## Implementation

- The Jetski passes `PhysicsDirectBodyState3D.step` to the water provider. The provider advances the shared ocean clock once per physics tick, guarded by the tick index, then builds CPU Lite at that exact current time before sampling contacts.
- Rendering computes `visual_wave_time = lerp(previous_physics_wave_time, current_physics_wave_time, Engine.get_physics_interpolation_fraction())`. The same value is dispatched to LONG, MID, SHORT, the clipmap surface, and the GPU surface query. The Jetski render pose uses `get_global_transform_interpolated()`.
- The normal water query remains DIRECT. No geometry, cascade multipliers, filtering, buoyancy, normal influence, stiffness, damping, mass, drive, or takeoff settings were changed.

## Runtime validation

All captures used `VISUAL = PHYSICS_ALIGNED`, `QUERY = DIRECT`, `DRIVE = RACE`, `TAKEOFF CLEANER = ON`, wind 40 m/s unless noted. The time capture recorded zero visual-clock residual and zero CPU-field/current-physics-time residual at every sampled frame. CPU field tick matched the physics frame; no invalid samples or script errors were recorded.

| Wave speed | Physics wave step | Fixed grid p95 / max | Four physics contacts p95 / max | Moving interpolated-contact spatial error (mean / p95 / max) |
|---:|---:|---:|---:|---:|
| 0.5 | 8.33 ms | 6.46 / 14.23 cm | 5.89 / 5.89 cm | 3.07 / 8.46 / 9.91 cm (112 samples) |
| 1.0 | 16.67 ms | 7.26 / 15.37 cm | 7.00 / 7.00 cm | 2.48 / 8.65 / 9.74 cm (84 samples) |
| 2.0 | 33.33 ms | 6.59 / 14.48 cm | 3.93 / 3.93 cm | 2.94 / 8.29 / 14.15 cm (192 samples) |
| 2.0, wind 8 m/s | 33.33 ms | 7.59 / 16.50 cm | 5.47 / 5.47 cm | 2.27 / 5.61 / 7.47 cm (156 samples) |

The moving metric compares CPU Lite DIRECT against the LocalSurface reference at interpolated Jetski contact positions. Both queries use the current physics field time, so this isolates the spatial surface difference while the separate per-frame clock capture verifies temporal interpolation. It is not a GPU texture readback or a same-frame GPU-versus-CPU measurement. The prior 18.37 cm p95 / 33.12 cm max trace used a different measurement path; the figures above should not be treated as a strict paired before/after sample.

The Jetski was moving in the live race scene, but no scripted throttle input or deterministic drive replay was applied during these captures.

At 8 m/s, a runtime screenshot showed the Jetski riding at the water surface without an obvious hover or deep-sink event in that frame. This was a visual spot check, not a long-duration event count.

## Performance and smoke

- Normal capture at 40 m/s and wave speed 2.0, with the opt-in LocalSurface capture disabled: 239.7 mean FPS (270 p95), physics time 6.43 ms mean (7.24 ms p95), CPU Lite field update 3.99 ms p95, sample query 31 μs p95.
- The explicit moving-contact LocalSurface validation reduced capture FPS (about 46 mean in the longest run) and raised observed physics timing. That validation-only path is disabled in normal gameplay; it does not run unless a capture is requested.
- Startup smoke succeeded. GDScript checks passed for all modified scripts. Runtime console reported no script errors; CPU Lite reported zero field-build failures.
- GPU FFT dispatch cost was not separately isolated. Normal-scene frame rate remained above 60 FPS in the measured run.

## Final scene state

`gameplay/jet_ski_ocean.tscn` is running with wind 40 m/s, wave speed 2.0, PHYSICS_ALIGNED visual water, DIRECT gameplay query, RACE drive, normal influence 0.50, and takeoff cleaner ON.

## Files changed

- `addons/ocean/fft/open_ocean_fft.gd`
- `gameplay/water/cpu_fft_water_provider.gd`
- `gameplay/vehicles/common/core/jet_ski_controller.gd`
- `gameplay/jet_ski_ocean.gd`
- `validation/ocean_surface_detail_wave_time_runtime.gd`
- `validation/physics/PHYS_WATERLINE_5_REPORT.md`
