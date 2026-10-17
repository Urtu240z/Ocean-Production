# PHYS-OPT-2I — Coastal coverage-edge continuity

**Result: geometry PASS.** The authored-rectangle gap is removed, the CPU/GPU contract agrees, and every retained failure capture regains a nearby root below the unchanged 1 mm tolerance. The known deterministic direct scalar/batch world-parity counterexample remains open. PHYS-4 was not started.

Date: 2026-10-02. Machine: i7-5820K / GTX 970, Godot 4.7.1, Forward+ / D3D12. All performance here is provisional on this PC.

## Preservation checkpoint

`38e11506a877d5c43d968225f24354ae101bf765` — `WIP preserve folded-surface branch continuity`.

Pushed and verified on `origin/wip/phys-opt-2` before geometry changes. This preserves the PHYS-OPT-2H PARTIAL implementation; it is not its acceptance commit. No merge to master.

## Root cause and accepted contract

The old rectangle test disabled Coastal immediately outside coverage while the sampled confidence could remain nonzero immediately inside. This created a real gap in the world-XZ mapping. More Newton seeds or polishing could not create a root in that gap.

The new factor is applied to Coastal authority before both LONG blending and effective shoaling:

```text
uv = (material_q - field_origin) / field_extent
cells = min(min(u,1-u)*(width-1), min(v,1-v)*(height-1))
t = clamp(cells / 1.0, 0, 1)
edge_weight = t*t*(3-2*t)
confidence = field.a * smoothstep(0,detj_safe,warp.z) * warp.w * edge_weight
```

Selected width: **1 authored bake cell = 4 m**, derived from resolution 353×354 and extent 1408×1412 m. Field/warp origins and extents coincide in this bake. The interval uses authored cells, not normalized hardware-sampler texel spacing. See [the canonical contract](COASTAL-COVERAGE-CONTRACT.md).

LONG alone receives Coastal transformation; MID/SHORT remain unchanged. Displacement, velocity and shoaling share this confidence. The static coverage factor requires no temporal term. Normals and physical determinant are evaluated from the same final blended surface. The direct oracle, AVX2 path and Dynamic FFT Mirror share `CoastalRuntime::sample`; the renderer/probes share a shader include, and GDScript reconstruction uses the equivalent helper.

## Width experiment and all four edges

Tested current Production, calm (Hs 0.8 m, wind 4 m/s, direction 20°, LONG chop 0.8), storm (3 m, 18 m/s, 75°, 2.0), each at times 0.36 / 2.25 / 16.89 s. Widths 0 / 1 / 2 / 4 cells: 36 packets, 65 positions per edge including corners. Diagnostics pass scalar doubles to retain micrometre offsets.

The following are maximum **3D displacement differences** across points 1 μm outside/inside the edge. A continuous field still changes over the 2 μm separation; these finite differences are not a claimed nonzero limiting jump.

| Edge | Old hard edge, m | One cell, m | At ±100 μm, m | Max one-sided slope difference at 100 μm |
|---|---:|---:|---:|---:|
| Left | 1.491994 | 1.378409e-6 | 1.378411e-4 | 2.797377e-5 |
| Right | 5.202808 | 1.425305e-6 | 1.425259e-4 | 9.755111e-5 |
| Top | 0.822103 | 2.087492e-6 | 2.087491e-4 | 1.541418e-5 |
| Bottom | 0.986227 | 1.553066e-6 | 1.553066e-4 | 1.849168e-5 |

These larger old gaps were found by the broader edge scan; the original 28.97 mm case was not the worst geometry at every sea state/edge.

| Width | World width | Max difference at ±1 μm | Max one-sided slope difference at 100 μm | Captures recovered |
|---|---:|---:|---:|---:|
| 1 cell | 4 m | 2.087492e-6 m | 9.755111e-5 | 5/5 |
| 2 cells | 8 m | 2.087492e-6 m | 2.438798e-5 | 5/5 |
| 4 cells | 16 m | 2.087492e-6 m | 6.097020e-6 | 5/5 |

