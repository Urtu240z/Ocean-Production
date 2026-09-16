# H2.4 — Breaker scale parity and real camera culling

## Contract

Breaker dimensions derived from Coastal `metrics.g` remain in Ocean Space. The breaker block derives its crest/lip/compression distances and horizontal cap from the authored wavelength, then adds the result to `long_displacement`. The existing final surface transform applies:

```glsl
surface_displacement.xz *= clipmap_geometry_scale;
surface_displacement.y *= ocean_surface_scale;
```

Thus horizontal breaker displacement is `D.xz * H` and vertical breaker displacement is `D.y * V`, with no `H²`, `V²`, or cross-coupling. Depth gates, shoreline/bathymetry coordinates, Coastal origin, and water depth remain world-space data and are not scaled.

The AABB breaker allowance follows the same contract: `longest_wavelength * max_horizontal_fraction * abs(H)`. The FFT allowance remains the conservative effective-Hs/choppiness bound from H2.3. Vertical breaker allowance remains authoring-space lift multiplied once by `V`.

## Validation

`validation/ocean_clipmap_gpu_bounds_runtime.gd` now validates:

- linear horizontal breaker displacement at `H = 0.5, 1, 2, 4`;
- independent H/V axis scaling for the required six combinations;
- exact H=1/V=1 baseline parity within float tolerance;
- absence of the old shader-side `metrics.g * clipmap_geometry_scale` expression and any V² expression;
- real `Camera3D` frustum planes at height `8 m`, with the camera rotated through `-25, -10, 0, 10, 25, 40` degrees and H `0.5, 1, 2, 4`;
- the Ocean Surface rotation remaining zero while only the camera rotates;
- every effective authored AABB that intersects the camera frustum also being covered by its published `custom_aabb`.

The test emits `OCEAN_BREAKER_HORIZONTAL_SCALE_PARITY_PASS`, `OCEAN_BREAKER_AXIS_SCALE_CONTRACT_PASS`, `OCEAN_BREAKER_BASELINE_PARITY_PASS`, and `OCEAN_CLIPMAP_REAL_CAMERA_CULLING_PASS`. GPU visual validation remains a separate result and must not be inferred from the renderer-independent checks.
