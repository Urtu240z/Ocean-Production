# PHYS-GAMEPLAY-BASE-1

**PARTIAL — the direct query and actual driveable vehicle work, but the full Coastal workload exceeds the two-tick age budget.** Stale data is rejected, and the missing forces prevent claiming continuous acceptable gameplay support across every requested region. Final handling remains user acceptance. No next architecture was started.

## Native evidence (2026-10-05)

Godot 4.7.1, Forward+/D3D12, NVIDIA GTX 970, Intel i7-5820K; development render size 960×540. The primary proof completed **10,002 four-contact batches / 40,008 checked GPU contacts**, with **zero invalid contacts, zero coherence errors, zero inverse calls, zero root searches and zero fold failures**. Runtime water sampling uses the production GPU textures. The native CPU FFT/reference and existing weather adapter were used only by validation; the launchable gameplay scene has no CPU ocean mirror.

| Measurement | Mean | p95 | Maximum |
|---|---:|---:|---:|
| Four-contact GPU query | 0.1132 ms | 0.1231 ms | 0.1352 ms |
| CPU submit (query API) | 0.0272 ms | 0.0450 ms | 0.3030 ms |
| CPU consume (query API) | 0.0150 ms | 0.0260 ms | 0.2100 ms |
| Water publication age, all available results | 2.483 ticks | 5 ticks | 11 ticks |
| Usable water age | 1.934 ticks | 2 ticks | 2 ticks |
| Contact input age | 2.491 ticks | 5 ticks | 50 ticks |

API CPU timings exclude contact packing/decoding and force integration. They are not total gameplay-frame costs. The primary run recorded 3,182 unavailable water-force ticks; the historical fold-region Coastal phase had four usable contacts on only 566/900 ticks. GPU samples themselves remained valid. Input ages include deliberate pause and validation/weather preparation; these older packets are not usable. Final consumption conservatively requires **both field age and input-coordinate age to be 0–2**. The additional coordinate-age guard was checked by the final launch/reset/close smoke; primary force-case statistics below precede that extra rejection guard. The outstanding limitation is asynchronous completion age under the heavier rendering workload, not a folded-surface inversion failure.

| Reference state | Height maximum error | Vertical speed maximum error | Normal maximum error |
|---|---:|---:|---:|
| Current production, 2× clock | 0.0266 mm | 0.0750 mm/s | 0.0198° |
| Calm, 1× clock | 0.0018 mm | 0.0014 mm/s | 0.0198° |
| Normal, 1× clock | 0.0087 mm | 0.0090 mm/s | 0.0280° |
| Storm, 1× clock | 0.0217 mm | 0.0183 mm/s | 0.0280° |

All 64 reference contacts pass the 1 mm / 1 mm/s / 0.5° gates. Reference height and velocity are evaluated at the returned ocean time and direct material coordinate `q=worldXZ`; reference normals use independent CPU height differences. No comparison to an inverse/highest folded surface is used. Signed depth is explicitly `surfaceY-contactY`; dry/contact/landing behavior exercises its sign.

Calm Hs=0.15 m settling (600 ticks) gives mean body Y −0.0214 m, mean pitch +0.398°, roll −0.318°, and mean vertical speed −0.0343 m/s over the final 120 ticks. Mean contact depths are `[0.1440,0.1433,0.1571,0.1574]` m and mean support forces `[708.5,704.1,771.7,774.3]` N. Oscillations remain small around actual moving water, with no explosion, persistent sink or launch. Four support-only restoring tests finish as follows:

| Initial tilt | Final pitch | Final roll |
|---|---:|---:|
| Roll +10° | +0.459° | −0.543° |
| Roll −10° | +1.262° | −1.214° |
| Pitch +10° | −0.561° | +1.071° |
| Pitch −10° | +0.256° | +0.452° |

Normal Hs=1 m stationary waves produce differing contact depths and roll/pitch response. Low throttle (0.3) reaches 9.53 m/s; medium throttle (0.65) reaches 19.66 m/s. Left steering changes yaw from about −9° to +82° (wrapped representation); right steering returns it toward +13°. All four contacts are usable throughout the 420/600/360/360-tick low/medium/left/right phases. Medium throttle includes four fully sampled dry ticks, demonstrating natural departure. Storm Hs=3 m driving reaches 16.83 m/s, with at least 11 fully sampled dry ticks and finite reentry support.

