# Foam pattern, white tint relief and speed whitening — 18 October 2026

The Ocean material now uses continuous warped texture coordinates with two differently rotated/scaled crest-texture layers. This replaces random triangular patch identities, reducing cell-related changes while strands deform. Smooth phase weights blend transported detail. Independent broad noise pockets add irregular filled areas between thin filaments; Patch Size can be reduced to 0.85 without also shrinking these broad pockets. This is irregular procedural variation, not a claim that finite textures can never repeat at any distance.

Ocean → Hull Foam → Generation and Irregularity gains **White Patch Strength** (0.65) and **White Patch Size M** (1.8 m). All saved artist values, including existing Patch Size, are retained. Defaults do not overwrite an existing resource.

The previous relief mask only followed agitation-white and optional Running Foam. With Water Tint set to white, much of the visible white was outside that mask. White-tinted pigment now follows the strand/pocket mask, receives relief and respects speed whitening. Blue tint retains its earlier response. Relief normal weighting is stronger at partial white coverage. The result is apparent surface relief; it does not raise the mesh or change the silhouette, waterline, waves, buoyancy, spray or camera.

Ocean → Hull Foam → Speed Whitening gains:

- **Low Speed White Strength**: 0.30, a multiplier of white intensity at rest/low speed.
- **High Speed White Strength**: 1.0, the high-speed multiplier.
- **White Low Speed Kmh**: 5 km/h, end of the low-speed plateau.
- **White High Speed Kmh**: 35 km/h, start of the high-speed plateau.

Smooth interpolation connects the plateaus. A safe 0.1 km/h minimum threshold interval prevents reversed/equal bounds from creating undefined shader behavior. Both strengths at one bypass the speed sample and restore the former intensity scaling. White tint participates as well; blue filaments and existing agitation/impact logic remain independent. Optional Running Foam retains its own controls.

Birth speed is deposited per stamp, coverage-premultiplied in an R16F companion to the existing shared GPU history. It uses the same localized stamp/transport dispatches and backtraced coordinates. Speed survives fade, advection and recentering. Stopping one boat cannot dim its old wake or another boat's foam. The two 512² R16F textures add exactly 1 MiB, bringing history allocation from 4 to 5 MiB regardless of vehicle count. There are no new meshes, wave simulations, CPU readbacks or per-pixel vehicle loops. Where speed gains differ, shading samples the scalar carrier once; the strand sampler uses two rather than three crest-texture reads per phase.

## Validation

- `foam_speed_history_check.gd`: actual GPU stamps for 0 and 10 m/s remain separate after transport/fade/recentering while only the stopped hull keeps emitting. Fast-pigment mean: 10.0028 → 10.0042 m/s; max active-pixel error below 0.05 m/s. Allocation 5,242,880 bytes; companion publication cleared at shutdown. PASS, empty stderr.
- `foam2d_history_contract.gd`: hull-centered birth, reverse footprint, all wet quadrants, outward transport, fan width, lifetime and initial-width checks still pass. Test now creates its own output directory in a clean fixture. PASS, empty stderr.
- `foam2d_ocean_authoring_check.gd`: six relief settings, four speed settings and two pocket settings forward through Ocean and survive scene save/load; independent resources and disabled states retained. PASS, empty stderr.
- `foam_relief_material_check.gd`: actual projected fragment rendered on a fixed test surface. Relief changes lit white, white tint and normal output; blue/underwater off/on difference remains exactly zero. White-tint speed control also changes output. At Patch Size 0.85, maximum deformation/speed evolves the strands over time; zero internal speed yields byte-identical frames with transport disabled. PASS, empty stderr.
- `foam2d_rebind_bindings_check.gd`: speed/history/wave samplers remain valid through repeated 35→3→35→3→35→3→0 m/s changes, wave toggles and drawing cached material variants. Ocean relief checkbox updates each variant. Initial run passed 80 sampled stages; final rerun includes the checkbox assertions. Fixture resource UID fallbacks are warnings, not shader/runtime errors.

## Rendering cost

**Correction:** the preliminary timings in this section are withdrawn as a frozen-view comparison. The Production child explicitly uses PAUSABLE processing, which overrides a disabled root. Freezing rigid bodies alone still allowed the Ocean/pigment to advance. The current harness disables every descendant and asserts that history update count stays unchanged. See `foam_fresh_wake_2026_10_18.md` for the new controlled Fresh Wake comparison; do not use the old table below to assess a rendering regression or speedup.

`foam_pattern_scene_check.gd` compares the preceding shader against this revision on the **same frozen production scene**, with rigid bodies explicitly frozen as well as processing disabled. One and six vehicles; 1280×720 D3D12; wind 3 m/s; Patch Size 0.85; saved artist style duplicated only in memory. Speed gains equal one in this comparison, isolating the pattern/relief material revision. Both sides share the new speed history allocation. Order before/after/after/before, 45 warm frames and 1.2 s windows. This is a draw-cost comparison, not a driving benchmark of the new scalar transport.

| Boats | GPU before / after | Render CPU before / after | Frame before / after |
|---|---|---|---|
| 1 | 4.294 / 4.286 ms | 0.786 / 0.781 ms | 6.786 / 6.891 ms |
| 6 | 4.166 / 3.971 ms | 0.787 / 0.772 ms | 6.541 / 6.261 ms |

These short samples show no clear draw-cost regression; they do not establish a speedup, total driving cost, RAM growth over long runs or 12-vehicle performance. The authoritative logs for these samples are `temp/wspeed/final_scene_1.out` and `final_scene_6.out`; later close-up capture runs may overwrite fixture PNGs/reports. Screenshots of the actual Ocean, close-ups and the isolated material fixture are under `temp/wspeed/TestAddons/temp/foam_pattern/` and `temp/foam_relief/material/` inside that fixture. The close-up uses 0.18 m puff detail in a disposable runtime to make the small-scale response easier to inspect.

No source preset, Jet Ski scene, splash appearance or physical-hull-wave playground artist edit was overwritten. This revision remains local for visual review.
