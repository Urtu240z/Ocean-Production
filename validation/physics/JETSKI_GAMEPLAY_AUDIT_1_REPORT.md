# JETSKI-GAMEPLAY-AUDIT-1 — Excessive Hops and Apparent Waterline Mismatch

## Completed reproduction — 2026-10-12

The prior section below records the blocked attempt. This completed run supersedes its “evidence insufficient” diagnosis. The scene started successfully after the foam fix; no foam or wake source was edited for this audit. The gameplay audit script check passed, and the editor error buffer after the capture contained zero errors.

### Configuration and startup comparison

- Wind 12 m/s; wave speed 1.0; `PHYSICS_ALIGNED + DIRECT`; SOFTER K = 4250 N/m/contact and C = 1698.2 N·s/m/contact; normal influence 0.50; FEEL-5 anti-hop off.
- Fresh-start 12/1 initialization and Remote-style property updates produced identical CPU Lite H0 hashes: LONG 2419220705, MID 4209287694, SHORT 2530801071. Fresh initialization had generation 1 / refresh count 0; the runtime update had generation 2 / refresh count 1. Both had wave-time rate 1.0. This confirms CPU spectrum equivalence; a GPU visual H0 hash was not captured.
- The throttle input was held for 30 seconds. The capture collected 2,502 physics rows over 45.79 seconds because the runtime call continued after the input window; it recorded 32 airborne transitions. Mean observed FPS was 329 and physics processing averaged 2.688 ms. The input was released and capture ended.

### Water alignment and rendered hull

Across 10,008 paired contact samples, the visual-equivalent CPU water Y and DIRECT physical water Y at identical XZ/time differed by 2.28 cm mean absolute error, 6.70 cm p95, and 19.59 cm maximum. These are query-surface comparisons, not GPU texture readback.

The five sampled bottom vertices of the actual rendered hull mesh were paired with water at 2,135 sample instants. Signed hull-Y minus DIRECT-water-Y was +0.418 m mean, +3.035 m p95, and +5.329 m maximum. Against visual-equivalent water the corresponding figures were +0.434 m, +3.052 m, and +5.338 m. Positive values mean the sampled mesh vertices were above the water. These measurements do not use the submerged buoyancy markers as a proxy for hull penetration; they also do not cover every point on the mesh continuously. The minimum signed clearance and fraction of samples below water were not retained, so the measurements cannot quantify deepest penetration or submerged-time percentage.

### Takeoff diagnosis from preceding 250 ms

The attached CSV records each of the 32 takeoff windows at 20 ms intervals and each of four contacts. Using a declared “unwanted takeoff” threshold of airtime ≥ 0.25 s and clearance ≥ 0.5 m, 18 events qualify. Across those windows:

- Upward spring impulse averaged 1,505 N·s (median 1,464; p95 2,468); mean peak spring force was 8.70 kN.
- Positive water-relative damping impulse averaged 476 N·s, while signed damping impulse averaged −1,194 N·s. The large damping peaks therefore mostly oppose upward motion rather than cause it.
- 14 of 18 events included contact water moving downward faster than 0.5 m/s; 90 sampled rows had contact/support loss. Six events exceeded 20° absolute pitch and one exceeded 20° absolute roll.
- The largest event reached 5.682 m clearance after 1.583 s airborne. Its preceding window contained 2,468 N·s spring impulse, 1,086 N·s positive damping impulse, and a 140.48 m/s² peak upward vertical acceleration; water vertical velocity reached −2.02 m/s.

**Dominant cause:** upward spring impulse is the largest measured upward contribution, about 3.2× the positive damping impulse on average. Contact separation over a falling wave face is a common amplifier (14/18 events and frequent support loss). Water-relative damping is not the dominant upward cause; its signed net impulse is downward. Pitch/contact geometry contributes in a subset, but cannot explain the majority by itself. No physics was tuned.

**One minimal corrective change to evaluate next:** lower the SOFTER per-contact spring stiffness K from 4250 N/m while holding damping and all other settings fixed, then repeat the same phase-locked trace. This directly tests the measured dominant upward impulse without adding a velocity clamp or changing wake behavior. No change was applied in this audit.

Full per-contact windows: [JETSKI_GAMEPLAY_AUDIT_1_TAKEOFF_WINDOWS.csv](JETSKI_GAMEPLAY_AUDIT_1_TAKEOFF_WINDOWS.csv).

## Prior blocked attempt (superseded)

The following section documents the earlier incomplete run and its historical measurements; its “What remains unmeasured” list is no longer current for the items reported above.

## Primary diagnosis: E — evidence insufficient for the current 30-second drive

The requested hot-update path was exercised and the CPU Lite spectrum refreshed to 12 m/s. The scene then failed to start after a restart needed to load the diagnostic capture code. A pre-existing parse error in the uncommitted interaction-foam script prevented the runtime bridge from reconnecting, so the current 12 m/s / 1.0 scene could not be driven for the requested 30-second trace or compared against a fresh 12/1 initialization. No physics or ocean tuning was changed.

## Remote-property reproduction

The normal gameplay scene started with the `Production/Ocean` exported properties at wind 40 m/s and wave-speed multiplier 2.0. I changed `wind_speed_mps` to 12 and `wave_speed_multiplier` to 1.0 on that same Ocean node through its exported property setters (`Object.set`, the setter path used by the Remote Inspector). The wind setter requested its normal debounced ocean rebuild; the speed setter forwarded the multiplier to the live FFT.

