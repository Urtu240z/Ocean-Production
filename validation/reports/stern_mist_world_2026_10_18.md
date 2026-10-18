# Editable world-space Stern Mist — 18 October 2026

The BowSprayRoot scene now contains a saved SternMist GPUParticles3D child. HullSprays reuses this authored node and preserves it during editor preview rebuilds. Older scenes without that node retain a generated fallback.

Authored defaults: 56 particles, 0.5 s lifetime, world coordinates, 0.3 m billboard quads. Native particle/material settings survive profile reconfiguration. The legacy profile still supplies color, opacity, emission offset and speed/preview controls; its Amount/Lifetime/Width/Length fields affect the generated fallback only.

Removed the moving shader envelope and the shared live-particle intensity gate. Stopping emission now lets previously emitted particles finish their lifetime. Increased internal noise detail and exposed Mist Texture as an optional grayscale/alpha mask.

Validation:

- `stern_mist_world_check.gd`: PASS on the Mobile Vulkan renderer. Moving a stopped emitter 8 m left live-particle image centroids at (321.16, 179.71) and (320.98, 179.75). Live particles remained visible and expired after the lifetime. Native particle edits survived configure.
- `hull_spray_editor_reload_check.gd`: PASS across three rebuilds; authored emitter identity, nozzle pose and profile values preserved. Removed a hard-coded roundness expectation so the test checks preservation of the actual saved preset.
- `stern_vfx_check.gd`: PASS, including rendered mist, tail rendering and dry/idle emission gates. This legacy fixture exercises the 28-particle generated fallback; the new world test exercises the authored node.
- `git diff --check`: PASS.

Visual tuning in Hull Wave Physics Playground remains the artist's next step. Commit, push and addon packaging follow that tuning, preserving the chosen Ocean and Jet Ski scene values.

## Native color-ramp authority follow-up

The authored emitter now also retains native Amount Ratio and shader tint/opacity/turbulence through profile updates. Color Ramp RGB/alpha reaches the spatial shader, replacing the hard-coded lifetime fade; the hard-coded growth curve was also removed. Shader defaults are neutral white/full opacity, with actual transparency provided by the particle ramp and texture masks. Existing saved and unsaved artist ramps/textures were not replaced. Legacy profile Amount supports up to 1,000.

Extended GPU test: PASS with 1,000 authored particles, unchanged ramp identity/endpoints, unchanged shader opacity and Amount Ratio after profile changes/step, and rendered transparent → visible white → transparent alpha states. World-space retention and particle expiry still pass.

## Continuous artist preset

Jet Ski 01 retains the artist's 700 particles, sphere emitter, placement, noise texture and ramp resource. Tuned Lifetime to 0.25 s, Amount Ratio to 1, Explosiveness/Randomness to 0, interpolation and fractional delta on, preserving Fixed FPS 0. Ramp stops now sit at 0/0.08/0.4/1; the first RGB is white with zero alpha to avoid a dark birth. Saved shader opacity is 0.2 and internal turbulence 0.7. Particle scale range is 0.8–1.8, turbulence strength 3, random noise speed 1.5 and influence 0.15–0.45.

Emission now follows forward speed and wet contact without a throttle requirement. GPU world test passes coasting, stationary and dry-contact gates. The dedicated continuity fixture loads the actual saved Jet Ski 01 emitter, moves it at 12 m/s and follows it with a camera. Saved-setting assertions and all 80 measured frames passed without blank emission frames. This checks rendering continuity in an isolated fixture; final appearance against Ocean water remains an artistic judgment in the playground.

## Wider, lighter mist with speed response

Latest artist preset: 1,000 particles, lifetime 0.35 s, sphere radius 0.55 m, ramp stops 0/0.25/0.45/1, base opacity 0.035, shader turbulence/breakup strength 0.35. Increasing overlap and softening spatial breakup targets visible particle births; the reduced base opacity compensates for accumulated transparency.

The shader's separate speed factor interpolates smoothly from 0.12 at 10 km/h to 0.9 at 60 km/h. The controller publishes filtered speed; it does not overwrite native particle ramps or authored material opacity. Surviving particles retain their last speed multiplier when the emitter stops.

GPU checks pass: actual saved preset, widened emitter, no blank steady-state frames, preserved authored opacity and world-space/ramp regressions. A frozen-particle comparison measured image energy 697.7 at 10 km/h versus 2853.5 at 60 km/h; both screenshots were inspected. This demonstrates the requested speed response, without claiming that every perceived birth is eliminated in the full playground.
