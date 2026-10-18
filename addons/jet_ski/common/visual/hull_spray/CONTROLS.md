# Bow Spray, Splash and Tail Jet

Select **BowSprayRoot** inside the vehicle. Its Inspector contains independent categories: **Bow Spray**, **Splash**, **Tail Jet** and **Stern Mist**. Existing property keys, node transforms and saved profiles are preserved.

## Authoring

Bow Spray retains its original controls. Splash and Tail Jet each expose an independent **Appearance → Settings** resource with the same appearance controls: General, Textures and Flipbook, Animation, Atlas Cleanup, Soft Edges and Side View, Spray Color, Water Appearance and Highlights, Submersion Suppression, Low/High Speed Shape, Volume and Undulation, Layer Scale and Height Motion, Solid Occlusion, Hull Attachment and Editor Preview.

Animation FPS, low/high speed multipliers, frame blending, distortion, normal motion and volume clocks remain independently adjustable. Zero animation FPS freezes PNG playback without stopping the other clocks. Editing one profile does not change the other emitters. Use Make Unique for a vehicle-specific resource.

Splash adds **Trajectory** and **Impact Response**. Elevation Degrees is measured above the sea plane: zero is horizontal. Sustained Rate Hz repeats contact sheets while moving; impacts add irregular left/right intensity, delay and duration. The sheets originate between the hull and sampled water surface and are suppressed in the air.

Tail Jet adds **Nozzle and Cone** and **Residual Water**. Choose **Splash 3** or **Splash 4** with Variant. The TailJet node is a fixed hull-local nozzle, following hull pitch and bank. Turn Response smooths its additional bend; Roundness gives the curved jet volume; Downward Curve controls its downstream drop. A finite residual-water envelope can produce irregular sputters after the intake leaves the water.

**Tail Jet → Visibility** adds **Surface Fade Depth M** (default 0.25 m) and **Water Core Strength** (0.45). The first softly fades shallow aerated water instead of cutting the jet abruptly at the sampled waterline. The second strengthens the wet core against white foam, respecting the PNG silhouette, Spray Opacity and Water Appearance toggle. Zero restores the previous behavior for each. Solid hull occlusion and full-submersion suppression still apply. Render Priority remains 100; drawing the jet through the hull is not a visibility fix.

The nozzle is deliberately not lifted to the sea surface. A low or downward-pointing TailJet can send most of its cone underwater; increasing brightness cannot recover clipped pixels. Adjust the anchor direction, High Speed Shape → Sheet Height or Nozzle and Cone → Downward Curve to change that trajectory. The visibility fade allows a shallow transition, rather than displaying a fully submerged jet above the ocean.

**SternMist** is a saved, editable **GPUParticles3D** child of BowSprayRoot. Enable Editable Children on BowSprayRoot in the vehicle, or open `bow_spray.tscn` directly. The native node owns Amount (56), Lifetime (0.5 s), Process Material and Draw Pass 1; profile changes do not overwrite these particle settings. Local Coords is off: newly emitted mist stays in the world while the nozzle moves. Dry contacts, jumps and coasting stop emission; existing particles finish their own lifetime instead of disappearing with the emitter.

For finer mist, edit **Draw Passes → Pass 1 → Size** (0.3 m), and **Process Material → Scale**, velocities, gravity and turbulence. **Process Material → Color → Color Ramp** controls color and alpha over lifetime: transparent white at 0, opaque white in the middle, transparent white at 1. The shader uses the native particle color/alpha without an additional lifetime fade or size curve. A NoiseTexture color ramp shapes texture values, rather than particle age; it is also preserved.

Under **Pass 1 → Material → Shader Parameters**, **Mist Texture** accepts a grayscale/alpha mask, **Mist Noise** controls internal breakup and **Detail Scale** sets its frequency. The material has no moving nozzle envelope. Use Make Unique for vehicle-specific resource edits. **Stern Mist → Appearance → Settings** controls Enabled, Offset, Speed Response and Editor Preview. Its Color, Opacity, Turbulence, Amount, Lifetime, Width and Length apply only to legacy, generated emitters; Height is retained for compatibility. The authored node keeps its own Amount, Amount Ratio, lifetime, particle process resource, color ramps, noise textures and draw material values through profile updates. Amount can be set to 1,000 on the node; the legacy profile also allows up to 1,000 without changing the saved count automatically. Offset follows the sampled stern waterline/nozzle and is applied to the emission origin. Enable Preview in Editor and set Preview Speed Kmh to tune without driving. No additional water queries or per-frame CPU particle updates are introduced.

Each category has its own **Editor Preview**. Enable Preview in Editor and set Preview Speed to 25 to tune Tail Jet without throttle or wet contact. Appearance Enabled must remain on. Gameplay emission can stay disabled while previewing.

The saved Jet Ski 01 mist preset uses 1,000 particles, Lifetime 0.35 s, sphere radius 0.55 m, Fixed FPS 0, Explosiveness 0, Randomness 0, interpolation and fractional delta enabled, and Amount Ratio 1. Its artist ramp reaches the first opaque stop at 25% of life, starts its long fade at 45%, and ends transparent. Mist Opacity is 0.035; Breakup Strength and shader Turbulence are both 0.35 to soften distinct birth silhouettes. Wet forward movement drives emission even when coasting without throttle; stationary or dry hulls stop emitting. These are editable saved scene values, not runtime overrides.

