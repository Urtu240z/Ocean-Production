# PHYS-CPU-LITE-1 — Report

**Overall status: PARTIAL.** The packed CPU Lite transform and reduced-grid mapping are validated, and the GPU `PHYSICAL_HEIGHTFIELD` matrix confirms near machine-precision agreement with Full CPU. Candidate B is now integrated as a selectable synchronous provider in the existing Jetski path and compared against Full CPU in same-phase open-ocean and storm runs. The existing vehicle constants were not changed. Gameplay acceptance remains open: contact-space errors are material, no visual/playability review was performed, and the requested i7-13650HX target is unavailable. Coastal and runtime weather-transition integration remain open.

## Gate summary

| Gate | Status | Evidence / remaining limit |
|---|---|---|
| HEIGHT + vertical velocity packed IFFT | **PASS** | Full-resolution parity and production packing checks pass. |
| One complex IFFT per active band | **PASS** | HEIGHT and VY are reconstructed from one complex inverse transform per active band. |
| Full-resolution CPU reference parity | **PASS** | All 65,536 texels per band at N=256 agree to floating-point roundoff. |
| Signed-bin mapping and isolated-mode phase | **PASS** | Reduced signed bins, Nyquist exclusions, and 64² analytical phase/wavelength cases pass. |
| Direct retained-spectrum values at texel centers | **PASS** | H/V errors remain at floating-point noise. |
| Off-grid interpolation characterized | **MEASURED; quality decision open** | Structured and random bilinear samples compared with direct sums of the same retained spectrum. |
| Candidate B vs full spectrum | **MEASURED; provisional** | Band and combined errors, spatial correlation, and extrema correspondence are reported below. |
| CPU performance | **PARTIAL** | Native 10k-update data and live-provider timings are from an i7-5820K; B has bursty native-IFFT tails. Target laptop is unavailable. |
| Optimized native build / SIMD | **PASS for measured path** | `template_release`, MSVC `/O2`, `NDEBUG`, AVX2 TU compiled and runtime AVX2 dispatch supported. |
| GPU `PHYSICAL_HEIGHTFIELD` open-ocean comparison | **CAPTURED; acceptable implementation parity** | 12 state/time cases, 1,536 identical XZ samples. CPU/GPU field disagreement is negligible; Lite differences track Lite-vs-full CPU reduction/interpolation. Production-fidelity decision remains open. |
| Jetski provider integration | **PASS for validation wiring** | Existing JetskiController, Jolt RigidBody, four buoyancy markers, propulsion point and water-force constants are shared across GPU, Full CPU and Lite B choices. |
| Controlled open-ocean gameplay A/B | **MEASURED; acceptance open** | A–G run with identical seed, transform, scripted input and deterministic 60 Hz wave clock. Contact errors and vehicle responses are recorded; no visual acceptance review. |
| Storm traversal | **MEASURED; acceptance open** | Same controlled A–H suite with the fixed Hs 3 m / wind 18 m/s fixture; no weather transition was exercised. |
| Shared-field scaling | **MEASURED** | Lite-only provider update plus synthetic batches of 4, 40 and 60 samples; see gameplay section below. |
| Coastal, runtime weather transitions, visual/breaker regression | **OPEN** | No Coastal CPU snapshot composition, transition/pause/resume tests, or visual review. |

## Scope and current architecture

The synchronous provider consumes the retained Production H0 snapshots, preserves the Production domain and `dk`, evolves HEIGHT and VERTICAL_VELOCITY at the current `OpenOceanFFT.get_wave_time()`, and samples CPU-resident fields. The selectable backends are GPU `PHYSICAL_HEIGHTFIELD`, Full CPU, and CPU Lite B. The same JetskiController and Jolt body are used in all modes. CPU Lite uses `q=worldXZ`, zero horizontal physical displacement, and the validated 1 cm centered finite-difference heightfield normal. The CPU path has no age-based stale-water force skip; a successful synchronous field is available each physics tick. No Coastal input is composed yet. No GPU readback, world-to-q inversion, root/fold ownership, or highest-Y reconstruction is used for CPU gameplay.

The source-to-lite coefficient mapping retains centered signed modes, excludes the reduced Nyquist boundary, scales H0 by `(N/256)^2`, and applies the tested sample-origin phase correction. The earlier `64.219 m` MID trough difference is an extremum switch after filtering, not a translated grid. It is not being treated as an FFT-origin defect.

## Direct-spectrum oracle: interpolation isolated from spectral reduction

The oracle directly sums the evolved retained HEIGHT/VY spectrum and analytic height gradient. This compares bilinear sampling of the reduced grid against the *same retained spectrum*, so the result is interpolation error only. It does not include the difference between the reduced and full Production spectra.

For Candidate B, 64 samples per pattern and band were taken at texel centers, half-cell offsets, quarter-cell offsets, deterministic fractional/random coordinates, and wrap boundaries. At texel centers the maximum observed H/V errors across candidates were below `2.63e-6 m` and `3.38e-6 m/s`. The off-grid error is measurable, especially for LONG height and SHORT vertical velocity:

| B band / resolution | Random H RMS / p95 / max (m) | Random VY RMS / p95 / max (m/s) | Random normal RMS / p95 / max (deg) |
|---|---:|---:|---:|
| LONG 128 | 0.03072 / 0.06167 / 0.08079 | 0.03979 / 0.08251 / 0.10272 | 0.896 / 1.694 / 2.128 |
| MID 128 | 0.00733 / 0.01356 / 0.02452 | 0.02292 / 0.04827 / 0.07600 | 1.018 / 1.970 / 2.688 |
| SHORT 64 | 0.00592 / 0.01024 / 0.01465 | 0.05224 / 0.11693 / 0.15719 | 2.778 / 4.670 / 5.329 |

Half-texel offsets generally increase these errors (for example LONG H RMS `0.04133 m`, p95 `0.07733 m`; LONG VY RMS `0.06131 m`, p95 `0.11675 m`). Quarter-cell and wrap cases were also captured. The texel-center normal discrepancy compares analytic retained-spectrum gradients with the grid sampler's finite-difference normal; it is not a location error. Raw pattern results are in `.godot/phys_cpu_lite_direct_oracle.json`.

