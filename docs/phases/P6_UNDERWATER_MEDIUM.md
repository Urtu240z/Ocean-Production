# P6 — Underwater Medium

## Objective

P6 promotes the active Ocean V3 camera-underwater medium only: camera state,
Beer–Lambert absorption and single-scattering composition over the resolved
post-transparent scene.

## V3 authority

Audited authority: `Water-Race-Ocean-Lab/ocean_v3/rendering/underwater/`
(`ocean_underwater_manager.gd`, `ocean_underwater_effect.gd`, and
`underwater_medium.glsl`) and `ocean_v3/ocean_v3.gd`. The active Lab scene
overrides `absorption_scale = 0.43` and `scattering_color =
(0.0024315654, 0.09275196, 0.13127226)`; absorption RGB `(0.35, 0.14, 0.10)`,
strength `1`, density `0.15`, maximum `120 m`, and both hysteresis margins
`0.05 m` remain the V3 defaults.

## Promoted / omitted

Promoted: POST_TRANSPARENT compute composition, resolved depth/world
reconstruction, V3 sky fallback, flat sea-level path limiting, macro LONG/MID
waterline classification and zero-dispatch above water. Explicitly omitted:
caustics, sunrays, water lens, particles, sediment, Snell/TIR, waterline
distortion, debug modes, artistic grading and benchmarking.

## Architecture and ownership

`Ocean` owns the structural toggle and `OceanUnderwaterMediumProfile` reference.
When enabled it creates `OceanUnderwaterMedium`, which attaches one
`OceanUnderwaterMediumEffect` to the scene's compositor. The effect owns only
its shader, pipeline, sampler and parameter buffer on the render thread; it
uses Godot resolved color/depth directly and allocates no intermediate target.
OFF detaches the compositor effect and releases all of those RIDs. Resource
changes update a mutex-protected CPU packet only; pipeline/RID work never runs
from the Resource callback.

When the system is enabled, the attached effect prewarms its shader, pipeline,
sampler and parameter buffer on the render thread. Above water still returns
before any compute-list creation or dispatch; only framebuffer-dependent uniform
sets wait for a real underwater frame.

The dynamic LONG/MID source route is readiness-gated independently of that
prewarm: `OpenOceanFFT` publishes the solver-owned displacement RIDs only after
both are valid, and P6 retries on startup until it can bind both once. Invalid
sources never reach `UniformSetCacheRD`; a delayed source emits at most one
warning rather than producing per-frame binding errors.

## Camera classification and optical model

The P6 camera assist consumes the shared GPU-authored H0 payloads through a
minimal native, point-only LONG+MID evaluator. It does not read back a
RenderingDevice texture, recreate a CPU grid, or include SHORT. Its committed
ABOVE/UNDER state uses `anchor_y - (sea_level + long_y + mid_y)` and the
profile's asymmetric thresholds. That one state drives both the final render
camera's world-Y-only visual offset and the compositor. The gameplay anchor is
never moved. Full bias is retained around the transition and released by the
configured safe distance; transition sign flips snap rather than interpolating
through the waterline.

Above water exits before compute-list creation or dispatch when this committed
path is active. The prior shader LONG/MID test remains solely as a fallback if
the optional native extension has not been built for the current platform.
Underwater water path is the V3 resolved-depth/world-space ray path (with its
sky-to-flat-plane fallback), clamped to `maximum_optical_distance_m`.

`T = exp(-absorption_coeff_rgb * absorption_scale * path)`

`S = 1 - exp(-scattering_density * path)`

`final = scene * T + scattering_color * S * scattering_strength`

## Configuration and lifecycle

Use **Systems > Underwater Medium** and **System Resources > Underwater Medium
Profile**. The profile contains optical controls plus advanced camera bias,
entry/exit threshold and bias-release controls. It is independent of P4 Optics.
Resize is safe because resolved scene RIDs and
cached uniform sets are reacquired each callback. Shutdown removes the effect
before render-thread resource release.

## Validation

Open `validation/p6_underwater_medium.tscn`. It inherits the existing free
camera; W/A/S/D move, Q descends and E rises. Start above the surface, cross it,
then return above it. Validate a stationary anchor for 30 seconds and both slow
crossing directions. Structural: PASS. Runtime/Visual: PENDING ERIC.
Performance: PENDING ERIC VISUAL PASS.

## Maintenance

SAFE TO MODIFY: profile optical values and validation scene setup.

MODIFY WITH CARE: camera classification, compositor attachment ordering and
resolved-depth reconstruction.

INTERNAL: shader bindings, RD formats, parameter packing, pipeline lifecycle
and shader dispatch dimensions.
