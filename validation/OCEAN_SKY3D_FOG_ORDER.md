# Sky3D / Ocean — ghostlike crests, 2026-10-16

Baseline: `7393cb2`. The user's raised waves still looked transparent after the
Wave Body Transmission control. The earlier generic fixture demonstrated
transmission attenuation, but did not reproduce this external compositing issue.

## Confirmed cause

Test Addons uses Sky3D's `shaders/AtmFog.gdshader` on `SkyDome._FogMeshI`.
`SkyDome.gd` gives that full-screen transparent material render priority **100**.
It reconstructs distances from `hint_depth_texture`, then draws atmospheric
scattering over the scene. That depth input does not provide the displaced water
surface at this stage. Its fallback sea-level cap handles downward plane hits,
not upward rays intercepted by wave crests. The result veils water against sky
or distant scenery and resembles transparency.

Reproduced with the actual `Level_1.tscn` assets, the frozen production FFT preview
at `preview_time = 0`, and a camera near `(1451.1, -0.3, 2418.2)` matching the
reported view. All tests are Windows Godot 4.7.1, Forward+ / D3D12.

- Disabling the water shader's transmitted scene term does not remove the veil.
- Disabling reflections does not remove it.
- `fog_disabled` and even a solid, unlit diagnostic water color do not remove it:
  a separate full-screen fog material is drawn afterward.
- Disabling Sky3D's fog removes the veil, establishing the external source.
- Moving only that fog material before Ocean removes the veil while keeping fog
  enabled and retaining its authored density/colors.
- Restoring priority 100 reproduces the artifact in the same frozen view.

The saved new Optics properties contained `null` entries during investigation.
Fresh loading nevertheless produced numeric defaults `1.0`, `1.5`, `0.75`, which
were verified on the material. Reloading or changing those controls is therefore
not an adequate fix for this artifact.

## Applied correction

After the user saved their pending scene changes, **one existing node property**
was added to `C:/Users/DEV/Documents/test-addons/Level_1.tscn`:

```ini
[node name="SkyDome" ... parent="Sky3D" ...]
fog_render_priority = -1
```

Ocean remains at priority **0**. The spray, rider, opaque geometry and other
vehicle effects keep their existing priorities. No Ocean/Jet Ski execution code,
shader, FFT, native binary, physics or authored optical coefficient is changed
by this correction. No Sky3D source is patched and Ocean gains no dependency on
Sky3D. This setting belongs to the host scene integrating the two addons.

This is a draw-order solution: the atmosphere still fogs the backdrop, but its
full-screen overlay no longer veils the surface of the water. It is not an exact
combined volumetric atmosphere/water calculation. Other transparent materials
also retain their existing ordering relative to their own priorities; this is
not a redesign of fogging every transparent object.

The previous transmission controls remain available for actual transmitted
scenery. They are not needed to fix this Sky3D overlay and should not be used to
compensate for it.

## Evidence and recovery

Evidence folder: `temp/wave_transmission_fix_20261016/`.

- `frozen_view_matching/`: matching-angle component-isolation images.
- `frozen_material_diagnostic/`: actual shader source, solid/unlit and fog-flag
  probes showing that the external veil survives internal material changes.
- `sky_fog_isolation/`: Sky3D fog enabled/disabled and water-after-fog test.
- `priority_fix/`: original 100, fog -1 with water 0, restored 100.
- `Level_1_before_fog_order.tscn`: byte-identical saved scene before the single
  configuration change; original SHA-256 verified before writing.
- `scene_change_manifest.json`: exact original/installed SHA-256 and restoration
  instructions. Diff must contain only `fog_render_priority = -1` in SkyDome.
- `saved_scene_runtime.json`: fresh-load validation of the persisted setting,
  actual fog/water material priorities, enabled fog, native field and vehicle.

The scene is outside the Production Git repository. Its backup/manifest, not
this documentation commit, preserves its exact bytes. The README shipped with
Ocean documents the existing setting so future installations can reproduce it.

Do not open two editors on the same project to apply this: save pending edits,
then reload the externally changed scene or set the same property in the open
editor before saving again.