## Candidate B against the full CPU Production reference

The comparison uses identical world XZ at simulation time `0.343977 s`, fixed 64×64 world coverage per band, and 4,096 deterministic world points for the combined field. The following error statistics are RMS / p95 / p99 / max. Normal errors are angular degrees.

| Band | Height error (m) | VY error (m/s) | Normal error (deg) | Zero-shift spatial correlation | Crest/trough correspondence |
|---|---:|---:|---:|---:|---|
| LONG 128 | 0.00950 / 0.01881 / 0.02485 / 0.03510 | 0.01544 / 0.03023 / 0.04045 / 0.05848 | 0.497 / 0.957 / 1.225 / 1.802 | 0.999037 | 34/34 significant full extrema retained and matched; displacement p95/max 2 m on the sampled z=0 line. |
| MID 128 | 0.00261 / 0.00504 / 0.00674 / 0.01136 | 0.00872 / 0.01699 / 0.02294 / 0.03744 | 0.525 / 0.909 / 1.153 / 1.371 | 0.998573 | 32/32 retained and matched; displacement 0 m on the sampled line. |
| SHORT 64 | 0.00927 / 0.01818 / 0.02388 / 0.03482 | 0.07179 / 0.13991 / 0.18200 / 0.25296 | 4.061 / 6.907 / 8.521 / 11.327 | 0.892894 | 31 of 43 significant full extrema matched; 12 disappear after filtering. Matched displacement p95 1.301 m, max 1.734 m. |
| Combined B | 0.02455 / 0.05075 / 0.07055 / 0.10500 | 0.08574 / 0.16697 / 0.22945 / 0.29875 | 4.346 / 7.576 / 9.106 / 12.512 | 0.998489 | Best cross-correlation translation is 0 m. |

The retained sub-Nyquist wavelength lower bounds are about LONG `8 m`, MID `2.14 m`, and SHORT `1.16 m` for the 512/137/37 m domains. Thus B removes LONG content below 8 m, MID content below 2.14 m, and SHORT content below 1.16 m, while SHORT64 also has the largest interpolation and velocity/normal error. Its high combined correlation does not erase the short-band loss; B removes 12 measured significant SHORT extrema in this sample.

Spatial phase is separated from changed amplitude/content with pointwise field errors, normalized z=0 profile correlation, cross-correlation over ±quarter-domain shifts, and nearby significant-extrema matching. For B, best translation is 0 m in all three bands and in the combined field. This replaces the unreliable single-deepest-trough metric; the legacy trough value is retained only as a diagnostic.

## Candidate alternatives E and F

All use the same retained Production spectrum. F is an N=2 DC-only SHORT proxy because a disabled-band API was not introduced; it should be read as “no propagating SHORT wave,” not a tested runtime disable flag.

| Candidate | Resolutions L/M/S | Mean / p95 / p99 / max update (ms) | Memory (MiB) | Key SHORT information lost vs full reference |
|---|---|---:|---:|---|
| B | 128/128/64 | 0.891 / 0.836 / 1.930 / 3.015 | 23.01 | 12 of 43 significant extrema disappear; SHORT H RMS 0.00927 m, VY RMS 0.07179 m/s. |
| E | 128/128/32 | 0.813 / 0.836 / 1.745 / 2.213 | 22.66 | 22 of 43 significant extrema disappear; 21 remain. SHORT cutoff rises to about 2.31 m. |
| F | 128/128/2 (DC proxy) | 0.809 / 0.923 / 1.968 / 2.714 | 22.54 | No significant SHORT extrema remain; SHORT has effectively no propagating modes. |

E saves about `0.08 ms` mean versus B and F about `0.08 ms`, with modest memory savings, while losing more measured SHORT chop. E's combined height error RMS/p95/max is `0.02854 / 0.05683 / 0.12837 m`, VY `0.12566 / 0.24955 / 0.43017 m/s`, and normal RMS/p95/max `5.032 / 8.816 / 13.745°`. F's corresponding errors are H `0.02932 / 0.05807 / 0.12960 m`, VY `0.12963 / 0.25690 / 0.43379 m/s`, and normal `5.065 / 8.860 / 13.847°`. B remains a better fidelity continuation candidate, not a selected gameplay configuration.

## Long-run performance and IFFT burst localization

The final local run used 300 warmups and 10,000 measured updates per candidate. Values are milliseconds. Candidate B's stage arrays and every update timing are retained in `.godot/phys_cpu_lite_prototype.json`.

| Candidate | Mean | p50 | p90 | p95 | p99 | p99.5 | p99.9 | Max | Stddev | >1.25 / >1.5 / >2.0 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| A 128/128/128 | 1.255 | 1.161 | 1.223 | 2.421 | 3.155 | 3.192 | 3.263 | 3.632 | 0.374 | 799 / 635 / 583 |
| B 128/128/64 | 0.891 | 0.857 | 0.884 | 0.905 | 1.930 | 2.186 | 2.393 | 3.015 | 0.192 | 321 / 280 / 83 |
| C 128/64/64 | 0.593 | 0.560 | 0.582 | 0.692 | 1.400 | 1.521 | 1.560 | 2.659 | 0.156 | 156 / 77 / 3 |
| D 64/64/64 | 0.268 | 0.261 | 0.272 | 0.279 | 0.588 | 0.715 | 0.733 | 0.936 | 0.054 | 0 / 0 / 0 |
| E 128/128/32 | 0.813 | 0.788 | 0.813 | 0.836 | 1.745 | 1.792 | 2.173 | 2.213 | 0.169 | 294 / 272 / 39 |
| F 128/128/2 | 0.809 | 0.768 | 0.795 | 0.923 | 1.968 | 2.104 | 2.142 | 2.714 | 0.206 | 413 / 367 / 97 |

B per-stage distributions (microseconds):

