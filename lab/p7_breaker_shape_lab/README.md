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
* `A` — longitudinal profile authority only (cross-shore fade)

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

Profile points are evaluated with a continuous C1 Catmull–Rom spline. RGB is
pure metre displacement; it is not premultiplied by A. The shader applies A
once for longitudinal authority, while its existing lateral wavefront envelope
provides the independent along-shore fade.

Final influence is `depth_authority × lateral_wavefront_envelope × vdm.A ×
lifecycle_visibility`. The same influence controls animated flatten; mode 6
remains the static depth-only flatten diagnostic. Modes 7/8 use the lateral
edge envelope to avoid a rectangular wall at the LAB box edges.

## Controls and HUD

* `5` BASE, `6` FLATTEN_ONLY, `7` VDM_ONLY, `8` COMBINED, `9` TILED_REFINEMENT (default `8`)
* `0` toggles lifecycle animation
* `LEFT` freezes the previous authored phase
* `RIGHT` freezes the next authored phase
* `SPACE` resumes interpolated lifecycle

The HUD identifies `PHASE 2E1 — MULTI-PHASE BREAKER`, `SHAPE SOURCE: OWN
MULTI-PHASE VDM`, the current phase, signed-distance U, travel (`8 m / 4 s`),
and `PROFILE: NON-MONOTONIC PLUNGING`.

When frozen, lifecycle visibility is held at full authority and the travel
offset is `0 m`; only the selected authored phase is held, making P5 PLUNGE
easy to inspect from the fixed oblique camera. SPACE resumes both phase
interpolation and travel.
P5 is the primary acceptance view: the crest must project forward, curl down,
pass back above the front face, and leave an open concavity beneath the lip.

## Phase 2E3 — Pure geometry reference mode

`MODE 7 / VDM_ONLY` preserves the existing FFT + Coastal displacement and only
disables the lab flattening term. It therefore cannot prove whether the
production clipmap topology can represent the authored P5 fold by itself.

The former `GEOMETRY_REFERENCE` mode was a LAB-only reference path. It preserved the
same production clipmap mesh, cells, vertices, P5 atlas, 12 m profile,
phase-freeze logic, and geometric normal reconstruction. Its source coordinate
is now fully parametric: `reference_s = dot(world_xz - origin,
shoreward_reference_direction)` and `reference_profile_u = reference_s / 12 +
0.5`. V uses the same fixed frame and the existing wavefront width. The real
shore-distance texture and Coastal phase direction are not used for shape
mapping. Inside the VDM authority region it removes the base FFT/Coastal
displacement before applying the authored VDM offset. R uses one fixed
shoreward LAB propagation frame, G its fixed tangent, and B world up. No
secondary mesh, topology rebuild, rescaling, coordinate negation, foam, spray,
or production path change is involved.

The reference HUD reports `BASE OCEAN: REMOVED INSIDE AUTHORITY`,
`DIRECTION: FIXED SHOREWARD LAB FRAME`, and `TOPOLOGY: PRODUCTION CLIPMAP`
while mode 9 is active. Bathymetry's sampled gradient remains the offshore
reference used to derive the fixed shoreward frame, but it no longer supplies
the profile coordinate. The atlas stores `R = target_s - base_s`; because
`base_s = (reference_profile_u - 0.5) * 12` and `reference_profile_u` is
derived from `reference_s`, the reference path guarantees `base_s ==
reference_s` and therefore `reference_s + R = target_s`. Before 2E4, atlas U
still came from the real coarse/curved shore signed-distance field, so that former reference mode
was not a completely pure topology test. If the P5 curl appears now, the
production clipmap topology is capable and the remaining problem is the real
shore-space parameterization/integration; stop topology investigation. If it
still reads as a wall or slab, stop modifying P5, signs, Coastal mapping,
coordinate frames, and authority: the next diagnostic is topology, effective
vertex density, or fold representation.

## Phase 2E6 — Topology / vertex-density A-B-C proof

The former density proof used `T` to cycle the LAB-only topology
diagnostic. `T0` keeps the visible production clipmap. `T1`, `T2`, and `T3`
hide it and show the same aligned regular grid covering `S = -6..+6 m` and
`V = -16..+16 m` at progressively finer spacing: production L0, L0/2, and
L0/4. The dense grid from 2E5 is unchanged and is now named T3.

For every diagnostic grid, rows are `v_cells = round(V_extent / spacing)` and
columns are `s_cells = round(S_extent / spacing)`, with
`vertices = (s_cells + 1) * (v_cells + 1)` and
`triangles = 2 * s_cells * v_cells`. The physical extension is exactly
12 m in S × 32 m in V for T1/T2/T3; the cells are centered at the breaker
origin. T0 retains the production clipmap's existing square per-level extent
(`cells_per_side * spacing_level`) and all of its existing levels.

With the current Production quality (`L0 = 0.25 m`), T1 is 48 × 128 cells,
6321 vertices / 12288 triangles; T2 is 96 × 256 cells at 0.125 m,
24929 vertices / 49152 triangles; T3 is 192 × 512 cells at 0.0625 m,
99009 vertices / 196608 triangles. T2 is therefore 4x T1 in triangles and
T3 is 16x T1. T0 reports its existing all-level vertex and triangle totals in
the HUD without changing its production topology.

T1/T2/T3 use the exact same `ShaderMaterial` instance, shader, VDM, and former reference-mode
path, reference frame, P5 parameters, and geometric-normal reconstruction;
only the incoming mesh topology changes. T0 restores every production clipmap
level and hides all diagnostic grids. The grid vertices are local frame offsets
and the diagnostic instances are placed at the breaker origin, so the shader
receives exactly `origin + reference_direction * S + reference_tangent * V`
without double-applying the origin.

