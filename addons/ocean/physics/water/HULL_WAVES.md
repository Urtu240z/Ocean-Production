# Physical hull waves (experimental)

Enable **Ocean → Hull Waves → General → Deformation Enabled**, then
**Hull Waves → Physics → Enabled**. The script constructor defaults to physics
off; saved appearance resources may explicitly opt in. Existing scenes retain
their saved foam and wave settings.

For a manual test, run `res://validation/hull_wave_physics_playground.tscn`.
It duplicates the scene's appearance resource and enables physics only for that
run. Drive a curve and cross your old wake. The ordinary foam playground retains
the user's saved settings, including an explicit physics opt-in. Use the normal
Godot Run Current Scene button.

## Controls

Underwater's camera sensor and waterline raster sample the same current/previous
wave atlas as the visible Ocean, with the same interpolation, height cap and
display falloff. This also works with wave physics disabled: the waterline
follows the visible deformation. No additional wave field, mesh or GPU readback
is introduced. Disabling deformation clears the borrowed underwater bindings.

- **Self Delay S** (0.8 s): fully protects the nearby hull from newly emitted own
  waves for this interval, then smoothly restores their effect over the next
  interval (fully physical by 1.6 s at the default). Zero disables protection.
- **Self Radius M** (3 m): the whole querying hull inside this radius is protected
  from its recent waves, including their troughs, slopes and vertical velocity.
  The protection fades outside the radius and ends at twice the radius. This
  prevents enabling physics from changing cruising flotation. Old own wakes and
  waves from other vehicles remain tangible.
- **Max Vertical Speed Mps** (5 m/s): bounds only the added vertical water
  velocity. It does not change the FFT water velocity or the visible height.
- Height, width, wavelength, propagation speed, rise, fade and duration continue
  to use the existing Wake and Impacts controls. The combined height cap is shared
  with drawing. Start with moderate wave heights before trying artistic extremes.

The velocity limit deliberately differs from the exact height derivative when
that derivative exceeds the limit. A two-metre, rapidly propagating short wave
can still be a severe obstacle. This prototype does not certify all combinations
of the Inspector's artistic ranges as stable driving settings.

## Implementation

One Ocean owns a bounded analytic packet state (maximum 128) and advances it at
most once per physics tick. Emission reads existing hull contacts and physics
transforms. A snapshot of all sources is published before the first water query
in a tick, with completed previous contacts as input. Every consumer sees that
same snapshot. The renderer uses the same packets and clock; interpolation is
retained between physics updates. Hull-wave time is independent of the FFT's
phase-speed multiplier.

The native sampler adds height, analytic X/Z slope and partial vertical water
velocity to the existing authoritative water samples. It runs once per actual
contact, after the base water's geometry history and seams, before drift and
contact-cache publication. Cached scalar reads copy the composite result.
FFT warm starts, branch geometry and base surface history never store the added
wave a second time. Existing buoyancy and driving laws consume the usual samples.

There is no second FFT, additional surface mesh, GPU readback or render-driven
physics. The extra native object holds packet descriptors; it builds no grids.
The state survives wind/spectrum rebuilds and remains active when Hull Foam is
disabled. Independent Oceans have independent states. Source ownership is stored
on each consumer's existing contact context, including impact packets.

Physics is independent of the camera. Drawing retains a 128-metre local atlas
and feathers its distant border in physical mode; this display limit does not
expire physical packets. The ordinary visual-only mode keeps its previous camera
fade and render emission path. Numerical packet/GPU agreement does not imply
exact equality after finite atlas sampling and Ocean mesh tessellation.

## Native platform requirement

The Windows extension is rebuilt with `publish_hull_waves` and `sample_hull_waves`.
An already open editor that loaded the earlier DLL needs a restart to discover
these methods. Other native platforms must rebuild from the updated source using
the addon's existing build scripts. A missing capability produces one warning
and leaves wave physics inactive; the original water provider remains usable.
The Linux binary has not been rebuilt or validated for this prototype.

## Validation entry points

- `validation/hull_wave_physics_contract.gd`: CPU/GPU packet parity, derivatives,
  ownership, sample composition and invalid-publication clearing.
- `validation/hull_wave_physics_runtime.gd`: production scene, cache, lifetime,
  camera/foam independence, wind rebuild and controlled physical response.
- `validation/hull_wave_self_flotation_check.gd`: production vehicle and emitter,
  flat-water cruising height with wave physics off/on (5 mm tolerance).
- `validation/hull_wave_self_mask_check.gd`: whole-hull self protection, smooth
  spatial/time derivatives, older own waves and unaffected other-vehicle waves.
- `validation/hull_wave_physics_benchmark.ps1`: alternating real-time runs with
  1/4/6/12 vehicles, frame/CPU/GPU timings and external process memory sampling.
- `validation/foam2d_ocean_authoring_check.gd`: English controls, default-off and
  save/load checks.

Performance reports distinguish integrated frame timings from the native dense
packet microbenchmark. Short memory windows are diagnostics, not a leak test.
