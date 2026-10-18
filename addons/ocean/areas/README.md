# Shared FFT sea states

Ocean has **three seas in total**: the original exterior plus two optional local
states. Local states use the same Production JONSWAP/Hasselmann H0 generator,
LONG/MID/SHORT bands and GPU Stockham FFT. They replace the earlier analytic wave
model. There is no extra surface, reflection pass or underwater compositor per state.

## Authoring

1. On Ocean, expand **Local Sea States → Local Sea State 1 / Local Sea State 2**.
   Each resource exposes **Ocean Space**, **Sea State** and **Wave Structure**.
2. Instance `res://addons/ocean/areas/ocean_wave_area_3d.tscn` in the level.
3. Set its **Ocean** and choose **Sea State** 1 or 2. Several areas can select
   the same state; they share one simulation and remain phase-coherent.
4. Edit the CollisionShape3D footprint and **Blend Distance M**, then save the level.

The exterior Ocean controls remain the source of its original sea. The local
states inherit its **Wave Profile** unless an alternative is explicitly assigned.
The default states start with wind 3 m/s, height scale 0.5, swell 0.15 and wind
7 m/s, height scale 0.7, swell 0.4 respectively. They are starting points, not
hardcoded harbor presets. Their resource instances belong to each Ocean separately.

| Local resource controls | Meaning |
|---|---|
| Ocean Scale | Vertical amplitude scale, matching Ocean. |
| Clipmap Geometry Scale | Horizontal wavelength scale. Uses the existing single mesh. |
| Sea State Mode | WIND_DRIVEN or MANUAL_HS, with the same Production normalization rules. |
| Significant Wave Height M | Target height in MANUAL_HS; 0 produces flat water. |
| Wave Height Scale | Natural spectrum amplitude in WIND_DRIVEN, matching Ocean. |
| Wave Speed Multiplier | Independent local clock speed; 0 freezes that sea. |
| Wind Speed Mps / Wind Direction Degrees / Swell | Same spectrum controls as the exterior. |
| Long Wave Spacing / Mid Fill Amount / Band Scales | Same wave structure controls as Ocean. |
| Choppiness Scale | Multiplies actual FFT choppiness in each inherited band. |

The local clocks continue from their accumulated simulation time when editing
settings, rather than restarting phase. Editor preview uses Preview Time and
dispatches a frozen snapshot only when the state/time changes. Local speeds are
independent of the exterior speed. Tree pause stops the simulation.

## Footprints and mixing

The XZ footprint is **fully local**. The smooth feather extends **outside** the
CollisionShape3D; increasing its width never dilutes the centre. Height/Y position
do not affect it. Box, Sphere and Cylinder are supported, with XZ scale and yaw.
Higher **Wave Priority** is composed last. Equal priorities use stable node paths.
**Influence** fades the selected state as a whole. **Surface Detail Strength**
controls how much of the original material's micro-normal detail remains (default 1).

At most eight active CollisionShape3D footprints per Ocean are uploaded. Extra
lower-priority shapes are omitted with a warning. The two FFT states are allocated
only when used; deleting/disabling the last selecting area releases that state's
solvers. No coastal rebake is required.

The visible mesh mixes the complete FFT displacement, including horizontal chop,
using the exterior's current visual water profile and cascade distance fades.
All generated foam surface variants receive the same hooks. The underwater
camera and waterline raster use those same textures and invert the mixed choppy
surface. CPU contacts import the exact same final H0 bytes into the existing native
CPU Lite field (128/128/128), built on demand only for states affecting a queried
batch. Mixed normals include the feather gradient. CPU Lite is an approximation
of the full-resolution rendered field; in full-chop border regions the native
queries invert each state's field before blending, unlike the GPU's joint inverse.
Hull wake deformation is added after the local sea state.

Local spectra do not receive the exterior's coastal warp/breaker deformation.
Global residual/whitecap foam is suppressed inside local areas so exterior crests
do not appear on calm water; local states do not add their own whitecap history.
Boat foam remains independent. Global breaker carriers, spindrift and experimental
GPU physics query modes still use the exterior field.

## Validation

`validation/local_fft_states_check.gd` checks sharing, native contacts, actual GPU
texture sampling, footprint feathering, state edits, disposal and underwater sensing.
`validation/wave_area_foam_render_check.gd` tests actual foam-material geometry.
`validation/local_fft_performance_check.gd` measures optional GPU timestamps and
on-demand CPU field cost; it writes a report under `temp/wave_areas/`.
