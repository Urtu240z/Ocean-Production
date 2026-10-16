# Wave body transmission — 2026-10-16

Base: `6eb5cd384e722b47c0855ddf790897b6e650af77`, branch
`wip/feel-soft-water`. Scope: an independent visual control for above-water
scenery/sky transmitted through raised waves. Jet Ski physics is deferred.

## Inspector

`Ocean → System Resources → Surface → Optics Profile → Wave body transmission`:

| Property | Default | Meaning |
| --- | --- | --- |
| `wave_body_opacity` | 1.0 | Strength; 0 restores the previous optical composition. |
| `wave_body_thickness_m` | 1.5 | Thickness estimate threshold; lower blocks scenery sooner. |
| `wave_body_softness_m` | 0.75 | Smooth transition width around the threshold. |

Existing profiles inherit these defaults, including the locally customized
Optics resource in Test Addons. No scene or existing profile value is rewritten.
The original preset snapshot remains intact; its manifest explicitly records the
three new default properties as a subsequent additive extension. Its strict
verifier still checks every original property, all 14 resources and 48 node values.

## Implementation and limits

Production optics lives in `OceanClipmapSurface.OPTICS_FRAGMENT`, injected into
the cached material variants. It uses screen color/depth for transmission and a
separate SSPR/PBR path for reflection. The Test Addons isolation probe removes
each component separately; transmitted scene color contributes to the observed
appearance. This does not establish that every feature in the user's original
screenshots was transmission rather than reflection.

The new code classifies the reconstructed background as emerged geometry or sky.
It estimates body thickness from the displaced surface height above sea level
and view angle. A smooth mask attenuates effective RGB transmission and feeds the
existing body/scattering composition. It does not change reflection confidence,
IOR, absorption coefficients, bottom visibility, FFT displacement or water queries.
The shared optics contract forwards all three scalars to existing consumers.
Surface world height is reconstructed from existing fragment data, avoiding a
new varying requirement for the historical carrier shader.

This is an artistic approximation, **not** a volumetric entry/exit calculation.
It does not measure the true width of individual wave crests. The sky is treated
as an emerged backdrop; geometry below sea level keeps the existing absorption
path. Background classification blends over 0.25 m above sea level. The effect
fades with the existing camera signed-distance waterline transition and is off
fully underwater even with Snell disabled. A camera crossing the waterline still
uses the existing transition, not a new underwater detector.

There are no extra texture samples, render passes, CPU callbacks or FFT builds.
GPU frame-time improvement/regression was not benchmarked; this change adds a
small amount of scalar/matrix shader arithmetic. No Steam Deck claim is made.

## Executed validation

Godot `4.7.1.stable.official.a13da4feb`, Windows, NVIDIA RTX 4070 Laptop,
Forward+ / D3D12. Evidence: `temp/wave_transmission_20261016/`.

1. `ocean_wave_body_transmission_runtime.gd` on production and on the reused clean
   two-addon project. The production optics shader is applied to fixed test
   geometry; only the fixture is unlit to isolate transmission. A shader without
   the new block is the oracle. Zero absorption in the clear-water stress fixture
   is a test override, not a production change.
   - Intensity 0: exact image equality (222,000 compared pixels).
   - Raised wave, intensity 1: 28,800 pixels changed; intermediate intensity has
     intermediate attenuation. Raising the threshold restores the clear result.
   - Flat water: exact image equality (222,000 pixels).
   - Fully underwater: exact image equality, with Snell both enabled and disabled
     (222,000 pixels in each test).
   - Submerged backdrop, production absorption `(0.35, 0.14, 0.10)`: exact image
     equality for 133,200 pixels whose rays hit below-water geometry.
   - Sky through raised water: 46,800 pixels changed.
2. Clean preset strict verification: 14 resources, 48 node settings, no differences
   after the explicitly recorded new properties.
3. Real preset runtime: optics/detail/reflection variants and underwater/caustics
   initialize; 120 valid CPU Lite samples, 60 builds / 60 ticks for two consumers,
   zero failures, 1.5 seconds of wave-clock advancement.
4. Actual editor preview: all three edited values reach the material without FFT
   reconstruction. Initial snapshot: one build, three dispatches; SSPR callback
   active. Generated nodes remain excluded from serialization. Temporary editor
   settings were restored byte-for-byte after the test.
5. `gameplay/jet_ski_ocean.tscn`: actual Forward+ runtime, 600 frames, exit 0,
   native CPU Lite/production driving setup and waterline initialized. This is a
   load/runtime smoke test, not a new exhaustive driving or trajectory replay.
6. Actual Test Addons `Level_1.tscn`: load/run and off/on/isolation captures exit 0;
   new defaults reach its custom Optics resource and absorption remains unchanged.
   Existing Terrain3D interpolation/assets warnings and a BasisUniversal mip
   warning were present in both the before/after probes and are outside this fix.

Initial test failures were confined to the harness: the submerged-pixel selector
used capture pixels instead of the project's stretched viewport coordinates; the
first editor launcher split the report-path argument. Both were corrected and
rerun successfully. Production values were not adjusted to satisfy a test.

## Deployment and recovery

Four files were synchronized to `C:/Users/DEV/Documents/test-addons`:
`core/ocean_optics_profile.gd`, `surface/ocean_clipmap_surface.gd`, `README.md`, and
`presets/ocean_production/source_manifest.json`, all under `addons/ocean/`.

Original files and SHA-256 installation/restoration records:
`temp/wave_transmission_20261016/test_addons_before/manifest.json`.
The manifest also records unchanged hashes of `Level_1.tscn` and `project.godot`.
No user level, resource override, asset, native binary or project setting was
replaced. The clean test project has its own backup in `clean_before/`.

To compare in the editor, set **Wave Body Opacity** to 0 and then 1. If an already
open editor retains its old material after the addon update, reopen the scene
or toggle **Editor Preview** off/on. Runtime picks up the new material on launch.