One cell is the smallest tested candidate. It removes the gap and recovers the captures without widening the affected area to 8/16 m. The new convergence checks require a 100× reduction in diagnostic separation to reduce position difference; they do not replace or loosen any existing parity/root tolerance.

### Representative known gap

At q.x −168.281373070313 / −168.281371070313 m, with Z independently solved for the same target:

| | Outside world X | Inside world X | Difference |
|---|---:|---:|---:|
| Before | −168.087064820617 | −168.058095240081 | 0.028969580536 m |
| After | −168.087064820617 | −168.087062916613 | 0.000001904004 m |

Z residual is approximately 1e-12 m. Decreasing separation reduces the new difference continuously rather than leaving a finite gap. No coordinate special case was added.

## Normals, Jacobian and velocity at the edges

| Edge | Max normal-vector difference at ±1 μm | Max determinant difference at ±1 μm | Determinant range in feather | Max velocity-vector difference at ±1 μm, m/s |
|---|---:|---:|---:|---:|
| Left | 1.633700e-6 | 1.071490e-6 | 0.009412 to 2.152788 | 4.506001e-6 |
| Right | 1.752653e-5 | 1.274680e-5 | −0.332835 to 2.481297 | 3.133094e-6 |
| Top | 1.368784e-6 | 7.323610e-7 | −0.018776 to 2.348563 | 3.255715e-6 |
| Bottom | 1.139939e-6 | 9.286340e-7 | 0.237500 to 2.154508 | 3.250112e-6 |

Physical folds remain: negative determinants were observed within right/top feather transects. The transition does not guarantee an injective surface or establish that every local negative determinant existed before blending. Geometry was not clamped or flattened. The normal comparison follows the existing upward-normal orientation, including folds; it does not claim that every fold or bilinear knot is globally smooth. Native-vs-independent position reconstruction is within 1e-15 m; normal reconstruction max is 1.333321e-7 in the GDScript float-vector diagnostic.

## Internal validity transitions and unaffected interior

Scanned 1,634 neighboring Field-mask transitions and 1,516 Warp-mask transitions. For each source, 128 spatially distributed transition points were tested across nine state/time combinations: 1,152 comparisons per source.

Worst displacement difference at ±1 mm / ±100 μm / ±1 μm: **0.06647159 / 0.006647160 / 0.00006647160 m**. This strong spatial gradient scales with separation; the sampled internal transitions show no residual hard gap. This finite scan is not proof over every possible bake/state. Internal masks were unchanged.

At scanned points with coverage weight exactly one, old/new displacement difference is **exactly zero**. The formula guarantees that equality outside the 4 m feather; finite-difference normal stencils must also remain outside it. Open-ocean fallback was exactly zero difference in the PHYS-3 regression.

## Failure capture recovery and independent root search

All five local CPU captures were replayed with their exact retained H0, band configuration, time, targets and history. These files were preserved by the diagnostic/polishing replay of the same failure scenarios. They are not asserted to be byte captures of the earlier v3 run's approximate ticks/times: its last reported tick 1186 is represented by stored file 1187; file 994 is an additional preserved failed acquisition. The available captures cover all four boundary-failure scenarios.

| Capture | Time, s | Recorded old residual, m | New independent root residual, m | Recovered material q X/Z, m |
|---|---:|---:|---:|---|
| 10 | 0.3601633333 | 0.005617657 | 4.303587e-11 | −168.277970237 / −652.479581848 |
| 992 | 16.8902506494 | 0.009420660 | 1.171857e-13 | −168.260797343 / −652.155636579 |
| 993 | 16.9069173160 | 0.010696747 | 6.874294e-13 | −168.270371967 / −652.168193457 |
| 1187 | 20.1386389827 | 0.002378493 | 1.675705e-7 | −168.278712561 / −651.822656203 |
| 994 | 16.9069173160 | 0.010712964 | 6.874294e-13 | −168.270355967 / −652.168192149 |

