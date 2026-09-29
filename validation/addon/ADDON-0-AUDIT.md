# Ocean Production Addon-0 audit

Date: 2026-09-29  
Reference HEAD for Addon-0.1: `a2dec991509da288fc91365af1ed0d0e4c27a6cf`

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
- Moved the H5 validation-only carrier and its `.uid` from `addons/ocean/breaker/` to `validation/`; updated the H5, attached, and static P7 scenes to load the new path. The carrier contents were not refactored.
- Created `validation/addon/ocean_live_clock_check.gd` to compare the Ocean facade clock with `OpenOceanFFT` and verify its time scale.
- No `physics/` or `interaction/` placeholder directories were created.

Existing P7 scene settings and profile data were preserved. The H5 scene changed only its carrier resource path; its local profile and tuning values were not edited.

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
| `validation/breaker_carrier.gd` | Standalone H5 breaker carrier diagnostic | Not in Ocean runtime closure or addon folder | Dev/validation only | P7 shape generator in `lab/`; three P7 validation scenes reference the carrier |
| `*.uid`, shader `*.import` | Godot resource identifiers/import metadata | Needed when their paired resource is used | No | Paired addon resources |

There are zero validation/lab/tests path references anywhere inside `addons/ocean/`, including its documentation. The standalone breaker diagnostic now lives under `validation/` and is referenced by the H5, attached, and static P7 scenes. P0's coastal bake and experimental profiles remain owned by validation and are not Ocean entry-point dependencies.

## E. Remaining dependencies and portability

- **Portable:** base scene, default profiles, scripts, shaders, and textures use addon-local `res://addons/ocean/...` references. No absolute filesystem paths, input actions, or autoload calls were found in the Ocean runtime source scan.
- **Target project configuration required:** FFT uses `RenderingDevice` compute. SSPR reflections use a compositor effect. Optional underwater presentation consumes camera/render state and benefits from a directional light. Optional spindrift fog reads Godot volumetric-fog project settings.
- **Feature authoring required:** Coastal requires a project-authored bake; it does not silently use the validation bake.
- **Boundary:** copying `addons/ocean/` no longer brings a script that preloads lab or validation tooling.

## F. Current public Ocean API

- Consumer-facing sea state: `get_wave_time()`, `get_sea_state()`, `set_sea_state(Dictionary)`.
- Consumer-facing feature gates: `get_feature_flags()`, `set_feature_flags(Dictionary)`.
- Runtime status: `get_runtime_feature_state()`.
- Current subsystem queries: `get_waterline_state()`, `get_spindrift_runtime_state()`.
- Existing lifecycle/configuration methods: `initialize()`, `shutdown()`, `get_fft_cascade_mask()`, `set_fft_cascade_mask()`, `set_waterline_state_readback_enabled()`.
- Validation/debug surface: breaker detector probe/capture getters and controls, and local breaker refinement authority/debug methods. These remain available for current callers; they are not recommended as the stable consumer contract.
- Underscore-prefixed methods are internal implementation/lifecycle helpers.
- `sample_water_batch()`, `register_interactor()`, and `unregister_interactor()` are not implemented; they remain future physics/interaction API.

Before Addon-0.1, `Ocean.get_wave_time()` returned its cached `_wave_time`, which only synchronized during rebuild. It now delegates to `_open_ocean.get_wave_time()` whenever the runtime exists and falls back to `_wave_time` only when no runtime is available. It does not read wall time or advance a second clock. `OpenOceanFFT` remains the clock authority.

Feature ownership: OpenOceanFFT owns FFT cascade simulation/publication; the clipmap owns rendered surface state; its surface-foam path owns surface foam; FFT crest state owns crest foam; coastal runtime owns coastal data mapping; optics/reflection/underwater/caustics/spindrift managers own their subsystem state; breaker simulation remains optional in its current FFT/surface path. The facade configures and synchronizes these systems.

## G. Native / GDExtension status

No `.dll`, `.so`, `.gdextension`, C/C++ source, or `OceanQueryNative` artifact was found in the project. The current addon has no native runtime dependency. Windows/Linux/Steam Deck native support is therefore not applicable yet; GPU backend support remains governed by Godot `RenderingDevice` and the target GPU/driver.

## H. Minimal scene validation

The live-clock check passed for `wave_speed_multiplier` 1.0 and 1.75. Both intervals advanced; the measured rates were 1.0000× and 1.7500×, and facade-vs-FFT parity error was 0.000000000 in both cases. This confirms one application of speed scaling with the FFT as sole authority.

Godot 4.7.1 headless parsed `ocean.gd` and ran `ocean.tscn`, `validation/addon/ocean_addon_smoke.tscn`, P0, and the H5, attached, and static P7 carrier scenes with exit code 0. After the move, an editor rescan refreshed Godot's global script-class cache; all three P7 carrier scenes then loaded. The final scene runs had no parse errors or missing-resource errors. Godot still prints a root-certificate-store error in this restricted environment.

The smoke scene's scope is limited to proving that `ocean.tscn` instantiates independently, Ocean runtime starts, the base surface is visible/moving in a normal renderer, and there are no validation/lab dependencies, missing resources, or parse errors. It is not a visual regression scene for reflections, optics, underwater, caustics, sunrays, coastal, or spindrift. It has not been enriched to resemble P0.

Use `validation/p0_open_ocean.tscn` for visual regression of those systems. P0 supplies the established scene, camera, lighting, HDRI, and known-good visual context. The permitted dependency direction is P0 → `addons/ocean/`; the addon must not depend on P0 or validation resources.

The headless P0 run reported `Ocean caustics inactive: runtime texture not ready`. This was only observed in headless mode; caustics were not changed. **Visual validation required in P0.** No ADDON-0-A classification until the user confirms the P0 visual review. Headless startup does not replace that confirmation.

## I. Regression and performance

P0 and P7 both started without script/resource load errors and exited successfully. P0's caustics readiness warning is recorded above. No scene-render screenshot or visual quality regression check was available in headless mode. Smoke acceptance remains limited to independent instantiation and base-surface startup/motion.

Changes add default resource references and facade methods only. The new dictionary allocations occur only when callers invoke the query methods; no per-frame loop, render pass, compute pass, texture, or readback was added. No benchmark delta was measured.

## J. Classification and Git

**ADDON-0.1-B — READY_FOR_USER_VISUAL_GATE.** The live clock and time scaling pass, all headless scene checks pass, and `addons/ocean/` has zero validation/lab/test path references. Keep the base phase at B until the user confirms the visual regression review in P0. The headless caustics warning is not a basis for a code change.

No commit or push was made; the request explicitly defers it until after the user visual gate. The H5 scene change is limited to the required carrier resource path.

## K. Next phase

Do not start **PHYS-0** yet. It should begin by auditing/resolving the CPU/native water query. No native query implementation was found, and no PHYS-0 work was started.
