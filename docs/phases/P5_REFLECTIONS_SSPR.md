# P5 — Reflections / SSPR

Authority is the active Ocean V3 route in `Water Race Ocean Lab`: Project,
Resolve, Temporal and mip generation run in a `CompositorEffect` at
`PRE_TRANSPARENT`, before the transparent water surface.

Production creates an `OceanSSPR` only while **Systems > Reflections** is on.
It owns the compositor attachment and the RenderingDevice resources. The target
size is `ceil(internal viewport * 0.40)`, Project/Resolve/Temporal use 8×8
groups, candidates are `uint`, raw/final/temporal-history color is RGBA16F and
depth history is R16F. The final texture has a mip chain. Kawase and Near SSR
are deliberately absent from the active path.

Project rejects sky and invalid depth. Resolve writes HDR linear RGB with alpha
as confidence, including the V3 local hole fill confidence of 0.35. A miss is
`vec4(0)`. Temporal reprojects the ocean plane and starts invalid after resize,
enable and resource recreation; its effective settings are enabled, 0.12 weight
and 0.035 depth threshold.

The material keeps `shading_normal_world` for FFT macro distortion and derives
`visual_normal` explicitly for Godot's view-space `NORMAL`. P2/P3 foam changes
the final roughness, so it attenuates SSPR; it does not destabilize projection.
P4 continues to use its view-space refraction normal. `RADIANCE.rgb` carries
the graded SSPR result and `RADIANCE.a` carries confidence: zero confidence
preserves Godot PBR/environment/IBL rather than displaying black.

Effective V3/Lab defaults: base roughness 0.08, range 80–300 m, distortion 1,
edge fade 0.25, exposure −1.5 EV, saturation 0.36, SSPR weight 0.55 and
environment specular boost 0.65. Water IOR is 1.333 (F0 0.020373).

OFF is structural: the surface returns to its base or P4-only shader first,
then the compositor detaches and all SSPR buffers, texture views, pipelines and
shaders are released. Resize retires the old published view before release and
only publishes a completed new final target.

`res://validation/p5_reflections.tscn` provides red, blue/green, white and dark
objects at near/far/grazing positions. `p5_reflections_runtime_validation.gd`
performs 20 OFF→ON cycles. Visual review and performance remain pending Eric.