| Stage | Mean | p50 | p90 | p95 | p99 | p99.9 | Max |
|---|---:|---:|---:|---:|---:|---:|---:|
| Phase | 41.8 | — | — | 51 | 91 | 214 | 464 |
| Spectrum evolution | 111.1 | — | — | 120 | 208 | 263 | 282 |
| Packing | 103.3 | — | — | 113 | 268 | 293 | 329 |
| All IFFTs | 625.4 | 600 | 622 | 638 | 1,420 | 1,725 | 2,336 |
| Publication | 0.003 | — | — | — | — | — | 11 |

B per-band IFFT means/p95/p99/max in microseconds: LONG128 `281/294/635/1,052`; MID128 `283/294/641/1,053`; SHORT64 `61/70/152/253`. Of B's 321 updates above 1.25 ms, 302 have all three bands above their own IFFT p95; 72 have all three above their band p99. Only five are LONG-only above p95; none are MID-only or SHORT-only. Of the 83 updates over 2 ms, 81 have all bands above p95. The events are burst-clustered and irregular rather than a stable every-N pattern. Example >1.5 ms ranges: `202–209, 240–256, 265–274, 291–304, 340–346, 930–948, 1061–1069, 2119–2120, 3065–3072, 3098–3106, 4385–4417, 5920–5921, 6108–6146, 6471–6490, 6504–6511, 6588–6592, 6670–6715, 6879–6886, 6891–6897` (1-based update indices). The evidence points to a shared burst across transforms, not a single consistently slow band. It does not identify whether scheduling, power/frequency state, cache contention, or timing instrumentation causes the bursts.

The native stage timers are active in this benchmark and may contribute measurement overhead. No separate no-instrumentation control was run. The benchmark exposes outliers and their per-band IFFT times; it does not claim an external cause.

## Native build, SIMD, and allocation audit

The rebuilt Windows x86_64 extension loaded successfully. Effective build: Godot 4.7.1 `template_release`; MSVC 19.44.35229; Python 3.12.14; SCons 4.11.1; Windows SDK 10.0.26100. `godot-cpp` selects speed optimization (`/O2`) for this target and defines `NDEBUG`. The main native objects use that release environment; the dedicated AVX2 translation units are built with `/arch:AVX2`. Runtime diagnostics report AVX2 support true and the CPU Lite implementation selects the AVX2-dispatched path. Profiling timers are enabled in the measured path.

Code audit found configured coefficient, evolution, packed-spectrum, output, bit-reversal, twiddle, and FFT scratch buffers sized during setup/warmup. `build_lite` has no temporary vector construction in its steady-state path; publication swaps preallocated buffers. The runner preallocates timing telemetry, and creates slow-sample dictionaries only for threshold crossings. This is a source audit, not allocator instrumentation; no allocation-growth counter was added.

## GPU `PHYSICAL_HEIGHTFIELD` open-ocean matrix

The successful non-headless run uses D3D12 / Forward+ on an NVIDIA GTX 970. It tested 128 deterministic identical world-XZ samples at each of 3 times (`0.36`, `2.25`, `16.89` s) for Current Production, Calm, Normal, and Storm: 12 captures / 1,536 sample comparisons. CPU fields were rebuilt at the exact returned GPU field sample time. Points include interior locations and samples close to wrap boundaries. Normal comparisons use the GPU operator: centered 1 cm finite differences of height versus world XZ. This avoids comparing the GPU heightfield normal with the CPU material normal that includes horizontal displacement derivatives.

Synthetic state fixtures are Calm (Hs 0.8 m, wind 4 m/s, direction 20°, long chop 0.8), Normal (Hs 1.8 m, wind 8 m/s, direction 35°, chop 1.0), and Storm (Hs 3 m, wind 18 m/s, direction 75°, chop 2.0); Current Production uses the actual current Production band snapshots. These are static states at three times, not weather transitions.

Worst per-capture RMS / p95 / max over the matrix:

| Comparison | Height | Vertical velocity | Heightfield normal angle |
|---|---:|---:|---:|
| Full CPU vs GPU | 6.8e-6 / 1.24e-5 / 2.20e-5 m | 5.23e-6 / 1.15e-5 / 1.53e-5 m/s | 0.00061 / 0.00109 / 0.00144° |
| Lite B vs full CPU | 0.0500 / 0.1099 / 0.1720 m | 0.0918 / 0.1721 / 0.3078 m/s | 4.145 / 7.054 / 10.978° |
| Lite B vs GPU | 0.0500 / 0.1099 / 0.1720 m | 0.0918 / 0.1721 / 0.3078 m/s | 4.145 / 7.054 / 10.978° |

The first row is a strong GPU implementation-parity result for heightfield semantics. Lite-vs-GPU and Lite-vs-full CPU are effectively identical, so there is no material CPU/GPU implementation disagreement in the Lite result; the observed difference is the intended spectral reduction plus bilinear sampling. The worst Lite errors occur in the higher-energy state/time captures. Whether those are acceptable to jetski physics remains a product/gameplay decision, so this does not close the Candidate B quality gate. Raw details: `.godot/phys_cpu_lite_gpu_parity.json`.

The initial headless attempt correctly could not access the Global RenderingDevice async readback. The matrix was rerun with the normal renderer. During this work the runner was fixed so report finalization occurs after every state (rather than quitting inside the first state loop), Normal was changed to explicit valid fixture parameters, and CPU normals were changed to match the GPU heightfield-normal operator.

## Synchronous provider and controlled Jetski gameplay A/B

`gameplay/jet_ski_ocean.gd` now selects GPU `PHYSICAL_HEIGHTFIELD`, Full CPU, or Lite B while retaining the existing JetskiController, Jolt `RigidBody3D`, `JetSkiWaterPhysicsSystem`, four buoyancy contacts, and propulsion point. The CPU provider imports the current Production H0 snapshot and builds at `OpenOceanFFT.get_wave_time()` once per physics tick. Lite queries `q=worldXZ`, uses no horizontal physical displacement, and provides height, 1 cm centered heightfield normal, vertical surface velocity, signed depth and validity synchronously. There is no stale-age force-drop path. The optional oracle mode builds the other CPU field at the same time and samples it at the exact same contact position; it calculates observer support force using the existing constants but applies no observer force. No vehicle constants or handling code were retuned.

