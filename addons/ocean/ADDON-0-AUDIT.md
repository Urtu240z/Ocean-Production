# Ocean Production Addon-0 audit

Date: 2026-09-29  
Reference HEAD: `c03339e3bcaf5ba5d74a48e16fae3ce3db102ecc`

## A. Before

`addons/ocean/ocean.tscn` already existed, but only attached `ocean.gd`. The facade requires both a wave profile and a quality profile, so the scene could not initialize on its own. The P0 validation scene supplied those plus demo and validation resources, including a validation wave profile and coastal bake. Subsystems already lived mostly in their own directories.

## B. After

`ocean.tscn` is a reusable `Ocean` entry point with addon-local default LONG/MID/SHORT wave and quality profiles. It does not add a camera, light, environment, island, or validation UI. Breakers are explicitly OFF. `Ocean` remains a lifecycle/configuration facade; FFT and visual algorithms stay in their subsystem scripts. No physics or interaction implementation was added.

## C. Files changed for Addon-0

- Created `resources/default_wave_profile.tres` and `resources/default_quality_profile.tres`.
- Modified `ocean.tscn` to use those profiles and explicitly disable Breakers.
- Modified `ocean.gd` with `get_wave_time()`, `get_sea_state()` / `set_sea_state()`, and `get_feature_flags()` / `set_feature_flags()`.
- Created `README.md` and this audit report.
- Created `validation/addon/ocean_addon_smoke.tscn` with only a root `Node3D`, the Ocean instance, camera, light, and minimal environment.
- No files were moved. No `physics/` or `interaction/` placeholder directories were created.

The two local P7 changes (`validation/p7_breaker_carrier_h5.tscn` and `validation/profiles/p7_h5_coherence_profile.tres`) were present before work and were left untouched.

## D. Dependency audit and inventory map

The dependency direction for the Ocean entry point is `Ocean.tscn -> Ocean facade -> addon subsystem scripts/resources/shaders`. A source scan found no `res://validation/`, `res://lab/`, or `res://tests/` paths in that Ocean runtime closure. No P0/P7 scene is loaded by the entry point.

| File scope | Role | Required / optional | Validation or dev-only | Main dependencies |
|---|---|---|---|---|
| `ocean.gd`, `ocean.tscn` | Public facade and reusable scene | Required | No | Core profiles and addon subsystems |
| `resources/*.tres` | Portable default wave and quality configuration | Required by default scene | No | `core/ocean_wave_profile.gd`, `core/ocean_quality_profile.gd`, wave-band resource |
| `core/*.gd` | Profiles, cascade state, space/configuration contracts | Required according to enabled subsystem | No | Godot `Resource` and addon scripts |
| `fft/*.gd`, `shaders/fft/*.glsl` | LONG/MID/SHORT spectrum, GPU FFT and publication | Required for surface simulation | No | Godot `RenderingDevice`, addon shaders and profiles |
| `surface/*.gd`, `surface/refinement/*.gd`, `surface/*.tres`, `shaders/ocean_surface.gdshader`, `shaders/surface_foam/*` | Clipmap surface, material presentation, crest/surface foam | Surface required; foam and refinement features optional | Breaker refinement diagnostics are gated | FFT publication, profiles and addon textures/shaders |
| `coastal/*.gd` | Coastal runtime mapping | Optional | No | Ocean FFT/surface and an authored coastal bake supplied by the consuming project |
| `reflections/*.gd`, `reflections/shaders/*` | SSPR reflection compositor effect | Optional | No | Godot compositor and `RenderingDevice` |
| `underwater/**/*.gd`, `underwater/**/*.glsl`, `underwater/**/*.inc`, `underwater/caustics/*` | Underwater medium, bubbles, sunrays and caustics | Optional | No | Camera/render state, configured profiles and addon textures/shaders |
| `spindrift/*.gd`, `shaders/spindrift*`, `spindrift/textures/*` | Spindrift simulation and presentation | Optional | Debug modes exist | FFT publication, textures and optional project volumetric-fog settings |
| `breaker/breaker_carrier.gd` | Standalone H5 breaker carrier diagnostic | Not in Ocean runtime closure | Dev/validation only | `res://lab/p7_breaker_shape_lab/breaker_shape_vdm_generator.gd`; validation scenes reference the carrier |
| `*.uid`, shader `*.import` | Godot resource identifiers/import metadata | Needed when their paired resource is used | No | Paired addon resources |

