# Bow Spray, Splash and Tail Jet

Select **BowSprayRoot** inside the vehicle. Its Inspector contains three independent categories: **Bow Spray**, **Splash** and **Tail Jet**. Existing property keys, node transforms and saved profiles are preserved.

## Authoring

Bow Spray retains its original controls. Splash and Tail Jet each expose an independent **Appearance → Settings** resource with the same appearance controls: General, Textures and Flipbook, Animation, Atlas Cleanup, Soft Edges and Side View, Spray Color, Water Appearance and Highlights, Submersion Suppression, Low/High Speed Shape, Volume and Undulation, Layer Scale and Height Motion, Solid Occlusion, Hull Attachment and Editor Preview.

Animation FPS, low/high speed multipliers, frame blending, distortion, normal motion and volume clocks remain independently adjustable. Zero animation FPS freezes PNG playback without stopping the other clocks. Editing one profile does not change the other emitters. Use Make Unique for a vehicle-specific resource.

Splash adds **Trajectory** and **Impact Response**. Elevation Degrees is measured above the sea plane: zero is horizontal. Sustained Rate Hz repeats contact sheets while moving; impacts add irregular left/right intensity, delay and duration. The sheets originate between the hull and sampled water surface and are suppressed in the air.

Tail Jet adds **Nozzle and Cone** and **Residual Water**. Choose **Splash 3** or **Splash 4** with Variant. The TailJet node is a fixed hull-local nozzle, following hull pitch and bank. Turn Response smooths its additional bend; Roundness gives the curved jet volume; Downward Curve controls its downstream drop. A finite residual-water envelope can produce irregular sputters after the intake leaves the water.

Each category has its own **Editor Preview**. Enable Preview in Editor and set Preview Speed to 25 to tune Tail Jet without throttle or wet contact. Appearance Enabled must remain on. Gameplay emission can stay disabled while previewing.

## Attachment points

```text
BowSprayRoot
  BowSprayLeft
  BowSprayRight
  SplashLeft
  SplashRight
  TailJet
  HullSprays
```

SplashLeft, SplashRight and TailJet transforms remain editable with Editable Children enabled. Animation offsets affect vertices rather than overwriting the authored nozzle transforms. Splash width controls outward reach, length controls longitudinal spread, and height limits elevation.

Bow Spray grows progressively after renewed water contact and suppresses both foam and transparent highlights in the air or underwater. Side splashes retain the user's disabled state. No new foam reinforcement is enabled by this cleanup.

## Assets and installation

Splash 2/3/4 atlases are inside `textures/`. Original bow PNGs are inside `../bow_spray/sequences/Splash_1/`. Copy both `addons/ocean/` and `addons/jet_ski/`; external root-level Splash folders are only source material for rebuilding atlases and are not needed by the runtime.

The optional live review panel is called **Splash and Tail Jet**. No effect uses F8. The Inspector is the full authoring interface.
