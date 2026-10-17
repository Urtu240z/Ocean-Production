# Coastal coverage authority

PHYS-OPT-2I changes the authority at the finite authored rectangle. It preserves the retained bake, spectral state, warp interpolation, shoaling equation and physical branch policy.

## Coordinates and units

Use the existing **material-q** coordinate before displacement and the field bake's origin/extent:

```text
uv = (material_q - field_origin) / field_extent
cell_distance = min(min(u, 1-u) * (field_width-1),
                    min(v, 1-v) * (field_height-1))
t = clamp(cell_distance / feather_cells, 0, 1)
edge_weight = t*t*(3-2*t)
```

The accepted width is **one authored cell**, `feather_cells = 1`. Authored cell spacing is `extent/(resolution-1)`. It differs from the normalized texture sampler's spacing `extent/resolution`. For the current 353×354 bake and 1408×1412 m extent, the feather is 4 m on every side. Width is derived independently for X/Z. No world-coordinate constant is embedded in the formula.

The weight is zero exactly at/outside the rectangle, one at least one cell inside, and has zero endpoint derivative. Taking the nearest edge also handles corners. The nearest-edge function can change branch along corner diagonals; this does not promise globally C1 geometry through every corner, bake knot, FFT interpolation knot or existing fold.

## One authority for all final fields

```text
confidence = field.a * smoothstep(0, detj_safe, warp.z) * warp.w * edge_weight
LONG = mix(LONG_open(q), LONG_deep(warp.xy), confidence)
LONG.y *= mix(1, field.g, confidence)
total = LONG + MID(q) + SHORT(q)
```

The coverage factor modifies confidence before both the displacement blend and effective shoaling. Velocity uses that same confidence/height multiplier. The bake and coverage are static in time, so no new temporal derivative is required; the existing weather-envelope and choppiness derivatives remain active. Physical normals/Jacobian continue to come from the final surface, with the existing 1 cm material stencil and upward-normal convention. Newton's stencil and 1 mm acceptance remain unchanged.

Implementations of this canonical formula:

- C++ `coastal_coverage.h`, called by the common `CoastalRuntime::sample`; direct, AVX2 and Dynamic FFT samplers inherit it.
- `coastal_coverage.gdshaderinc`, included by the surface shader, auxiliary underwater surface reconstructions and GPU validation probe.
- `coastal_coverage_contract.gd`, used by CPU validation reconstruction.

The main shader's geometry, Coastal optical-normal authority and auxiliary waterline/caustics/bubbles height queries all receive the same factor. Their remaining formulas and sampler policies are unchanged. CPU bake-authoring utilities return bake fields rather than final wave geometry; their masks and interpolation are unchanged.

## Validation diagnostic

`OceanQueryNative.sample_coastal_bake(qx, qz, diagnostic_feather_texels)` is a read-only diagnostic. It returns shoaling, field validity, warp X/Z, warp determinant, warp validity, final confidence and edge weight. Width zero reconstructs the old hard authority only for validation. It does not change any gameplay sampler setting. All normal query paths use the canonical one-cell width.

No camera, LOD, hardware filtering quantization, GPU readback or scheduler state participates in coverage authority. Outside coverage the full physical result reduces exactly to PHYS-2 open ocean. Beyond the feather, displacement and velocity are identical to the previous Coastal formula. Derivative stencils must also lie beyond the feather to be identical.
