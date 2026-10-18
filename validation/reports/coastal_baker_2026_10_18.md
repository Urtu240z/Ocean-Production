# Portable coastal baker — 2026-10-18

## Complete-terrain workflow update

The default workflow now exposes a single **Terrain** slot and a **Bake** button.
All active Terrain3D regions are included automatically. Terrain Resolution
sets samples along the longest axis (512/1024/2048); spacing is derived from
the whole extent. Manual bounds and solver settings are hidden behind Advanced
Settings. Last Bake is visible as a read-only resource ready to assign to Ocean.
An optional Ocean target synchronizes sea level/direction before baking.

Actual complete Level_1 bake: PASS, all 29 regions, region size 256 vertices,
vertex spacing 5 m. Domain including padding: (-2624, -1344) to (5184, 6464),
approximately 7.808 km square. Output 512×512, 15.27986 m spacing, 31601 land
samples and 230543 water samples. Saved separately as
`res://coastal_bakes/level_1_complete/coastal_bake.res`. This supersedes the
spawn-only fixture described below. Higher resolutions retain the same domain.
The final complete bake was repeated with sea level and incoming direction read
from the scene's Ocean defaults (sea level overridden to Level_1's 2 m).
Offline Level_1_Coastal binding check PASS, including matching sea level and wind
direction. The simplified Inspector and automatic-grid checks also PASS.

Added a standalone authoring node and packed scene inside `addons/ocean/coastal`.
The existing laboratory bathymetry, finite-depth, Eikonal and warp algorithms
were ported to addon-local scripts and the portable resource format. Terrain3D
sampling is optional and merges world-space heights with selected mesh faces.
No runtime sampling or dependency on validation/lab files is introduced.

Validation:

- `coastal_baker_check.gd`: PASS with Terrain3D-compatible test data and a
  transformed mesh. Verified upper-surface selection, terrain depth, land,
  holes/real coverage, compressed binary save/reload and repeated bake.
- Actual Terrain3D in `C:/Users/DEV/Documents/test-addons`: 29 active regions,
  vertex spacing 5 m, spawn ground height -1.08402586 m. Baked a 1024 m square
  at 8 m resolution and sea level 2 m: 129×129 samples, 7450 land and 9191 water.
  Generated `coastal_bakes/level_1_spawn/coastal_bake.res`; validation PASS.
- `Level_1_Coastal.tscn`, inheriting the user's unmodified Level_1: offline
  instantiation PASS. Terrain array, Ocean target, saved bake and enabled coastal
  references all resolve. No visual gameplay evaluation is claimed.
- Standalone Terrain3D test used empty decorative mesh assets and reported
  missing instancer assets; the terrain height data and bake passed. This is
  unrelated to the user's full level with its authored assets.

The node has explicit world bounds, grid budget, sea-level/direction copy,
Inspector preview, binary output, and optional assignment to Ocean. No bake
runs automatically at startup. Terrain edits, source geometry changes or a
different incoming wave direction require a new bake. The first Level_1 bake
covers the spawn area, not all regions.

Source test used Godot 4.7.1 headless. Terrain queries use the official API:
https://terrain3d.readthedocs.io/en/stable/api/class_terrain3ddata.html#class-terrain3ddata-method-get-height
