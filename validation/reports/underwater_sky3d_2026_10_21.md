# Sky3D underwater ambient tint — 2026-10-21

Fixed in Production and the user's actual project:
`C:/Users/DEV/Documents/test-addons`, scene `res://Level_1.tscn`.
This is separate from the TestAddons folder inside the addon release directory.

## Cause

Sky3D writes its ambient palette to `Environment.ambient_light_color` independently
of the sun/moon direct-light energy. Ocean approximated sky irradiance using
the celestial lights and the sky-contribution blend. At sky contribution 0.995,
with both celestial sources below the horizon, almost all authored ambient color
was lost. The underwater shader then multiplied the volume by that near-zero
irradiance. It also retained its fixed blue scattering tint.

In the saved Level_1 rig, the ambient palette remained nonzero while underwater
incident RGB fell to around 0.00004–0.00023. The warm sky was visible above the
surface, but the medium below it was almost black. The previous generic
day/sunset/moon test did not reproduce this combination of Sky3D ambient color,
sky contribution and zero direct energy.

## Change

- Preserve a separate linear `ambient_tint` in the existing lighting snapshot.
  Direct energy, its horizon gating and the existing irradiance estimate remain
  unchanged for other visual consumers.
- Pass ambient tint separately to the underwater compositor. One vec4 is added
  to its uniform block: 336 → 352 bytes, with matching CPU packing and mutex state.
- When an authored ambient tint is present, the profile controls volume intensity
  and depth falloff; ambient chroma controls the tint. A sun/moon horizon gap no
  longer zeros the authored volume. This is an artistic ambient response, not a
  claim of physical sky-irradiance integration.
- `scene_lighting_influence` blends the authored scattering color toward the
  ambient palette. Zero restores the authored color exactly. Surface strength,
  reference energy, density, absorption, visibility distance and depth falloff
  remain available. A black scattering color still disables the base volume.
- Bubble illumination uses the same ambient helper while keeping its tint,
  spectral attenuation and density behavior.
- Rays and caustics inherit ambient hue while retaining the actual directional
  source's direction/energy. No rays or caustics are fabricated when the sun and
  moon are unavailable.
- No extra render pass or sky readback. No edits to physics/C++, Sky3D, Level_1,
  saved profile resources, foam or bow spray. Luna's existing Production changes
  are retained; only the underwater portions needed this correction.

## Validation

Godot 4.7.1, Forward+, D3D12, Windows / RTX 4070 Laptop.

1. Actual Level_1 before/after, same submerged viewpoint and authored automatic
   exposure. Runtime-only changes set the hour, camera and diagnostic view; none
   are saved to the scene or resources. Five time samples pass hue and nonblack
   volume checks, with no shader/script errors.

| Saved rig hour | Sky3D palette | Before: mean final RGB luminance | After |
| ---: | --- | ---: | ---: |
| 6 | White | 0.552 | 0.557 |
| 10 | Near-neutral warm | 0.450 | 0.487 |
| 12 | Orange | 0.030 | 0.318 |
| 20 | Blue | 0.024 | 0.420 |
| 0 | Orange | 0.035 | 0.356 |

These are SDR screenshot measurements with the scene's auto exposure, not
radiometric calibration or performance results. The hours reflect this rig's
saved Sky3D location/UTC/time-mode configuration. No sunset is forced by clock
time: underwater follows whichever ambient color Sky3D actually publishes.

2. `validation/underwater_environment_tint_runtime.gd` exits 0. Isolated real-GPU
   fixture checks neutral/warm/blue ambient at 100% sky contribution with zero
   celestial/estimated irradiance; all remain visible and follow their palette.
   Reported physical irradiance stays exactly zero. It also checks:
   - No fabricated rays without a valid directional source.
   - Real sun supplies ray energy; ray color follows warm ambient.
   - Bubble shader variant can be activated/deactivated without shader errors.
   - Live changes retain compositor identity.
   - Zero influence gives byte-identical frames for different ambient colors.
   - Reference energy remains an intensity control.
   - Zero surface strength or black scattering color disables the volume.
   - Disabled ambient plus no lights still produces darkness.

3. Six scoped Test Addons files are verified against their deployment SHA-256
   hashes. Their original bytes are preserved under
   `temp/underwater_ambient/original_test_addons/`; the manifest is
   `temp/underwater_ambient/sync_manifest.json`.
4. `git diff --check` passes. Existing Terrain3D deprecated-interpolation warning
   remains unrelated; no native addon was updated.

Evidence: `temp/underwater_ambient/before.json`, `after.json`, screenshots
`before_12.png`, `after_12.png`, `after_20.png`, and `regression/result.json`.
The fixed Test Addons files are deployed in place. Production changes remain
local alongside Luna's uncommitted work; nothing is pushed or repackaged.

## Follow-up: independent low-light intensity

The initial tint-only response kept full authored volume brightness even after
the sun disappeared. It was visibly too bright at dusk/night. Added
`OceanUnderwaterMediumProfile.low_light_volume_strength` under Scene Lighting,
range 0–1, default 0.20. A value of 1 restores that first, brighter response.

The gain blends from this low-light setting to 1 according to actual directional
linear luminance divided by `scene_light_reference_energy`, clamped to 0–1.
Thus the ambient palette remains independent of intensity, while full daylight
retains unit gain. The gain applies to the base water volume and bubble fill;
ray/caustic energy still follows its actual directional source. Legacy influence
0 ignores this new gain. A reserved uniform component carries the scalar, so
the uniform buffer remains 352 bytes and no new pass is added.

The extended GPU regression exits 0: changing the setting from 1 to 0.20 produces
byte-identical images at full daylight. The isolated warm low-light volume mean
luminance drops from 0.260 to 0.108, remains visible and keeps its warm hue.
The actual Level_1 probe also exits 0: its warm sample drops from 0.318 to 0.130,
and its blue sample from 0.420 to 0.239. These actual-scene measurements include
automatic exposure and are not expected to scale linearly with the control.

The control is installed in Production and `C:/Users/DEV/Documents/test-addons`.
The deployment manifest now covers seven scoped addon files, including the
profile script. Existing `.tres` settings and `Level_1.tscn` remain unchanged.
Evidence: `low_light.json`, `low_light_12.png`, `low_light_20.png`,
`low_light_regression.stdout.log`, and `regression/result.json` in the same root.
