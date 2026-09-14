# Ocean V4 Spindrift

Ocean V4 spindrift is an optional, world-space GPU particle system. It is
implemented under `addons/ocean/spindrift/` and is not referenced by Ocean V3.

## Source signal

The source mask reuses the existing `crest_foam_long`, `crest_foam_mid`, and
`crest_foam_short` textures. Their red channel is the residual crest signal
already produced from the FFT displacement Jacobian. The particle shader
combines that signal with steepness from the existing normal textures and
relative displacement height:

`spindrift_source = smooth_crest * steepness_gate * height_gate * storm_strength`

This adds no FFT, no CPU readback, and no permanent Ocean base-path buffer.

## Runtime design

- `Ocean.enable_spindrift` is the master gate. OFF removes the controller and
  its three `GPUParticles3D` nodes.
- Chunks, streaks, and fine mist use independent GPU particle emitters and
  independent materials, with the source sampled in the particle `start()`
  shader. Existing particles keep their world-space transforms when the
  emitter/culling region recenters around the camera.
- The wind direction is the same authored direction passed to the FFT. Wind
  dominates velocity; crest normal kick, spread, and cheap trigonometric
  turbulence are secondary.
- `SOURCE_MASK` creates a temporary subdivided debug overlay only while that
  mode is selected. It is hidden and unallocated by the normal OFF/FULL path.

## Controls

The profile is `validation/profiles/p0_spindrift_profile.tres`. Main controls
are `crest_threshold`, `crest_softness`, `min_wave_strength`,
`emission_density`, `storm_strength`, `wind_velocity_multiplier`,
`crest_kick`, `horizontal_spread`, `vertical_spread`, turbulence controls,
`spindrift_radius`, and per-layer amounts/lifetimes/LOD distances.

Debug modes are `OFF`, `SOURCE_MASK`, `CHUNKS_ONLY`, `SPINDRIFT_ONLY`,
`MIST_ONLY`, and `FULL`.

## Benchmark

Use the existing benchmark with identical camera, resolution, warmup, and
measurement windows:

```text
Godot_v4.7.1-stable_win64_console.exe --path . --scene res://validation/ocean_benchmark.tscn -- --ocean-benchmark=spindrift --ocean-resolution=1920x1080
```

The matrix reports base-with-crest-source, chunks only, streaks only, mist
only, and full spindrift. `spindrift_max_configured_particles` is the exact
GPU particle capacity (the system deliberately does not read particles back
to the CPU).

The visual validation scene is `res://validation/spindrift_storm.tscn`.
