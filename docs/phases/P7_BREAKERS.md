# P7 — Breakers

## Phase 1 — Main Mesh Deformation

P7 Phase 1 deforms only the existing Coastal LONG contribution of
`OceanClipmapSurface`. It does not add a solver, RenderingDevice owner, bake
format, texture, viewport, particles, foam, spray, churn, secondary lip, query
representation, or waterline representation.

`Ocean.breakers` is authoring-only and defaults to `false`. The effective state
requires all of: Breakers requested, Coastal waves active, a valid Coastal data
dictionary, and the LONG cascade active. The shader variant is therefore
`*:*:*:nobreaker` for every ineffective case and `*:*:*:breaker` only for the
valid Coastal LONG case. The regular OFF material is
`base:fallback:flat:nobreaker` and is the existing P0–P6 shader source with
only inert P7 markers; it has no P7 uniforms, varyings, texture samples, vertex
math, or fragment normal reconstruction.

The Breaker variant consumes existing Coastal channels only: `field.g` for
shoaling, `field.a` and warp safety for authority, `warp.z` for compression,
`metrics.r` for depth, `metrics.g` for wavelength, and `phase.yz/.a` for local
direction/reached authority. It additionally samples the existing LONG normal
at the same Coastal-warped coordinate, so its three additional samples are
`coastal_phase`, `coastal_metrics`, and `normal_long`.

The environment gate combines valid/reached Coastal authority, a shallow-to-
deep depth window, shoaling, and positive safe Jacobian compression. It is
multiplied by a positive current LONG crest gate. The resulting deformation is:

```text
delta_s = clamp(crest_forward - front_compression,
                ± wavelength_m * max_horizontal_fraction)
long_displacement.xz += local_direction * delta_s
long_displacement.y  += min(positive_crest_height * crest_lift_scale
                            * crest_shape * breaker_strength,
                            positive_crest_height * max_vertical_lift_scale)
```

The crest moves forward, the selected forward face moves back toward it, and
only positive LONG crests receive lift. MID and SHORT remain unchanged. The
Breaker variant interpolates final displaced world position and reconstructs a
derivative geometric normal in the fragment stage, blending it into the macro
normal before P5.5 Surface Detail.

`validation/p7_breakers.tscn` reuses the P4 scene and its external valid
Coastal bake, enables Coastal/LONG/Breakers, exposes an `OceanBreakerProfile`,
and deliberately leaves Underwater Medium off for visual review.

## Status

| Area | State |
| --- | --- |
| Structural | pending senior review |
| Runtime | pending senior review |
| Visual | PENDING — Eric |
| Performance | NOT REQUESTED |
| Waterline parity | PENDING |
| Physics/query parity | PENDING |
| Secondary lip geometry | FUTURE |
| Spray/churn/foam injection | FUTURE |

Promotion blocker: visual deformation approval must be followed by a P7 parity
phase for waterline and query/physics representation before Breakers can become
part of the normal FULL production profile.
