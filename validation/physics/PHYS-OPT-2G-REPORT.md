# PHYS-OPT-2G — total moving-weather surface velocity

2026-10-02. Old development PC: i7-5820K / GTX 970; Godot 4.7.1,
Forward+ / D3D12. Branch `wip/phys-opt-2`, baseline `421fc25`.
Native identifier: `PHYS-OPT-2G-total-weather-velocity-v7`.

**PHYS-OPT-2G: PASS.** Final v7 native build, complete velocity matrix, runtime
weather controls, 3,600-tick producer run and original PHYS-3 suite passed.

## Actual equation and weather contract

The authoritative GPU equation in `addons/ocean/shaders/fft/evolve_spectrum.glsl`
is reproduced by the native mirror:

```
H = A * exp(-i*omega*t) + B * exp(+i*omega*t)
```

B is the retained conjugate-negative H0 channel, not an independently generated
spectrum. `dynamic_ocean_weather.gd` publishes the mirror's retained float32 H0
to Production. The native publisher mixes the two immutable endpoints with
`alpha = clamp((wave_time-start)/duration, 0, 1)`. There is no easing.
The existing float32 rounding boundary, parity convention, operation order,
seed/phase identity and endpoint generation remain unchanged.

Inside the ramp, `alpha_dot = 1/duration`; outside, and at the exact endpoints,
the selected fixed-side derivative is zero. Direction, wind, Hs, common amplitude,
band scales and MID fill are already embedded in endpoint H0. Lattice k,
dispersion omega, domain and resolution are fixed during these transitions.

Before this change, velocity included only phase evolution. It now includes:

```
A_dot = (A_target - A_source) * alpha_dot
B_dot = (B_target - B_source) * alpha_dot
V_height = -i*omega*A*exp(-i*omega*t) + i*omega*B*exp(+i*omega*t)
         + A_dot*exp(-i*omega*t) + B_dot*exp(+i*omega*t)

a1 = -lambda*kx/|k|; a2 = -lambda*kz/|k|
Dx = -i*a1*H; Dz = -i*a2*H
Vx = -i*a1*V_height - i*a1_dot*H
Vz = -i*a2*V_height - i*a2_dot*H
```

No choppiness derivative enters vertical height. Static Coastal warp,
confidence and shoaling apply the existing LONG displacement blend to its
velocities. No artificial time derivative is assigned to a static bake.
MID/SHORT remain at the common external material-q.

All terms enter the existing velocity spectra: **six packed complex IFFTs per
band, 18 packed 2D IFFTs per snapshot; twelve real fields per band**. No new
transform, GPU readback, per-query derivative or inversion change was added.

## Async ownership and cost control

One immutable build request owns endpoint spectra, start, duration and version.
The producer preallocates six endpoint-difference arrays per band (9 MiB total)
at startup. On a version change, it fills them from that request before dispatch.
They stay immutable throughout the joined native batch. A newer request cannot
overwrite arrays being read by the current jobs. Snapshot metadata additionally
exposes alpha_dot, ramp start/duration and per-band choppiness_dot.

There is no new query lock, main-thread array preparation, or allocation per
steady-state field. Triple buffering/latest-wins and the existing one-tick
clock pipeline are preserved. The direct spectral oracle is untouched.

## Independent velocity oracle

The new `phys_weather_velocity_runner.gd` evaluates only final displacement
at t-h and t+h to construct the oracle. It does not use analytic velocity in
the difference. Subtraction happens on the double packed outputs before making
Godot Vector3 values, avoiding a float32 world-coordinate subtraction artifact.

Coverage:

- Calm (Hs .8 m, wind 4 m/s, direction 20 deg, LONG lambda .8), storm
  (3 m, 18 m/s, 75 deg, lambda 2), and a direction-only 75→20 deg storm change.
- Calm→storm, storm→calm and the direction change; 1, 3 and 10 second ramps.
- Alpha 0, .1, .25, .5, .75, .9 and 1.
- 92 points: 16 open, 32 Coastal interior, 32 boundaries/mask transitions,
  12 periodic-wrap points; 4,140 interior-ramp comparisons and 1,656 endpoint checks.
- Central differences h=1/120, 1/240 and 1/480 seconds. At endpoint kinks,
  second-order one-sided differences distinguish the selected outside derivative
  from the inside derivative and from the central average.

The new oracle budget is 0.0001 m/s. No existing PHYS-3 tolerance was changed.

### Fixed weather

Calm, current Production and storm: maximum Vy/Vx/Vz difference versus the
fixed-H0 phase-only control was **0 / 0 / 0**. The native scalar-versus-AVX2
fixture compared 55,296 field values across forward/reversed ramps, endpoints
and configuration phase rebases: maximum difference **3.69482e-13**.