Each is well below **0.001 m**, unchanged. No remote-root substitution or q snapping. The independent dense 61×61 local-seed search/refinement also found an accepted solution from each of its 32 best seeds for every capture; best residual 0 to 1.383060e-12 m. Those are converged seeds, not a claim of 32 distinct roots. Captures remain local ignored CPU data, not GPU readbacks or committed binaries.

## PHYS-OPT-2H replay

Controlled suite: **9,360 contact updates; 9,351 CONTINUED; 9 LOCAL; 0 GLOBAL; 0 FAILED; 0 detected jumps**. Scalar/batch contact max difference zero; coherent snapshot metadata. Six former border LOCAL events disappear. Remaining local events occur in the legitimate folded trajectories. Branch ownership/search policy is unchanged.

Iterations mean/p95/max: 2.169 / 5 / 117. Horizontal residual mean/p95/max: 0.000044595 / 0.000255458 / 0.000997676 m. The high iteration count is a local reacquisition, not hidden failure. Both known opposite-determinant roots, separated by 0.213846 m, retain independent ownership. Moving fixed-target branch B: 117 CONTINUED, 3 LOCAL, 0 GLOBAL/FAILED/detected jumps over 120 updates.

Live run: **1,200 ticks / 4,800 contacts; 4,796 CONTINUED; 2 LOCAL; 2 explicit GLOBAL; 0 FAILED**. No mixed bands/time reversal. The live loop does not have the controlled oracle on every contact, so this is not a claim of zero independently measured live branch jumps. Its two global reacquisitions remain visible in status output.

Pause: 30 ticks, field frozen, zero q changes/reacquisitions. Rapid A→B→C version update coherent and passed. No force integration.

## CPU/GPU and moving-weather regressions

The full PHYS-3 runner returned **PHYS-3-A in this execution**, with unchanged gates. Combined GPU vs interpolation-matched native residual:

| Packet | Vector mean | p95 | Max |
|---|---:|---:|---:|
| 64 interior | 0.000285831 m | 0.000793506 m | 0.001807578 m |
| 16 boundary | 0.000118868 m | 0.000402048 m | 0.000402048 m |

GPU manual Field/Warp/FFT reconstruction vs matching native lattice interpolation: 8,192 samples, vector mean **6.849333e-8**, p95 **1.192093e-7**, p99 **1.292198e-6**, max **3.758038e-5 m**. The 64-interior / 16-boundary matched reconstruction max is 3.030890e-5 / 1.319691e-5 m. This separates hardware FFT/Field interpolation residual from the mathematical coverage contract. No texture downloads or global RD submit/sync were introduced.

PHYS-3 world inversion: 64/64; horizontal residual mean/p95/max 0.000163612 / 0.000586347 / 0.000843949 m; iterations 2.234 / 3 / 3. Physical-normal FD max 7.947248e-5. Direct material/world scalar-batch max in this packet: 3.323057e-12 / 3.754650e-12 m. Fallback exactly zero. Moving-time association, 1x, freeze and resume passed.

**Separate legacy blocker remains:** at fixed t=0.473258666666665 s and the retained four-point fixture, world scalar/batch max is **2.23847251845655e-8 m against 1e-8 m**. It is identical to the prior baseline and 2H candidate. Material max is 5.954928e-14 m. Thus this phase does not close that known PHYS-3 counterexample merely because the ordinary run returned A. The new tracked diagnostic records `gate_passed=false`; the optional direct-oracle aggregate runner fails on that result.

Full PHYS-OPT-2G: 63 transition packets, 92 positions, 1,656 fixed-endpoint checks. Fixed velocity XYZ max difference **0/0/0**; geometry-control max 1.319833e-12 m. At the converged FD step, velocity-component max errors in m/s:

| Region | X | Y | Z |
|---|---:|---:|---:|
| Open | 4.4465e-5 | 1.7703e-5 | 3.0279e-5 |
| Coastal interior | 3.1710e-5 | 2.2173e-5 | 4.1485e-5 |
| Boundary | 3.2187e-5 | 1.8597e-5 | 3.6657e-5 |
| Periodic wrap | 3.2425e-5 | 1.7822e-5 | 2.6092e-5 |