A controlled actual-body drop from 3.6 m body-origin Y exercises at least 46 fully sampled dry ticks, gravity/air motion, landing and return to support. First observed wet force is 5,527.6 N per point and maximum is 9,276.4 N; the maximum observed force step is 5,527.6 N. The support law fades from zero at depth zero and uses forces, not landing impulses; these discrete force steps are reported rather than hidden. The body returns to a finite floating state. The aggregate `air_ticks` field also includes unavailable samples; the fully sampled dry counts here are conservative lower bounds, avoiding that ambiguity.

The existing normal-to-storm weather transition completes without rebuilding the ocean resource epoch. Shader headers and all three-band config checks show zero mismatches. Pause produces exactly zero ocean-time delta and zero body-position delta; resume returns to coherent sampling. Rigid-body linear/angular damping are both 0 in the scene, additive to project defaults of 0.1/0.1.

Primary shutdown retires the query with **zero owned buffers, zero in-flight callbacks, zero pending packets and zero completed-pending packets**; every dispatched batch has completed. The final plain-scene smoke additionally checks throttle, reset invalidation and the actual Escape/window-close drain path without a validation weather initializer. Startup correctly matches the producer's config generation 0 until runtime weather metadata exists. After reset it completes 191 batches, has age 2 and finite body position `(0.031858,-1.45313,0.01842)` in the moving current sea. Close reports zero buffers/in-flight/pending, retired=true, zero errors/mismatches and no leaked-RID warnings. This is recorded with the measurements.

**Visual ocean regression: YES, unchanged. Breaker lifecycle/geometry regression: YES, source unchanged.** The reused P0 scene retains all LONG/MID/SHORT and full visual horizontal choppiness, Coastal, breakers/Carrier, crest/surface foam, spindrift, optics/reflections/detail and underwater/waterline features. No visual shaders, profiles or scene values were edited. The FFT hook change only adds query publication tick and clock-rate metadata. Fixed-camera, frozen-field captures compare query velocity production off/on: mean RGB change about 0.118/255 and p95 1/255; this is a renderer sanity comparison, not a bit-exact temporal-effects certificate.

Information-only mismatch uses 16 representative contacts per state. It reports visual horizontal displacement and the direct-height proxy `|h(q+D.xz(q))-h(q)|`; it performs no inverse/root search:

| Sea | Horizontal displacement mean / max | Height proxy mean / max |
|---|---:|---:|
| Calm | 0.075 / 0.203 m | 0.0019 / 0.0168 m |
| Normal | 0.417 / 0.728 m | 0.0283 / 0.1154 m |
| Current production | 1.617 / 3.017 m | 0.2330 / 0.5352 m |
| Storm | 1.690 / 3.041 m | 0.1980 / 0.6103 m |

Evidence: `PHYS-GAMEPLAY-BASE-1-MEASUREMENTS.json`, `PHYS-GAMEPLAY-BASE-1-visual-before.png`, `PHYS-GAMEPLAY-BASE-1-visual-after.png`, and `PHYS-GAMEPLAY-BASE-1-drive-final.png`. The measurement file is compact distributions and phase summaries, not a full temporal/root corpus. The validation runner returns nonzero for the documented age-budget failure. **PASS is withheld until the remaining completion-age/force-availability issue is acceptable in the full requested workload.**

## Launch and manual acceptance

Open `gameplay/jet_ski_ocean.tscn` in Godot 4.7.1 and run that scene (F6), or use:

```powershell
& 'C:/Users/Eric/Desktop/Godot_v4.7.1-stable_win64_console.exe' --path 'C:/Users/Eric/Desktop/Ocean-Production' --log-file .godot/gameplay_manual.log res://gameplay/jet_ski_ocean.tscn
```

