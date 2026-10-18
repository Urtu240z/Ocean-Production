# Physical hull waves — opt-in prototype, 18 October 2026

Status: functional prototype; **not approved for default activation or release**.
Initial measurements were made with explicit on/off overrides against master
`5430272`. The user subsequently enabled physical waves in the saved appearance
preset; that choice is preserved. The script constructor remains opt-in. This
prototype is checkpointed with the subsequent Inspector cleanup at the user's
request; its twelve-vehicle performance gate remains open.

## Trying it

Run `res://validation/hull_wave_physics_playground.tscn` using Run Current Scene.
It enables physics on a duplicate appearance resource for that execution.
The existing test course/ramp remains part of the scene.

Controls: **Ocean → Hull Waves → Physics**. Enable General → Deformation Enabled
as well. Self Delay S and Self Radius M soften newly emitted own waves; old own
wakes remain physical. Max Vertical Speed Mps bounds added water velocity.
Wake/Impacts height, width, wavelength, propagation speed and lifetime are shared
with the visible waves. See `addons/ocean/physics/water/HULL_WAVES.md`.

The Windows native extension was rebuilt. Restart an editor that has already
loaded the previous DLL. Linux requires a source rebuild; its existing binary
was not updated or certified for physical hull waves.

## Functional evidence

- One Ocean-owned bounded snapshot per physics tick; maximum 128 packets.
  Sources use existing V1 contacts and physics transforms. Rendering and queries
  share the packet definition and clock. No additional FFT, surface mesh or
  runtime GPU readback was added.
- Native/GPU comparison at 432 grid centres with two wake owners plus an impact:
  maximum height discrepancy **0.695 mm**, X/Z slope discrepancies 0.001008 /
  0.001028. Finite-difference derivative discrepancies below 0.0002 in this test.
  This validates the sampled packet field, not exact final mesh tessellation.
- Recent own impact attenuated; another owner's contribution unchanged; old own
  impact fully physical. Height, slope, depth and vertical velocity composition
  tested; invalid base samples stay invalid and malformed publications clear.
- Production-scene runtime passes: same snapshot within a tick, cached scalar
  reads add the overlay once, camera-independent packet queries, physics remains
  active with Hull Foam disabled, wind rebuild preserves history and rebinds
  drawing, maximum one FFT field build per physics tick.
- Controlled response with two actual Jet Ski bodies: a 0.6 m impact wave from
  the first owner crosses the receiver in flat base water. Compared with the
  zero-amplitude control, maximum receiver height difference **0.382 m**, vertical
  speed difference **0.511 m/s**, roll difference **24.36°**. After six seconds
  the receiver settles back to essentially the control height (0.03 mm apart).
  This is a controlled crossing, not an endurance or all-presets certification.
- English Inspector/save-load check passes with 71 Ocean controls, independent
  resources and default-off physics. Manual opt-in scene starts, draws and
  preserves the saved default resource. Final validation logs contain no errors.

The base FFT surface history/warm starts stay separate: the overlay is applied
after base geometry publication, before drift and consumer cache publication.
Existing buoyancy and driving laws are unchanged.

## Integrated performance

Windows, Godot 4.7.1, D3D12 Forward+, RTX 4070 Laptop GPU; production gameplay
scene, 1280×720, seed 24017, wind 18 m/s, full existing waves, foam and visual hull
waves enabled in both cases. Physical interaction is the on/off variable. Side
spray diagnostics and development journals are disabled identically. Each run has
eight seconds of driving warm-up followed by twelve seconds of measurement.
Vehicle collisions are disabled identically. Throttle is 0.65; standard camera
and normal driving remain active.

Order: 1 off/on, 4 on/off, 6 off/on, 12 on/off. These are short, single paired
runs per count, not statistical guarantees. Initial conditions/settings/inputs
are common; physical response changes trajectories and the following camera.
Consequently, the full-frame difference includes changed scene/VFX visibility
and scheduling, not only the analytic sampler. At 12 vehicles the baseline also
exceeds a normal physics-tick budget and frame catch-up strongly amplifies cost.

