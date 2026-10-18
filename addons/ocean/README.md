# Ocean addon

## Entry point

Instance `res://addons/ocean/ocean.tscn`. Its public node is `Ocean` (`class_name Ocean`). The scene includes only the facade; it does not add a camera, lighting, environment, island, or demo setup. The bundled default wave and quality profiles let the ocean initialize without validation resources.

The wave clock advances on Ocean's own physics ticks, including when no vehicle or CPU water consumer exists. Contact preparation shares the same tick guard and cannot advance it a second time. `wave_speed_multiplier = 0` pauses wave evolution; the default is `1`. Disabling Ocean also stops its clock. No input action or Jet Ski is required to start the waves.

## Production preset

`presets/ocean_production/` contains independent copies of the current production
profiles and a preconfigured `ocean_production.tscn`. `AJUSTES_OCEAN.md` lists all
48 effective node settings, including the existing Physics aligned presentation
choice. The base addon defaults remain unchanged. Optional environment/HDR and
sun references are supplied separately so the host can keep its own lighting.

The original map-specific coastal bake is inactive in that gameplay scene and is
preserved separately as legacy reference, not made a runtime dependency of the
portable preset. All active profiles and their dependencies are inside Ocean.

## Bake a Terrain3D coastline

Instance `res://addons/ocean/coastal/coastal_baker.tscn` in your level, assign
your Terrain3D node to **Terrain** and press **BAKE COASTAL ASSET**. The baker
reads all active regions and computes the full extent automatically. The saved
**Last Bake** resource can be assigned to Ocean's **Coastal Bake** property;
assigning **Ocean** in the baker also synchronizes and applies it automatically.
Optional GLB coastal meshes are supported. See [Coastal baking](coastal/BAKING.md).

## Wave body transmission

In **Optics Profile → Wave body transmission**:

- **Wave Body Opacity** (default `1`): suppresses above-water scenery/sky
  transmitted through elevated wave bodies. `0` restores the previous composition.
- **Wave Body Thickness M** (default `1.5`): estimated thickness threshold.
  Lower values make smaller waves obscure the backdrop sooner.
- **Wave Body Softness M** (default `0.75`): smooth transition around that threshold.

This is an artistic estimate using displaced surface height above sea level and
view angle, not an entry/exit thickness measurement or volumetric simulation.
The background's reconstructed height separates emerged scenery from submerged
geometry. No absorption coefficients, seabed visibility settings, reflection
strengths or FFT fields are changed. The effect fades out at the existing camera
waterline and is disabled fully underwater, including when Snell is disabled.
It adds scalar shader math, with no extra texture fetches, pass or CPU query.

Existing profiles inherit these three defaults. The production preset manifest
records them separately from the original exact snapshot. Material changes also
update the frozen editor preview without an FFT rebuild. After updating an open
editor, reopen the scene or toggle Editor Preview if the old material is cached.

## Sky3D screen-space fog

When using the separate Sky3D addon, select **Sky3D → SkyDome → Fog Render
Priority** and set it to **`-1`**. Keep Ocean's material priority at its normal `0`.
Sky3D's default `100` draws its full-screen atmosphere over the water using opaque
scene depth. Raised waves against sky/distant scenery can then look transparent,
even when water transmission is disabled. Optics absorption and Wave Body Opacity
cannot control a different addon drawing over Ocean afterward.

The `-1` order preserves Sky3D's fog on the backdrop and draws Ocean afterward.
It does not disable fog globally, change its density, move Ocean above vehicle
effects, or require any Sky3D class in Ocean. Both editor and runtime use the same
saved SkyDome setting. This is a draw-order compatibility setting, not a shared
volumetric atmosphere: Sky3D's screen-space fog no longer overlays the water
surface; distant-water appearance continues to use Ocean's existing shading.

## Editor preview

The Ocean inspector has **Editor Preview**, **Preview Time** and **Refresh Preview**.
Preview is enabled by default. Reopen an already open scene after updating the
addon, or toggle Editor Preview to initialize it after script reload.

The preview renders a frozen wave snapshot with the existing production spectrum,
GPU FFT, clipmap and surface shader. Changing Preview Time, waves or geometry
refreshes the snapshot. Material, optics, reflection and detail profiles update
the surface without rebuilding the FFT. After the snapshot is ready, no further
FFT dispatches occur until a refresh is needed. Moving the first editor 3D
viewport camera updates the clipmap position and its real SSPR reflections.