The development window defaults to 960×540. W/S apply throttle/reverse, A/D steer, F3 toggles contacts, P pauses/resumes, R resets, and Escape/window close drains query resources before exiting. Arrow keys retain the vehicle's rider shift controls. Debug crosses mark actual contacts, green/orange indicate wet/dry, vertical lines reach the physical heightfield, and cyan lines show support forces. The HUD shows water-field age and whether coherent samples are available.

Manual handling quality remains **USER VISUAL/DRIVING ACCEPTANCE**. Automated execution, response and finite force checks do not certify final feel. Judge stationary float, low/medium throttle, left/right turns, travelling over several waves, crest departure, air time and landing. Horizontal visual/physical mismatch is deliberately accepted for this phase.

Tune mass/COM/markers/propulsion and existing drag/steering in `gameplay/vehicles/jet_ski_01/jet_ski_01.tscn` and its controller. The four-point water system exports `equilibrium_depth` (0.15 m) and `damping_ratio` (0.9); these drive support. Legacy controller buoyancy strength/deep-force fields do not set the new heightfield spring. Scene exports control debug, development window size and metric capture. The instantiated Production/Ocean retains its original authoring values and feature gates. Configure authoring changes before launch.

## Contract and integration

`PHYSICAL_HEIGHTFIELD` is explicit production query mode 5, with world XYZ input and `q = worldXZ`. Physical horizontal displacement is zero. It returns before inverse mapping, persistent ownership and root/envelope code. One ski submits one 128-byte four-contact packet and receives a coherent 384-byte rich result. Existing batch capacity remains available; no fleet work was added.

Height samples authoritative LONG+MID+SHORT displacement Y, sea level, and the existing Coastal LONG warp/confidence/one-cell edge feather/shoaling treatment at the supplied world XZ. The physical normal is `normalize((-dh/dx, 1, -dh/dz))`, using ±1 cm differences of that same height sampler. Vertical speed uses the authoritative spectral/weather derivative multiplied by the ocean clock rate. Horizontal orbital velocity is not supplied. Signed depth is surface Y minus contact Y, positive when wet.

Global RenderingDevice dispatch follows the authoritative FFT publication. Three bounded slots use `buffer_get_data_async`; there is no `rd.sync`, blocking `buffer_get_data`, local rendering device, runtime CPU FFT mirror or inverse query. CPU completion publication uses the mutex; GPU RID destruction stays on the render thread. Packet headers carry ocean time, field publication tick, ocean epoch, config generation and query generation.

The consumer retains the latest coherent completion. Water age is measured from the recorded authoritative publication tick, and input-coordinate age is reported separately. Both ages must be 0–2 to be usable. Missing, mismatched or older data skips water/thrust forces. No prediction or fabricated surface is applied. Depth for forces uses cached sampled Y minus the current contact Y; force position and contact velocity use the current rigid-body state. Reset clears cached contacts and rejects older in-flight generations.

The actual Water-Race jet ski was ported with its hull/handle models, convex collision hull, four markers, controller, input, drive, navigation, rider/handling and supporting states. Source was read from the sibling working tree; its HEAD was `09051c918450740e2590daae8e8521b365cdefdb`. Vehicle audio and its separate Water-Race spray effects were omitted from this development scene. Production ocean foam/spindrift/breakers remain in the reused P0 scene. Submarine and trick preload are disabled for this first drive.

## Vehicle audit and support

Before changes, the scene has mass 300 kg, custom COM `(0,-0.22,0)`, front markers `(-0.45,-0.15,-1.15)` / `(0.45,-0.15,-1.15)`, rear markers `(-0.50,-0.15,1.05)` / `(0.50,-0.15,1.05)`, and PropulsionPoint `(0,-0.18,1.25)`. Collision geometry and model transforms were retained. The marker Y supports a 0.15 m equilibrium depth around body-origin sea level.

Original support used 5500 N/m per point, 2500 N·s/m damping, 0.8 m depth clamp, additional deep support and sampled-normal force direction. Existing per-point forward drag is 15 linear / 1.5 quadratic, lateral drag 80 / 7, depth exponent 1, and force limits 3500 / 7000 N. Existing propulsion uses 4200 N forward / 1800 N reverse, full immersion at 0.3 m, forward falloff 18–28 m/s and reverse 5–9 m/s. Steering is ±12°, with existing speed reduction and coasting steering. These drag/input/drive mechanisms were retained. Rear-contact surface/normal/vertical-speed averages gate the actual propulsion point, requiring no fifth query.

