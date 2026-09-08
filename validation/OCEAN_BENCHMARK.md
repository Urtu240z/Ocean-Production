# Ocean Production benchmark

The benchmark runs without the editor or Inspector and uses only the dedicated
scene, the Ocean addon, the tracked rough wave profile and the tracked Coastal
bake.

```text
godot --path . --scene res://validation/ocean_benchmark.tscn -- --ocean-benchmark=deck
```

`deck` runs the complete protocol. For a quick wiring/lifecycle check:

```text
godot --path . --scene res://validation/ocean_benchmark.tscn -- --ocean-benchmark=smoke
```

## Canonical BASE

BASE keeps `Ocean` enabled with the three FFT cascades active, using the tracked
`rough_validation.tres` wave profile and a standard `OceanQualityProfile`.
Optics, Surface Detail, Crest Foam, Surface Foam, Coastal, SSPR, Underwater
Medium, Sunrays and Bubbles are all OFF. Spacing/fill remain at 1.0. The scene
contains only an environment, directional light, camera and Ocean; it does not
depend on the P0 validation scene or local validation assets.

The FFT block changes only the central cascade mask. Feature-isolation cases
reset to BASE before enabling one feature. The production chain is cumulative
in the requested order. The underwater chain uses an underwater camera, while
the above-water chains use the canonical surface camera. `I8` and `I9` are
compatibility cases only; they are not reported as isolated Sunrays/Bubbles
costs. The summary reports `Underwater base = U0 - BASE`, `Sunrays = U2 - U1`
and `Bubbles = U3 - U2`.

Full-minus-one is split into two independent blocks. Surface Full Minus One
uses the above-water camera and removes SHORT, SSPR, Surface Foam, Crest Foam,
Coastal, Surface Detail and Optics. Underwater Full Minus One uses the
underwater camera and removes Bubbles, Sunrays and Underwater Medium. Their
rankings are never combined. `FULL-SHORT` may leave Surface Foam requested but
its runtime state is reported, because MID is the actual Surface Foam dependency.

For every underwater case, lifecycle validation checks the actual P6 effect,
its failed state, `P6 waterline raster state: READY`, and the required compute,
camera-state, raster and framebuffer resources. A present node without an
operational P6 is reported as `UNDERWATER_RUNTIME=FAIL` and fails the benchmark.

Each case waits 3 seconds and measures 5 seconds in the full protocol. GPU
FPS is derived from median GPU frame time; classification is `PASS_60`,
`PASS_40` or `FAIL_40`. If the backend does not expose GPU timing, the output
uses `UNAVAILABLE` instead of silently substituting wall-clock FPS.

The resolution block keeps the output window unchanged and repeats P0..P6 at
3D scales 1.00, 0.85 and 0.70. The environment header prints the active
renderer, adapter, API, window/viewport/internal resolution, scaling mode,
TAA/MSAA, VSync and frame cap. The driver is read from the platform-specific
setting; when Godot does not expose a reliable platform driver setting, the
value is reported as `unknown` rather than using a Windows setting on Linux.