At every ramp packet, displacement, normal and Jacobian outputs were also
compared against the same-time fixed-H0 control. Maximum difference across
those geometry fields was **1.31983e-12**: velocity packing did not alter the
surface being differentiated.

### Error against temporal finite differences

Units in this table are **micrometres/second** (multiply by 1e-6 for m/s).
The selected h is 1/480 s; counts are q/time comparisons per component.

| Region | Component | Mean abs | RMS | p95 | p99 | Max |
|---|---|---:|---:|---:|---:|---:|
| Open (720) | Vy | 3.853 | 5.049 | 10.177 | 15.825 | 17.703 |
| Open | Vx | 4.667 | 6.819 | 14.305 | 24.199 | 44.465 |
| Open | Vz | 6.038 | 8.116 | 17.166 | 21.219 | 30.279 |
| Coastal interior (1440) | Vy | 3.957 | 5.191 | 10.729 | 15.020 | 22.173 |
| Interior | Vx | 4.290 | 6.124 | 13.977 | 18.716 | 31.710 |
| Interior | Vz | 5.532 | 7.584 | 15.587 | 22.888 | 41.485 |
| Coastal boundary (1440) | Vy | 3.650 | 4.805 | 10.014 | 13.828 | 17.755 |
| Boundary | Vx | 3.954 | 5.696 | 12.398 | 19.193 | 32.187 |
| Boundary | Vz | 5.323 | 7.352 | 15.259 | 22.888 | 31.948 |
| Periodic wrap (540) | Vy | 4.026 | 5.230 | 11.444 | 13.947 | 17.822 |
| Wrap | Vx | 4.465 | 6.685 | 13.947 | 24.319 | 32.425 |
| Wrap | Vz | 5.559 | 7.799 | 16.451 | 25.511 | 26.092 |

Halving h from 1/120 to 1/240 reduces vector mean error from approximately
63–73 to 16–19 micrometres/s. At 1/480 the truncation error approaches the
existing H0 float32 composition and Vector3 reporting floor. Literal quantized
H0 is a staircase, without a useful classical derivative at rounding jumps;
the velocity differentiates the authored linear envelope, not numerical
quantization. Finite differences use the actual rounded displacement.

### Magnitude of the previously missing envelope term

Vector envelope velocity, mean/max in m/s over the five interior alpha values
and all 92 points (different simulation times between rows):

| Transition | Duration | Mean | Max |
|---|---:|---:|---:|
| Calm→storm | 1 s | 1.4140 | 5.6400 |
| Calm→storm | 3 s | .4821 | 1.6739 |
| Calm→storm | 10 s | .1404 | .6027 |
| Storm→calm | 1 s | 1.3450 | 5.9066 |
| Storm→calm | 3 s | .4641 | 2.2048 |
| Storm→calm | 10 s | .1278 | .4473 |
| Direction-only | 1 s | 1.5039 | 4.2096 |
| Direction-only | 3 s | .4751 | 1.2117 |
| Direction-only | 10 s | .1368 | .3336 |

A separate same-time/same-alpha comparison isolates duration scaling:
at t=120, alpha=.5, mean/max envelope velocity is 1.418288/3.091592 (1 s),
.472763/1.030531 (3 s), .141829/.309159 (10 s). Multiplying by duration gives
agreement within **5.77316e-15 m**.

An isolated LONG choppiness 0→2 ramp with unchanged H0 gives horizontal
envelope maximum .320651 m/s, vertical envelope maximum 1.66533e-15 m/s,
and temporal-oracle vector maximum error 4.74335e-6 m/s.

### Representative Coastal point

Calm→storm, 3 s, q=(74.08604,-995.8035); height in m, velocities in m/s:

| Alpha | Height | Phase-only Vy | Envelope Vy | Total Vy | Central FD Vy |
|---:|---:|---:|---:|---:|---:|
| 0 | -.232661 | -.144042 | 0 | -.144042 | -.113942 |
| .1 | -.205116 | .188101 | .081719 | .269820 | .269819 |
| .25 | -.026252 | .382153 | .092487 | .474640 | .474641 |
| .5 | .260320 | .045752 | .070720 | .116472 | .116471 |
| .75 | .126236 | -.455058 | -.001321 | -.456380 | -.456385 |
| .9 | -.126531 | -.587931 | -.053927 | -.641859 | -.641855 |
| 1 | -.312875 | -.485951 | 0 | -.485951 | -.526340 |

Endpoint central differences straddle a real kink, hence their different
values. Endpoint outside-side oracle maximum error is 1.99493e-5 m/s;
largest measured one-sided vector jump is 6.21420 m/s for the authored 1 s ramps.
No impulse term, sign correction, new easing or ramp behavior was introduced.