The only direct lab path found is in the standalone breaker diagnostic. It is not referenced by `ocean.tscn`, `ocean.gd`, or the Ocean runtime dependency closure; it is loaded by P7 carrier validation scenes. It remains physically under `addons/ocean/breaker/`, so a package that blindly copies every file in the directory must exclude this dev-only carrier or relocate it in a separately reviewed change. P0's coastal bake and experimental profiles remain owned by validation and are not Ocean entry-point dependencies.

## E. Remaining dependencies and portability

- **Portable:** base scene, default profiles, scripts, shaders, and textures use addon-local `res://addons/ocean/...` references. No absolute filesystem paths, input actions, or autoload calls were found in the Ocean runtime source scan.
- **Target project configuration required:** FFT uses `RenderingDevice` compute. SSPR reflections use a compositor effect. Optional underwater presentation consumes camera/render state and benefits from a directional light. Optional spindrift fog reads Godot volumetric-fog project settings.
- **Feature authoring required:** Coastal requires a project-authored bake; it does not silently use the validation bake.
- **Boundary follow-up:** the H5 carrier's lab preload must be excluded from a portable package or relocated. It does not block instancing the Ocean entry scene.

## F. Current public Ocean API

- Consumer-facing sea state: `get_wave_time()`, `get_sea_state()`, `set_sea_state(Dictionary)`.
- Consumer-facing feature gates: `get_feature_flags()`, `set_feature_flags(Dictionary)`.
- Runtime status: `get_runtime_feature_state()`.
- Current subsystem queries: `get_waterline_state()`, `get_spindrift_runtime_state()`.
- Existing lifecycle/configuration methods: `initialize()`, `shutdown()`, `get_fft_cascade_mask()`, `set_fft_cascade_mask()`, `set_waterline_state_readback_enabled()`.
- Validation/debug surface: breaker detector probe/capture getters and controls, and local breaker refinement authority/debug methods. These remain available for current callers; they are not recommended as the stable consumer contract.
- Underscore-prefixed methods are internal implementation/lifecycle helpers.
- `sample_water_batch()`, `register_interactor()`, and `unregister_interactor()` are not implemented; they remain future physics/interaction API.

Feature ownership: OpenOceanFFT owns FFT cascade simulation/publication; the clipmap owns rendered surface state; its surface-foam path owns surface foam; FFT crest state owns crest foam; coastal runtime owns coastal data mapping; optics/reflection/underwater/caustics/spindrift managers own their subsystem state; breaker simulation remains optional in its current FFT/surface path. The facade configures and synchronizes these systems.

## G. Native / GDExtension status

No `.dll`, `.so`, `.gdextension`, C/C++ source, or `OceanQueryNative` artifact was found in the project. The current addon has no native runtime dependency. Windows/Linux/Steam Deck native support is therefore not applicable yet; GPU backend support remains governed by Godot `RenderingDevice` and the target GPU/driver.

## H. Minimal scene validation

Godot 4.7.1 headless loaded and ran `validation/addon/ocean_addon_smoke.tscn`, `validation/p0_open_ocean.tscn`, and the existing `validation/p7_breaker_carrier_h5.tscn`; each process exited with code 0. P7 was loaded with the pre-existing local settings and those files were not changed by this work.

The headless P0 run reported `Ocean caustics inactive: runtime texture not ready`. This environment also cannot provide visual confirmation. Coastal toggling, feature-by-feature image output, and caustics readiness therefore remain unverified. The smoke run confirms entry-scene startup, not the full visual acceptance checklist.

## I. Regression and performance

P0 and P7 both started without script/resource load errors and exited successfully. P0's caustics readiness warning is recorded above. No scene-render screenshot or visual quality regression check was available in headless mode.

Changes add default resource references and facade methods only. The new dictionary allocations occur only when callers invoke the query methods; no per-frame loop, render pass, compute pass, texture, or readback was added. No benchmark delta was measured.

## J. Classification and Git

**ADDON-0-B.** The Ocean entry scene now initializes with portable required profiles and is isolated from validation resources. The phase remains B because visual feature acceptance was not completed, P0 caustics readiness was not established, and the standalone lab-dependent breaker diagnostic remains inside the addon tree pending a safe packaging boundary.

The requested automatic commit and push apply only to ADDON-0-A, so no commit or push was made. The pre-existing local P7 changes remain outside this phase.

## K. Next phase

Not ready to start **PHYS-0** yet. Close the remaining Addon-0-B visual/packaging checks first. No PHYS-0 work was started.