The live scene runner is `validation/physics/phys_cpu_lite_gameplay_runner.gd`. Full and Lite were run in separate processes with the same Production seed/state, initial rigid-body transform, control schedule, and deterministic wave clock: both start at 0.5 s and advance the authoritative OpenOceanFFT time by 1/60 s per physics tick, with physical wave-speed scale 1.0. This removes startup-time phase drift. Each backend drove the same existing vehicle once while the other CPU field observed the driver's current contacts. Seven normal-state scenarios covered stationary float, low/medium throttle, high speed, left/right turns, and drop/re-entry (1,320 ticks per run). Storm runs added a 300-tick traversal (1,620 ticks total) with Hs 3 m, wind 18 m/s, direction 75°, swell 0.8 and wave-height scale 1.16. Coastal and visual breakers were disabled for this open-ocean fixture. All paired runs reported zero CPU-field build failures and four valid buoyancy samples each physics tick.

For each scenario below, contact errors are p95 absolute errors at hull contacts where both fields are wet. Force is the per-contact support-force difference, not vehicle total force. Values are ranges across the seven normal-state scenarios or eight storm-fixture scenarios; H is metres, VY m/s, normal degrees, force kN.

| Fixture | H p95 range | VY p95 range | Normal p95 range | Support-force p95 range |
|---|---:|---:|---:|---:|
| Current Production | 0.060–0.134 | 0.476–0.565 | 18.8–22.1° | 0.57–1.20 |
| Storm fixture | 0.033–0.112 | 0.062–0.187 | 2.1–7.0° | 0.19–1.04 |

These errors are not implementation disagreement: the Full CPU/GPU correspondence gate already passed. They are the intentional reduced-spectrum/interpolation difference measured at where the hull actually samples the surface. They are large enough to alter local contact orientation and damping force, particularly in the normal Production state. In the deterministic Current Production runs, vehicle behavior remained in the same broad range: stationary mean body Y was -0.740 m Full / -0.717 m Lite, pitch RMS 0.196 / 0.189 rad, and mean wet contacts 3.54 / 3.52. Drop/re-entry ended at mean Y 1.003 / 1.006 m with p95 speed 7.84 m/s in both. High-speed case mean Y differed by 0.295 m (0.274 / -0.021 m), with p95 speed 11.50 / 12.08 m/s. Storm traversal mean Y was 0.057 / 0.063 m and p95 speed 18.03 / 18.22 m/s. The trajectories remain controlled and similar at this duration, but contact force deltas reach over 1 kN p95 in some scenarios. That is enough to keep B provisional pending hands-on/visual handling review; no visual playback was captured here, so “no pass-through” and perceived chop/launch quality are not claimed.

The driver samples the propulsion point as a separate fifth location. Its water height, normal, velocity and depth are logged; support-force delta is zero there because that point does not receive the buoyancy spring force. Raw paired positions and samples, including wet flags, are captured in `.godot/phys_cpu_lite_gameplay_{full,lite}{,_storm}.json` for local review.

### Lite-only field and 10-craft sampling cost

An additional Lite-only run removes the Full CPU observer, isolating selected-backend field and lookup costs on the current Intel i7-5820K / GTX 970 workstation. Values are microseconds from the live Godot provider, not the native microbenchmark.

| Metric | Mean | p95 | p99 | Max |
|---|---:|---:|---:|---:|
| Lite field update, 1 shared field | 1,173 | 2,664 | 3,129 | 5,570 |
| Contact sample call | 33.8 | 35 | 39 | 67 |

| Synthetic batch | Mean batch time | Mean per contact |
|---|---:|---:|
| 1 craft × 4 contacts | 158 µs | 39.6 µs |
| 10 craft × 4 contacts | 1,663 µs | 41.6 µs |
| 10 craft × 6 contacts | 2,417 µs | 40.3 µs |

This demonstrates one shared field update plus approximately linear contact lookups: on this host, 10 craft × 6 contacts costs about 2.42 ms of sampling plus 1.17 ms mean shared-field generation. Adding the measured field p95 to mean sampling gives about 5.08 ms as a rough budget estimate, not a joint percentile measurement. It is within a 16.67 ms tick on this older host, but does not predict the requested i7-13650HX result.

## Target hardware procedure

The target Intel i7-13650HX / RTX 4070 Laptop is not available here; no timing extrapolation is made. From the repo root on that system, use the same Godot 4.7.1 console build and run:

```powershell
$godot = 'C:\path\to\Godot_v4.7.1-stable_win64_console.exe'
& .\validation\physics\setup_native_windows.ps1 -GodotExe $godot
if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
& $godot --headless --log-file "$PWD\.godot\phys_cpu_lite_target.log" --path "$PWD" --script 'res://validation/physics/phys_cpu_lite_prototype_runner.gd'
```

The runner itself fixes the candidate list A–F, Production H0/configuration, seed and sample timing, 300 warmups, 10,000 measured updates, stage timings, machine/build metadata, and percentiles. Capture `.godot/phys_cpu_lite_prototype.json` from that machine and compare the same fields above. The GPU is recorded for machine completeness but does not participate in the CPU transform benchmark. The 1 ms p95 is a preferred engineering target, not an architecture kill threshold; evaluate absolute cost, tail stability, target performance, shared-field scaling, and fidelity together.

## Remaining integration boundaries

The target Intel i7-13650HX / RTX 4070 Laptop has not been measured. The selected field and synthetic batch timings above are only from the current i7-5820K workstation; no extrapolation is made. The integrated gameplay provider is still validation-only. Coastal snapshot composition, transitions among weather states, direction changes, pause/resume, wave-speed changes during play, and visual/breaker regression have not been run. No planing, slamming, breaker impulse, or other hydrodynamic model was added.

## Result

