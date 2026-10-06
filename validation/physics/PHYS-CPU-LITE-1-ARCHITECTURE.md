# PHYS-CPU-LITE-1 — Architecture Gate

**Decision: continue validating a synchronous reduced CPU heightfield. Overall status: PARTIAL.** The packed FFT representation, reduced-bin mapping, and Full CPU/GPU `PHYSICAL_HEIGHTFIELD` correspondence are supported by direct measurements. B (128/128/64) remains the baseline; fixed-trajectory contact replay now points to LONG+SHORT (256/128/128) as the strongest tested reduced candidate across Current Production, Normal, and Storm. Candidate selection is provisional: Production normal error remains material, target-hardware timing and human gameplay review are still open.

## Chosen mathematical shape

- Reuse the final Production H0 snapshots, domain sizes, gravity, wave time, and weather-composed spectrum supplied by the existing open-ocean path.
- Keep q equal to world XZ; physical horizontal displacement is not inverted and has no root/fold ownership step.
- Retain signed centered modes from the 256 source grid, with unchanged domain and `dk`; exclude reduced Nyquist aliases consistently.
- Scale retained coefficients by `(Nlite/Nsource)^2` to account for the normalized inverse FFT. Apply the validated source-to-lite sample-origin phase correction.
- Evolve HEIGHT and VERTICAL_VELOCITY as a Hermitian pair packed into one complex inverse FFT per active band. Publish CPU-resident fields and sample them bilinearly.
- GPU `PHYSICAL_HEIGHTFIELD` remains a comparison oracle only. It is not gameplay authority and does not change the CPU Lite design.

This retains the deliberate simple single-valued field. No GPU readback authority, world-to-q inversion, roots, fold ownership, highest-Y, or upper-envelope reconstruction is part of CPU Lite.

## Evidence already closed

| Gate | Result |
|---|---|
| HEIGHT + VY packing and one IFFT per active band | **PASS** |
| Full-resolution parity to the existing CPU Production field at N=256 | **PASS**, 65,536 texels per band within floating-point roundoff |
| Signed reduced-bin map, scaling, and Nyquist handling | **PASS** |
| 64² single-mode wavelength/phase/origin checks | **PASS** |
| Direct retained-spectrum at reduced texel centers | **PASS**, H/V errors at floating-point noise |
| Old 64.219 m MID trough discrepancy | **Explained** as changed extremum identity after filtering; it was not an FFT translation |
| GPU `PHYSICAL_HEIGHTFIELD` vs full CPU | **PASS for open-ocean implementation parity** across 4 static states, 3 times, and 1,536 shared world positions; max H error 22 µm, max VY error 16 µm/s, matched heightfield-normal error 0.0015° |

## Quality is separate from mapping correctness

The direct-spectrum oracle isolates reduced-grid bilinear interpolation from spectral truncation. Texel-center values correspond. Off-grid interpolation has material error in B, especially for LONG height and SHORT VY. Candidate B vs the full CPU field also drops SHORT content: 12 of 43 significant SHORT extrema disappear in the tested z=0 profile; its SHORT zero-shift correlation is 0.8929. LONG and MID zero-shift correlations are 0.9990 and 0.9986. Combined correlation is 0.9985 with best translation zero. Thus there is no global phase shift, but there is real amplitude/content loss. See [PHYS-CPU-LITE-1-REPORT.md](PHYS-CPU-LITE-1-REPORT.md) for all error percentiles, off-grid patterns, and GPU comparisons.

E (128/128/32) and F (128/128/2 DC-only SHORT proxy) reduce mean cost about 0.08 ms on the local CPU but lose more SHORT extrema: E retains 21/43; F retains none. This supports B as the fidelity-first candidate for further evaluation, not as an approved production configuration.

## Performance and build gate

A final 10,000-update run per candidate followed 300 warmups on an Intel i7-5820K / GTX 970 host. B measured mean 0.891 ms, p50 0.857, p90 0.884, p95 0.905, p99 1.930, p99.9 2.393, max 3.015 ms. 302/321 updates above 1.25 ms had all three band IFFTs above their own p95; these are clustered irregular shared bursts, not a stable single-band slowdown. The external cause is unknown. The run used an optimized `template_release` MSVC `/O2` build with `NDEBUG`; AVX2 translation units and runtime dispatch were active. Native steady-state allocation was source-audited, not allocator-instrumented. Full stage distributions and outlier ranges are in the report.

**CPU performance stays PARTIAL.** This host is not the requested Intel i7-13650HX / RTX 4070 Laptop. No extrapolation is valid. The report gives an exact repeatable target-host PowerShell command for the same candidates and 300/10,000 update counts. The GPU is metadata only for the CPU timing run. Evaluate absolute cost, tails, shared-field scaling, and wave fidelity; the preferred 1 ms p95 is not a hard architecture rejection threshold.

## Gameplay-provider gate

