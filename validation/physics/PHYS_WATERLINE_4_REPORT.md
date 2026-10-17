# PHYS-WATERLINE-4 — Rendered/Physics Surface Alignment

## Implementation

- Added `PHYSICS_ALIGNED`: horizontal displacement multipliers LONG/MID/SHORT = `0 / 0 / 1`.
- Kept vertical FFT displacement, normals, foam, and the rest of the visual spectrum unchanged.
- Kept `FULL_CHOPPY_DEBUG` available as an F2 visual-only A/B. Physics remains DIRECT / GAMEPLAY_SURFACE in both profiles.
- The CPU LocalSurface builder receives the same visual per-band horizontal multipliers, and is used only by explicit debug validation.

## Phase-locked static validation

Each pair used the same wind spectrum, wave time, frozen Jetski transform/velocity, and 225-point grid plus four actual Jetski contacts. The CPU field was refreshed from the live FFT at the held timestamp before each pair. H0 imports matched the selected wind state.

| Wind | Wave-rate phase | Profile | Dense grid mean / p95 / max (cm) | Contacts valid | Contact max (cm) |
|---:|---:|---|---:|---:|---:|
| 12 m/s | 0.5 | PHYSICS_ALIGNED | 2.38 / 6.57 / 12.87 | 4/4 | 4.93 |
| 12 m/s | 0.5 | FULL_CHOPPY_DEBUG | 89.34 / 286.71 / 365.77 | 4/4 | 31.79 |
| 12 m/s | 1.0 | PHYSICS_ALIGNED | 2.66 / 7.20 / 14.95 | 4/4 | 5.99 |
| 12 m/s | 1.0 | FULL_CHOPPY_DEBUG | 186.70 / 394.00 / 446.71 | 4/4 | 303.14 |
| 12 m/s | 2.0 | PHYSICS_ALIGNED | 2.31 / 5.91 / 13.49 | 4/4 | 4.07 |
| 12 m/s | 2.0 | FULL_CHOPPY_DEBUG | 53.49 / 173.47 / 225.80 | 4/4 | 32.78 |
| 40 m/s | 0.5 | PHYSICS_ALIGNED | 2.63 / 7.01 / 13.97 | 4/4 | 3.33 |
| 40 m/s | 0.5 | FULL_CHOPPY_DEBUG | 111.11 / 213.84 / 263.35 | 4/4 | 166.53 |
| 40 m/s | 1.0 | PHYSICS_ALIGNED | 2.58 / 6.45 / 11.81 | 4/4 | 2.58 |
| 40 m/s | 1.0 | FULL_CHOPPY_DEBUG | 21.79 / 55.41 / 131.90 | 4/4 | 15.10 |
| 40 m/s | 2.0 | PHYSICS_ALIGNED | 2.71 / 7.66 / 13.17 | 4/4 | 4.06 |
| 40 m/s | 2.0 | FULL_CHOPPY_DEBUG | 39.72 / 116.97 / 210.29 | 4/4 | 33.40 |

All PHYSICS_ALIGNED static cases met mean <5 cm, p95 <10 cm, and max <20 cm. All 225 grid points and all four contacts were valid. FULL_CHOPPY_DEBUG did not match the DIRECT surface.

## Moving contact trace and short-band check

At wind 12 m/s, wave-rate 2.0, PHYSICS_ALIGNED short scale 1, a moving contact trace recorded 3,740 valid samples: mean 7.61 cm, p95 18.37 cm, max 33.12 cm. The broader moving trace exceeded the static error targets.

A same-phase short-scale sweep at wind 12 m/s / wave-rate 2.0 did not improve p95: scale 1.0 = 12.43 cm; 0.5 = 13.23 cm; 0.0 = 13.14 cm. The default short scale remains 1.0; reducing it did not reduce this error.

## Synchronization and normal runtime

- H0 hashes at 12 m/s: LONG `2419220705`, MID `4209287694`, SHORT `2530801071`.
- H0 hashes at 40 m/s: LONG `2770334873`, MID `1709276678`, SHORT `1122654252`.
- Every reported static A/B pair used an identical FFT and CPU field timestamp. Runtime spectrum refresh/rebind was explicitly triggered after wind reconfiguration while the body was held still.
- Final running scene restored from its saved configuration: wind 40 m/s, wave-rate 2, PHYSICS_ALIGNED `0/0/1`, and direct physics queries. Advanced diagnostics and contact overlay are off.
- Runtime checks: query mode DIRECT, experimental/displaced queries off, LocalSurface build tick `-1`, invalid samples `0`, field update failures `0`, one normal CPU field build in the sampled physics tick, and finite vehicle state.
- Final normal HUD reported 70 FPS with diagnostics off. The debug grid builds a LocalSurface patch (roughly 9–24 ms in the paired runs); that work is not performed by normal gameplay.
- GDScript checks passed and the native Release DLL rebuilt successfully. The editor error buffer was empty after validation.

## PHYS-WATERLINE-4 files

- `addons/ocean/fft/open_ocean_fft.gd`
- `addons/ocean/physics/native/ocean_query/src/ocean_query_native.cpp`
- `addons/ocean/physics/native/ocean_query/src/ocean_query_native.h`
- `addons/ocean/shaders/ocean_surface.gdshader`
- `addons/ocean/surface/ocean_clipmap_surface.gd`
- `gameplay/jet_ski_ocean.gd`
- `gameplay/water/cpu_fft_water_provider.gd`
- `validation/physics/PHYS_WATERLINE_4_REPORT.md`
