# Local wave areas — 2026-10-18

> Superseded by shared Production FFT states. See
> [local_fft_states_2026_10_18.md](local_fft_states_2026_10_18.md).
> The implementation details below describe the previous analytic model.

## Visual/blend correction and spectrum expansion

The original runtime check did not start the hull-foam director and therefore
missed the shader replacement used in gameplay. The director rebuilds materials
from preserved shader sources, which lacked the new area code. Area hooks now
run inside the common surface shader builder, including preserved Base/Optics/
SSPR/detail variants. Height and normal hooks run before the hull-wave overlays.
The first implementation's full 3D distance also capped every interior sample
by the default Box's 30 m half-height. This explains the whole-area dilution
above a 30 m blend. Zones now use an XZ footprint with a full-strength core and
an exterior distance feather. Height and vertical placement do not reduce it.

The old fixed four-wave train is replaced with a seeded broadband spectrum:
4–24 main components, 3 independent swell components and 4 ripple components.
Controls include wavelength/energy variation, angular spread, crossed seas,
wind-to-height influence, moving wave groups, independent band speeds, global
micro-normal detail weight and foam attenuation. Three starting presets are
available. Coefficients are cached by authored settings; GPU material variants,
CPU physics and underwater use the same coefficients and clock. GPU snapshots
are now 9488 bytes. The peak-sum bound is used for clipmap culling.

New verification:

- CPU/GPU spectrum check: PASS, including stable seed, seed variation,
  independent swell/ripples and full core with a 100 m exterior blend.
- Translated material probe at (1625, 2, 1613): PASS, using an actual rendered
  ShaderMaterial rather than only a compute-buffer comparison.
- Actual hull-foam material geometry regression: PASS on Vulkan and D3D12.
  It uses a controlled non-flat displacement texture to avoid startup-dependent
  FFT publication. Captured height-image variance is 0.008873 for the exterior,
  zero for a calm zone with a 100 m blend, and about 0.00104 for local irregular
  waves. This proves the gameplay foam shader changes the visible geometry.
- D3D12 hull-foam rendering regression repeated in test-addons: PASS.
- Updated full runtime contact/underwater check on Vulkan and test-addons D3D12:
  PASS, `failures=[] waterline=0.0` in the calm zone.
- SHA256 of the user's Level_1, Ocean scene, default wave profile and default
  foam style remained unchanged after installation. Authored tuning was retained.

The initial validation and limitations below are historical; this section
supersedes its four-component model and interior-feather description.

Added `addons/ocean/areas/ocean_wave_area_3d.tscn`, an editor-editable Area3D
with an independent local wave climate and smooth interior feather. Box,
Sphere and Cylinder CollisionShape3D nodes are supported. Local controls cover
height, wavelength, speed, wind direction/speed, choppiness, angular spread and
phase seed. Priority resolves overlaps; up to eight shapes per Ocean are kept.
Shapes outside the selected Ocean have no effect. An explicit target or Ocean
ancestor is supported; automatic binding requires exactly one active Ocean.

The field uses four analytic components and a bounded crest harmonic, not an
additional FFT per area. It replaces exterior height in the volume and preserves
the global FFT horizontal mesh parameterization. The signed shape distance is
converted to a world-metre smoothstep. CPU and GPU include the blend gradient
when composing slopes. Hull waves compose afterwards. Global FFT-derived foam
is attenuated according to the local steepness. Underwater camera/waterline
shaders use the same local heights via a 1040-byte immutable snapshot.

Validation:

- `wave_area_check.gd`: PASS. Registration, unchanged exterior/boundary, local
  interior, exact transition slope vs finite difference, time derivative vs
  vertical speed, calm interior, disabled area, Sphere/Cylinder footprints,
  rotated/scaled Box, overlap priority, physics height/depth and GPU buffer size.
- `wave_area_check.gd -- --gpu`: PASS on Vulkan. Five CPU/GPU height comparisons
  across interior, feather and exterior of the rotated/scaled volume.
- `wave_area_runtime_check.gd`: PASS using the real Ocean, GPU surface shader,
  native CPU FFT provider and underwater compositor. Calm-zone contact height
  is zero; a changed local climate reaches CPU contacts; material uniforms are
  bound; underwater sensor reports the local flat water surface (0 m).
- Runtime check repeated in `C:/Users/DEV/Documents/test-addons`: PASS,
  `WAVE_AREA_RUNTIME_RESULT failures=[] waterline=0.0`.
- Final GPU-rendered screenshot inspected at `temp/wave_areas/runtime.png`.
- `git diff --check`: PASS.

Existing test-addons source files were staged, patched with only wave-area
hunks, then installed. No Level_1 scene or saved tuning resource was modified.

Limitations: analytic local heightfield, no independent local JONSWAP spectrum,
no horizontal Gerstner folds and no local coastal rebake. Global breaker
carriers, spindrift emission and experimental GPU validation contact modes are
not redirected to the local climate. Public CPU water contacts and underwater
classification are integrated. Advanced effects that require the global FFT
should be disabled when evaluating calm sheltered zones.
