# Ocean addon

## Entry point

Instance `res://addons/ocean/ocean.tscn`. Its public node is `Ocean` (`class_name Ocean`). The scene includes only the facade; it does not add a camera, lighting, environment, island, or demo setup. The bundled default wave and quality profiles let the ocean initialize without validation resources.

The wave clock advances on Ocean's own physics ticks, including when no vehicle or CPU water consumer exists. Contact preparation shares the same tick guard and cannot advance it a second time. `wave_speed_multiplier = 0` pauses wave evolution; the default is `1`. Disabling Ocean also stops its clock. No input action or Jet Ski is required to start the waves.

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