All remain under the unchanged 1e-4 m/s oracle budget. Duration 1/T envelope scaling error 5.162537e-15; choppiness-only FD vector error 4.743346e-6 m/s. Velocity uses the same final confidence as displacement. The GPU probe has no authoritative velocity texture; this velocity result is the independent final-surface temporal FD check, not a fabricated GPU velocity measurement.

## Provisional performance

Paired old v3 DLL vs new v1 DLL, identical four material coordinates, t=2.25 s, four workers, full bands/Coastal, 100 warmups, 2,000 material/contact repetitions and 200 synchronous snapshots per trial. Three alternating before/after pairs; actual DLL identifiers checked and current DLL restored afterward.

| Metric | Before median trial mean | After median trial mean | Delta |
|---|---:|---:|---:|
| Material N4 | 0.035045 ms | 0.036638 ms | +0.001593 ms |
| Stationary contact N4 | 0.035689 ms | 0.037196 ms | +0.001507 ms |
| Synchronous producer | 11.260400 ms | 11.456355 ms | +0.195955 ms |

Material trial means before 0.034845–0.035700 ms, after 0.034741–0.049933 ms; contact before 0.035069–0.036341, after 0.035337–0.050605 ms. The first after run showed additional scheduling variation; it is retained in the results. There is a small query overhead, not a producer optimization claim.

Producer means overlap: before 11.257525–11.846585 ms, after 11.233895–11.888920 ms. Short-run p99 before 15.948–19.410, after 15.532–19.565 ms; max before 24.151, after 30.487 ms. Producer implementation, 18 packed IFFTs, 256²×3 bands and buffering are unchanged. These short paired runs do not establish a deadline/freshness acceptance.

Controlled moving contact N4 means (before→after, ms): ordinary 0.111140→0.100678; Coastal 0.131132→0.150455; folded 0.052758→0.053311. Final smoke material N4 means: ordinary 0.031712, Coastal 0.041511, folded 0.042052 ms. Different fixtures must not be mistaken for the same benchmark.

Live N4 contact mean/p95/p99/max: 0.124069 / 0.173 / 0.269 / 3.122 ms. Live producer 12.90863 / 16.313 / 20.490 / 22.766 ms. Field age mean/p95/p99/max: 0.467119 / 1.094540 / 2.017091 / **10.976640 ticks**, startup included. This age outlier is explicitly retained; geometry PASS is not a declaration that async freshness/tails are solved.

### GPU and visual comparison

Frozen t=2.25 s, fixed camera per edge, 1280×720, Forward+/D3D12, orthographic width 90 m, VSync off, uncapped, three full FFT bands and Coastal; breakers/foam disabled only in the fixture. Two alternating repetitions per edge, 60 warm frames + 180 measured frames. Old variant removes only the coverage factor. Shader uniforms are preserved across shader swaps.

| Edge | Before GPU ms | After GPU ms | Delta |
|---|---:|---:|---:|
| Left | 3.029975 | 3.042228 | +0.012253 |
| Right | 3.130347 | 3.163753 | +0.033406 |
| Top | 3.046708 | 3.076581 | +0.029872 |
| Bottom | 2.953172 | 2.980397 | +0.027225 |

These are **total viewport timings**, not an isolated Coastal GPU pass. No extra texture fetches: the factor adds texture-size metadata and arithmetic. GTX970 measurements are provisional.

Filled and wireframe captures were generated for every edge. Wireframe inspection retains the same overall mesh structure; filled captures are dark and insufficient for a detailed optical review. The measured geometry changes are confined to 4 m along the authored rectangle. This is an intended local visual correction, not a claim of pixel-identical borders:

| Edge | Mean old/new displacement delta within tested strip | Max delta |
|---|---:|---:|
| Left | 0.109254 m | 1.491993 m |
| Right | 0.389435 m | **5.202808 m** |
| Top | 0.112313 m | 0.903192 m |
| Bottom | 0.110698 m | 1.014499 m |

