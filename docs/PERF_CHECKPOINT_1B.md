# PERF CHECKPOINT 1B

Date: 2026-09-09

## Scope

This checkpoint adds the reproducible B0-B12 feature matrix and the separate
G0-G2 geometry/shadow matrix requested after `PERF_CHECKPOINT_1_AUDIT.md`.
Production FFT resolution, clipmap geometry, shadow defaults, and platform
presets are not changed by the benchmark runner.

## SSPR ownership correction

`validation/p0_open_ocean.tscn` no longer attaches a direct
`OceanSSPREffect` compositor to `FreeCamera`. With `Ocean.reflections=true`,
the only SSPR effect is now the one created and owned by Ocean's reflection
runtime. With reflections disabled, the Ocean-owned effect is removed and no
SSPR pass is scheduled by the P0 scene.

## Matrix definition

- B0 is the environment/camera/light floor with no Ocean node.
- B1 enables Ocean with FFT off and all optional features off.
- B2-B4 add LONG, MID, and SHORT cumulatively.
- B5-B12 add Coastal, Crest Foam, Surface Foam, Optics, Ocean-owned SSPR,
  Surface Detail, Underwater Medium, and finally Sunrays+Bubbles cumulatively.
- Deltas are current median minus immediately preceding gate median.
- G0 is full-FFT Ocean only; G1 adds the validation island with shadows off;
  G2 uses the same island with normal shadows.
- Both required resolutions are explicit command-line inputs: 1920x1080 and
  1280x800. Dynamic resolution and upscalers remain off.

## Measurement and output

The runner uses the existing Godot measured viewport GPU/CPU timers when they
return samples. It records `UNAVAILABLE` when they do not. Derived FPS then
uses the measured wall-frame median and marks its source as
`wall_frame_fallback`. Primitive and draw-call medians are collected through
Godot's `RenderingServer.get_rendering_info` constants when available.

The standalone entry points are isolated export presets: `Windows Benchmark`
and `Linux Benchmark`. Both carry the custom feature `benchmark`, and
`project.godot` contains one conditional
`run/main_scene.benchmark="res://validation/ocean_benchmark.tscn"` override.
The normal `run/main_scene` remains P0, and no manual edit is required before
each export. Therefore the exported benchmark executable is launched with the
user arguments only, without `--scene`.

All four export presets explicitly include `*.glsl`, `*.inc`, and `*.source`.
The P6 common source is kept as the raw
`ocean_underwater_medium.glsl.source` asset because it is concatenated through
`FileAccess` at runtime; it is not treated as an imported `RDShaderFile`.
The three Bubble source blocks remain raw `.inc` assets.

The Windows Benchmark Release PCK was regenerated after this change. Its
source-path check covered 23 dynamically loaded/preloaded Ocean shader files
and reported `MISSING_SOURCE_COUNT=0`, including the P6 common `.glsl.source`
and all three Bubble `.inc` blocks. The standalone executable was then run at
1280x800: the P6 diagnostics reported `file_exists=true`,
`resource_exists=false`, `length=21563`, and `file_access_error=0`; B11 and B12
completed without the missing-source error.

Results are written to `user://benchmark_results.txt` and
`user://benchmark_results.csv`; the console prints their globalized paths.

## Validation status

`git diff --check` passes. Godot 4.7.1 headless editor scanning completes
without a script parse error in this workspace. The Windows Benchmark Release
was validated through its real D3D12 executable; the exported-build commands
remain documented in `validation/OCEAN_BENCHMARK.md` for Windows and Linux.