**PHYS-CPU-LITE-1 remains PARTIAL.** Core packed FFT correctness and Full CPU/GPU open-ocean correspondence pass. The actual Jetski path has selectable GPU/Full CPU/Lite providers, and deterministic Production/Normal/Storm contact replays are complete. B is the baseline; LONG+SHORT is the strongest tested reduced candidate but remains provisional because Production normal error is still material, hands-on handling has not been reviewed, and target-machine performance is unknown. Keep Coastal and weather-transition work open.

## Contact-trace replay, band attribution, and direct gradients (2026-10-06)

These fixed-trajectory replays supersede divergent-body comparisons as the primary water-fidelity evidence. Full CPU drove the craft; each tick recorded the same body pose/velocity, four hull-contact world positions and contact velocities, scenario label, time, and authoritative Full sample. Replays froze vehicle physics and rebuilt each Lite candidate at the recorded time before querying the same positions. Captures contain 1,319 ticks / 5,276 contacts for Current Production and Normal, and 1,619 / 6,476 for Storm. The first settling tick is absent from the contact trace. Every candidate's complete per-metric mean, RMS, p90, p95, p99, max, scenario breakdown, force components, and build/query profile is in the corresponding `.godot/phys_cpu_lite_contact_replay_{current_production,normal,storm}.json`.

The table gives all-contact p95 absolute error (height/depth metres, vertical velocity m/s, normal degrees, support force N). Each variant starts from B and restores the named band; `LONG+SHORT` is the single combined follow-up after the individual attribution.

| Trace state | Variant | Height / depth | VY | Normal | Support force |
|---|---|---:|---:|---:|---:|
| Production | B 128/128/64 | 0.0997 | 0.5159 | 21.33 | 773 |
| Production | B+LONG 256/128/64 | 0.0686 | 0.5041 | 21.37 | 669 |
| Production | B+MID 128/256/64 | 0.0987 | 0.5130 | 20.94 | 761 |
| Production | B+SHORT 128/128/128 | 0.0768 | 0.2268 | 17.00 | 503 |
| Production | LONG+SHORT 256/128/128 | 0.0290 | 0.1912 | 16.76 | 263 |
| Normal | B 128/128/64 | 0.0648 | 0.0951 | 2.82 | 413 |
| Normal | B+LONG | 0.0040 | 0.0239 | 1.19 | 33 |
| Normal | B+MID | 0.0645 | 0.0948 | 2.72 | 408 |
| Normal | B+SHORT | 0.0650 | 0.0931 | 2.66 | 413 |
| Normal | LONG+SHORT | 0.0032 | 0.0142 | 1.01 | 23 |
| Storm | B 128/128/64 | 0.0849 | 0.1347 | 5.63 | 468 |
| Storm | B+LONG | 0.0041 | 0.0222 | 1.10 | 32 |
| Storm | B+MID | 0.0844 | 0.1338 | 5.64 | 469 |
| Storm | B+SHORT | 0.0847 | 0.1316 | 5.55 | 461 |
| Storm | LONG+SHORT | 0.0034 | 0.0135 | 0.94 | 23 |

**Attribution changes with the spectrum state.** LONG restoration dominates Normal and Storm; MID and SHORT restoration alone barely change those traces. Current Production is different: LONG mostly reduces height, SHORT substantially reduces VY and normal error, and the combined candidate improves all four measures. LONG+SHORT is the best tested reduced field across all three traces, while costing about 2.9–3.1 ms mean native field-build time on the i7-5820K during these replay loops. It is provisional: Production still has a 16.76° p95 normal error. Per-scenario high-speed/drop-re-entry numbers are retained in the JSON; for example, Production LONG+SHORT gives 29 mm / 0.170 m/s / 18.04° / 465 N at high speed and 31 mm / 0.164 m/s / 13.10° / 256 N during drop/re-entry. In Normal these become 3 mm / 0.012 m/s / 0.96° / 28 N and 3 mm / 0.014 m/s / 0.90° / 20 N; in Storm, 3 mm / 0.010 m/s / 1.00° / 51 N and 4 mm / 0.015 m/s / 0.79° / 25 N.

### Normal operator attribution

Lite's normal is the analytic derivative of its periodic bilinear height cell. Against Lite's previous centered 1 cm finite difference, angular p95/max was 0.623°/15.20° in Production, 0.013°/1.86° in Normal, and 0.067°/4.73° in Storm. The outliers cluster around interpolation-cell boundaries; the typical difference is much smaller. The Lite centered-difference normal against the validated Full CPU/GPU 1 cm heightfield operator had p95/max 21.21°/39.59°, 2.82°/5.30°, and 5.63°/8.35° respectively. Thus finite-difference semantics explain little of the Production p95 error: reduced spectral content plus bilinear reconstruction dominate. Restoring SHORT helps Production by about 4.3°, but does not eliminate its remaining normal discrepancy; LONG dominates the Normal/Storm normal error. GPU and Full CPU semantics remain closed and unchanged.

### Force and contact-query cost

The replay holds contact positions and contact velocity fixed. The current vertical support law does not use the surface normal; its force difference comes from signed depth/height and water VY passed through the spring/damper and wet clamp. The runner reports the height-only and velocity-only force components separately (the p95 values are not additive because the force law clamps). It times three force-law evaluations per recorded contact—Full, height-only, and Lite—to form that decomposition: about 5.8–7.6 µs/contact for all three on this host, roughly 1.9–2.5 µs for one call. Contact/body velocity is identical across variants.

The prior 2.417 ms synthetic 60-contact lookup figure came from the pre-optimization query path and is superseded. One optimized native call now handles an arbitrary contact batch. A provider batch maps each band cell once, reads four packed complex texels per band once, and derives height, VY, and gradient from those values. Across three bands this is 12 complex texel reads/contact, three height and three VY bilinear interpolations, with direct-gradient algebra fused into the same loop. The normal adds no height samples and no FFT. A contact batch crosses GDScript/native once, not once per point. The existing per-vehicle integration submits one four-contact batch per craft; a shared 60-point call is also measured and supported by the API.