At a check about five seconds later:

- Ocean authoring values were 12 m/s and 1.0.
- CPU Lite was field-ready, had `wave_time_rate = 1.0`, `physics_min_wavelength_m = 1.0`, zero invalid samples, and zero field-update failures.
- CPU-imported H0 bands all reported wind 12 m/s and 1,048,576 bytes each: LONG hash 2419220705, MID 4209287694, SHORT 2530801071.
- The provider reported spectrum sync generation 3 and refresh count 2. The imported H0 matched the requested wind, but the two refreshes were more than the single rebuild anticipated by the prior audit; without a live visual snapshot after the failed restart, I cannot determine whether that represents duplicate replacement or provider reconfiguration.
- CPU physics field time was 434.783356 s at the check. A same-instant visual FFT clock read was not obtained.

The prior 40 m/s H0 hashes for comparison are LONG 2770334873, MID 1709276678, SHORT 1122654252. They differ from the 12 m/s hashes, confirming that CPU Lite did not keep using the old wind spectrum after this hot change. The live visual H0 hashes were not independently read in this run.

## Contact snapshot after the hot update

One physics-system snapshot at 12/1 had the following hull-contact Y minus DIRECT `GAMEPLAY_SURFACE` Y values:

| Contact | Hull Y (m) | DIRECT water Y (m) | Hull minus DIRECT (m) |
|---|---:|---:|---:|
| FL | -0.319 | -0.154 | -0.165 |
| FR | -0.387 | -0.231 | -0.157 |
| RL | -0.567 | -0.399 | -0.169 |
| RR | -0.643 | -0.440 | -0.203 |

At that instant, the sampled hull points were about 16–20 cm below the physical query surface. This single frame does not establish how the rendered surface compared or explain the reported above-water appearance.

The active force configuration remained K = 4250 N/m per point, C = 1698.2 N·s/m, normal influence = 0.50, torque scale = 1.0, wet angular damping = pitch/yaw/roll 20/15/80. FEEL-5 anti-hop remained disabled. No RAW/SOFTER comparison was made.

## Prior measurements — context only, not a substitute for this reproduction

The earlier [PHYS-WATERLINE-AUDIT-1 report](PHYS_WATERLINE_AUDIT_1_REPORT.md) recorded a 12 m/s static-grid DIRECT-versus-LocalSurface absolute error of mean 16.0 cm, p95 34.7 cm, max 65.7 cm, and one four-contact snapshot with signed gameplay-minus-visible errors of +41, +46, +93, and +95 cm. That report also recorded a different static-grid case with p95 100.4 cm and max 115.8 cm.

The later [PHYS-WATERLINE-5 report](PHYS_WATERLINE_5_REPORT.md) used physics-authoritative interpolated time and reported, at wave speed 1.0, moving-contact spatial error of mean 2.48 cm, p95 8.65 cm, max 9.74 cm. It explicitly notes this is a CPU Lite versus LocalSurface reference, not a GPU texture readback, and it did not use a deterministic throttle replay. The historical measurements therefore use different captures and methods and cannot be combined into one current mean/p95/max.

The earlier FEEL-5 matched A/B runs produced roughly 17–20 airborne events per 30 seconds, around 35–45% time airborne, and mixed short-hop/large-jump changes. The anti-hop candidate failed its acceptance criteria and remains off. Those runs do not isolate spring versus water-relative damping for the user’s present drive scenario.

## What remains unmeasured

- Fresh initialization at 12 m/s and 1.0 versus the hot update.
- Current live visual FFT H0 hashes, visual wave time, and visual/CPU parameter values several seconds after rebuild.
- A 30-second actual-drive trace at the requested settings, including current DIRECT-versus-visual error mean/p95/max and signed hull clearance mean/p95/max.
- Current airborne-transition count, airtime distribution, percent airborne, and maximum clearance.
- Per-transition preceding 250 ms of hull/water velocities and acceleration, per-contact spring/damping/final forces, saturation, attitude, and wet contacts.
- Clearance of the actual rendered hull bottom/collision geometry relative to the water; the snapshot only covers the four buoyancy contact points.

The attempted restart could not compile because the existing uncommitted `addons/ocean/surface/ocean_interaction_foam.gd` reports `Expected indented block after "for" block` at line 217. That script is outside this audit’s physics/ocean scope, so I left it untouched. The resulting `open_ocean_fft.gd` parse errors were downstream of that unresolved script. The gameplay scene is open in the editor but is not running.

## One minimal recommended next change

Repair the indentation error in `addons/ocean/surface/ocean_interaction_foam.gd:217`, then rerun this audit unchanged. Do not tune buoyancy or add another anti-hop system until the matched 30-second trace and force decomposition are available.

## Files changed in this audit

- `gameplay/jet_ski_ocean.gd` — added opt-in debug capture for contact heights, force decomposition, clearance, and takeoff windows; disabled by default and does not set physics diagnostics that affect takeoff classification.
- `validation/physics/JETSKI_GAMEPLAY_AUDIT_1_REPORT.md` — this report.

No commit was created. The worktree was preserved; the existing interaction-foam compile error was not modified.
