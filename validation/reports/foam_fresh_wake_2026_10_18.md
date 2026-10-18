# Fresh stern foam — 18 October 2026

At speed the freshly churned aft pigment now fills the strand holes with dense white, then settles into the existing configured filament wake. This is the same Ocean history and surface, not an attached overlay or a screen blur. Filament Deformation and Filament Speed need not be enabled. Existing artist settings are retained.

**Ocean → Hull Foam → Fresh Wake** contains Enabled (true), Strength (1.0) and Settling S (0.8 s). Speed Whitening's existing low/high km/h limits gate the phase; its strength is independent of High Speed White Strength. Stationary contact is unchanged. Strength zero/disabled restores the preceding pattern; once settled, the older wake recovers its exact former output. Settling S controls this brief white phase, not the overall wake lifetime. At higher speeds the same duration occupies more distance.

The existing speed companion becomes RG16F: R retains premultiplied emission speed; G carries premultiplied aft pigment times exp(-age). The shader decodes a smooth settling envelope with a short fully white onset. A local, exponential churn refreshes both speed and fresh pigment as a moving wet stern passes over previously deposited foam. This also avoids treating most of a swept high-speed segment as bow pigment. White coverage has a soft density threshold; fresh strands' normal/relief contrast is reduced and their finish is rougher. Original wave geometry, buoyancy, camera and spray are unchanged.

Allocation increases by **1 MiB** over the preceding speed-history version: total shared foam history is **6 MiB** for every vehicle count. Both channels share the existing sampler and compute passes. No new meshes, FFT, dispatch pass, per-pixel boat loop or gameplay readback is added. Restart the scene after shader import because the runtime texture format changes.

## Validation

- `foam_speed_history_check.gd`: real GPU deposits keep speed and freshness separate. Fresh pigment originates aft; it ages through transport and recentering while speed remains about 10 m/s. Final fast-pigment mean 10.0008 → 10.0013 m/s; normalized freshness 0.2526 → 0.05085. Bow fresh mass 0.00144 versus stern 3.134 at the first snapshot. PASS, empty stderr.
- `foam_relief_material_check.gd`: actual fragment with fixed history. Fresh whitening decreases smoothly at ages 0, 0.4 and 0.8 s; at the end it is byte-identical to the preceding filament output. Fresh phase on/off is byte-identical at rest. Existing blue/underwater relief and speed-intensity checks still pass. Filament motion is explicitly disabled for fresh-phase tests. PASS, empty stderr.
- `foam2d_ocean_authoring_check.gd`: all three new Ocean controls survive save/load, including disabled state; total 86 authoring controls. PASS, empty stderr.
- `foam2d_rebind_bindings_check.gd`: RG16F companion and history/wave samplers remain valid through wind changes, wave toggles and cached variants. PASS, 79 sampled stages, no runtime/shader errors. Fixture UID fallback warnings remain separate from shader validation.
- `foam_pattern_scene_check.gd --fresh-wake`: actual production Ocean, 1280×720 D3D12, wind 3 m/s, Patch Size 0.85, high-speed white strength 0.57, both filament-animation settings zero in a disposable resource. GPU readback verifies actual fast/fresh pigment exists before comparison. A rear review camera includes the stern; it does not modify the saved gameplay camera.

## Controlled draw comparison

An initial comparison exposed a harness error: the Production node explicitly uses PAUSABLE processing, so disabling the scene root did not stop the Ocean. Fresh pigment kept aging between shots. Those preliminary logs, including earlier pattern/relief frozen-view claims, are not usable as frozen-view comparisons.

The final harness freezes rigid bodies **and every descendant**, drains queued work, rebinds the final history snapshot and asserts an unchanged history-update count after the entire comparison. The same current material is toggled off/on/on/off, with 45 warm frames and 1.2-second sample windows for each state. The source preset is duplicated; readback happens before timing. This isolates drawing cost, not live transport or full driving performance. Final results are in `temp/fresh_wake/verified_scene_1.out` and `verified_scene_6.out`; captures are in `temp/wspeed/TestAddons/temp/fresh_wake/scene_1/` and `scene_6/`. Shader/material, history, authoring and wind logs live beside those final timing logs.

| Boats | GPU off / on | Render CPU off / on | Frame off / on |
|---|---|---|---|
| 1 | 4.529 / 4.530 ms | 0.769 / 0.780 ms | 4.747 / 4.758 ms |
| 6 | 4.541 / 4.535 ms | 0.827 / 0.822 ms | 4.759 / 4.763 ms |

Values average the two runs per state. There is no clear drawing regression above this short test's variation; this is not a claim of zero total runtime cost. GPU snapshots confirm 716/2701 fast-fresh pixels in the one/six-boat frozen views, respectively, and history remains unchanged through the comparisons. Final scene/material runs contain no runtime/shader errors. Saved source appearance and playground scene match their pre-task backups.

No artist preset, Jet Ski scene, splash appearance or physical-hull-wave playground edit was overwritten. No commit or push is part of this revision.