| Lite layout | Calls per round | Mean round wall | Mean/contact | Native query/contact | Provider/GDScript overhead/contact |
|---|---:|---:|---:|---:|---:|
| 1 craft × 4 | 1 | 20.1 µs | 5.03 µs | 0.050 µs | 3.41 µs |
| 10 craft × 4, global batch | 1 | 179.9 µs | 4.50 µs | 0.211 µs | 3.30 µs |
| 10 craft × 4, per-craft batches | 10 | 231.8 µs | 5.79 µs | 0.048 µs | 4.10 µs |
| 10 craft × 6, global batch | 1 | 285.7 µs | 4.76 µs | 0.207 µs | 3.60 µs |
| 10 craft × 6, per-craft batches | 10 | 323.9 µs | 5.40 µs | 0.186 µs | 3.76 µs |
| 100 contacts, global batch | 1 | 443.0 µs | 4.43 µs | 0.200 µs | 3.31 µs |
| 100 contacts, ten batches of 10 | 10 | 507.4 µs | 5.07 µs | 0.203 µs | 3.68 µs |

Times are from 20 rounds on the i7-5820K, with position/sample validation included in round wall time. For the realistic ten-craft/six-contact case, batching per craft costs about 0.324 ms and one global batch about 0.286 ms, versus the prior ~2.42 ms. Native work is about 11–12 µs total for 60 contacts; provider result conversion/call overhead is the larger share. The direct-normal arithmetic is fused and has no separate standalone timer; its whole native cost is bounded by the reported ~0.20 µs/contact query average, including coordinate mapping, packed reads, interpolation, and sample packing.

The selected B live run measured field update mean/p95/p99/max 1.109/1.379/2.088/6.414 ms on this machine. Field generation remains separate from sampling. Replay field-build percentile distributions are in the state JSONs; the LONG+SHORT candidate's native mean/p95/p99/max was approximately 3.0/5.6/5.8/6.7 ms. Neither result predicts target hardware.

### Manual open-ocean A/B and remaining gates

`gameplay/jet_ski_ocean.tscn` now starts on Full CPU. Drive with W/S and A/D. Press **1** for Full CPU, **2** for Lite B+LONG (256/128/64), **3** for Lite LONG+SHORT (256/128/128), and **4** for Lite 128/128/128 all-band cubic. Switching keeps the same provider, body pose/velocity, controls, camera, vehicle constants, and evolving ocean state; the new field is built on the next physics contact tick. The overlay shows field-update p95, latest contact-query wall time, wet-contact count, and speed. F3 toggles contact markers; R resets the craft. This is ready for the required hands-on same-course review, but no human gameplay acceptance has been recorded.

**Status remains PARTIAL.** Before the cubic replay, LONG+SHORT was the strongest tested reduced candidate. The phase addendum below supersedes that ranking for Current Production and preserves LONG256 as the lower-error option in Normal and Storm. No production choice is accepted; target i7-13650HX timing and manual handling review are outstanding. Coastal and runtime weather transitions remain out of scope until these gates close.

## 2026-10-06 — spectrum vs reconstruction and periodic cubic sampling

### Actual Production spectral support

Measured from the exact Current Production H0 RGBA32F snapshots uploaded by `OpenOceanFFT`; no nominal spectrum substitute or new seed was used. “Meaningful” means an individual mode's phase-averaged height power is at least `1e-8` of its band's total height power. The active range is the nonzero H0 mode range; the taper range is the band weight's nonzero interval. Wavelengths are meters.

| Band | Domain | H0 active wavelengths | Meaningful wavelengths | Taper support |
|---|---:|---:|---:|---:|
| LONG | 512 m | 12.008–128 | 12.578–128 | 12–132 |
| MID | 137 m | 3.254–20.423 | 3.374–20.423 | 3.25–20.75 |
| SHORT | 37 m | 0.350–5.131 | 0.401–5.131 | 0.35–5.15 |

For each resolution, `dx = domain/N`, axis Nyquist wavelength is `2*dx`; the shortest diagonal-corner wavelength is also listed because square-grid corners can retain shorter radial waves than the axis Nyquist suggests.

| Band | N | dx | Axis Nyquist | Corner wavelength | Height power retained | VY power retained |
|---|---:|---:|---:|---:|---:|---:|
| LONG | 64 | 8.000 | 16.000 | 11.679 | 99.937% | 99.802% |
| LONG | 128 | 4.000 | 8.000 | 5.747 | 100.000% | 100.000% |
| LONG | 256 | 2.000 | 4.000 | 2.851 | 100.000% | 100.000% |
| MID | 64 | 2.141 | 4.281 | 3.125 | 99.768% | 99.370% |
| MID | 128 | 1.070 | 2.141 | 1.538 | 100.000% | 100.000% |
| MID | 256 | 0.535 | 1.070 | 0.763 | 100.000% | 100.000% |
| SHORT | 64 | 0.578 | 1.156 | 0.844 | 93.683% | 82.403% |
| SHORT | 128 | 0.289 | 0.578 | 0.415 | 99.797% | 99.133% |
| SHORT | 256 | 0.145 | 0.289 | 0.206 | 100.000% | 100.000% |

The source uses centered 256×256 bins and retains only bins with `abs(kx) < N/2` and `abs(ky) < N/2` for an N-grid field. Thus N=64 retains 3,969 source bins and discards 61,567; N=128 retains 16,129 and discards 49,407; N=256 retains 65,025 and discards the 511 Nyquist-edge bins. These are per-band counts. At N=128, the removed LONG/MID bins have effectively zero actual Production H0 power; at SHORT64, removed bins include the nonzero high-frequency tail quantified by the energy fractions above.

LONG128 and MID128 retain every mode with measurable power at the stated threshold; their residual discarded power rounds below the shown precision. LONG256 therefore does not gain meaningful Production frequency content over LONG128. SHORT64 does discard real content, particularly `17.60%` of VY spectral power; SHORT128 retains `99.13%` of it. At 128, LONG/MID error is reconstruction error, while SHORT has both spectral and reconstruction error.

### Direct-spectrum loss vs grid reconstruction