## Pause and rapid requests

The full live Production weather runner pauses for 30 physics ticks mid-ramp.
Simulation time, alpha, version, published velocity and transition metadata
remain unchanged; velocity difference is exactly zero. Resume completes from
the same state, with endpoint H0 byte-identical to Production.

Rapid requests at 20→75→110 degrees accept only the latest serial (6), with
no mixed bands. Configuration changes reset/rebase phase history coherently.
Stored velocity is the intrinsic derivative with respect to simulation time;
pause freezes that field rather than rewriting it as wall-clock velocity zero.

## Performance and rejected candidates

Five workers, full three-band Coastal, no oracle in the timed producer loop.
All results are old-PC measurements. Identical live-weather runner, 3 s ramps:

| Producer | Mean ms | p95 ms | p99 ms | Max ms |
|---|---:|---:|---:|---:|
| Baseline 421fc25, nearby run | 11.602 | 13.267 | 15.785 | 17.993 |
| Corrected v7, focused run | 11.771 | 13.485 | 15.049 | 17.439 |

Mean increment: **.169 ms**. The focused v7 run had max field age 1.11968 ticks,
p95 1, p99 1.02318; no age≥2 or age≥3 samples and no mixed bands.
Its single material query averaged .02924 ms; weather preparation/poll work
is measured separately from main-thread snapshot advance.

Rejected v1–v5 variants fused endpoint mixing/evolution or changed accumulation
layout, but cost 12.8–13.4 ms in the live-weather runs. v6 initially measured
12.059 ms, but repeats reached 12.732/13.152 ms versus a nearby baseline 11.602.
That regression was not accepted. v7 caches endpoint differences once per
configuration and reuses them in the existing AVX2/scalar velocity spectrum.
Packing the existing twelve real fields four modes at a time also avoids extra
scalar packing cost. The IFFT count remains 18.

The version-change delta preparation is worker-side, not hidden: one first
configuration build had 2.949 ms outside FFT batch work, versus approximately
.005–.006 ms in ordinary builds. It adds no cost on subsequent ramp snapshots.
No heap growth occurs during those steady-state builds.

Fixed-weather measurements (baseline run 600 ticks; final run 3,600 ticks):

| Producer | Mean ms | p95 ms | p99 ms | Max ms |
|---|---:|---:|---:|---:|
| Baseline fixed weather | 9.094 | 10.899 | 12.513 | 13.541 |
| Final v7 fixed weather | 8.995 | 10.503 | 11.530 | 14.840 |

The different run lengths and OS scheduling variance do not establish a
steady-state speedup; they show no measured steady-state penalty. Nearby weather
runs are the matched comparison for the added envelope work.

Final 3,600-tick run: query mean/p95 .015286/.024 ms; main advance mean/p95/max
.001814/.003/.027 ms; no bad query, mixed band or age≥2/3 sample. Field age
mean/p95/p99/max .8512/1.12592/1.14620/1.16385 ticks, with the existing pipeline
time explicit. Pause/resume passed.

Four-point Coastal material batches measured .01293/.01346/.01661 ms in the
duration-scaling tests. Cold world N4: .16779/.16931/.16831 ms. The live-weather
regression measured material N4 .01365–.01372 ms, N16 .05194–.05435 ms, cold
world N4 .12272–.17236 ms across the three endpoint states. No derivative is
computed per query and the world solver was not altered.

## PHYS-3 and preexisting diagnostic

The original PHYS-3 runner and its limits are unchanged. A v6 full run passed
PHYS-3-A with 64/64 inversions, exact outside fallback, material batch max
3.22753e-12 m, world batch max 4.14174e-11 m and 8192-point reconstruction
max 3.62758e-5 m.

Final v7 suite: **PHYS-3-A** at frozen time .506687624990039, 64/64 inversions,
material scalar/batch max 3.30288e-12 m, world scalar/batch max 3.71006e-12 m.
Horizontal residual mean/p95/max .000161389/.000629361/.000803228 m;
iterations mean/p95/max 2.25/3/3. Physical normal FD maximum 8.23058e-5.
8192-point interpolation-matched Coastal reconstruction vector max 3.71744e-5 m,
with exact zero open fallback. Frozen/moving packets, borders, source/sampling
gates, normals, batch and 1x/0x/resume all passed without tolerance changes.

Dynamic-mirror weather endpoint regression also passed 64/64 for all three
states, with scalar/batch differences zero and no mixed bands. Known folded
sources still had alternate q recovery errors up to .2821 m despite a low
horizontal residual: these diagnostics are preserved, not claimed as branch
ownership correctness. That remains PHYS-OPT-2H.

