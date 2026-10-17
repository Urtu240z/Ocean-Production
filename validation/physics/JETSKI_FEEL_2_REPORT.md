# JETSKI-FEEL-2 Runtime Report

Date: 2026-10-11
Scene: `gameplay/jet_ski_ocean.tscn`
Runtime left open: STOCK ballast, Water Race hull, combined rider inertia, Water Race COM.

## Configuration

- Visual FFT: FULL
- Physics water: GAMEPLAY_SURFACE
- Physics minimum wavelength: 1.0 m
- Hull mode: WATER RACE
- Base mass: 300 kg
- Gameplay COM: (0, -0.22, 0) m in all three ballast modes
- Buoyancy torque scale: 1.0
- Wet angular damping: pitch 20, roll 80, yaw 15 N·m·s/rad
- Rider reference: 80 kg at (0, 0.85, 0.55) m relative to the stock hull COM
- Ballast location: (0, -0.30, 0.10) m local to the vehicle
- Ballast shape used for inertia: 0.50 × 0.20 × 0.40 m cuboid

## Ballast and runtime inertia

The existing 300 kg combined rider inertia remains the base. Added ballast inertia uses the cuboid's centroidal inertia plus the parallel-axis contribution from ballast COM to the preserved gameplay COM. Runtime values:

| Mode | Total mass | Ixx pitch | Iyy yaw | Izz roll |
|---|---:|---:|---:|---:|
| STOCK | 300 kg | 208.087 | 172.687 | 62.884 |
| +20 kg | 320 kg | 208.748 | 173.570 | 63.495 |
| +40 kg | 340 kg | 209.410 | 174.454 | 64.106 |

All inertia values are kg·m². Runtime checks confirmed the explicit tensor and COM in each mode. Modeled physical COM remains diagnostic only: (0, 0.0067, 0.1467) m at STOCK; gameplay COM stays at (0, -0.22, 0).

With the unchanged Water Race shallow linear buoyancy branch (5500 N/m per point), an evenly shared static load suggests about 0.9 cm extra immersion for +20 kg and 1.8 cm for +40 kg. Live instantaneous point-depth samples varied with the moving wave phase and did not establish a controlled monotonic sink-depth comparison; the visual increment was not isolated.

## Contact effects and smoke

- Wet: at least one valid sample is deeper than 0.025 m.
- Supported: at least one wet sample carries at least 100 N.
- Airborne: dry for 0.08 s.
- Landing: reentry from airborne with at least 1.0 m/s downward relative-normal speed; landing effect lasts 0.24 s.
- Spray and foam use existing per-tick contact samples. Wake is limited to supported contact above 3.5 m/s. Landing splash is a one-shot GPU particle effect. No additional water query or CPU surface construction was added.
- Smoke exercised all ballast modes in the existing production waves, acceleration, steering, and left rider lean. Runtime showed wet/supported/airborne transitions and repeated landing events; the landing serial advanced past 100 during the longer input run.
- Throttle and steering inputs registered while held. Rider-left input produced a roll shift of -1.0. Position and velocities remained finite.
- FPS stayed above 60; sampled runtime screenshots ranged from about 136 to 344 FPS. The final STOCK runtime showed about 136 FPS.
- All four edited GDScripts passed Godot's offline validation. The final runtime log had no script errors.

Wave phase and vehicle motion varied during the quick smoke, so these observations are not a phase-locked ballast comparison.

## Files changed for this task

- `gameplay/jet_ski_ocean.gd`
- `gameplay/vehicles/common/core/jet_ski_controller.gd`
- `gameplay/vehicles/common/systems/jet_ski_water_physics_system.gd`
- `gameplay/vehicles/common/visual/jet_ski_water_contact_fx.gd`
- `gameplay/vehicles/common/visual/jet_ski_water_contact_fx.gd.uid`
