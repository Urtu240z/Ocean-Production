# Jetski FEEL-3C Takeoff Cleaner Validation

Date: 2026-10-11

## Scope and method

Validation only. No cleaner thresholds, cleaner curves, or gameplay physics code were changed. The validation runner scanned the current `GAMEPLAY_SURFACE` with a 3 m grid over a 96 m square, then froze the FFT wave time and used the same start transform, linear and angular velocity, and input state for each OFF/ON pair. A launch counted only after confirmed navigation AIRBORNE, geometric clearance, zero water contacts, crest crossing, and a takeoff transition event. No AIRBORNE state was forced.

The surface scan took 32.5 ms. The successful pass used wave time 11.558019. It took 135.3 s and ended at 237 FPS.

## Paired results

| Measure | Cleaner OFF | Cleaner ON |
|---|---:|---:|
| Valid launches | 31 | 31 |
| Matched, phase-locked pairs | 31 | 31 |
| No-takeoff trials | 8 | 8 |
| Phase-rejected pairs | 0 | 0 |
| Pitch rate absolute median / p95 / max (rad/s) | 1.215 / 2.322 / 2.322 | 1.160 / 1.878 / 1.878 |
| Roll rate absolute median / p95 / max (rad/s) | 0.572 / 1.466 / 1.466 | 0.572 / 1.150 / 1.150 |
| Pitch change >45° / >60° in first 500 ms | 3 / 0 | 0 / 0 |
| Roll change >30° / >45° in first 500 ms | 0 / 0 | 0 / 0 |
| Median 500 ms pitch / roll change (degrees) | 20.59 / 17.92 | 20.58 / 18.13 |
| Flip-like in-progress / complete | 0 / 0 | 0 / 0 |

Cleaner ON reduced the measured pitch-rate p95 by 19.1% and roll-rate p95 by 21.6% in this run. Mean OFF/ON release differences were 1.224° pitch, 0.266° roll, 0.583° yaw, 0.034 m/s vertical speed, and 0.152 m/s forward speed.

### Scenario coverage

| Scenario | Pair attempts | Matched | Failed/no takeoff |
|---|---:|---:|---:|
| Straight medium crest | 4 | 3 | 1 |
| Straight large crest | 5 | 3 | 2 |
| High-speed crest | 3 | 3 | 0 |
| Diagonal crest | 3 | 3 | 0 |
| Turning crest | 7 | 3 | 4 |
| Rider neutral reference | 3 | 3 | 0 |
| Rider back | 3 | 3 | 0 |
| Rider forward | 3 | 3 | 0 |
| Rider left | 3 | 3 | 0 |
| Rider right | 3 | 3 | 0 |
| Extreme pitch-rate probe | 1 | 0 | 1 |
| Extreme roll-rate probe | 1 | 1 | 0 |

The extreme pitch-rate probe did not produce a valid takeoff in either mode. The extreme roll-rate probe produced one matched pair, classified NORMAL in both modes; neither showed a flip-like event. Failed probes were excluded from rate statistics.

### Flight snapshots

Example matched straight-large-crest pair (body pitch/roll degrees; local pitch/roll rates in rad/s):

| Mode | +100 ms | +250 ms | +500 ms |
|---|---|---|---|
| OFF | 61.39 / 0.13; 2.295 / 0.643 | 78.93 / 6.72; 2.261 / 0.634 | 61.66 / 13.70; 2.205 / 0.618 |
| ON | 52.76 / 0.21; 1.544 / 0.642 | 65.02 / 7.41; 1.521 / 0.632 | 72.49 / 17.49; 1.484 / 0.617 |

## Rider controls and final runtime state

Rider intent remained measurable against the matched neutral reference. Signed ON release rates were: back 1.700 vs neutral 0.874 rad/s; forward 1.878 vs 0.874; left 0.992 vs neutral -0.010; right 1.009 vs -0.010.

After validation, the scene was restored and left running with RACE drive mode, `GAMEPLAY_SURFACE` provider, FFT processing enabled, takeoff assist ON, buoyancy torque scale 1.0, and diagnostics OFF. Wet angular damping remained pitch 20 and roll 80. No runtime script errors or NaN log entries appeared; the invalid-sample warning flag remained false. The editor has `gameplay/jet_ski_ocean.tscn` open.

## Files changed

- `validation/physics/jetski_feel_3_takeoff_validation.gd` — validation runner and reporting only.
- `validation/physics/JETSKI_FEEL_3C_REPORT.md` — this report.

No commit was created.
