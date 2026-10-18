# Jet Ski authoring cleanup — 18 October 2026

The vehicle keeps its saved tuning and the existing Normal Hull V1, Heavy and Legacy implementations. Property names and groups are English. All 440 editable exports across the eleven Jet Ski scripts have documentation comments for Godot's Inspector help; the added explanations are Spanish.

## Changes

- Reorganized the root into water, buoyancy, hull assists, mass, propulsion, steering, rider, diving, tricks, contacts and recovery sections.
- Added an optional editor Inspector filter. The default Normal V1 configuration shows 152 of 179 root script controls. Show All Mode Settings reveals the other modes without resetting or converting their values.
- Exposed the existing Drive Mode selector. Custom (Stock) uses the force/falloff exports; Sport and Race retain their existing hardcoded presets. Race remains the default. Previously those force controls were visible even when the preset ignored them.
- Removed unused droplets atlas controls from Bow Spray and Spray Appearance. Retained their serialized properties for scene compatibility. Hid the internal WaterPhysicsSystem draft offset, which the parent vehicle supplies on startup.
- Added the optional plugin to the combined addon example. Ocean-only packaging removes that plugin reference. No editor dependency is added to gameplay.

The only changed runtime function body in the eleven Jet Ski scripts is the separately tested physical-wave owner registration. Inspector cleanup changes declarations, documentation and editor-only code; it does not alter driving, buoyancy, camera or spray formulas. The saved Jet Ski scene and shared Ocean appearance resource match their pre-cleanup backups byte for byte.

## Validation

- `jet_ski_authoring_check.gd`: mode gates, custom engine controls, global pitch/recovery behavior, retained storage fields, root save/load equality and complete export help coverage.
- Isolated Godot editor: native property controls, Normal/Heavy changes, Custom engine values and Show All Mode Settings. Inspector row counts include built-in Godot properties and therefore differ from the script-only counts above.
- `foam2d_ocean_authoring_check.gd`: 71 Ocean controls, save/load, independent resources and disabled-state preservation; original/F1F2 comparisons exclude physical hull waves.
- `hull_spray_controls_check.gd`: 24 switches, three cached atlases and save/reload.
- `hull_wave_physics_contract.gd`: 432 GPU/CPU comparison points, finite derivatives, self-wave protection and water-sample composition.
- `hull_wave_physics_runtime.gd`: two production vehicles, wind rebuild, camera/foam independence, cached overlay once and one shared snapshot per physics tick.
- Clean combined and Ocean-only source packages: dependency audit and standalone runtime checks.

The automated Inspector assertions passed. Closing that isolated editor through the test harness also emitted one engine `get_node()` outside-tree diagnostic without a script backtrace; its origin remains unconfirmed. The standalone runtime, authoring, spray and physics checks completed with empty stderr. The editor diagnostic is retained as a validation limitation rather than counted as a clean editor log.

## Remaining performance work

This cleanup adds no gameplay frame loop. It is not a measured performance optimization. The physical-wave prototype still needs full-scene CPU profiling and repeated multi-vehicle runs, especially at twelve vehicles; see `physical_hull_waves_2026_10_18.md` for the measured limits. Candidate pruning and shared query work are candidates to investigate after profiling. No additional FFT simulation is proposed.

Windows D3D12 is the tested target. The physical-wave native extension has not yet been rebuilt for Linux; the capability check leaves that optional feature inactive with the older Linux binary.
