# JETSKI-FEEL-4 — Normal Direction Validation

## Baseline force model audit

- Four buoyancy contacts; body mass 300 kg.
- Water Race shallow support: `5500 N/m` per point, using `min(depth, 0.8 m)`.
- Deep support starts at `1.0 m`; its effective slope is `min(3500, 5000) = 3500 N/m` per point.
- Normal-velocity damping: `2500 N·s/m` per point, faded by `clamp(support_depth / 0.8, 0, 1)`.
- Per-point force clamp: `5500 N`; draft offset: `0 m`.
- Torque scale: `1.0`. Runtime wet angular damping: pitch/yaw/roll `20 / 15 / 80 N·m·s/rad`.
- Estimated static shallow equilibrium: `300 × 9.81 / (4 × 5500) = 0.134 m` support depth, assuming four equally loaded points, zero relative velocity, and no force cap.

The test changed only the applied force direction to `normalize(UP*(1-x) + water_normal*x)`. The sampled water normal remains the damping axis; force coefficients, depth response, force caps, and damping values were not changed.

## Phase-locked method

The run used ocean time `1.291700` at simulation-time multiplier `0.50`, then held the FFT clock at that phase. It compared `NORMAL_100`, `NORMAL_050`, `NORMAL_025`, and `NORMAL_010` across stationary, gentle-wave, small-lateral, medium-lateral, medium-head-on, diagonal, and high-speed-crossing cases. Each of the 28 accepted trials began with the same scenario transform, linear and angular velocities, rider/throttle inputs, and wave time. The runner rejects mismatches. Results below are averages of the seven scenario p95 values, not a pooled p95.

| Normal influence | Pitch rate p95 (rad/s) | Roll rate p95 (rad/s) | Pitch accel p95 (rad/s²) | Roll accel p95 (rad/s²) | Buoyancy torque p95 (N·m) | Horizontal/vertical force | Support depth (m) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 100% | 1.741 | 2.278 | 30.88 | 26.38 | 6383 | 0.171 | 0.178 |
| 50% | 1.613 | 1.648 | 27.50 | 24.61 | 5745 | 0.089 | 0.180 |
| 25% | 1.653 | 1.668 | 30.59 | 23.64 | 6282 | 0.045 | 0.178 |
| 10% | 1.658 | 1.628 | 31.24 | 23.48 | 6352 | 0.018 | 0.178 |

At 50%, mean case p95 torque fell 10.0%, pitch rate fell 7.4%, roll rate fell 27.7%, pitch acceleration fell 10.9%, and roll acceleration fell 6.7%. Horizontal-to-vertical force fell 47.8%. Torque p95 was lower in all seven scenarios and pitch acceleration p95 was lower in six of seven. The clearest individual result was small-lateral roll rate: `9.163 → 4.656 rad/s` and roll acceleration: `73.542 → 48.997 rad/s²`. Head-on and diagonal roll response remained mixed, so this is a measured compromise rather than a uniform reduction in every metric.

## Selection

Leave **CANDIDATE / NORMAL_050** active. Among the tested values it gave the lowest average pitch-rate, pitch-acceleration, and torque p95 while substantially reducing horizontal force. The normal-only change addresses most of the measured excess response, so stiffness and damping were not retuned or tested.

The completed run produced 28 rows at 277 FPS and restored the saved ocean time multiplier and vehicle runtime state. An initial harness launch stopped on an incorrect getter name before collecting data; the getter was corrected before the successful phase-locked run.
