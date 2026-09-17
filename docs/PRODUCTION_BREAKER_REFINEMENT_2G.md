# Production Breaker Refinement 2G

Open `res://validation/production_breaker_refinement_2g.tscn`.

This is a deliberately small Production prototype. It keeps the real FFT,
Coastal bake, P7 breaker shader, material, lighting and outer clipmap levels.
Only L0 is replaced when `local_breaker_refinement_enabled` is enabled:

- L0 coarse tiles derive their Ocean Space size from `OceanQualityProfile.base_spacing_m`.
- HIGH tiles use half the derived coarse spacing; the largest supported tile divisor
  (16, 8 or 4 cells) is selected so the L0 extent is covered exactly.
- 16 HIGH edge-mask variants plus one COARSE variant are prepared once.
- One world-space region is allowed (`MAX_ACTIVE_BREAKERS = 1`).
- No second water surface, skirt, alpha transition or runtime ArrayMesh rebuild.

The scene selects one shallow point from the real Coastal bake and uses its
render direction and wavelength for the conservative footprint: 2 m rear and
5 m front. The region is world-space, so moving the camera does not move the
HIGH tiles. The validation shell anchors the existing Production clipmap at
the selected bake point; if the host re-centers that clipmap, only the local
MultiMesh transforms are updated.

Controls:

- `F6`: switch A — Production Base / B — Production Breaker.
- `F7`: show or hide the optional tile overlay. Cian is the L0 coarse extent;
  orange outlines are HIGH tiles.

For the reproducible A/B benchmark, run the existing Production benchmark with
the user argument `--ocean-production=2g`. It writes the normal benchmark
outputs under `user://` and reports GPU ms, CPU ms, FPS, total triangles,
HIGH/COARSE tile counts, active batches and runtime ArrayMesh rebuilds.

The historical default profile (`cells_per_side = 192`, `base_spacing_m = 0.25`)
derives 16 coarse cells per tile, 4 m Ocean Space tiles, 0.25 m coarse spacing,
0.125 m HIGH spacing and a 12 × 12 logical grid. This is the compatibility
benchmark for the default geometry.

Reference run (Windows, Forward+, NVIDIA GeForce RTX 4070 Laptop GPU,
1280 × 720): OFF = 1.190 ms GPU / 0.201 ms CPU / 591.37 FPS / 574,848
triangles. ON = 1.202 ms GPU / 0.210 ms CPU / 592.77 FPS / 596,332
triangles, with 15 HIGH tiles, 129 COARSE tiles and 8 active batches. The
geometry delta is +21,484 triangles (+3.74%); runtime ArrayMesh rebuilds are 0.
