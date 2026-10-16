# Inspector connection and frozen editor preview — 2026-10-16

Parent: `39fb3d2`, branch `wip/feel-soft-water`.

## Changes

- Jet Ski exports a typed `ocean: Ocean` node reference in the Water group.
  The vehicle owns a one-time connection node only when this field is assigned.
  It binds the existing provider/contact context, waits for the existing source,
  configures the first shared CPU Lite provider with the shipped demo settings,
  and restores the original Freeze state. Already configured providers retain
  their native object and settings. No scene-root script or node search is needed.
- Manual `configure_ocean` / `configure_water_provider` integration remains
  available with the inspector field empty. The demo also recognizes an assigned
  inspector reference and does not run its own duplicate initialization.
- Ocean creates an editor-only internal preview node. It uses the existing
  `OceanSpectrumState.build`, GPU generation/solver and clipmap surface shader.
  No new spectrum calculation or shader was introduced. Three one-shot dispatches
  produce one frozen wave snapshot. Ordinary material edits apply without FFT
  rebuilds. Preview Time, spectral/topology edits and Refresh Preview regenerate
  the snapshot. Idle preview does not dispatch more FFT work.
- SSPR can receive an explicit editor camera; default runtime attachment logic
  remains unchanged. The editor camera compositor receives the effect, keeping
  the scene's WorldEnvironment resource unchanged. Preview does not run CPU
  water fields, underwater, historical foam, breakers or particles.
- Existing solver/generation/surface/SSPR attachment scripts are marked `@tool`
  so their same implementations can be used by the preview. Runtime FFT math,
  shaders, native DLL/SO, vehicle forces and authored parameters are unchanged.

## Validation results

Actual Godot 4.7.1 Windows / Forward+ D3D12, Jolt Physics. No new performance
benchmark or Linux/Steam Deck hardware claim. Evidence is retained under
`temp/addon_usability_20261016/`.

| Test | Result |
| --- | --- |
| Autonomous wave clock regression | Pass; no failures, 12 query contexts, one CPU construction per tick |
| Inspector reference, 1 vehicle | Pass; no host script, reference preserved through PackedScene serialization, buoyancy and propulsion |
| Inspector reference, 12 vehicles | Pass; 12 distinct contexts, one retained native object, max one CPU build per physics tick, zero field failures |
| Clean-install existing host route | Pass; acceleration, 2 landings, recovery, 8 spray frames, contact particles, 9 camera controls, air/water/air, zero field failures |
| Test Addons installed scripts | Pass; 1 vehicle using inspector startup in a temporary test world, not the user's terrain level; no scene/config modifications |
| Actual editor viewport | Pass; frozen surface visible, one initial build and 3 initial dispatches, no idle redispatch |
| Editor reflections | Pass; attached to editor camera, render callback seen, one effect occurrence |
| Editor profile edits | Pass; reflection roughness 0.35 reaches the production shader without rebuilding FFT |
| Editor Preview Time and ON/OFF | Pass; time reaches material, rendered image changes, teardown removes effect, ON recreates snapshot |
| Scene serialization | Pass; generated preview and mesh nodes excluded; WorldEnvironment compositor unchanged |

Source comparison confirms the only existing controller methods changed are
`_ready` and the parameter name of `configure_ocean`. The force dispatcher and
all buoyancy/driving/camera/VFX implementations remain unchanged. Runtime FFT
solver/generation changes consist only of `@tool` annotations.

The first editor test tried to read a GPU texture without a readback usage flag;
that validator attempt failed. The validation was corrected to inspect material
time, dispatch/build counters, actual editor viewport images and shader uniforms.
No GPU texture flags or FFT implementation were changed for the test. Initial
failed logs remain preserved alongside final passing results.

## Delivery and use

Updated scripts/docs are copied to `C:/Users/DEV/Documents/test-addons`.
`test_addons_before/manifest.json` in the evidence folder records original paths,
backup hashes, installed hashes and restore instructions. No target scenes,
project settings, assets or native binaries are replaced.

Reopen the target level, select JetSki and drag its Ocean node into **Water →
Ocean**. Root integration code is no longer required. Leave the field empty for
an existing game-managed integration. In Ocean, use **Editor Preview**, **Preview
Time** and **Refresh Preview**. The preview follows the first editor 3D viewport.
Use scene lighting/environment in that viewport for authored reflection review.
Surface/reflection rendering still consumes GPU; disable preview to release it.

Repeat the runtime probe with `validation/addon_inspector_connection_runtime.gd`
and `--vehicles=1|12 --result=<JSON>`. The real editor probe and instructions are
under `validation/editor_preview/` and are not shipped inside either addon.
