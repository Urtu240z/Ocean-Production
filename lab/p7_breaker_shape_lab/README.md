# P7 Phase 2E1 — Multi-Phase Breaker Lab

Phase 2E1 retires the single-static Waterline VDM as the active breaker shape.
The LAB now generates an authored `256 × 2048` RGBA16F atlas once at startup:
eight `256 × 256` tiles, one for each phase `P0`–`P7`. The proprietary
Waterline extraction remains temporary reference infrastructure only; it is not
sampled for active breaker geometry.

The scene keeps the validated infrastructure: real Coastal placement, the
BathymetryData signed shore-distance texture, fixed world-space framing,
camera auto-placement, a `32 m × 32 m` safety box, and the production
clipmap's LONG/MID/SHORT surface. There is still one ocean surface draw, no
secondary mesh, no CPU readback, and no topology rebuild.

## Authored VDM contract

Each atlas texel stores the local profile in meters:

* `R` — displacement along the Coastal propagation direction
* `G` — lateral displacement along the wavefront tangent (initially `0`)
* `B` — vertical displacement
* `A` — authored geometric authority

The eight authored profiles are:

```text
P0 SWELL      P1 SHOAL       P2 STEEPEN       P3 CREST
P4 PRE_LIP    P5 PLUNGE      P6 COLLAPSE      P7 DISSIPATE
```

P3 narrows and raises the crest, P4 leans it forward, and P5 is explicitly
non-monotonic: the lip projects forward, then its profile travels backward and
downward beneath the nose before reconnecting with the lower face. This
backward section is authored in `R`; it is not synthesized by a scalar at
runtime.

Along-shore variation is gentle and edge-faded, so the side profile remains
coherent across the wavefront. No noise, foam, spray, or normal texture is
used in this geometry review.

## Travel, authority, and interpolation

Coastal determines **WHERE** the breaker occurs and its propagation frame.
World `shore_signed_distance` increases offshore. The authored profile uses
`+s` toward shore, so the multi-phase sampler converts the world coordinate
with `profile_u = 1 - shore_u`: profile U `0` is offshore/rear and profile U
`1` is shoreward/front. Both the physical shore-distance domain and authored
source span are `12 m`. The signed shore-distance texture remains the travel
coordinate; the cycle is `4.0 s`, travel is `8.0 m`, and motion is toward shore.
This is separate from the VDM phase, which determines **WHAT** shape is shown.

The shader samples both adjacent atlas tiles using the same shore-space V and
the converted profile U,
with a half-texel-safe tile mapping, then blends them with:

```text
phase_pos = lifecycle_phase * 7
phase0 = floor(phase_pos)
phase1 = min(phase0 + 1, 7)
blend = smoothstep(0, 1, fract(phase_pos))
```

Final influence is `depth_authority × lateral_wavefront_envelope × vdm.A ×
lifecycle_visibility`. The same influence controls animated flatten; mode 6
remains the static depth-only flatten diagnostic. Modes 7/8 use the lateral
edge envelope to avoid a rectangular wall at the LAB box edges.

## Controls and HUD

* `5` BASE, `6` FLATTEN_ONLY, `7` VDM_ONLY, `8` COMBINED (default `8`)
* `0` toggles lifecycle animation
* `LEFT` freezes the previous authored phase
* `RIGHT` freezes the next authored phase
* `SPACE` resumes interpolated lifecycle

The HUD identifies `PHASE 2E1 — MULTI-PHASE BREAKER`, `SHAPE SOURCE: OWN
MULTI-PHASE VDM`, the current phase, signed-distance U, travel (`8 m / 4 s`),
and `PROFILE: NON-MONOTONIC PLUNGING`.

When frozen, lifecycle visibility is held at full authority and travel is held
at that phase, making P5 PLUNGE easy to inspect from the fixed oblique camera.
P5 is the primary acceptance view: the crest must project forward, curl down,
pass back above the front face, and leave an open concavity beneath the lip.

## Previous experiment and next architecture

The single Waterline VDM was useful as an architecture and travel proof, but it
failed the target plunging silhouette; changing its horizontal sign only
mirrored the same incorrect fold. Phase 2E1 therefore stops tuning that single
texture and moves the geometry into authored multi-phase profiles.

If the frozen P5 profile still does not read as one convincing breaker, stop
tuning this atlas. The next architecture is **MULTI-PHASE / FLIPBOOK VDM** with
additional authored states interpolated on the GPU.

Production P7, `OceanBreakerProfile`, FFT, Coastal producer/bake, and
`validation/p7_breakers.tscn` are outside this LAB change. The proprietary RAW
file remains under `temp/waterline_source/`, ignored and untracked.
