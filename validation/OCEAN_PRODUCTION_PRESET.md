# Portable production resources — 2026-10-16

Base before this change: `03d15d3`, `wip/feel-soft-water`. The inspector connection
and editor preview are already committed in that base in Ocean Production.

## Source and output

Source: `gameplay/jet_ski_ocean.tscn` → inherited `Production/Ocean`, after the
existing gameplay initializer reports `ready_to_drive`. This includes values
inherited from `validation/p0_open_ocean.tscn`, serialized overrides in the jet ski
scene, and effective gameplay changes. Original scenes and profile files remain
unchanged.

`addons/ocean/presets/ocean_production/` contains:

- Thirteen standalone Ocean profiles: waves, quality, crest foam, surface foam,
  optics, reflections, surface detail, underwater medium, bubbles, sun rays,
  caustics, breakers and spindrift. The last two profiles are preserved even though
  the gameplay feature flags are off.
- An independent environment resource, its original HDR and the original HDR
  import settings. Two noise resources required by spindrift are relocated too.
- `ocean_production.tscn` referencing those standalone resources and preserving
  all 48 effective serialized Ocean settings. Profiles are external references,
  not duplicated subresources inside the scene.
- Optional `lighting_reference.tscn` with the source WorldEnvironment and Sun.
- `source_manifest.json`: canonical recursive resource values and bit-preserving
  scalar encodings, source paths, relocation map, runtime values and exceptions.
- `AJUSTES_OCEAN.md`: user-readable settings and assignment instructions.

The preset is 20,783,842 bytes (22 files at delivery). No compiled shader cache,
Godot cache or native binary is copied into it. The 20,674,857-byte HDR is already
protected in Git at its source path; its identical content can reuse the Git
object while the portable resource uses its own addon-relative path.

## Existing presentation override

The gameplay integrator selects PHYSICS_ALIGNED through the FFT API. Copying
profiles alone would lose this override. Ocean now exposes the existing choice
as `visual_water_profile`, with the same standalone default FULL_CHOPPY_DEBUG.
The new preset selects 1 / PHYSICS_ALIGNED. Preview applies the same existing
surface multipliers. No shader, FFT math, resolution, physical parameter, camera
or vehicle code changed.

## Inactive original coastal bake

The source stores a legacy coastal bake, but gameplay sets `coastal=false` and
`breakers=false`. Its resources depend on the old `validation/p4_paradise` classes
and on the original island geometry. They are not silently ported into Ocean or
activated in another terrain.

The original bake/data/scripts are preserved separately in a verified
4,930,448-byte `coastal_reference.zip`, delivered under
`Test Addons/resource_exports/ocean_production_legacy/`. The internal manifest
retains original relative paths, SHA-256 hashes and the source Git revision.
The portable active preset has no dependency on this archive or on validation
classes. Its complete configured resources and flags match the effective source
apart from the unused bake reference, which is explicitly separated.

## Verification

Godot 4.7.1 Windows / Forward+ D3D12; existing clean project reused. Evidence
retained in `temp/production_preset_20261016/`.

- `verify_exact.json`: all 14 resource trees and all 48 node properties match the
  original capture exactly. Scalar comparison uses encoded Variant bytes, not
  rounded display strings. Only relocated resource/import-cache paths are rebased.
- HDR raw source hash matches; identical import settings produce identical BPTC
  output (11,184,900 bytes), SHA-256
  `e426a0cc78485f3461cb368263a3e1f8c3531da7f731375dc68531f1fe2a444d`.
- `runtime_clean.json`: preset executes without the development project,
  PHYSICS_ALIGNED and multipliers (0,0,1) active, surface/underwater/caustics
  initialized, 120 valid CPU Lite samples across two consumers, 60 shared builds
  in 60 physics ticks, zero failures and 1.5 seconds of wave evolution.
- Resource/scene paths are inside `addons/ocean/`; no active resource loads
  `gameplay/` or `validation/`. Source paths in the provenance manifest are data.
- Source scenes, original profiles, Jet Ski and native/physics files have no diff
  from the base. No Source/Test Addons scene or project settings were changed.
- Delivery checksums and backup paths are in
  `test_addons_before_preset/manifest.json` in the evidence folder.

Initial exporter/checker attempts exposed the inactive legacy bake dependency,
JSON numeric type-tag conversion, and different default HDR import settings.
These were addressed through explicit separation, string type tags and preserving
the original import parameters. Earlier failed logs are retained. No tolerances
were added to the final equality check.

Reproduction: run `validation/export_ocean_production_preset.gd --mode=export`,
then `validation/relocate_ocean_production_preset.py`; import the preset with a
real editor and run the Godot tool in `--mode=verify` and `--mode=runtime` in the
clean project. Pass `--result=<JSON>` to each Godot invocation.

## Use in Test Addons

The files are copied to the same addon-relative preset folder in
`C:/Users/DEV/Documents/test-addons`, with pre-update script backups. Native
binaries, existing terrain/sky/lighting and `Level_1.tscn` are untouched.

For manual use, load each `.tres` into its matching Ocean field and apply node
settings from `AJUSTES_OCEAN.md`. Alternatively replace the Ocean instance with
`ocean_production.tscn` and reassign that instance to the Jet Ski's Ocean field.
The optional lighting reference is separate from Ocean so an existing Sky3D
setup is retained unless the user chooses to replace it. Equal Ocean settings
do not make different terrain, lighting and reflected scenery identical.
