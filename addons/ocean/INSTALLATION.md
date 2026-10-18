# Ocean — Windows and Linux addon

Requires Godot 4.7.1 and Forward+ with RenderingDevice. Copy `addons/ocean/` into the destination project and let Godot import it. Ocean imports independently; Jet Ski is an optional consumer. No editor plugin, MCP, autoload, development scene or vehicle input configuration is required.

Do not copy `.godot`, native build folders, godot-cpp, captures or development `temp/` directories. Preserve import settings, resource UIDs, native library files and the case of resource paths.

## Scene and authoring

Instantiate `res://addons/ocean/ocean.tscn`. The Inspector uses English groups for Editor Preview, General, Ocean Space, Sea State, Wave Structure, FFT Cascades, Systems, System Resources, Advanced and Diagnostics. Hull effects are organized as **Hull Foam**, **Running Foam** and **Hull Waves** with their own subgroups. See `surface/foam2d/CONTROLS.md`.

The default scene now contains the saved Hull Wave Physics Playground settings from 18 October 2026, including wave profiles, foam/relief and physical hull-wave controls. Its portable profiles and optional lighting reference live in `presets/hull_wave_playground/`. All active coastal data/resources required by that preset are included inside Ocean. The older `presets/ocean_production/` remains a separate historical preset. Saving and exporting `addons/ocean/` preserves the current defaults without the validation or gameplay directories.

Existing property names remain compatible with saved scenes and presets. Enable Hull Foam on the Ocean that owns registered vehicles. Foam and hull waves use the existing deformed surface. Hull Waves are visual by default; experimental physical interaction is available under **Hull Waves → Physics → Enabled** with an updated native extension. See `physics/water/HULL_WAVES.md` for controls and platform requirements.

For underwater rendering, enable `underwater_medium` and supply a current camera and directional light. Existing profile resources control optics, foam, underwater, caustics and spindrift.

## Physical water queries

Ocean owns WaterSurfaceProvider3D, WaterSample3D, CpuFftWaterProvider and their helper types. Obtain `ocean.get_water_provider()` once, after `get_physics_source_state().status == "OK"`. Configure the provider once per Ocean; all its vehicles share that provider and native field.

Production uses CPU_LITE_B, resolutions 128/128/128, cubic interpolation, comparison disabled and `set_water_race_mode(true)`. Each vehicle owns an OceanWaterContactContext, selected before its synchronous batch of water queries. Do not interleave another consumer without selecting its context. This API is not multithreaded.

Contexts contain contact history/cache only. The native object, spectrum, clock, field, synchronization and one-build-per-tick limit remain shared. Context switching transfers references and clears active slots to avoid PackedArray aliasing. Spectrum invalidation expires all contexts by epoch; recovery invalidates only the recovering vehicle's contacts. LOCAL_SURFACE additionally invalidates its shared geometry patch when changing consumer. DIRECT is the production-validated mode; Legacy/Heavy remain available.

`register_hull_foam_vehicle(vehicle)` connects a compatible rigid body to the visual hull effects without making Ocean depend on the Jet Ski class. Jet Ski calls this through its normal Ocean configuration.

## Packaging and exports

Run `tools/package_water_addons.py --out <new-output-folder>` from the source repository to build `ocean_source.zip`, `jet_ski_source.zip`, a SHA-256 manifest and clean TestAddons/OceanOnly projects. Runtime resources stay under their addon folders. Original and F1/F2 visual references are preserved inside the Ocean addon.

Export include filters must contain **`*.glsl,*.inc,*.source`**. Compute and shader source files are read at runtime. Keep `physics/native/ocean_query/ocean_query_native.gdextension` and its platform library beside the addon. The addon works without development `temp/`, `validation/` or `gameplay/` folders.

## Native platforms and limits

The included GDExtension selects the Windows x86-64 DLL or Linux x86-64 SO. This consolidation does not modify either native binary or the FFT/CPU Lite implementation. The descriptor targets Godot 4.7; validation uses 4.7.1.

Windows uses D3D12. Linux uses Vulkan; the example's Windows driver setting does not affect Linux. The Linux binary uses the Godot 4.7 SDK and official single precision, GCC 9.4/glibc 2.31, with static libstdc++/libgcc; its newest required GLIBC symbol is 2.29. Build details are in `physics/native/ocean_query/LINUX.md`.

Earlier Linux checks used Ubuntu 22.04 under WSL2 with software Vulkan llvmpipe. They do not certify Steam Deck GPU performance, controls or a selected Steam Linux Runtime. Physical Steam Deck execution and Linux export verification remain pending. Current hull-effects consolidation is validated on Windows D3D12.