Drawing the surface and reflections still costs GPU time. Disable Editor Preview
when not needed. Reflections use the editor camera and scene lighting; use the
editor's scene environment/light options to see your authored environment.

This is a surface authoring preview, not the full game simulation: historical
foam, breakers, underwater, caustics, particles and vehicle interactions run in
the game. Preview creates no CPU physics provider or water queries, never advances
the runtime wave clock, and its generated nodes are not saved into the scene.
Its compositor attaches to the editor camera without modifying the serialized
WorldEnvironment. No editor plugin needs to be enabled. Forward+ is required.

## Day/night lighting

Ocean's **Underwater Sun Light**, **Underwater Moon Light** and **Underwater
Environment** are optional references to your scene's directional lights and
WorldEnvironment. With no explicit references, the first directional light is
the sun; exactly two directional lights allow automatic selection of the other
as the moon. Larger rigs should assign both. References are cached, never searched
per physics contact. The environment defaults to Ocean's World3D environment.
No Sky3D dependency or additional root script is required.

In **Underwater Medium Profile → Scene lighting**:

- `scene_lighting_influence`: 1 follows scene illumination; 0 restores the old
  fixed artistic illumination. Existing scattering colors and absorption stay.
- `scene_light_reference_energy`: incident energy giving the authored strength.
- `scene_ambient_weight`: environment contribution beside the sun and moon.

Volume and bubbles share linear incident color/energy. Sunrays and caustics use
the strongest available sun/moon source, with their artistic colors/intensity
retained. Hidden lights and sources below the horizon do not illuminate water.
No second ray march, GPU readback, or water query is introduced. Sky ambient is
approximated from the directional lights and authored ambient color/energy;
this is not a CPU integration of the rendered sky/cloud cubemap. Local point/spot
lights illuminate regular materials such as bow spray; they are not injected
into the full-screen underwater volume by this feature.

In **Reflection Profile → Low light reflections**, `low_light_reflection_boost`
(default 1.5; 1 disables it) gently increases existing specular response when
directional irradiance falls below `low_light_reference_energy` (default 0.5).
Daylight at or above that threshold uses exactly the existing specular strength.
This adds no emission or minimum light, changes neither absorption nor exposure,
and needs existing sky/screen-space radiance to show reflections. It applies to
the editor preview too. External sky/fog drawing order still matters (see above).

## Feature families and ownership

- **Rendering and FFT:** `Ocean` owns authoring and lifecycle; `OpenOceanFFT` owns LONG/MID/SHORT simulation resources and publication.
- **Surface, crest foam, surface foam, optics, reflections, coastal:** the clipmap surface owns presentation state; the corresponding FFT/coastal/reflection modules own their implementation and runtime resources.
- **Underwater, caustics, spindrift:** their managers/controllers own feature runtime state; `Ocean` configures and synchronizes them.
- **Breakers:** optional and OFF by default. Breaker simulation stays in its existing subsystem.
- **Physics and interaction:** Ocean owns the water types, CPU FFT provider and shared native field. Consumers receive `get_water_provider()` during configuration and keep separate contact contexts; the native field is shared. Vehicle effects use the direct foam and landing-ripple API.

## Current facade API

Use exported `Ocean` properties or `set_sea_state()` / `get_sea_state()` for sea-state authoring. `set_feature_flags()` / `get_feature_flags()` expose the feature gates, and `get_runtime_feature_state()` reports activated runtime state. `get_wave_time()` exposes the simulation clock. `get_waterline_state()` and `get_spindrift_runtime_state()` are current subsystem queries. Lifecycle and lower-level diagnostic methods remain available for current validation callers and are not yet a narrow stable consumer API.

## Portability note

The base ocean entry point and required wave/quality profiles are inside this directory. The standalone H5 breaker carrier and its P7 shape generator are validation/lab tooling kept outside the portable addon.

The FFT uses Godot's `RenderingDevice` compute API. Reflections add a compositor effect. The base surface needs no input actions, autoloads, camera, light, or game-specific project settings; the consuming project must provide a renderer/device compatible with the requested GPU features. Scene-dependent lighting and camera inputs apply only to optional underwater/reflection presentation.