| Vehicles | Mean frame off → on (ms) | Frame p95 off → on (ms) | Mean render GPU off → on (ms) |
|---:|---:|---:|---:|
| 1 | 3.98 → 4.26 | 6.53 → 6.88 | 2.96 → 3.04 |
| 4 | 6.96 → 8.88 | 11.33 → 14.13 | 3.47 → 3.47 |
| 6 | 9.79 → 10.39 | 14.21 → 14.81 | 3.42 → 3.47 |
| 12 | 47.49 → 69.80 | 62.77 → 88.09 | 11.90 → 18.19 |

The four-vehicle pair also needs follow-up profiling: its larger difference is
not justified by the isolated sampling cost alone. **Twelve vehicles do not pass
a production performance gate.** The six-vehicle result is a useful prototype
measurement, not approval to enable the feature globally.

| Vehicles | Engine physics monitor mean off → on (ms) | All-thread process CPU off → on (ms CPU/s real) | Private RAM change off → on (MiB) |
|---:|---:|---:|---:|
| 1 | 3.64 → 3.62 | 936 → 896 | +0.20 → −0.07 |
| 4 | 10.38 → 14.76 | 1107 → 1064 | −0.07 → −0.07 |
| 6 | 12.59 → 13.15 | 1095 → 1066 | −0.07 → +0.36 |
| 12 | 21.92 → 22.07 | 1110 → 1076 | +0.02 → +0.06 |

CPU is summed across threads of the actual engine PID; 1000 ms CPU/s equals one
fully used core. Lower CPU/s with slower frames does not imply cheaper frames.
Private committed memory starts around 1462–1477 MiB. Working-set changes during
these windows stay below 0.48 MiB. The harness's accumulated frame rows also
contribute about 0.2–2.7 MiB of Godot static allocations. These short memory windows
show no large new growth; they cannot establish absence of a long-term leak.
Separate HullWaves GPU timestamp ranges were unavailable in this backend run;
the table reports the measured whole-viewport GPU time instead.

The first matrix was discarded for performance conclusions: its external monitor
followed Godot's console launcher rather than the engine PID, and development
capture journals distorted timings/memory, especially with twelve vehicles.
The corrected matrix uses the engine's own PID marker and disables those journals
in both configurations. A failed early baseline setup with foam disabled was
also discarded. Only `matrix_corrected` supplies the tables above.

## Isolated native calculation

Final production core, MSVC /O2, 128 packet fixtures and 14 points per vehicle;
16 warm-up iterations plus 192 measured iterations. Packet snapshot publication,
Godot transfer, sample composition, force evaluation and rendering are excluded.
This deliberately overlaps every track in the dense case.

| Vehicles | Sparse median (ms/tick) | Dense median (ms/tick) | Dense p95 (ms/tick) |
|---:|---:|---:|---:|
| 1 | 0.0045 | 0.0682 | 0.0716 |
| 4 | 0.0172 | 0.2757 | 0.3199 |
| 6 | 0.0252 | 0.4259 | 0.4692 |
| 12 | 0.0485 | 0.8518 | 0.9179 |

Maximum discrepancy against the independent study fixture is 7.05×10⁻⁷.
Integrated packet publication has a median cost of 0.222 / 0.447 / 0.433 /
0.502 ms per sampled physics tick for 1/4/6/12 vehicles. Sample evaluation and
publication are separate costs; neither replaces the integrated frame tables.

## Artifacts and remaining gates

- Raw corrected measurements: `temp/hull_wave_physics/matrix_corrected/`.
- Numerical contract: `temp/hull_wave_physics/contract.json`.
- Controlled trajectories: `temp/hull_wave_physics/response_zero/` and `response_wave/`.
- Native replay: `validation/native/hull_wave_core_check.cpp`, local study input
  `temp/physical_wake_study/native_fixture.txt`, result `temp/hull_wave_physics/core_result.json`.
- Final logs: `temp/hull_wave_physics/{authoring,contract_final,manual,runtime_final}.{out,err}`.
- Source packaging: `temp/hull_wave_physics/final_package/`; dependency audit passes
  for 464 addon files. Packaging is not a Linux physical-wave runtime certification.

Still needed before release: user visual/handling approval; repeated controlled
camera/trajectory profiling for four/twelve vehicles; extended memory/feedback
soak; turns, jump landings and own-wake crossings over the intended range of
artistic settings; platform rebuilds. Keep the feature opt-in until those gates
are met. The velocity cap bounds only added vertical flow, not all possible
forces caused by an extreme height or slope.