One earlier run failed its 1e-8 m world scalar/batch gate at time
.472943000000001, source q=(37.13506,81.04028). An isolated four-query replay
with both the rebuilt baseline 421fc25 DLL and v6 DLL produced **identical**
max difference 2.23305818281005e-8 m, residuals .000486127746222101 and
.000486234254803473, two iterations. This is a preexisting numerical edge in
the direct inverse path, not caused by weather velocity. Both successful and
failed runs are disclosed; the gate, direct solver and inversion were not
changed to hide it. Branch ownership/fold policy remains outside this phase.

## Reproduction and changed source

Build with MSVC x64 initialized, from `addons/ocean/physics/native/ocean_query`:

```powershell
python -m SCons platform=windows target=template_release godot_cpp_path=../godot-cpp -j 6
```

During these incremental tests, `build_library=no` reused the already built,
validated godot-cpp 10.0.0-stable / API 4.7 library. The repository SConstruct
compiled and linked the changed native sources and generated the descriptor.
The existing unknown `godot_cpp_path` warning is unchanged hygiene debt.
No binaries, dependency checkout or generated captures belong in the commit.

```powershell
godot --path . --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_weather_velocity_runner.gd
godot --path . --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_weather_runner.gd
godot --path . --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_recovery_runner.gd -- --ticks=3600 --load-ms=0
godot --path . --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys3_coastal_probe_runner.gd
```

`run_dynamic_physics_validation.ps1` now includes the velocity oracle.
Standalone scalar/AVX2 correctness and matched producer A/B sources are
`phys_weather_velocity_native_test.cpp`, its shared fixture header, and
`phys_weather_velocity_producer_bench.cpp`. The fixture is synthetic full-N
kernel coverage; the Godot tests use actual Production H0 and Coastal bakes.

Changed native source: dynamic publisher/header, physics field/header,
AVX2 kernel/header, and snapshot metadata/build identifier in the native wrapper.
Changed validation: velocity runner/fixtures, pause assertions in weather runner,
build guard, aggregate validation entry point and runtime/recovery documentation.
No renderer, spectrum generator, Coastal formula, force or inversion file changed.

Exact source manifest:

```
addons/ocean/physics/native/ocean_query/src/dynamic_ocean_async.cpp
addons/ocean/physics/native/ocean_query/src/dynamic_ocean_async.h
addons/ocean/physics/native/ocean_query/src/dynamic_ocean_fft_avx2.cpp
addons/ocean/physics/native/ocean_query/src/dynamic_ocean_fft_avx2.h
addons/ocean/physics/native/ocean_query/src/dynamic_ocean_physics_field.cpp
addons/ocean/physics/native/ocean_query/src/dynamic_ocean_physics_field.h
addons/ocean/physics/native/ocean_query/src/ocean_query_native.cpp
validation/physics/DYNAMIC-PHYSICS-RECOVERY-REPORT.md
validation/physics/DYNAMIC-PHYSICS-RUNTIME.md
validation/physics/PHYS-OPT-2G-REPORT.md
validation/physics/phys_native_build_contract.gd
validation/physics/phys_weather_runner.gd
validation/physics/phys_weather_velocity_native_fixture.h
validation/physics/phys_weather_velocity_native_test.cpp
validation/physics/phys_weather_velocity_producer_bench.cpp
validation/physics/phys_weather_velocity_runner.gd
validation/physics/run_dynamic_physics_validation.ps1
```

## Acceptance / Git

**PASS:** all prescribed velocity gates, fixed states, temporal oracle, Coastal,
forward/reverse/direction weather, pause/resume, rapid coherent versions,
PHYS-3-A and producer/query cost passed. The 0.169 ms nearby weather mean
increment is below the requested 0.25 ms strong goal; no extra IFFT or quality
concession was needed. Final v7 engine tests reported no console errors or
native crash.

Validated source and documentation are committed together with message
`Correct ocean velocity during runtime weather transitions`, then pushed only
to `origin/wip/phys-opt-2`. The resulting hash is reported in the task response
(avoiding a self-referential hash inside its own commit). Generated DLL, objects,
dependency products, captures, logs and baseline diagnostics remain ignored.

## Mandatory pending roadmap

- Crest G / Spindrift clamp discrepancy.
- P3D.1 travelling phase after TIME-1 in an initialized Ocean/Carrier scene.
- P3E handoff after TIME-1 in an initialized Ocean/Carrier scene.
- TIME-1 audit instrumentation: remove, move to validation/debug or retain intentionally.
- NEXT: PHYS-OPT-2H folded-surface branch continuity, not started here.

PHYS-4 and jetski forces were not started. No branch was merged into master.
