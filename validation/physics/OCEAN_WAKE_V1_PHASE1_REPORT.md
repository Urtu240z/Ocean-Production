# Ocean Wake V1 — Phase 1 Refinement Report

## Status

Phase 1 is still **not accepted**. This refinement removes the baked-in V and separates wake energy from the visible foam response, but the final normal-camera capture does not show a consistently readable, naturally broken wake across the full test range. Keep deformation out of scope until the visual gate is approved. No deformation, wake heightfield, geometry displacement, or new wave simulation was added.

## Audit findings

- **A — Stamp shape: confirmed as the source of the diagonal arms.** The old `stamp_shape()` explicitly drew a center band and two side bands whose separation grew with distance. That was a ready-made V.
- **B — Stamp placement: not the source of the V.** Jetski stamps were interpolated along its supported, water-relative motion path. Placement provides continuity and curved history.
- **C — Directional blur/spread: not the source of the V.** No directional blur existed. The refinement adds a small, isotropic diffusion step so the energy field can widen gradually; it does not draw side arms.
- **D — Final shading: modifies the appearance, but did not create the V.** The former surface breakup and albedo/roughness blend could soften or strengthen the stamped bands. They could not create their diverging geometry.
- **Instant solid appearance: confirmed in the old accumulation.** Each update used `max(previous * decay, stamp_shape(...))`, writing final foam intensity directly. There was no separate energy field or rise response, so a new stamp reached its full value immediately.

## Refinement

- The 512×512 world-space history now stores **R = wake energy** and **G = visible foam** over the existing 128 m region. Energy accumulates and decays separately; foam rises toward a thresholded energy target and fades with its own rate.
- The V arms were removed. Each stamp is a compact, velocity-aligned stern churn with soft elliptical falloff and local breakup. Existing interpolated intermediate stamps, world anchoring, overlap preservation, airborne emission stop, and landing impulse path remain.
- Energy broadens through low-rate isotropic diffusion. The surface reads the visible channel and uses the existing crest breakup texture plus local modulation. Foam affects albedo, roughness, and specular with a lower coverage cap.
- Inspector controls under **Persistent Interaction Wake** now include energy lifetime/decay, foam rise rate, foam decay rate, target coverage, intensity, width, and a debug view selector. Debug modes expose the energy and visible channels; recent source stamp positions and headings are also available through runtime diagnostics. Normal HUD is unchanged.

## Validation evidence

- Godot script checks passed for `ocean_interaction_foam.gd`, `open_ocean_fft.gd`, and `ocean_clipmap_surface.gd`; the existing jetski contact FX script also passed. The gameplay run loaded the compute resource, reported `ready: true`, no foam-system error, and nonzero submitted-stamp counts.
- A short stationary/start capture and several short throttle captures were taken. A turn was sampled with throttle and steering held together. The diagnostic energy view showed a world-anchored trail that follows the jetski’s changing heading. The normal capture after tightening coverage no longer shows the previous broad solid patch, but the wake is too faint and inconsistent to pass the visual gate.
- Final normal-view screenshot: `user://screenshots/ocean_wake_phase1b_threshold_final.png` (`C:/Users/DEV/AppData/Roaming/Godot/app_userdata/Ocean Production/screenshots/ocean_wake_phase1b_threshold_final.png`). Diagnostic captures: `ocean_wake_phase1b_after_spread_debug.png` and `ocean_wake_phase1b_turn_debug.png` in the same screenshots directory. The earlier broad-patch result is `ocean_wake_phase1b_final_candidate.png`.
- Runtime `pass_submit_ms` remained in the 0.002–0.006 ms range. This is CPU command-submission time only; it is not GPU execution timing. The earlier OFF/ON FPS samples remain confounded by changing boat and camera state and are not a performance conclusion.

## Remaining validation

The stationary, slow movement, short throttle, and turn checks were sampled, but there is no controlled high-speed run, dedicated hop/airborne-stop and landing-impulse capture, clipmap-boundary sweep, or measured multi-second foam-rise/fade capture. The low-speed gameplay capture also does not establish a stable V emerging from history. These gaps, plus the faint normal-camera result, keep Phase 1 unaccepted.

FEEL-5 remains complete; its rejected anti-hop candidate is still disabled. No vehicle physics, FFT spectrum, ocean query, wave clock, PHYSICS_ALIGNED configuration, or H0 synchronization was changed. No commit was created.

## OCEAN-WAKE-1C visibility diagnosis

The source chain exposes two consecutive gates after emission. The compute pass first maps energy through `smoothstep(0.08, 0.38, energy) * target_coverage` and moves visible foam toward that target at the configured rise rate. The surface then maps the visible channel through a threshold ramp, multiplies by the crest breakup mask and a second local modulation mask, scales by coverage strength and `0.62`, and caps the blend at `0.30`. This identifies the likely visibility bottleneck as the combined late energy response and stacked surface masks; runtime field views are still required to determine which dominates in motion.

For 1C, the surface threshold is now an inspector control (`interaction_foam_visible_threshold`, initially `0.05`), with a fixed `0.25` transition width. Diagnostic modes are Surface, Energy Field, Visible Foam, and Final Coverage. The normal view remains selected by default. The foam history resolution, region size, R/G channel roles, stamp footprint/placement, and rate-based rise/decay remain unchanged. No deformation or lateral wake arms were added.

Future lateral propagation should evolve the world-space energy field over time: store or derive the local wake heading, then let older energy expand sideways with a bounded age-dependent lateral spread while preserving the anchored field origin and gradual decay. That would produce emerging arms from evolving water energy rather than painted diagonal geometry. It remains deferred until the foam visibility gate passes.

Runtime validation and final parameter selection for 1C are pending the exclusive Godot window. Phase 1 remains unaccepted until normal and elevated captures verify readable broken foam at RACE speed and through turns, contact loss, airborne transition, and landing.
