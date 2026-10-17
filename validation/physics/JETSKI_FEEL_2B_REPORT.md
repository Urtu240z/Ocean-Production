# JETSKI-FEEL-2B Validation Report

Date: 2026-10-11

## Final gameplay configuration

- Visual FFT: FULL
- Physics water: GAMEPLAY SURFACE; query and ocean settings unchanged
- `physics_min_wavelength_m`: 1.0 m
- Hull: WATER RACE; buoyancy torque scale: 1.0
- Ballast: STOCK; rigid-body mass: 300 kg
- COM: `(0, -0.22, 0)` m
- Inertia: `(208.087, 172.687, 62.884)` kg·m²
- Draft: STANDARD, 0.00 m
- Drive: RACE
- Wet angular damping remains 20 pitch / 80 roll / 15 yaw N·m·s/rad.

## Draft validation

Draft offsets are 0, 0.05, 0.10, and 0.15 m. Raw signed depth still drives geometric contact and contact effects. Buoyancy support uses `max(raw_depth - draft_offset, 0)`. Hydrodynamic drag continues using raw immersion.

The automatic 8-second pass sampled the current moving ocean during the last four seconds of each mode:

| Draft | Mean raw contact depth | Mean effective support depth | Mean buoyancy force |
| --- | ---: | ---: | ---: |
| STANDARD 0.00 m | 0.146 m | 0.146 m | 3002 N |
| LOW 0.05 m | 0.179 m | 0.139 m | 2639 N |
| DEEP 0.10 m | 0.228 m | 0.136 m | 2983 N |
| VERY DEEP 0.15 m | 0.277 m | 0.157 m | 3401 N |

Raw depth increased as draft increased while effective support depth stayed near 0.14–0.16 m. Ocean time continued between cases, so these are representative moving-wave samples rather than phase-locked equilibrium comparisons.

## Drive audit and profiles

Before tuning, STOCK drive used 4200 N forward, 1800 N reverse, full contact depth 0.30 m, and forward thrust falloff from 18 to 28 m/s. Reverse falloff remains 5 to 9 m/s. Throttle previously had no response filter; STOCK stays immediate. The drive force is applied at local position `(0, -0.18, 1.25)` m. Existing per-point drag is forward `15v + 1.5v|v|` N and lateral `80v + 7v|v|` N, capped at 3500 N and 7000 N respectively. There is no velocity clamp; speed control comes from propulsion falloff.

SPORT uses 6650 N forward / 2200 N reverse and forward falloff 22.5–32.5 m/s. RACE uses 10000 N forward / 2500 N reverse and falloff 25.5–36.5 m/s. Throttle response is immediate in STOCK, 0.20 s in SPORT, and 0.18 s in RACE. Airborne propulsion authority falls to 8%; reentry restores authority over 0.18 s.

Thirty-second automated runs used the same vehicle transform and zero initial velocities for each profile. Ocean phase continued between runs.

| Profile | Max supported forward speed | 0–50 km/h | 0–80 km/h | Peak measured longitudinal acceleration |
| --- | ---: | ---: | ---: | ---: |
| STOCK | 58.7 km/h | 4.07 s | not reached | 54.4 m/s² |
| SPORT | 90.8 km/h | 3.85 s | 10.25 s | 64.7 m/s² |
| RACE | 105.9 km/h | 0.88 s | 2.02 s | 141.1 m/s² |

Acceleration peaks are single-physics-tick maxima and include wave/contact impulses; the runs are not phase-locked to the ocean. Landing was observed in all three profiles. Maximum airborne propulsion was 233 N STOCK, 409 N SPORT, and 615 N RACE, compared with supported maxima of 4200 N, 6650 N, and 10000 N.

The existing spray, foam, wake, and landing splash script was preserved. It continues to use already sampled raw contact data; airborne contact gates new spray/wake emission, and landing splash velocity scales with downward entry speed.

## Smoke and runtime checks

- Draft stationary/settling intervals, acceleration, profile top speed, airborne transitions, and landing were exercised by the in-game runner.
- Full left steering was observed at -12° with four raw contacts. Left rider shift reached -1.0 and released normally.
- Water provider maximum: 1 field build/tick and 25 sampled query positions/tick. The changes add no water sample calls.
- Final screenshot HUD showed FPS 206; runtime linear and angular velocity vectors were finite.
- All changed GDScript files passed `script_check`. No gameplay script parse/runtime errors appeared in the final run.

## Files changed

- `gameplay/vehicles/common/systems/jet_ski_water_physics_system.gd`
- `gameplay/vehicles/common/state/jet_ski_water_state.gd`
- `gameplay/vehicles/common/systems/jet_ski_drive_system.gd`
- `gameplay/vehicles/common/core/jet_ski_controller.gd`
- `gameplay/jet_ski_ocean.gd`
- `validation/physics/jetski_feel_2b_validation.gd`
- `validation/physics/JETSKI_FEEL_2B_REPORT.md`
