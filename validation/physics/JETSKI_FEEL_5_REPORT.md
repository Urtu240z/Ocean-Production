# JETSKI-FEEL-5 Validation Report

## Result

The anti-hop candidate did not reduce short hops consistently while preserving large launches across both phase-locked wave rates. It remains disabled in gameplay. The Water Race baseline is restored and active.

The diagnostic distinguishes micro hops (maximum hull-point clearance ≤0.30 m and airtime ≤0.08 s), small jumps, and large jumps (clearance ≥1.0 m or airtime ≥0.65 s). The measured events show mixed causes: some short separations follow a strong upward buoyancy impulse; other long flights begin without that impulse and are consistent with a falling wave face/contact separation. A blanket contact-loss correction is therefore not justified by these runs.

## Matched A/B

Each OFF/ON pair used the same saved vehicle transform, 18 m/s forward start velocity, zero angular velocity, throttle input, and ocean phase. Wave rates were 1.0 at phase 49.933336 and 2.0 at phase 79.933338; each mode ran for 30 seconds. The tested candidate used an 18 m/s² upward-acceleration limit, a 100 ms/0.30 m low-clearance propulsion grace, and the moving-water crest exception. These were debug-only settings.

| Wave rate | Mode | Events | Micro / small / large | Airborne | Mean speed | Large-jump mean airtime | Physics p95 | FPS |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1.0 | OFF | 18 | 0 / 4 / 14 | 38.44% | 14.79 m/s | 0.710 s | 11.65 ms | 209 |
| 1.0 | ON | 19 | 0 / 5 / 14 | 34.94% | 16.90 m/s | 0.656 s | 13.04 ms | 136 |
| 2.0 | OFF | 18 | 0 / 3 / 15 | 43.06% | 9.63 m/s | 0.794 s | 66.51 ms | 214 |
| 2.0 | ON | 19 | 2 / 5 / 12 | 34.28% | 14.30 m/s | 0.633 s | 61.74 ms | 189 |

The candidate's effect changed with wave rate: it did not reduce small jumps at either rate, and at rate 2.0 it introduced two micro hops while reducing the large-jump count and mean airtime. The improvement in average speed at rate 2.0 does not offset the loss of large-launch consistency. Physics p95 varied between 11.65 and 66.51 ms across the run, so the timing data does not establish a performance improvement. FPS stayed above 60 during the comparison.

A stronger 12 m/s² cap was also tried earlier. It reduced airborne time at rate 1.0 but cut mean speed substantially; its rate 2.0 results were mixed. It was not retained.

## Final runtime state

- Anti-hop candidate: OFF; validation runner idle.
- Water Race buoyancy: 4250 N/m per point, damping 1698.2, normal influence 0.5, torque scale 1.0.
- Vehicle: 300 kg, COM (0, -0.22, 0), combined inertia (208.087, 172.687, 62.884) kg·m².
- Wet angular damping: pitch 20, yaw 15, roll 80.
- Takeoff cleaner and the softer FEEL-4B water profile retain their pre-test settings.
- Script checks passed for the runner, water physics system, controller, and gameplay root. The corrected runner uses the project's `rider_shift_left/right` action names. The fresh editor error buffer was empty after the rerun; earlier cached game-log entries were from the prior incorrect action names.
- Both phase-locked runs completed and restored the original transform, velocities, ocean clock/rate, and physics parameters. The normal gameplay baseline remains active.

## Files touched for FEEL-5

- `validation/physics/jetski_feel_5_validation.gd` — phase-locked A/B runner and per-event evidence output under `user://`.
- `gameplay/vehicles/common/systems/jet_ski_water_physics_system.gd` — opt-in anti-hop candidate and diagnostics; disabled by default.
- `gameplay/vehicles/common/core/jet_ski_controller.gd` — optional propulsion-grace integration.
- `gameplay/jet_ski_ocean.gd` — advanced debug controls and diagnostics.
- `validation/physics/JETSKI_FEEL_5_REPORT.md` — this report.

No ocean, water-query, spectrum, or baseline gameplay tuning was changed for FEEL-5. No commit was created.