Decision gate:

* **A — T0 fails, T1 works:** the production world grid or breaker-frame
  alignment is the main problem.
* **B — T0 fails, T1 fails, T2 works:** effective vertex density is the main
  problem.
* **C — T0, T1, T2, and T3 fail:** stop topology/density investigation. The next
  task must inspect GPU VDM reconstruction/displacement semantics or whether a
  single folded surface can represent the desired breaker.

## Phase 2F1 — Static local refinement tile (superseded by 2F2)

The original `R0/R1` isolated tile proof remains documented for provenance;
the active MODE 9 diagnostic is now the tiled runtime proof described below.
`R0` is one coarse `20 m × 16 m` aligned tile at `0.25 m`. `R1` keeps that
same physical outer extent and transform, but replaces its central
`12 m × 5 m` core with `0.125 m` geometry. Both states are one
`ArrayMesh`, one `MeshInstance3D`, and one material surface; the Production
clipmap is hidden while the LAB diagnostic is active and is never modified.

R1 is a conforming 2:1 transition. The refined core boundary has two fine
segments for every coarse `0.25 m` edge segment. Each transition segment is
filled by three triangles between the fine boundary vertices `A-M-B` and the
coarse outer edge `C-D`. Four coarse corner quads close the transition buffer.
The coarse cells inside the core plus one-cell transition buffer are omitted,
so no coarse triangle overlaps the refined core and no skirt, alpha mask, or
second surface is used.

The R1 accounting is:

* outer regular region: `8040` triangles;
* refined core: `7680` triangles (`96 × 40` cells at `0.125 m`);
* 2:1 transition: `416` triangles (`408` side-stitch triangles plus `8`
  corner triangles);
* total: `16136` triangles and `8213` vertices.

R0 is `5265` vertices / `10240` triangles. The runtime topology check reports
zero non-manifold internal edges for R1, one mesh, and one draw-call-relevant
surface. The refined core uses the exact same shader, `ShaderMaterial`, P5,
VDM, authority, transform, displacement path, and normal pipeline as its
outer region. Only the mesh topology changes.

Phase 2E2 is the first deliberate silhouette redraw after the geometry pipeline
was validated. The previous P5 kept its elevated forward section too long, so
it read as a broad horizontal slab. The new authored P5 uses a short forward
nose, an immediate downward curl, an explicit backward-moving underside, an
open cavity, and a smooth forward reconnection. All other phase points and the
Catmull–Rom evaluator remain unchanged.

## Previous experiment and next architecture

The single Waterline VDM was useful as an architecture and travel proof, but it
failed the target plunging silhouette; changing its horizontal sign only
mirrored the same incorrect fold. Phase 2E1 therefore stops tuning that single
texture and moves the geometry into authored multi-phase profiles. The earlier
stepped/slab appearance was also invalidated by three evaluation errors:
phase overrides still advanced travel, A stayed active at clamped U ends, and
piecewise smoothstep interpolation stopped at every control point.

If the frozen P5 profile still does not read as one convincing breaker, stop
tuning this atlas. The next architecture is **MULTI-PHASE / FLIPBOOK VDM** with
additional authored states interpolated on the GPU.

Production P7, `OceanBreakerProfile`, FFT, Coastal producer/bake, and
`validation/p7_breakers.tscn` are outside this LAB change. The proprietary RAW
file remains under `temp/waterline_source/`, ignored and untracked.

## Phase 2F2 — Tiled runtime local refinement

Mode `9` is the LAB-only tiled refinement proof. It creates a logical `5 × 4`
grid of `4 × 4 m` tiles once at startup. Every tile can point at one prebuilt
mesh: one coarse `16 × 16` cell mesh at `0.25 m` (512 triangles), or one of 16
high `32 × 32` variants at `0.125 m` (2048 triangles before the conforming
transition strips). The variants are selected by a four-bit `N/E/S/W` mask:
bit `1=N`, `2=E`, `4=S`, `8=W`; a set bit means that edge borders a coarse
neighbor and receives a 2:1 conforming stitch. A clear bit borders another
HIGH tile and stays at fine resolution. Corner combinations add only their
disjoint coarse corner cells, so there are no skirts or overlaps.

Press `T` to cycle the manual patterns:

```text
P0  all coarse
P1  one isolated HIGH
P2  3 × 1 HIGH
P3  3 × 2 HIGH
P4  HIGH cross (corner combinations)
P5  moving 3 × 2 HIGH region
```

Every pattern has 20 logical tiles. Their coarse/high counts are respectively
`20/0`, `19/1`, `17/3`, `14/6`, `15/5`, and `14/6`; the HUD reports the exact
active triangle total for each selected mask combination. During P5 movement,
only the tiles whose state changes are reassigned (at most eight assignments
when the 3 × 2 block advances one column).

In P5, press `M` to move the 3 × 2 region one tile horizontally (three
positions). A switch changes only logical state, neighbor masks, and the
`ArrayMesh` assigned to each existing `MeshInstance3D`; it never builds vertex
arrays, indices, or meshes at runtime. HUD counters report active tile counts,
mask variants, triangles, assignments, generated meshes, per-frame rebuilds,
instance/surface counts, and manifold/overlap checks. After startup and after
every switch, meshes generated this frame and `ArrayMesh` rebuilds this frame
must remain zero.
