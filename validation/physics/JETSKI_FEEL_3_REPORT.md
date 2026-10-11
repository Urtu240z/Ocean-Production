# JETSKI-FEEL-3 — Takeoff Assist Validation

## Configuration and implementation

- Assist defaults ON and toggles with F8. It acts only during the takeoff candidate window, scales pitch/roll buoyancy torque, preserves yaw torque and net buoyancy lift, and skips extreme events. Rider shift remains part of the takeoff response.
- Physics/ocean tuning from the locked gameplay baseline was left unchanged.
- The automated runner freezes the FFT process at wave time `190.934855 s`, then reuses the same captured vehicle transform, per-case start velocity, angular velocity, and inputs for the OFF/ON passes. It samples both variants over the first 500 ms, even when the takeoff classifier reports no event.

## Run result

The run completed at **157 FPS**. It restored the takeoff assist to ON and the vehicle to the saved scene transform. No NaN or script-error messages appeared in this run’s runtime log; all four changed GDScript files passed Godot script validation.

Values below are peak absolute pitch/roll angular rate, peak absolute pitch/roll angular acceleration, maximum absolute pitch/roll angle, then peak total buoyancy torque and lift during the first 500 ms. Units are shown in the column headers.

| Scenario | Rate OFF → ON (rad/s) | Acceleration OFF → ON (rad/s²) | Max angle OFF → ON (deg) | Torque OFF → ON (Nm) | Lift OFF → ON (N) |
|---|---|---|---|---|---|
| Straight | 1.318/1.834 → 1.261/1.584 | 20.67/33.82 → 18.69/31.54 | 8.46/10.30 → 9.01/8.56 | 4385.8 → 4630.3 | 14165 → 14007 |
| Faster crest | 1.272/1.989 → 1.234/1.391 | 19.14/37.77 → 18.14/24.79 | 9.19/11.12 → 9.01/8.11 | 4694.4 → 4526.6 | 14251 → 13902 |
| Diagonal crest | 1.731/2.041 → 1.764/1.993 | 21.60/39.63 → 21.20/40.03 | 12.06/12.69 → 12.44/12.61 | 4782.5 → 4702.0 | 11559 → 11239 |
| Turning crest | 1.274/1.733 → 1.285/1.869 | 18.89/29.04 → 19.25/31.95 | 10.31/9.79 → 10.35/10.44 | 4609.6 → 4675.5 | 13981 → 14069 |
| Rider back | 1.033/1.281 → 1.033/1.285 | 19.05/22.95 → 19.05/22.97 | 9.68/7.08 → 9.68/7.11 | 9363.2 → 9366.4 | 9438 → 9437 |
| Rider forward | 1.007/1.833 → 1.007/1.839 | 30.52/28.80 → 30.53/28.83 | 10.72/9.91 → 10.72/9.95 | 7884.8 → 7885.3 | 12108 → 12111 |
| Rider left | 1.299/2.583 → 1.299/2.584 | 19.73/56.40 → 19.73/56.43 | 9.77/18.00 → 9.77/18.00 | 4779.6 → 4779.5 | 13038 → 13039 |
| Rider right | 0.828/4.336 → 0.829/4.392 | 12.74/87.97 → 12.77/89.82 | 8.30/14.38 → 8.33/14.34 | 3509.2 → 3507.9 | 11642 → 11754 |

The clearest reduction was on the faster crest: peak roll rate fell about 30% and peak roll acceleration about 34%, while maximum pitch/roll angle also fell slightly. Most other cases changed only a little; turning and rider-right showed higher roll rate/acceleration. The turning case was classified `NO_CANDIDATE`, so it did not exercise the assist. Takeoff detection classifications varied, but all rows have actual 500 ms physics measurements rather than zero-filled missing data. This is a mixed result, not evidence of a consistent improvement across all cases.

## Files changed

- `gameplay/vehicles/common/systems/jet_ski_water_physics_system.gd`
- `gameplay/vehicles/common/core/jet_ski_controller.gd`
- `gameplay/jet_ski_ocean.gd`
- `validation/physics/jetski_feel_3_takeoff_validation.gd`
- `validation/physics/JETSKI_FEEL_3_REPORT.md`
