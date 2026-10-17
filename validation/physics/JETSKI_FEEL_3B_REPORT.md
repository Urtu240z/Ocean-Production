# JETSKI-FEEL-3B — Clean Takeoff Angular Velocity

## Configuration and implementation

- Cleaner default: ON; F8 toggles ON/OFF.
- Water Race buoyancy torque authority remains `1.0`; the old takeoff-candidate torque scaling was removed.
- At the authoritative takeoff transition, the cleaner changes body-local pitch and roll angular rates with a one-time torque impulse. Yaw rate and transform are preserved. There is no angular-velocity clamp and no airborne leveling.
- Normal rate envelope: pitch soft/strong `0.8 / 1.5 rad/s`; roll `0.6 / 1.2 rad/s`.
- Matching rider intent expands the relevant envelope by `65%`: BACK allows positive pitch, FORWARD negative pitch, LEFT/RIGHT their matching roll direction.
- The smooth rate curve stays sign preserving and asymptotically approaches its upper envelope. Extreme bypasses use attitude (`60°` pitch, `50°` roll), rate (`4.5 rad/s` pitch, `5.5 rad/s` roll), point force (`20 kN`), contact impulse (`1200 N·s`), or side impulse (`600 N·s`) thresholds. Speed alone is not a bypass condition.
- F4 advanced diagnostics show the last classification, before/after local rates, correction impulse, and rider intent. The normal HUD is unchanged.
- Airborne rider torque code and its settings were left unchanged.

## Phase-locked validation

The automated run froze the FFT at wave time `39.231737 s`. Each trial reset navigation/contact state and restored the same start transform and linear/angular velocity before applying the same scenario input in OFF and ON modes. The run completed at `161 FPS`.

There were 9 matched valid launches per mode (3 repetitions each for DIAGONAL CREST, RIDER BACK, and RIDER LEFT). The other 18 of 27 trials per mode did not reach the authoritative takeoff transition and are reported as `NO_TAKEOFF`; they are excluded from rate and orientation comparisons. No launches were classified EXTREME.

| Matched case (3 repetitions) | OFF pitch rate at release | ON pitch rate before → after | OFF → ON pitch rate at 250 ms | OFF → ON pitch rate at 500 ms | Release orientation delta |
|---|---:|---:|---:|---:|---:|
| Diagonal crest | `-3.879` | `-3.879 → -1.663` | `-3.777 → -1.619` | `-3.683 → -1.579` | `0° / 0°` |
| Rider back | `1.467` | `1.467 → 1.462` | `1.554 → 1.552` | `1.558 → 1.557` | `0° / 0°` |
| Rider left | `-0.979` | `-0.979 → -0.968` | `-0.953 → -0.942` | `0.442 → 0.456` | `0° / 0°` |

Rates are in rad/s. For the diagonal crest, roll rate at release changed only from `-0.669` to `-0.667 rad/s`; rider-left roll changed from `1.092` to `1.089 rad/s`. These remain within the applicable soft region, including rider-intent expansion. The pitch correction was greatest in the high-rate diagonal crest case, as intended.

Across the 9 matched launches per mode, there were `0` cases with more than `45°` roll change or more than `60°` pitch change during the first `500 ms`. Airborne rider input remains routed through the existing rider dynamics system; the matched BACK and LEFT cases retained their rider intent and measured post-release rates.

## Runtime verification

- DRIVE: RACE; physics mode: WATER RACE; cleaner: ON; buoyancy torque scale: `1.0`.
- FFT cascade gate logged as FULL. Runtime remained active after validation.
- No new script/runtime errors were present after clearing the prior editor error buffer and checking it after this run.
- Scene `gameplay/jet_ski_ocean.tscn` was reopened in the editor and remains in the running playtest.

## Files changed for FEEL-3B

- `gameplay/vehicles/common/systems/jet_ski_water_physics_system.gd`
- `gameplay/vehicles/common/core/jet_ski_controller.gd`
- `gameplay/jet_ski_ocean.gd`
- `validation/physics/jetski_feel_3_takeoff_validation.gd`
- `validation/physics/JETSKI_FEEL_3B_REPORT.md`
