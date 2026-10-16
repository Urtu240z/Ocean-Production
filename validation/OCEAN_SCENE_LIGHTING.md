# Scene lighting: underwater, reflections and bow spray

Base: `70de1e0`, branch `wip/feel-soft-water`. Tested with Godot 4.7.1
Forward+, D3D12, RTX 4070 Laptop, Windows. No Linux/Steam Deck execution is
claimed for this visual change.

## Implementation

- `Ocean` caches one main-thread lighting snapshot per process frame. Optional
  sun, moon and WorldEnvironment references avoid a time-of-day plugin dependency.
  Automatic discovery is cached; exactly two directional lights allow an
  unambiguous automatic moon. The edited scene is used in editor preview.
- Linear incident color/energy modulates existing underwater scattering and
  bubble illumination. The existing artistic colors, absorption, waterline,
  depth falloff, clocks, patterns and simulation remain. Three controls live in
  `OceanUnderwaterMediumProfile`: `scene_lighting_influence` (1),
  `scene_light_reference_energy` (1), `scene_ambient_weight` (0.35).
- Rays and caustics follow the dominant sun/moon source, including color,
  visibility, horizon and energy. There is one existing ray marcher, not two.
  Caustics previously used sun direction without its actual color/energy.
- Sky irradiance is an approximation using the scene's celestial lights and
  authored environment ambient settings. No sky cubemap readback or extra GPU
  pass is added. Local lights are not injected into the underwater volume.
- Medium and caustics each add one std140 vec4 to their existing uniform block
  (320 to 336 bytes), with matching snapshots under their existing mutexes.
- Reflections retain their original daytime response. Existing specular is
  multiplied by a smooth low-light gain, controlled separately by
  `low_light_reflection_boost` (1.5; 1 disables) and
  `low_light_reference_energy` (0.5). This is an artistic gain, not an exposure
  correction or added radiance. A genuinely black environment still reflects
  black. The actual Test Addons sky produced reflections at night in the probe;
  the reported completely black sea was not reproduced as a general renderer
  failure. No camera exposure or third-party sky settings were changed.
- Bow spray now puts foam color into lit ALBEDO and has zero EMISSION. It
  receives shadows and local lights. Foam has a rougher response than water.
  Animation, PNGs, alpha, solid-depth occlusion, render priority, geometry,
  attachment and contact fades remain unchanged.

## Validation and evidence

Evidence root: `temp/scene_lighting_impl_20261016/` (preserved, excluded from
the commit). All successful runtime tests used the real Forward+ renderer.

| Check | Result |
| --- | --- |
| Clean addon editor import | No script/shader errors (`import3_output.log`) |
| Rendered lighting fixture | PASS, `fixture3/result.json`; day/sunset/moon/dark, medium and caustics packets, real bow shader |
| Complete darkness | Underwater fixture mean luminance 0; bow maximum RGB 0 |
| Local orange light | Bow maximum RGB 0.396; visible red illumination with directional lights off |
| Daytime reflections | Gain exactly 1; darkness gain 1.5 |
| Live editor preview | PASS, `editor/editor_preview.json`; light energy and gain changes reach shader, no FFT rebuild |
| Preset values | PASS, `preset_result.json`; 14 resources, 48 node settings, zero differences |
| Shared CPU FFT | PASS, `preset_runtime_result.json`; two consumers, 60 ticks, 60 builds, 120 valid samples, zero failures |
| Production full scene | Native loaded, vehicle and camera active, zero water build failures, no runtime errors |
| Production acceleration | 14.02 m/s, native builds continue, 8-frame production spray sequence loaded, no runtime errors (`full_scene_driven/production.json`) |
| Test Addons full scene | Native loaded, OceanConnection ready, vehicle floats, autonomous camera active, no runtime errors (`full_scene/test_addons.json`) |
| Real Sky3D | Cached sun/moon resolved; sunset warm, moon blue, dark incident irradiance about 0.00003–0.00007, matching residual authored ambient |

Screenshots for the actual Test Addons scene are in `full_scene/`, including
sunset, moon and darkness. The separate sky reflection probe changes only its
in-memory lighting and camera exposure; its exaggerated specular comparison
is diagnostic, not a production setting. The isolated bow fixture uses uniform
coverage to make the lighting assertion independent of sparse PNG pixels;
the moving production scene also loads the original sequence.

One concurrent Test Addons **editor import** could not create its hot-reload
`~*.dll` copies while the user's editor was open. It also reported existing
third-party UID issues. Neither binary was replaced or unlocked. Subsequent
regular runtime executions loaded both native libraries and the actual scene
successfully. The clean addon project imported successfully.

The first fixture launch had an incorrectly formed output argument; the
corrected run passed. An unprivileged helper launch failed during engine
startup; the normal-permission rerun succeeded. These failed attempts are kept
in the evidence directory and are not the passing validation results.

## Preservation and installation

The original preset snapshot remains intact: new profile controls are additive
`profile_extensions` entries in `source_manifest.json`. Existing authored `.tres`
files and scenes were not resaved. No FFT implementation, native binary,
provider, hull, forces, driving, camera or input code was modified.

Test Addons received the same changed addon files (19 paths). Original files
are under `temp/scene_lighting_impl_20261016/test_addons_before/` with SHA-256
before/after values in `test_addons_deployment.json`. That manifest preserves
original backup hashes through the final three-file editor correction. To roll
back the destination, restore files with a non-null `previous_sha256` to the
same relative paths and verify their hashes. The two helper files with a null
previous hash were new; remove those only after restoring the referring scripts.
`Level_1.tscn`, user profile resources and Sky3D were not edited.

Production rollback is the inverse of this commit. All former experiments,
worktrees and performance evidence remain untouched.
