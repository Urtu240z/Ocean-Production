# Ocean Production performance benchmark

The benchmark is isolated in `validation/ocean_benchmark.tscn`. It does not
change production defaults, FFT resolution, clipmap geometry, dynamic
resolution, FSR, or the P0 scene. Each run uses a fixed window size, a 3 s
warm-up and a 5 s measurement window. `smoke` shortens those windows only for
wiring checks.

Run once per required resolution:

```text
Godot_v4.7.1-stable_win64_console.exe --path . --scene res://validation/ocean_benchmark.tscn -- --ocean-benchmark=matrix --ocean-resolution=1920x1080
Godot_v4.7.1-stable_win64_console.exe --path . --scene res://validation/ocean_benchmark.tscn -- --ocean-benchmark=matrix --ocean-resolution=1280x800
```

Quick wiring check:

```text
Godot_v4.7.1-stable_win64_console.exe --path . --scene res://validation/ocean_benchmark.tscn -- --ocean-benchmark=smoke --ocean-resolution=1280x800
```

For a standalone Windows benchmark build, use the dedicated export preset. The
preset carries the custom feature `benchmark`; the project has one conditional
`run/main_scene.benchmark` override while the normal main scene remains P0.
The exported executable therefore starts at
`res://validation/ocean_benchmark.tscn` and does not use `--scene`:

```text
Godot_v4.7.1-stable_win64_console.exe --headless --path . --export-release "Windows Benchmark"
"..\\Ocean Production Benchmark.exe" -- --ocean-benchmark=matrix --ocean-resolution=1920x1080
"..\\Ocean Production Benchmark.exe" -- --ocean-benchmark=matrix --ocean-resolution=1280x800
```

## Definitive B gates

The B sequence is cumulative and non-overlapping. Every case resets the Ocean
runtime to the prior common state before applying its listed additions; the
reported `delta` is always the median of the current case minus the immediately
previous B case.

| Gate | State added | Dependency note |
| --- | --- | --- |
| B0 FLOOR | Environment, camera and light only | No Ocean node |
| B1 STATIC_SURFACE | Ocean surface, FFT off | Optional features off |
| B2 LONG_ONLY | LONG | One active FFT cascade |
| B3 LONG_MID | MID | LONG remains active |
| B4 LONG_MID_SHORT | SHORT | Full FFT; LONG and MID remain active |
| B5 + COASTAL | Coastal | Added to B4 |
| B6 + CREST_FOAM | Crest Foam | Added to B5 |
| B7 + SURFACE_FOAM | Surface Foam | Added to B6; its MID dependency is already present |
| B8 + OPTICS | Optics | Coastal remains enabled as the bake/seabed dependency |
| B9 + REFLECTIONS_SSPR | Ocean-owned SSPR | No camera compositor SSPR |
| B10 + SURFACE_DETAIL | Surface Detail | Added to B9 |
| B11 + UNDERWATER | Underwater Medium | Camera stays above water for cumulative comparability |
| B12 FULL | Sunrays and Bubbles | Added to B11 |

## Geometry and shadow gates

The separate G block uses full FFT and all optional Ocean features off. G0 has
Ocean only, G1 adds `validation/testisland.glb` with directional and island
shadows disabled, and G2 uses the same island with the normal shadow settings.
The production P0 shadow defaults are not changed.

## Output and metrics

Each run writes copyable files to:

```text
user://benchmark_results.txt
user://benchmark_results.csv
```

The console prints the globalized paths. The CSV contains test name,
resolution, warm-up/measure durations, GPU/CPU median milliseconds, derived FPS,
FPS source, wall-frame median, primitive/draw medians when the Godot renderer
exposes them, active FFT cascade count, feature state, and sequential deltas.
If measured GPU/CPU time or renderer counters are unavailable, the field is
`UNAVAILABLE`; derived FPS falls back to the wall-frame median and records
`wall_frame_fallback` rather than pretending it is a GPU measurement.

On Steam Deck, export the dedicated Linux benchmark preset. Its initial scene
is embedded in the executable, so the run also does not use `--scene`:

```text
Godot_v4.7.1-stable_linux.x86_64 --headless --path . --export-release "Linux Benchmark"
./"Ocean Production Benchmark.x86_64" -- --ocean-benchmark=matrix --ocean-resolution=1920x1080
./"Ocean Production Benchmark.x86_64" -- --ocean-benchmark=matrix --ocean-resolution=1280x800
```

Do not infer a Deck result from the PC run.
