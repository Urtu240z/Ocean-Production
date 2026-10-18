# Hull foam wave drift — 2026-10-18

Implemented locally in the existing Ocean foam history. Deposited pigment, birth speed and freshness are backtraced together using horizontal changes in the three existing FFT displacement maps. Premultiplied material offsets carry strands, broad pockets and relief with the pigment. Existing crest foam gently adds agitation only where hull foam already exists. This is visual transport; FFT, physical queries, buoyancy and driving are unchanged.

## Authoring

**Ocean → Hull Foam → Wave Drift** exposes Enabled, Strength (0.85), Max Speed Mps (2), Detail Strength (1) and Crest Mix (0.25), with Spanish tooltips. It works with Filament Deformation/Speed at zero. Motion Strength remains an independent procedural current. Restart the scene after updating the GPU history layout. Saved artist resources were not edited by this change; tests duplicate their settings in an isolated fixture.

## Measured cost

Local Windows, Godot 4.7.1, 1280×720, wind 18 m/s, saved foam update rate 60 Hz, no frame cap during timed intervals. Order **off/on/on/off**, 1.5 s settling then 4 s sampling per state. Each entry averages the two interval means. Both states include the same new auxiliary allocation; this comparison measures enabling drift, not removing the feature's allocation.

| Boats | Drift | Frame ms | Viewport GPU ms | Process CPU ms | Physics CPU ms | Foam contact CPU ms | Foam passes GPU ms/update |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | Off | 15.734 | 12.106 | 21.663 | 4.335 | 0.426 | 0.02472 |
| 1 | On | 12.506 | 9.041 | 20.296 | 4.253 | 0.400 | 0.03755 |
| 6 | Off | 18.257 | 9.786 | 19.271 | 12.134 | 0.706 | 0.02799 |
| 6 | On | 20.122 | 11.125 | 24.805 | 11.001 | 0.728 | 0.03996 |

The isolated history-pass increment is **0.01283 ms/update with one boat and 0.01197 ms/update with six**. At 60 updates/s these correspond to about 0.77/0.72 ms of GPU work per second, not that amount per frame. No extra transport dispatch or CPU water sampling was added. Timestamp resolution and short runs limit precision.

Whole-scene timing is noisy: moving boats change the view, wave phase, contacts and visible effects. Process/physics monitors report different portions of engine work and are not additive wall-frame times. The off/on frame differences above are not a controlled estimate of feature cost or an FPS guarantee. Six boats can separate beyond the existing camera-centred 128 m history: clipped stamps rose from 127/2013 submitted at the first interval to 1813/5147 at the last. This is the pre-existing history extent, not an additional drift limit; the six-boat run is not a worst-case all-visible stamping benchmark.

A separate identical frozen-view ABBA comparison isolates material rendering, with all world processing stopped and the same pigment field, FFT phase, lighting and camera in each state:

| Boats in fixture | GPU off/on ms | Render CPU off/on ms | Wall frame off/on ms |
|---|---:|---:|---:|
| 1 | 2.307 / 2.332 | 0.608 / 0.622 | 3.514 / 4.306 |
| 6 | 2.428 / 2.369 | 0.624 / 0.565 | 3.798 / 3.566 |

The material adds one texture sample where projected foam is evaluated and Detail Strength is nonzero. These short measurements show a small/noisy material delta, including a negative six-boat delta, so no reliable total frame penalty is claimed.

History allocation is fixed at **10 MiB**, up from 6 MiB: **+4 MiB shared**, independent of boat count, allocated even with Wave Drift off. New auxiliary textures are released on shutdown. Engine static-memory growth during each 4 s live interval was 9–97 KiB off / 50–68 KiB on with one boat and 33–108 KiB off / 2–31 KiB on with six. These include measurement-array allocation; they are neither process RSS nor a long-duration leak test.

## Correctness and visual evidence

- `foam_wave_drift_check.gd`: real GPU analytic transport PASS. Expected displacement (1.0, 0.4) m; measured pigment centroid delta (0.925, 0.352) m and transported detail offset (1.010, 0.405) m. Birth speed remains 10.00 m/s, freshness follows age, and crest agitation increases smoothly. Recentring, source-generation changes, retired source textures and shutdown pass without invalid bindings or jumps.
- `foam_wave_drift_scene.gd`: one- and six-boat visual replay PASS. New emission is stopped while V1 contacts keep the real wave clock advancing. Mean material displacement after approximately 3 s is **0.260 m / 0.207 m**; maximum adjacent offset difference is 0.026 m / 0.072 m. Final off/on captures share initial pigment and final FFT/lighting/camera. Filament Deformation/Speed are zero in the test.
- `foam2d_ocean_authoring_check.gd`: PASS, 91 controls, scene save/load and independent Ocean resources.
- `foam2d_rebind_bindings_check.gd`: PASS, 80 material inspections, wind 35→3 and other wind changes, all prepared variants actually drawn, disabled-effect samplers remain valid, no render/script errors.
- `foam_speed_history_check.gd` and `foam2d_history_contract.gd`: PASS, existing speed attribution, hull-origin birth, reversal and outward transport retained.
- `git diff --check`: PASS.

Visual captures are local test artifacts under `temp/wspeed/TestAddons/temp/wave_drift/boats_1/` and `boats_6/`: `before.png`, `after.png`, `top.png`, `mask_before.png`, `mask_after.png`, and `moving_00.png` through `moving_05.png`. Logs are under `temp/wave_drift/`: `analytic_dense`, `authoring`, `flow_visual`, `six_final`, `rebind`, and the two history regressions. One-boat live measurements are archived in `live_1.json`; final six-boat measurements and frozen-view data are in the fixture's `boats_6/report.json`. Earlier failed test-fixture experiments are excluded: frozen V1 contacts froze the FFT clock, and clone cameras initially left the history centred at the origin. Both fixture issues were corrected before the reported visual checks.

Packaging produced source archives and fixtures but its broad dependency audit flags the unrelated coastal-baker output directory literal `res://coastal_bakes` as missing. Packaging is not marked fully validated; no coastal authoring changes were made for this feature. The isolated runtime fixture also logs existing invalid-UID text-path fallback warnings for terrain assets; no script/render errors occurred in the successful checks.

## Limits

This approximates surface transport from open-ocean FFT horizontal motion, not a fluid simulation or crest phase-speed translation. Coastal phase-warp/refraction transport is not included. Repeated bilinear transport at 0.25 m cells can soften thin foam; speed caps and source-reset handling prevent large impulses but do not make the scheme mass conserving. Crest Mix modulates agitation rather than merging two foam simulations into one. Long-duration memory behaviour and broader hardware performance remain unmeasured. Validation was completed before the user's approval to commit and push this iteration.
