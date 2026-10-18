# Jet Ski — production addon

Requires **Godot 4.7.1, Forward+ and `addons/ocean/`**. Ocean is a direct mandatory dependency. No editor plugin, MCP, autoload or development scene is required.

The Jet Ski 01 prefab and BowSprayRoot component now share the current saved authoring defaults from 18 October 2026. This includes the two guided mist emitters, birth/end sizes, color ramps, normal maps and speed transparency. The vehicle scene retains the current physics and handling settings. Ocean's default scene carries the saved Hull Wave Physics Playground settings; copy both complete addon folders to preserve these defaults.

The optional **Jet Ski Inspector** editor plugin hides settings that do not apply to the selected mode. Enable it under Project Settings → Plugins; the example project enables it already. Property names are English and hover help is Spanish. See `editor/CONTROLS.md` for the control map and engine presets.

## Install and run

1. Extract `ocean_source.zip` and `jet_ski_source.zip` at the destination project's root, preserving `addons/ocean/` and `addons/jet_ski/`.
2. For a new project, copy `addons/jet_ski/examples/project.godot.example` to the root as `project.godot`. Existing projects should use Forward+, Jolt Physics and physics interpolation. Windows uses D3D12; Linux uses Vulkan.
3. Import with Godot, then run `res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn`.

The standalone example includes Ocean, procedural lighting and one vehicle, with Hull Foam enabled. It uses the addon's normal vehicle configuration and contains no custom buoyancy, driving, camera or spray implementation. The production gameplay scene keeps its own environment and overrides.

## Connect a vehicle

Instantiate Ocean and `addons/jet_ski/jet_ski_01/jet_ski_01.tscn`. Assign the Ocean node in the vehicle root's **Water → Ocean** field. The vehicle waits for the physical source before unfreezing. A missing source/native library keeps it frozen and reports an error. An intentionally saved Freeze state is preserved. Node names and hierarchy are unrestricted.

Assign the same Ocean to every vehicle. The first consumer configures the shared provider, subsequent consumers reuse it; each vehicle retains a separate contact context. A provider already configured by the host keeps its configuration. No per-contact name/group lookup or additional native field is introduced.

Existing code integrations can call `vehicle.configure_ocean(ocean)` before adding the vehicle to the tree, leaving its Inspector Ocean field empty. Hosts that own the provider can configure it once after Ocean reports status OK, then pass the same provider with `configure_water_provider(provider)`.

Production provider settings remain CPU_LITE_B, 128/128/128, cubic interpolation, backend comparison disabled, query mode DIRECT and water race mode enabled. Wave drift remains strength 0.75 / maximum 0.5 m/s. This consolidation does not retune forces, Buoyancy Physics, driving or camera.

## Visual effects

All spray controls live on **BowSprayRoot**, in **Bow Spray**, **Splash**, **Tail Jet** and **Stern Mist** categories. Each effect has independent appearance controls and editor preview. Tail Jet can select Splash 3 or Splash 4; Stern Mist is a small local GPU cloud with its own speed response. No effect uses F8. See `common/visual/hull_spray/CONTROLS.md`.

Ocean owns Hull Foam, Running Foam and Hull Waves. The vehicle registers through its normal Ocean configuration. Waves are visual by default; Ocean's optional **Hull Waves → Physics** prototype feeds their height, slope and vertical water velocity into the existing buoyancy queries. See Ocean's `physics/water/HULL_WAVES.md`. Retired ring and placeholder contact particles are disabled except when explicitly running historical comparison fixtures. User-disabled side splashes and Running Foam remain disabled.

Assets are internal: bow PNGs in `common/visual/bow_spray/sequences/Splash_1/`, and Splash 2/3/4 atlases in `common/visual/hull_spray/textures/`. Root-level source sprite folders are not runtime dependencies. Preserve the complete addon tree, import settings and UIDs. Keep export filters `*.glsl,*.inc,*.source` for Ocean.

## Camera, input and physics

Camera settings belong to CameraRig. Its optional Controls child can be disabled without removing following, vibration or impacts. **Buoyancy Physics** is the standard model. Old Four Point and Heavy settings live together under **Legacy → Show Legacy Settings**, disabled by default. The optional buoyancy HUD is in `debug/jet_ski_buoyancy_hud.gd`; add it explicitly if needed.

ProductionSetup registers only missing InputMap actions once at startup. Existing bindings, deadzones and deliberately empty actions take precedence. Custom bindings can use JetSkiInputBindings or the project's Input Map. Actions remain shared; this addon does not add multiplayer input routing.

| Action | Default physical key |
|---|---|
| throttle | W |
| brake | S; braking then reverse |
| steer_left / steer_right | A / D |
| rider_shift_forward / rider_shift_back | Up / Down |
| rider_shift_left / rider_shift_right | Left / Right |
| reset_vehicle / recover_vehicle | R / T |
| eject_rider | E |

Camera controls remain C for presets, +/- or wheel for distance and PageUp/PageDown for height. Existing rider, mass, hull, driving, camera and nozzle transforms are retained.

## Platforms

Ocean supplies the Windows x86-64 DLL and Linux x86-64 SO; Jet Ski adds no native library. Current effects consolidation is validated on Windows D3D12. Earlier Linux checks used Ubuntu 22.04 under WSL2 and software Vulkan, which does not certify Steam Deck hardware, controls, performance or Steam Linux Runtime compatibility. No Steam Deck-specific optimization is claimed.
