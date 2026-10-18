# Coastal baker

Drag `res://addons/ocean/coastal/coastal_baker.tscn` into the level. Select
CoastalBaker, drag your Terrain3D node into **Terrain**, then press
**BAKE COASTAL ASSET**. All active regions are included automatically, including
negative region coordinates and the terrain's vertex spacing. No manual bounds
are needed. **Terrain Resolution** sets the number of samples along the longest
axis (512 by default, or 1024/2048 for finer detail); the entire domain is retained.

The generated resource appears in **Last Bake**, ready to assign to Ocean's
**Coastal Bake** property. Optionally assign **Ocean** in the baker: its sea level
and wind direction are read at bake time and the result is assigned automatically.
Without an Ocean target, the sea level defaults to 0 m; change it in advanced
settings if your water surface is at a different elevation.

The following controls are available under **Advanced Settings**. Manual bounds
apply only when **Full Terrain** is disabled. Additional GLB coastal geometry
can be selected with **Source Root** in either mode.

- **Terrain sources:** add the Terrain3D node(s). Heights are sampled directly
  from `Terrain3D.data.get_height(world_position)`, respecting vertex spacing,
  holes and missing regions. Terrain3D is optional; no dependency is required
  for projects that only use meshes.
- **Source root / Source:** optional static terrain, islands and rocks imported
  from Blender/GLB, or a MeshInstance3D. Mesh transforms are included. Select
  only coastal geometry; do not select the level root containing Ocean, boats
  or decoration. The highest surface wins where terrain and meshes overlap.
- **Ocean:** assign the Ocean node. The **Read sea level and direction** button
  copies its current sea level and wind direction. **Apply after bake** assigns
  the generated resource and enables coastal when the bake succeeds.
- **Bounds min/max XZ:** world coordinates in metres, independent of the baker
  node transform. Start with a bounded test area. **Use source bounds** instead
  covers all selected terrain regions/mesh geometry plus padding.
- **Cell size (manual mode):** horizontal sampling distance in metres. Try 4–8 m on large
  terrain, then reduce where shoreline detail needs it. **Max grid cells**
  prevents accidentally baking a huge domain. It never silently lowers quality.
- **Synthetic depth:** fills places without actual seabed geometry. Missing
  regions/holes are treated as open water, never as real seabed coverage.
- **Reference wavelength / Incoming direction:** define the representative
  coastal wave solved offline. Changing direction or geometry needs a rebake.
- **Output root / Coast ID:** the compressed binary bundle is written to
  `res://coastal_bakes/<coast_id>/coastal_bake.res` by default. Keep the bundle
  with the exported level. It contains depth, propagation and warp together.

The Inspector preview shows land in brown, shallows in turquoise and deep water
in blue; a purple tint indicates synthetic water without real seabed coverage.
Save the level after baking to retain the assignments and authoring settings.
The runtime reads the saved bake; it does not sample Terrain3D or GLB triangles.

This is a top-surface heightfield bake. It does not represent caves, bridges
with separate seabeds or changes made only by a vertex shader. Near-vertical
mesh walls are excluded from seabed sampling. MultiMesh decoration is excluded.

Terrain API: https://terrain3d.readthedocs.io/en/stable/api/class_terrain3ddata.html#class-terrain3ddata-method-get-height