The larger deltas remove the former artificial edge jumps. The strip occupies about 1.13% of this bake rectangle; interior outside it is unchanged. No Coastal retuning, mask edits, FFT changes, quality reduction or breaker-policy changes.

## Reproduction and evidence

After the existing native bootstrap/build, launch Godot with:

```powershell
& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_coastal_coverage_runner.gd
# Also: -- --internal-only; -- --captures-only (when local captures exist).
& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_coastal_coverage_cost_runner.gd
& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_coastal_coverage_visual_runner.gd
# Also: -- --wireframe (separate image/report filenames).
& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys3_legacy_world_parity_runner.gd
```

The legacy diagnostic exits zero when it successfully records the comparison; inspect `gate_passed`, not its exit code. `run_dynamic_physics_validation.ps1 -IncludeDirectOracle` explicitly rejects the known failing numerical result. Other geometry runners reject their convergence/replay failures.

Evidence is local/ignored under `.godot`: `phys_coastal_coverage.json`, `phys_coastal_coverage_internal.json`, `branch_failure_diagnosis.json`, `coverage_branch.stdout.log` (full controlled suite), `phys_branch_live.json`, `phys_weather_velocity.json`, `phys3_legacy_world_parity.json`, cost/visual JSON and screenshots. The full PHYS-3 runner retains its existing temporary JSON report location. No generated captures, DLL, OBJ, dependencies, UIDs or caches are committed. Four-edge validation works without local captures; exact historical replay additionally needs the retained local CPU capture files.

Final native build: MSVC 19.44 x64 / SDK 10.0.26100.0, template_release/API4.7. Generated DLL 693,760 bytes, build ID `PHYS-OPT-2I-coverage-feather-v1`, SHA256 `35CB77467B4674C8D6C430082461D13A46F1592693B207514820F841321132BA`. It loads/registers/instantiates in Godot. Native generation uses the existing SConstruct and descriptor; the old unknown `godot_cpp_path` warning remains separate build hygiene debt. Final runners completed without runtime errors; PHYS-3 stderr contains stage progress messages. One exploratory internal-scan run omitted a required diagnostic argument and aborted; that harness error was corrected and the definitive run completed successfully.

## Files and Git

Production/native: `coastal_coverage.h`, common `ocean_query_core.cpp/.h`, diagnostic binding/build ID `ocean_query_native.cpp/.h`; `coastal_coverage_contract.gd`, `coastal_coverage.gdshaderinc`, `ocean_surface.gdshader`; four existing auxiliary underwater geometry shaders (waterline camera/raster, caustics, bubbles).

Validation: PHYS-3 probe/reconstruction, new coverage/visual/cost and legacy-parity runners, existing contact/live runner instrumentation, build contract, aggregate validation entry point. Documentation: this report and `COASTAL-COVERAGE-CONTRACT.md`. `.gitignore` adds exact rules for regenerable physics/source UIDs; no legitimate source is hidden.

Commit: **`Smooth Coastal coverage boundary geometry`**, the commit containing this report. Resolve its exact SHA with `git log -1 --format=%H -- validation/physics/PHYS-OPT-2I-REPORT.md`. Explicit-path staging only; push destination `origin/wip/phys-opt-2`. The final delivery supplies the verified commit ID. Working tree is checked after publication; unrelated work is preserved. No master merge.

## Pending closure and next gate

1. Resolve deterministic direct scalar/batch PHYS-3 world parity at the exact fixture without changing 1e-8 tolerance.
2. Rerun PHYS-OPT-2H final acceptance after that fix. Keep explicit global reacquisitions, fold diagnostics and async age/tail observations visible.
3. Later run target-machine validation. PHYS-4 remains unstarted.
4. Crest G / Spindrift clamp discrepancy remains open.
5. P3D.1 travelling phase: revalidate after TIME-1 in an initialized Ocean/Carrier scene.
6. P3E handoff: revalidate after TIME-1 in an initialized Ocean/Carrier scene.
7. TIME-1 audit instrumentation: later decide removal, move to validation/debug, or intentional retention.