The decomposition runner used eight evenly spaced tick groups from the same Current Production, Normal, and Storm Full CPU trajectories (32 real contact positions/state). It evaluated the Full Production direct spectrum, the exact retained-spectrum direct oracle, and the retained grid at identical XZ/time. Error summaries below are p95 absolute errors. Gradient-normal angles are computed per band (they are not additive).

Current Production, 128/128/128 bilinear:

| Band | Spectral H | Spectral VY | Spectral normal | Grid H | Grid VY | Grid normal |
|---|---:|---:|---:|---:|---:|---:|
| LONG | <1e-12 m | <1e-12 m/s | 0° | 0.0759 m | 0.1173 m/s | 3.01° |
| MID | <1e-12 m | <1e-12 m/s | 0° | 0.0235 m | 0.0552 m/s | 3.59° |
| SHORT | 0.00905 m | 0.1143 m/s | 5.31° | 0.0179 m | 0.2246 m/s | 12.88° |

With SHORT64, its p95 spectral errors rise to 0.0407 m, 0.3378 m/s, and 18.18°. For LONG256/128/128 bilinear, LONG's spectral error remains zero while LONG grid reconstruction falls to 0.0200 m / 0.0313 m/s / 1.27°. This directly attributes LONG256's gain to spatial sampling density, not restored frequency content. For 128 cubic, p95 grid errors improve to LONG 0.0143 m / 0.0246 m/s / 0.73°, MID 0.00572 m / 0.0290 m/s / 1.20°, and SHORT 0.0123 m / 0.1272 m/s / 8.48°.

All-band p95 decomposition is captured in `validation/physics/results/phys_cpu_lite_error_decomposition_{current_production,normal,storm}.json`. In Current Production, 128 bilinear has all-band spectral H/VY/normal p95 0.00730 m / 0.0707 m/s / 5.11°, against reconstruction p95 0.0702 m / 0.1468 m/s / 11.39°. With cubic, reconstruction falls to 0.0123 m / 0.1092 m/s / 7.64°; the remaining dominant normal spectral error comes from SHORT. With 256 LONG, LONG reconstruction improves but SHORT's sampling error remains. Normal and Storm 128 cubic all-band spectral errors are small (Normal 0.00034 m / 0.0030 m/s / 0.28°; Storm 0.00028 m / 0.0032 m/s / 0.19°); their residual is also mostly interpolation, especially SHORT.

### Cubic derivative validation and real contact replay

Periodic 4x4 separable Catmull-Rom now samples H and VY using the same polynomial and returns analytic `dH/dx,dH/dz`; normal is `normalize(-dH/dx,1,-dH/dz)`. No extra epsilon-offset production queries are made. At 36 real contacts, analytic derivatives compared with a centered 1 mm finite difference of the same cubic reconstruction give `dh/dx` absolute error p95 `1.07e-5`, `dh/dz` p95 `1.16e-4`, and normal angle p95/max `0.0062°/0.0081°`. This validates the derivative implementation, not equivalence to the Full CPU's separate 1 cm normal operator.

Same-contact trajectory results below show p95 `height / VY / normal / support force` errors. Full mean, RMS, p90, p95, p99, and max distributions for all requested measures are in `validation/physics/results/phys_cpu_lite_contact_replay_{current_production,normal,storm}.json`; the spectral retention input is `validation/physics/results/phys_cpu_lite_spectral_support.json`.

| Trace | 128/128/128 bilinear | 256/128/128 bilinear | 128/128/128 cubic all bands | 128 cubic LONG+MID, SHORT bilinear |
|---|---:|---:|---:|---:|
| Current Production | 0.0768 m / 0.227 m/s / 17.00° / 503 N | 0.0290 / 0.191 / 16.76 / 263 | **0.0198 / 0.132 / 11.11 / 181** | 0.0238 / 0.176 / 16.52 / 241 |
| Normal | 0.0650 / 0.0931 / 2.66 / 413 | **0.0032 / 0.0142 / 1.01 / 23** | 0.0121 / 0.0246 / 1.47 / 78 | 0.0122 / 0.0246 / 1.57 / 78 |
| Storm | 0.0847 / 0.132 / 5.55 / 461 | **0.0034 / 0.0135 / 0.94 / 23** | 0.0217 / 0.0356 / 2.99 / 137 | 0.0217 / 0.0358 / 3.02 / 138 |

The cubic reconstruction beats the 256 LONG candidate on all four Current Production p95 measures, and lowers Production normal p95 from 16.76° to 11.11°. It substantially improves the baseline in all three replay states. It does not match 256/128/128 in the Normal and Storm traces: longer-wave contact error remains visibly lower with LONG256. The previous 16.76° Production normal error divides into substantial LONG/MID/SHORT bilinear reconstruction error and SHORT truncation; cubic reduces the reconstruction component, while SHORT spectral loss remains. Thus the new best Production result is reconstruction-limited less than before, but is not a universal replacement for LONG256 under the tested Normal/Storm traces.

### Field, IFFT, and shared 60-contact cost

Replay timing is native build time plus a separately measured 60-contact one-batch provider wall time (200 measured batches after 20 warmups), collected on the i7-5820K. Total is the mean native field build plus mean 60-contact wall query; use as a relative local comparison, not target hardware acceptance. Times are milliseconds. Per-band IFFT rows are mean/p95 in LONG/MID/SHORT order.

| Candidate | Field mean / p50 / p90 / p95 / p99 / max | Per-band IFFT mean / p95 | 60-contact batch mean / p95 | Mean field + batch |
|---|---:|---:|---:|---:|
| A 128/128/64 bilinear | 0.832 / 0.828 / 0.846 / 0.854 / 1.005 / 1.414 | 0.252/0.266, 0.253/0.267, 0.056/0.066 | 0.396 / 0.485 | 1.228 ms |
| B 128/128/128 bilinear | 1.287 / 1.139 / 1.819 / 2.496 / 3.052 / 3.168 | 0.289/0.579, 0.289/0.590, 0.290/0.584 | 0.261 / 0.280 | 1.547 ms |
| C 256/128/128 bilinear | 2.796 / 2.697 / 2.818 / 2.927 / 5.678 / 6.998 | 1.243/1.265, 0.270/0.281, 0.270/0.281 | 0.208 / 0.263 | 3.004 ms |
| D 128/128/128 cubic all bands | 1.193 / 1.137 / 1.182 / 1.425 / 2.833 / 3.245 | 0.270/0.292, 0.267/0.307, 0.268/0.330 | 0.265 / 0.292 | 1.458 ms |