The mist shader multiplies native ramp alpha and authored Mist Opacity by a speed factor. Shader Parameters expose Opacity Start Speed Kmh (10), Opacity Full Speed Kmh (60), Low Speed Opacity (0.12) and High Speed Opacity (0.9). The controller publishes smoothly filtered speed without overwriting these settings or the ramp. The result is faint mist at 10 km/h and progressively more visible mist toward 60 km/h. A stopped/dry emitter retains its last speed factor so surviving particles finish naturally.

## Mist microdroplet relief

In **SternMist → Draw Passes → Pass 1 → Material → Shader Parameters**, **Droplet Relief Enabled** toggles procedural normal-map lighting. **Droplet Normal** is a dedicated NoiseTexture2D with As Normal Map enabled, driven by FastNoiseLite. It is separate from **Mist Noise**, which remains scalar for distortion and opacity breakup. Converting Mist Noise itself to a normal texture does not create lighting relief.

Initial relief values: **Droplet Normal Strength 0.55**, **Droplet Normal Tiling 3**, **Droplet Roughness 0.28**, **Droplet Specular 0.35**. Increase Strength for stronger slopes; increase Tiling for finer, more numerous details. Lower Roughness sharpens reflections; raise Specular for stronger highlights. Edit Noise → Frequency and Bump Strength inside Droplet Normal for the procedural source. Illumination uses the same billboard basis as the camera-facing geometry, and highlights follow actual scene lighting. This adds apparent surface relief, not particle geometry or volumetric scattering. Native color ramps, alpha masks and speed transparency continue to multiply the result.

## Two guided hull-side emitters (current experiment)

The current saved scene replaces the single rear cloud with **BowSprayRoot → SternMist** (left) and **SternMistRight** (right). Both are saved GPUParticles3D nodes with independent process/draw materials. Their initial budget is 500 each (1,000 total), Lifetime 0.65 s, Fixed FPS 0, Randomness 0 and world coordinates. The longer lifetime lets a particle travel the length of the hull. The artist's latest draw material values and color ramp are retained; the primary node also keeps its original ParticleProcessMaterial in **Metadata → Original Particle Process Material** for reverting to free mist.

The curved trajectory uses a **ShaderMaterial** as Process Material rather than ParticleProcessMaterial. Open **Process Material → Shader Parameters**:

| Parameter | Meaning | Initial value |
| --- | --- | --- |
| Side | Left/right sign | -1 / +1 |
| Front Z / Stern Z | Start/end along the hull, relative to the nozzle/water anchor | -2.95 / 0 m |
| Front Width / Middle Width / Stern Width | Distance from the center line | 0.3 / 0.68 / 0.49 m |
| Guided Fraction | Fraction of lifetime spent on the complete metric route, including merge and tail | 0.95 |
| Stern Swirl | Small deformation along the contour, tapering to zero at release | 0.045 m |
| Emission Jitter | Width/height/longitudinal scatter around the curve | (0.055, 0.025, 0.04) m |
| Merge Distance M | Distance behind stern over which the sides meet at the center | 0.25 m |
| Tail Length M | Straight shared segment after convergence, independent of Lifetime | 1 m |
| Scale Min / Scale Max | Native billboard scale range | 0.8 / 1.8 |
| Birth Size / End Size | Size multipliers at birth and death, smoothly interpolated over lifetime | 1 / 1 |
| Color Ramp | Particle color/alpha over lifetime | artist ramp |

Particles follow the rounded sides, converge behind the stern and continue along a straight common segment. Tail Length M controls that segment in metres: raising Lifetime slows travel along the same route rather than extending it. The complete route occupies Guided Fraction of lifetime; at its end particles detach with the measured hull velocity and finish their fade in world space. Detached particles do not rotate with later steering. Dry/disabled emission releases surviving particles at their current positions. Runtime pose/velocity/lifetime/active uniforms are managed by the controller; the authoring parameters above remain editable. Amount can be reduced to 60–70 on either native node. The initial artist ramp is shared between the two process materials: Make Unique on the ramp for independent color edits. If the tail fades too early, move the last opaque ramp stop later in life; geometry length cannot override zero alpha.

## Attachment points

```text
BowSprayRoot
  BowSprayLeft
  BowSprayRight
  SplashLeft
  SplashRight
  TailJet
  HullSprays
  SternMist (GPUParticles3D)
```

SplashLeft, SplashRight and TailJet transforms remain editable with Editable Children enabled. Animation offsets affect vertices rather than overwriting the authored nozzle transforms. Splash width controls outward reach, length controls longitudinal spread, and height limits elevation.

Bow Spray grows progressively after renewed water contact and suppresses both foam and transparent highlights in the air or underwater. Side splashes retain the user's disabled state. No new foam reinforcement is enabled by this cleanup.

## Assets and installation

Splash 2/3/4 atlases are inside `textures/`. Original bow PNGs are inside `../bow_spray/sequences/Splash_1/`. Copy both `addons/ocean/` and `addons/jet_ski/`; external root-level Splash folders are only source material for rebuilding atlases and are not needed by the runtime.

The optional live review panel is called **Splash and Tail Jet**. No effect uses F8. The Inspector is the full authoring interface.
