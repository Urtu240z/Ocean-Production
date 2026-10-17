# Gameplay Baseline Lock

Date: 2026-10-11

## Locked configuration

- Visual FFT: FULL
- Physics water: GAMEPLAY SURFACE, CPU Lite B, DIRECT query
- Physics minimum wavelength: 1.0 m
- Hull mode: WATER RACE
- Mass: 300 kg
- Gameplay COM: (0, -0.22, 0) m
- Inertia mode: COMBINED RIDER
- Inertia: Ixx 208.087, Iyy 172.687, Izz 62.884 kg·m²
- Buoyancy torque scale: 1.0
- Wet angular damping: pitch 20, roll 80, yaw 15 N·m·s/rad
- F4 enables advanced diagnostics; F3 contact overlay is available while diagnostics are enabled.

## Cleanup and smoke evidence

- Normal startup explicitly selects DIRECT water queries. Displaced and LocalSurface query modes are blocked unless an explicit validation routine enables them; the full CPU candidate is similarly gated.
- Physics event/statistics collection is disabled during normal play and enabled by F4. The normal HUD shows only water mode, hull, mass, COM, inertia mode, and FPS.
- Smoke input covered idle, throttle acceleration, right turn, continued wave traversal (medium/large visible waves), throttle release/contact support, and left/right rider lean.
- Runtime snapshot: 0 invalid samples, 0 LocalSurface builds, 0 displaced fallbacks, 1 CPU field build on the observed physics tick, finite position/velocity, and 238 FPS. The provider rejects more than one field build in a physics tick.
- Rider lean input reached a smoothed left shift of (-1, 0) while held; rider weight shifting remains enabled.
- The wave traversal did not produce an airborne transition, so no forced landing was injected. Water contact remained active after throttle release.
- All modified GDScript files passed offline script validation; no runtime script errors were observed after the smoke run.

## Files changed

- gameplay/jet_ski_ocean.gd
- gameplay/water/cpu_fft_water_provider.gd
- gameplay/vehicles/common/systems/jet_ski_water_physics_system.gd
- validation/physics/phys_surface_align_validation.gd
- validation/physics/GAMEPLAY_BASELINE_LOCK_REPORT.md
