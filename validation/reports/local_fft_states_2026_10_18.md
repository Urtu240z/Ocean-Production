# Three shared FFT seas — 2026-10-18

Implemented in **Ocean Production only**. Test Add-ons has not been changed.
The exterior retains its authored settings. Ocean owns two independent optional
`OceanLocalSeaState` resources. Area3D footprints select a slot and share its
simulation with all areas selecting that slot. Both use the same inherited wave
profile, Production H0 preparation, native H0 builder and Stockham GPU FFT.
No duplicate surface, reflections, underwater compositor or boat VFX are created.

Authoring: **Ocean → Local Sea States → Local Sea State 1 / 2**, then select
**Sea State** on each `OceanWaveArea3D`. Ocean Space, Sea State and Wave Structure
are exposed on the resources. The two defaults provide calmer starting values.
The previous analytic controls are retired; footprint size/transform, priority,
feather, influence and detail strength remain. Save the level after authoring.

## Correctness

Godot 4.7.1 / Forward+ / D3D12 / RTX 4070 Laptop:

- `local_fft_states_check.gd`: PASS. Three footprints share exactly two additional
  three-band simulations; disabled final users release the corresponding solvers.
- With identical weather/structure settings, sampled final H0 floats are identical
  to the exterior (`h0_relative_error=0.0`). This verifies the same wave model.
- Four actual GPU texture probes agree with native CPU Lite contact fields within
  **0.00984 m** at 128/128/128 CPU resolution; no per-frame GPU readback is used.
- Real CPU contacts select the calm/second FFT state; 100 m feather retains the
  full-strength core, extends outside, and ignores shape Y/height.
- Actual underwater camera sensor matches calm local water. Full horizontal chop
  with independent horizontal scale 1.3 and vertical scale 1.2 also passes (2.5 cm
  tolerance against approximate native CPU Lite).
- A state edit rebuilds its own spectrum; unchanged properties reuse it.
- Local speed runs while the exterior is frozen. Freezing/changing local speed
  preserves phase and does not regenerate the spectrum. Ocean Space changes
  likewise update sampling/presentation without rebuilding H0.
- `wave_area_foam_render_check.gd`: PASS on the real generated hull-foam material.
  Controlled exterior geometry variance 0.008873, calm local approximately zero,
  irregular local FFT variance 0.000795. The exterior test map is an explicit
  fixture, not a claimed steady-state live FFT measurement.

Logs and images: `temp/local_fft_final3.log`, `temp/local_fft_foam_final.log`,
`temp/wave_areas/foam_*_height.png`. Compatibility validation entry points now
delegate to the replacement FFT tests rather than retaining obsolete analytic tests.

## Initial performance measurement

`local_fft_performance_check.gd`: 100 steady samples per configuration; 320×240
test viewport, D3D12, no coastal/reflection/underwater extras. The GPU columns
measure only additional FFT dispatches via RD GPU timestamps. CPU fields are
queried in every active local state, so the two-state case deliberately includes
contacts in both seas. In gameplay an unqueried state does not build a CPU field.

| Total seas | Additional FFT GPU median / p95 | Additional CPU fields median / p95 |
|---|---|---|
| Exterior only | No additional work | No additional work |
| Exterior + one | 0.519 / 0.537 ms | 2.369 / 3.791 ms |
| Exterior + two | 0.593 / 0.968 ms | 2.427 / 3.000 ms |

These are a local microbenchmark, not whole-game frame-time guarantees. GPU
figures exclude the extra surface texture sampling/shading and CPU figures exclude
full vehicle dynamics. First spectrum/field builds are more expensive than steady
updates. The loop's approximately 16.67 ms wall time includes waiting for 60 Hz
physics and must not be presented as measured game FPS. Raw results are in
`temp/wave_areas/local_fft_performance.json`.

## Scope and limits

The visible mesh and underwater raster mix complete FFT displacement at material
coordinates; underwater sensing inverts that combined surface. CPU Lite queries
each local field and blends heights/slopes with the feather gradient. Full-chop
edge inversion remains an approximation, as detailed in the area README.
Local states do not apply the exterior coastal warp/breaker deformation or create
independent whitecap history. Exterior residual foam is suppressed inside them;
boat wake waves/foam remain independent. Global spindrift, breaker carriers and
experimental GPU physics queries still reference the exterior ocean.

No project scene, saved exterior wave/foam tuning or Test Add-ons file was edited.
