# Two curved hull-side mist emitters — 18 October 2026

The existing SternMist node now supplies the left side, with a second saved SternMistRight node. Budget is split 500/500, retaining 1,000 total. Both use independent process and draw materials. Original artist opacity (0.01), relief strength (2), specular (~0.674), textures and ramp remain in the saved Jet Ski preset. Lifetime changes from 0.1 to 0.65 s so particles can traverse the whole hull.

A dedicated GPU particle process shader guides particles around rounded front/middle/stern widths (0.3/0.68/0.49 m) from front Z -2.95 to stern Z 0 relative to the water/nozzle anchor. The first 68% of life follows the hull; the remaining portion detaches into a straight world-space tail with a stored release heading. Gentle swirl tapers to zero at release. Stops/jumps release particles at their current positions. No extra water queries or CPU particle simulation are introduced.

Both emitters are wired to runtime wetness/speed gates and editor preview. Original ParticleProcessMaterial is retained as metadata for reverting the primary emitter. Guided path/color/scale controls are exposed on each Process Material Shader Parameters; native Amount/Lifetime and draw materials remain editable. The original artist ramp is initially shared; make it unique for independent ramp edits.

Validation:

- Actual saved GPU scene: both curved contours render, mirrored sides, independent materials, correct 500/500 counts and lifetime; existing particles remain visible when stopped and emitters move 20 m; particles expire. Diagnostic contours were visually inspected with temporary contrasting colors and increased opacity, without saving those test overrides.
- Speed-opacity continuity fixture: passes on the guided left emitter and preserves the actual artist opacity.
- Original native/free-mist GPU contract: passes using the retained ParticleProcessMaterial fixture, including 1,000 particles, ramp alpha and coasting gates.
- Editor preview reload fixture: both authored emitters preserve their identities and emit through three helper rebuilds. Fixed headless shader-default reflection returning null for unassigned path parameters.

Final appearance around the moving Jet Ski in the playground still needs the artist's assessment. Commit/push/export remain after the visual tuning stage.

## Central merge and a metric common tail

The latest path keeps the hull side widths, then merges into the center over 0.25 m behind the stern and continues along a common 1 m straight segment. Tail Length M now controls distance directly; Lifetime sets traversal timing. Guided Fraction is 0.95 to avoid spending a large portion of life dwelling at the route end. Surviving particles detach at the end with measured world hull velocity; dry stops release them in place. Release state uses CUSTOM.z and VELOCITY. The controller explicitly synchronizes native lifetime to the path shader.

Extended GPU test passes central-tail rendering, a spatial comparison between 0.2 m and 1 m tails, and the same 1 m route with native Lifetime 1 s. Diagnostic mesh size/colors/opacity are fixture-only. Native saved particle counts, opacity and color ramp remain untouched. The earlier free-flight calculation did not provide a reliable metric visible tail, so convergence and the shared metre are now part of the guided route itself.
