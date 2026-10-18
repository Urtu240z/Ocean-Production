# Saved addon defaults and source release — 18 October 2026

The saved Hull Wave Physics Playground Ocean and saved Jet Ski 01 prefab are the authoring authorities for this release. No live editor session was open at capture time. The current saved mist count is 250 per side; values were preserved rather than replaced with earlier experimental settings.

## Default entry points

- `addons/ocean/ocean.tscn`: all 65 stored Ocean author properties captured from the playground, including complete foam/wave profiles and active coastal data.
- `addons/ocean/presets/hull_wave_playground/ocean.tscn`: the same portable preset, with optional saved lighting reference and its dependent assets.
- `addons/jet_ski/jet_ski_01/jet_ski_01.tscn`: the saved vehicle physics, handling and effects values.
- `addons/jet_ski/common/visual/bow_spray/bow_spray.tscn`: a standalone component matching the vehicle's saved nine-node BowSprayRoot subtree, including both native GPU emitters and their materials/ramps/sizes.

Default foam, wave, quality and Jet Ski appearance resources are synchronized. The older Ocean Production preset remains a separate historical preset. Active coastal resources formerly defined under validation now have portable, independently named resource/sample classes inside Ocean; data and behavior are retained. Resource UIDs are preserved for existing Jet Ski profile references.

The exact source/default fingerprints, including hashes of packed geometry/data arrays, are stored in `addon_saved_defaults_2026_10_18.json`. Recheck with `freeze_addon_defaults.gd -- --mode=verify`. The freezer's explicit `--mode=freeze` rebuilds defaults from saved authoring scenes; the default audit mode does not write values.

## Final validation

- Exact default reload verification: PASS, 65 Ocean properties and nine BowSprayRoot nodes; saved source scenes unchanged.
- Source package dependency audit: PASS, 523 files, 145,979,838 source bytes, no missing paths or development-directory dependencies.
- Fresh final package import: PASS for Ocean alone and Ocean + Jet Ski, without import warnings/errors.
- Fresh final package runtime, Godot 4.7.1 Forward+ / Vulkan on Windows: PASS for Ocean alone and the combined playable addon demo.
- Ocean authoring: PASS, 86 controls, round-trip persistence and independent Ocean instances.
- Hull spray controls: PASS, 24 variant switches, three cached atlases and save/reload. Test startup is bounded for asynchronous readiness; mesh-cache restoration uses the actual authoring layer count.
- Guided mist GPU checks: PASS, actual saved author values, central metric tail, 0.2 m versus 1 m, one-second lifetime, zero-size recovery and lifetime size interpolation.
- Native hull-wave self-mask: PASS, derivative error 0.00000656.
- Native hull-wave self-flotation: PASS, height delta 0 m.
- Linux x86_64 native release library rebuilt successfully under the existing Ubuntu 22 WSL toolchain; Windows and Linux libraries are included. This does not claim a new Linux graphical runtime or Steam Deck hardware test.

Final local packages: `temp/addon_defaults_release_2026_10_18_final/ocean_source.zip` and `jet_ski_source.zip`. The packaging manifest contains per-file SHA-256 hashes. Development tools, caches and native SDK/build directories are excluded.