The cubic query adds about 4 µs to a 60-contact batch versus 128 bilinear in this sample, while avoiding LONG's 256² transform. Relative to 256/128/128, 128 cubic cuts measured mean field-plus-batch from 3.00 to 1.46 ms (about 51%) and improves Current Production contact p95. Field cost alone is not the decision metric. Tail spikes are visible, so the benchmark remains provisional pending target hardware and longer steady-state profiling.

### Phase decision

Evidence answers the core question for Current Production: 128 LONG contains the useful spectrum, and cubic reconstruction more than recovers the contact p95 lost to 128 bilinear while costing about half of 256 LONG's shared field/query total. That supports option A for the tested Production contact trajectory. It does **not** establish universal parity: Normal and Storm traces still favor 256 LONG, so option C (128 all-band cubic as a Pareto candidate; 256 LONG as the higher-fidelity fallback) is the defensible phase result until the user drives the manual A/B and target hardware is measured. No production configuration is selected. Manual gameplay acceptance remains pending; no vehicle constants changed; target i7-13650HX validation remains open; Coastal/weather remain deferred. Overall status: **PARTIAL**.

## 2026-10-06 — Normal/Storm attribution and manual gate setup

### Full trajectory comparison and error attribution

A focused replay paired all recorded contacts against 128/128/128 cubic and 256/128/128 bilinear. The 256 candidate has lower absolute normal error at 3,810/5,276 Normal contacts (72%) and 5,118/6,476 Storm contacts (79%). It wins height at 87%/92% and VY at 66%/81%, respectively. This is a trajectory-distribution result; the smaller 32-contact direct-oracle subset is not a substitute for the full replay.

The remaining gap is **not spectral loss**. Both candidates retain the same Fourier support in Normal/Storm; only LONG resolution and the interpolation family differ. The `128 cubic LONG+MID, SHORT bilinear` replay is nearly the same as all-band cubic in Normal (p95 H/VY/N/force `0.0122 m / 0.0246 m/s / 1.57° / 78 N` vs `0.0121 / 0.0246 / 1.47 / 78`) and Storm (`0.0217 / 0.0358 / 3.02° / 138 N` vs `0.0217 / 0.0356 / 2.99° / 137`). Cubic SHORT therefore does not explain the difference. Earlier MID-resolution restoration also had little contact effect. The evidence points mainly to **LONG spatial reconstruction in the trajectory tails**, particularly where the craft encounters rapid VY changes; 256 LONG's denser grid tracks those changes more closely against the Full CPU contact reference.

The high-slope bucket does not explain the residual. In Normal, cubic normal-error p95 is 1.57° in the highest-slope decile and 1.46° in the other 90%; in Storm it is 2.29° versus 3.04°. By contrast, for the highest decile of encountered Full CPU VY change rate (same contact slot across adjacent ticks, so this includes movement through the field), cubic vs 256 VY-error p95 is 0.0262 vs 0.0133 m/s in Normal and 0.0426 vs 0.0145 m/s in Storm. This is a useful Storm tail-risk signal, not an isolated temporal derivative at a fixed world coordinate.

Worst-contact records and local cell inspection are saved in `validation/physics/results/phys_cpu_lite_extrema_normal.json` and `..._storm.json`. Each selected contact includes the Full CPU reference, both candidate values, analytic cubic gradient, per-band direct values, the periodic 4×4 H/VY stencil, and the contact's fractional location in each band cell. A 9×9 sweep through each selected contact's cell compares cubic and bilinear ranges with the direct band-limited reference. Across inspected worst contacts, cubic extends beyond that reference range by at most **0.54 mm in height** and **0.00211 m/s in VY**, both in SHORT; Normal maxima are 0.25 mm and 0.00175 m/s. These excursions are small relative to trajectory errors and do not explain the Normal/Storm gap. The selected worst-normal contacts are not consistently at sharp extrema, and error is not concentrated in high-slope regions. No meaningful cubic ringing/overshoot problem was found in this inspection.

### Manual sea-state launch and telemetry

The Jetski validation scene supports the same fixed start pose and camera, with `simulation_seed=1` and a fresh ocean clock on each launch. Select the exported `validation_sea_state` on the scene root (`Current Production`, `Normal`, `Storm`), or pass `--phys1-state=current`, `--phys1-state=normal`, or `--phys1-state=storm` as Godot user arguments when launching `res://gameplay/jet_ski_ocean.tscn`. State parameters are applied before `Production/Ocean` enters the tree and initializes its spectrum; vehicle constants remain untouched. The HUD shows the selected state and wave time so repeated starts can be aligned.

Candidate keys: **1 Full CPU**, **2 B+LONG 256/128/64**, **3 LONG+SHORT 256/128/128 bilinear**, **4 128/128/128 cubic**. Compare 1 vs 4 first, then 1 vs 3. Drive W/S and A/D; R resets the craft. Manual sampling writes one row per second to `.godot/phys_cpu_lite_manual_<state>_<timestamp>.csv` with backend, sea state, wave time, field update, contact query, velocity XYZ, pitch, roll, wet-contact count, and airborne state. This sampling rate is intended to keep logging lightweight.

**Manual Full-vs-Cubic results: PENDING USER DRIVE. Manual Full-vs-256 results: PENDING USER DRIVE.** No handling judgment has been inferred from automated replay data. The current open-ocean candidate remains provisional 128/128/128 cubic; do not lock the architecture or begin Coastal/weather integration until the user reports the three-state driving comparison. `TARGET HARDWARE PERFORMANCE = OPEN`; i7-5820K figures remain relative evidence. Overall status remains **PARTIAL**.