The real Jetski scene has a selectable GPU `PHYSICAL_HEIGHTFIELD`, Full CPU, or Lite B provider. All choices drive the same JetSkiController, Jolt body, four buoyancy contacts and propulsion point; no support/damping/drive/steering constants changed. The CPU provider imports current Production H0 snapshots, rebuilds synchronously from `OpenOceanFFT.get_wave_time()` once per physics frame, and has no stale-sample age skip. Lite keeps `q=worldXZ` and zero horizontal physical displacement, and its normal follows the GPU heightfield operator.

Deterministic Full-vs-Lite scripted runs now cover stationary float, low/medium throttle, high speed, left and right turns, drop/re-entry, and a fixed storm traversal. Runs start at wave time 0.5 s and advance the ocean clock by exactly 1/60 s per physics tick with physical wave speed 1.0. Both fields are sampled at each driver's same contact coordinates and time. Provider field failures were zero and four contact locations remained valid per physics tick.

The craft-level comparison does not yet accept B. For the current Production fixture, per-scenario p95 absolute error across both-wet hull samples spans 6–13 cm in height, 19–22° in normal, and 0.48–0.57 m/s in vertical velocity; per-contact support-force p95 reaches 1.20 kN. On the storm fixture those ranges are lower for most measures (3–11 cm, 2–7°, 0.06–0.19 m/s; force up to 1.04 kN). Short-run body response is broadly similar, including stationary float, drop/re-entry and storm traversal, yet p95 hull force deltas can materially affect damping and contact orientation. No visual playback or human handling review was performed, so do not mark quality PASS from metrics alone. Full scenario statistics and raw capture paths are in the report.

The prior 2.417 ms Lite 60-contact lookup is superseded by the optimized direct-gradient batch path: the repeat measured 0.286 ms for one global 60-point batch or 0.324 ms split into ten six-point vehicle batches. B's latest Lite-only live field update measured 1.109 ms mean / 1.379 ms p95 / 2.088 ms p99 on the older i7-5820K. This supports shared-field-plus-batched-contact sampling on that host; it does not substitute for the i7-13650HX benchmark.

## Implementation boundary and next gate order

The native path and selectable CPU provider remain validation-scoped; the Jetski controller itself is unchanged. No Coastal snapshot composition, weather-transition coherence, runtime pause/resume, or visual/breaker regression is claimed. Synthetic Calm, Normal, and Storm static fixtures were compared with GPU `PHYSICAL_HEIGHTFIELD`; transition behavior is untested.

Continue in this order:

1. Review the recorded Jetski playback and contact-space error; decide whether Candidate B's normal-state force/orientation differences are acceptable or whether a nearby resolution needs evaluation.
2. Run the prepared benchmark on the i7-13650HX target and assess tail stability and cost; do not infer target timing from this workstation.
3. After open-ocean gameplay is accepted, validate weather changes and add Coastal snapshot correspondence.
4. Keep breakers and advanced hydrodynamics outside this gate; do not add planing, slamming, breaker impulses, or tune the Jetski to hide water-backend differences.

No production configuration is selected yet. No architecture redesign is indicated by the current evidence.

## Fixed-trajectory replay update (2026-10-06)

Full CPU drove deterministic Jetski traces; the replay then froze body physics and sampled the same contact positions, contact velocities, and wave times against B, B+LONG, B+MID, B+SHORT, and one combined LONG+SHORT candidate. Trace sizes were 5,276 contacts / 1,319 ticks for Production and Normal, and 6,476 / 1,619 for Storm. Complete mean, RMS, p90, p95, p99, max and per-scenario data are stored in the three local replay JSON captures named in the report.

The band responsible for lost contact detail depends on the active spectrum. In Normal and Storm, restoring LONG alone reduces contact p95 height to about 4 mm, VY to 0.022–0.024 m/s, normal to 1.1–1.2°, and support force to 32–35 N. Restoring MID or SHORT alone leaves errors near B. In Current Production, restoring LONG alone primarily helps height; restoring SHORT drops VY from 0.516 to 0.227 m/s and normal from 21.33° to 17.00°, while combined LONG+SHORT reduces height/VY/normal/force p95 to 29 mm / 0.191 m/s / 16.76° / 263 N. The combined 256/128/128 field is best across all three tested states, with a replay native update mean around 3.0 ms and p95 around 5.6 ms on the i7-5820K. This is relative local evidence, not the i7-13650HX gate.

The analytic normal is the exact derivative of each band's bilinear cell and reuses the four complex-packed H/VY texels already loaded for that band. It replaces repeated epsilon-offset field lookups; no derivative FFT was added. Against the prior Lite 1 cm finite-difference normal, direct-gradient p95/max angle was 0.623°/15.20° (Production), 0.013°/1.86° (Normal), and 0.067°/4.73° (Storm). The centered Lite normal against the validated Full CPU/GPU 1 cm heightfield operator still differs by 21.21° p95 in Production. The large discrepancy is therefore primarily reduced spectral/interpolation content rather than a new normal-operator semantics bug. Production's remaining 16.76° hybrid p95 keeps the quality gate open.