Support derives each point's effective mass from the actual runtime rigid body: `m_eff=m/4`, `k=m*|gravity|/(4*equilibrium_depth)`, `c=2*zeta*sqrt(k*m_eff)`. At 300 kg, gravity 9.8 m/s², depth 0.15 m and zeta 0.9: **k=4900 N/m**, **c≈1091.2 N·s/m per point**. Relative damping speed is contact-point vertical speed minus sampled surface vertical speed. Damping fades continuously from zero at water entry to full strength at equilibrium depth. Negative support clamps to zero; dry points have no support. Finite checks report invalid forces.

Each support force points opposite gravity and uses `PhysicsDirectBodyState3D.apply_force(force, world_offset)` at the actual marker. The engine supplies the off-centre moment; the buoyancy system adds no torque separately. Normal gravity and rigid-body dynamics continue in air. Existing tangential submerged drag remains provisional. Restoring-tilt validation disables the existing turn-lean helper, isolating the four support points; ordinary driving restores that helper.

## Scope and preserved roadmap

The starting remote GPU baseline was verified as `98928f170aa53023c83215376c85990d9cf8a2b4`; the worktree was clean and `git diff --check` passed before creating `wip/phys-gameplay-base-1` from `origin/wip/phys-gpu-1`.

Preserve the independent R&D branches: `wip/phys-gpu-1` at `98928f170aa53023c83215376c85990d9cf8a2b4`, `wip/phys-gpu-envelope-1` at `a2f3da697cf73101a11989d140a6ef210603532d`, and `wip/phys-gpu-surface-contract-1` at `6c9b037ff5029feb8829b6d238d300e4bbe8af0a`. Master remains `fe6df4d4ce8dcafe05d176f1f312eaa4c9332dbf`. No master merge or next architecture was started.

Pending roadmap, documentation only:

1. `spindrift_h1_contract_runtime.gd`: Crest G clamp `[0,1]` discrepancy.
2. Revalidate P3D.1 travelling after TIME-1 with a fully initialized Ocean/Carrier.
3. Revalidate P3E handoff after TIME-1 with the fully initialized scene.
4. Later decide whether TIME-1 instrumentation in `gpu_stockham_fft.gd` is removed, moved or retained.

No safe-chop search, atlas/envelope, raycast/raymarch research, fleet reduction, prediction, full breaker physics or PHYS-4 was started. The 281-case research corpus was not expanded or reanalysed.

## Delivery files and commits

The production changes are limited to `addons/ocean/fft/open_ocean_fft.gd`, `addons/ocean/physics/gpu/ocean_surface_query.gd` and `addons/ocean/physics/gpu/ocean_surface_query.glsl`. The new `gameplay/` tree contains the real jet ski port, GPU water provider, launchable scene and debug display. `project.godot` and the production visual shaders, scenes and profiles are unchanged.

Validation artifacts are `PHYS-GAMEPLAY-BASE-1-MEASUREMENTS.json`, this report, `phys_gameplay_base_runner.gd`, `phys_gameplay_smoke_runner.gd`, and the three `PHYS-GAMEPLAY-BASE-1-*.png` screenshots in `validation/physics/`, with their import metadata. The measurements distinguish the primary force run from the final consumer-policy launch/reset/close smoke. The before/after images document the unchanged visual path; the drive image shows the imported vehicle in the production ocean.

Delivery commits on `wip/phys-gameplay-base-1`:

1. `42e2851` — Add single-valued gameplay ocean physics.
2. `534329a` — Drive jet ski from four GPU buoyancy contacts.
3. The commit containing this report — Validate first gameplay buoyancy path.

The delivery target is only `origin/wip/phys-gameplay-base-1`. Final verification requires its remote tip to equal local HEAD, a clean worktree, and the protected branch tips listed above to remain unchanged. The result is **PARTIAL**; further latency work and architecture changes are outside this delivery.