### Optimized sampling and live review setup

The optimized backend makes one GDScript/native call per contact batch. For each point and each of three bands, it maps the cell once, reads four packed complex texels once, and computes H, VY, `dH/dx`, and `dH/dz` from the shared values: 12 complex reads/contact total, not repeated five-offset queries. The previous path issued 15 native band queries/contact and about 90 H plus 15 VY bilinear scalar evaluations. New 60-contact means were 286 µs for one global batch and 324 µs for ten per-craft batches; provider conversion dominates native work. The API accepts 60 positions in one call, while current vehicle callbacks aggregate each craft's four or six positions as one batch. See the report for 4/40/60/100-contact scaling and support-force timing.

The manual scene is ready at `gameplay/jet_ski_ocean.tscn`: start on Full CPU, drive W/S and A/D, and compare with key 2 for B+LONG (256/128/64), key 3 for LONG+SHORT (256/128/128), or key 4 for 128/128/128 periodic cubic. Key 1 returns to Full CPU. Switching preserves the current body state and ocean clock; a new field is built on the next contact tick. Telemetry shows field-update p95, last query time, wet hull points, and speed. This is a test procedure, not recorded human acceptance.

**Decision:** this pre-cubic decision is superseded by the 2026-10-06 spectral/reconstruction addendum below. Keep overall status **PARTIAL** pending manual gameplay acceptance and target-machine measurements. Coastal and weather transitions remain deferred by scope.

## Spectrum/reconstruction decision update (2026-10-06)

Exact uploaded Production H0 measurements show that LONG128 and MID128 retain essentially all meaningful spectral energy. LONG256 adds no useful retained frequencies; its replay gain was spatial reconstruction density. SHORT64 loses 6.32% of height and 17.60% of vertical-velocity spectral power, while SHORT128 retains 99.80% and 99.13% respectively.

Periodic 4x4 Catmull-Rom sampling with analytic height gradients cuts the 128/128/128 Current Production contact p95 normal error from 17.00° bilinear to 11.11°, and yields better p95 height/VY/normal/support-force error than 256/128/128 bilinear in that trace. Its mean field plus measured 60-contact batch cost is 1.46 ms versus 3.00 ms on the i7-5820K. In Normal and Storm, 256/128/128 still has lower contact errors than 128 cubic. This is a Pareto result, not universal parity or hardware acceptance.

The manual scene now also exposes **4 = 128/128/128 periodic cubic** while preserving the existing keys: 1 Full CPU, 2 B+LONG 256/128/64, 3 LONG+SHORT 256/128/128. No human acceptance has been recorded. Vehicle constants are unchanged. The i7-13650HX gate remains open. No production configuration is selected; overall status remains **PARTIAL**.

### Normal/Storm difference and manual state setup (2026-10-06)

Full contact replay shows that the 256 LONG bilinear option wins on most contacts in Normal and Storm, even though it adds no meaningful Fourier support. The remaining gap is primarily LONG reconstruction in trajectory tails. Cubic SHORT changes Normal/Storm p95 very little; MID resolution restoration also had little effect. The largest cubic VY error is associated with the top decile of encountered VY change rate, especially in Storm. This rate compares adjacent trace ticks at the same contact slot and includes Jetski movement through the field. High-slope contacts are not the cause: Normal cubic normal p95 is 1.57° in the high-slope decile vs 1.46° elsewhere; Storm is 2.29° vs 3.04°.

Focused 9×9 continuous-in-cell checks of worst Normal/Storm contacts found at most 0.54 mm height and 0.00211 m/s VY cubic range excursion beyond the directly evaluated band-limited field, both in SHORT. No meaningful overshoot/ringing was found. The raw diagnostics include each worst contact's 4×4 per-band H/VY stencil and values for Full, 128 cubic, and 256 bilinear, plus local direct-reference ranges.

For human review, the validation root has an exported state selector and accepts the scene user argument `--phys1-state=current|normal|storm`. Normal/Storm parameters are applied in `_enter_tree` before the Ocean initializes, with the same fixed start pose, seed, and fresh wave clock per launch. Keys 1–4 choose Full CPU, B+LONG, LONG+SHORT, and 128 cubic. The HUD shows sea state/time; a 1 Hz CSV under `.godot/phys_cpu_lite_manual_<state>_<timestamp>.csv` records backend, field/query time, velocity, pitch/roll, wet contacts, and airborne state. This is validation telemetry, not acceptance evidence.

**Open-ocean decision remains pending the user's 1-vs-4 driving comparison across Current Production, Normal, and Storm, followed by 1-vs-3 as reference.** Automated data do not decide perceptual handling. Do not lock FFT/reconstruction, start Coastal/weather integration, or call performance final. `TARGET HARDWARE PERFORMANCE = OPEN`; status remains **PARTIAL**.
