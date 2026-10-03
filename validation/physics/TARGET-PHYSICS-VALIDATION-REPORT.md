# TARGET-PREP-1 / target physics validation

## Preparation versus acceptance

Preparation status: **TARGET-PREP-1 PASS** — clean native build and required package smoke passed on the development PC. Optional separate-render mode is explicitly unqualified; target acceptance is pending.

Target hardware: **NOT TESTED**. Target acceptance remains pending. No PHYS-4 integration and no master merge are authorized by this package.

Starting checkpoint: `d51ba47528ded38a4a77b8245b2ed74c96460202`, branch `wip/phys-opt-2`.

The native contract remains `PHYS-OPT-2J-world-numerics-v2`: FULL LONG/MID/SHORT at N256, 18 packed 2D IFFTs, Coastal, total weather velocity, contact branch ownership, coverage feather and deterministic legacy world parity. Production mathematics, thresholds and defaults are unchanged.

## Local preparation evidence

Current machine: **Intel i7-5820K, 6 cores/12 logical processors; GTX970; Windows10 Pro10.0.19045**. GPU driver32.0.15.8228. Exact target: **NO**.

Preflight verified Godot4.7.1.stable.official.a13da4feb, MSVC19.44.35229/toolset14.44.35207, SDK10.0.26100.0, Python3.12.14, SCons4.11.1, godot-cpp10.0.0-stable/507ed9d840c01a3c5b2a39af8bb4000bfac30bf5, API4.7. Runtime Forward+/D3D12 and actual GTX970 adapter were verified.

The local dependency had lost its Git metadata. All **198** tracked files matched an independent clone of the exact pin; only verified `.git` metadata was restored, preserving all sources/builds. A clean clone downloads its own dependency normally. No local dependency source was added to Git.

The extension was cleanly rebuilt, linked and loaded. DLL size **712704 bytes**, SHA256 **CDE9FE37749CB25050CE001B9D47F7381847D063990D6B6BFFBB47C4970E6921**. The final rerun exercised SkipBuild fingerprint/hash verification against that clean-build manifest. The native build ID and generated descriptor entry/mapping were checked.

Local smoke passed: native load/instance; Production spectrum identity; exact2J replay;120-tick recovery with pause/resume and shutdown-reader checks;120-tick minimal-render mirror;120-tick integrated Production renderer/weather; controlled contact/recovery-cost wrapper. No mixed bands or invalid accepted samples in qualified performance smoke. Full PHYS-3/2G/2H/2I/2J matrices are orchestrated unchanged and remain **unexecuted in this preparation phase**; their validated starting checkpoint is preserved.

The final short minimal-render smoke measured producer mean **9.951ms**, p95 **10.411ms**, p99 **11.280ms**, max **11.964ms**; material N4 mean **0.0088ms**, Coastal material N4 mean **0.0128ms**. These are plumbing checks on120 measured ticks, **not sustained acceptance or a replacement for the old-PC baseline ranges**.

Observed initial band contracts: LONG N256/L512m/choppiness3; MID N256/L137m/choppiness1; SHORT N256/L37m/choppiness1. Runtime weather changes LONG choppiness with the existing0.8↔2.0 ramp recipe; resolutions and domains remain fixed. Source domains were measured, not assumed equal.

Prepared worker tests: supported3/4/5/6, with request8 observed as actual6 and recorded unsupported. Only four-worker timing was exercised locally; there is no target worker recommendation yet. Default integrated mode passes; separate mode is attempted and excluded because of the documented engine/resource teardown errors.

Local raw evidence lives in ignored `.godot/target_validation/package_final/` (clean build) and `package_final_verified/` (final guards and smoke), with `package_final_preflight/` retaining the standalone final preflight. Generated JSON/logs/binaries are excluded from the preparation commit.

Files added: `target_validation_common.ps1`, `target_physics_preflight.ps1`, `run_target_physics_validation.ps1`, `phys_target_package_smoke.gd`, `phys_target_performance_runner.gd`, `phys_target_contact_cost_runner.gd`, `target_physics_benchmark_world.gd`, and this report. Commit: **Prepare target physics validation harness**, branch/push destination **origin/wip/phys-opt-2**; exact delivered commit is the branch tip accompanying this report. No existing Production/native source or authoritative runner was modified.

## Preserved local package smoke evidence

The following preparation-only results are from the old development PC, not the target laptop. They are retained as historical evidence: native load, spectrum identity, world exactness, recovery, package smoke, integrated smoke, and contact-cost smoke passed; separate-render smoke was unsafe or unsupported. The recorded producer samples were recovery mean/p95/p99/max 10.425/12.379/13.154/13.511 ms, package 9.951/10.411/11.280/11.964 ms, and integrated 13.455/15.298/17.249/18.185 ms. These short smoke samples are not target acceptance.

<!-- target-run:start -->
Preparation execution: **FAIL**

Target validation: **FAIL: correctness/build/harness; acceptance halted**

Mode: Full; source: dc3c743af500c6f372fda489c62dc416ffa75cec; workers: 4.

| Suite | Execution | Seconds |
|---|---|---:|
| native_load | PASS | 1.207 |
| spectrum_identity | PASS | 2.678 |
| PHYS3 | PASS | 53.511 |

| Producer run | Mean ms | p95 ms | p99 ms | Max ms | Age p99 ticks |
|---|---:|---:|---:|---:|---:|

Detailed commands, distributions and machine-specific metadata: ignored run directory `summary.json`, `environment.json`, `REPORT.md` and logs.
<!-- target-run:end -->

## First target attempt — 2026-10-03 (blocked before build)

Independent read-only inventory confirmed the expected target: Intel Core i7-13650HX (14 physical cores / 20 logical processors), NVIDIA GeForce RTX 4070 Laptop GPU, 96 GB RAM, Windows 11 Pro 10.0.26200, and NVIDIA driver package 32.0.16.1062 (NVIDIA-SMI 610.62). The active Windows power plan was Turbo. Battery telemetry reported AC connected, not charging, and 100% remaining. ASUS profile and CPU temperature were unavailable. An idle NVIDIA-SMI sample reported 47 C GPU temperature and 210 MHz graphics clock; this is not a load or thermal result.

The repository was clean on `wip/phys-opt-2` at `df4f5eca68c1d5918cd6bfd4e6f6cfb08c1260e7`; fetch/fast-forward confirmed it remained the remote tip. Godot 4.7.1 was present. Python 3.14.7 with SCons 4.11.1 was prepared in the ignored task-local environment. Windows SDK 10.0.26100.0 was present. The exact MSVC toolset 14.44.35207 was installed under Visual Studio 2026 and reports compiler 19.44.35228. The prepared preflight only enumerated Visual Studio 2022 (`vswhere -version [17.0,18.0)`), so it rejected the available toolset and stopped at `target_validation_common.ps1:104`.

## Harness compatibility fix and resumed target run — 2026-10-03

`target_validation_common.ps1` now asks `vswhere` for all installed products with the VC tools component, filters for the exact `VC\Tools\MSVC\14.44.35207` directory and `vcvars64.bat`, and deterministically selects the highest installation version that provides both. It initializes that installation's x64 environment with `-vcvars_ver=14.44`, then retains the exact compiler-path, 19.44 family, and SDK 10.0.26100.0 checks. The selected product/version/path, `vcvars`, toolset path, and compiler are recorded in `environment.json`.

Preflight passed on the exact target: Visual Studio Build Tools 2026 18.9.12112.369; toolset 14.44.35207; MSVC 19.44.35228; SDK 10.0.26100.0; Godot 4.7.1; Python 3.14.7; SCons 4.11.1; `godot-cpp` 507ed9d840c01a3c5b2a39af8bb4000bfac30bf5, API 4.7. The environment capture confirms i7-13650HX, RTX 4070 Laptop, 96 GB, Windows 11 Pro build 26200, AC connected, Turbo plan.

The prepared clean native build and package smoke passed. A fresh 709,632-byte DLL was linked (SHA256 `AE4BDE4FE547DA3DB8CC7F28820146E52F4831D6F3EAE6AAB3B0675C195F21BE`) and the expected `PHYS-OPT-2J-world-numerics-v2` build ID loaded. Native load, spectrum identity, world exactness, 120-tick recovery, package smoke, integrated renderer smoke, and contact-cost smoke passed. Separate-render smoke remains unqualified/unsafe and is excluded. Smoke-only runs do not qualify target acceptance; the full target plan is pending.

The Visual Studio discovery fix is commit `42af4683a320b519c0789e64589e72b96020457f`. Preflight evidence is in ignored `.godot/target_validation/20261003-095204-714/`; clean-build and smoke evidence is in `.godot/target_validation/20261003-095326-776/`. No physics source or thresholds changed.

### First Full-run attempt — harness stopped before 2G

The Full run freshly rebuilt and loaded the extension, then passed spectrum identity and PHYS-3-A. It stopped before PHYS-OPT-2G because the orchestration function accessed `.Count` on an empty optional argument array under strict mode. The worker capability probe reported 3, 4, 5, and 6 actual workers; request 8 correctly reported actual 6. No physics failure was observed and no later Full suites ran. The run capture is in ignored `.godot/target_validation/20261003-095740-229/` (fresh DLL SHA256 `55F0DE2FC52377B6E30F41C82AF96BD4C440D043BD4D2431B178208E1316353F`). A second harness-only guard now skips forwarding when the optional array is null or empty; Full is pending rerun.

## One command

Run from the repository root with PowerShell 7. Executables are discovered from PATH and nearby installation directories; explicit paths are optional parameters, never tracked personal paths.

```powershell
# Environment only; no benchmark or native build.
pwsh -NoProfile -File validation/physics/run_target_physics_validation.ps1 -PreflightOnly

# Default is Quick; existing correctness suites still include expensive oracles.
pwsh -NoProfile -File validation/physics/run_target_physics_validation.ps1 -Quick

# Complete target run; clean working tree required.
pwsh -NoProfile -File validation/physics/run_target_physics_validation.ps1 -Full

# Short exploratory worker sweep; never target acceptance.
pwsh -NoProfile -File validation/physics/run_target_physics_validation.ps1 -Quick -WorkerSweep

# Package plumbing only on the development PC.
pwsh -NoProfile -File validation/physics/run_target_physics_validation.ps1 -SmokeOnly
```

Optional `-GodotExe`, `-PythonExe`, `-Configuration template_release`, `-OutputDirectory`, `-GpuIndex` and `-SkipBuild` are supported. An exact target inventory is insufficient if Godot actually renders on the integrated GPU: Full stops and asks for the intended adapter index. No persistent graphics preference is changed. SkipBuild requires a prior clean-build manifest matching every native source hash, dependency pin and DLL hash. Full acceptance records whether it actually rebuilt; a skipped build cannot satisfy the fresh-build acceptance gate. Existing dependency directories are never silently switched or overwritten.

Install prerequisites explicitly if preflight reports missing components. Python 3 with `python -m pip install scons==4.11.1`; VS2022 C++ toolset `14.44.35207`, compiler `19.44`, SDK `10.0.26100.0`; Godot `4.7.1`. No automatic VS installation, power-mode change or affinity policy. Absent godot-cpp is cloned from `10.0.0-stable` and verified at **507ed9d840c01a3c5b2a39af8bb4000bfac30bf5**, API **4.7**. Existing source modifications or missing Git metadata cause a diagnostic stop.

## Reproducibility and build guard

Preflight records Windows, CPU physical/logical cores, GPU/driver, RAM, battery/AC if available, Windows power scheme, exact Godot/Python/SCons/MSVC/SDK/dependency and source revision. ASUS profile, temperatures and hybrid core types are explicitly unavailable unless reliably collected; the runner does not infer them. CPU utilization is derivable from child process CPU seconds divided by wall time and logical core count in process-memory samples.

The native build cleans and links `template_release` x86_64, verifies the generated descriptor and DLL, records size/SHA256, then checks the loaded class, instance and build ID. Runtime **driver name**, rather than adapter feature-level string, proves D3D12; renderer must be `forward_plus`. Every suite must create a fresh artifact and exit successfully; failed script parsing is rejected even if Godot exits zero. Each invocation owns one child and may terminate only that child on timeout. A locked DLL asks the user to close the editor using this checkout.

Source fingerprints and the build manifest stay under `.godot/target_validation/`. Tracked importer sidecars that were clean before import are restored after the run; pre-existing edits are preserved. `project.godot` is hashed before and after. Render threading, window, VSync and viewport scaling changes exist only in the owned process.

## Authoritative correctness inventory

| Contract | Existing runner / artifact | Mode |
|---|---|---|
| Production H0/phase identity | `phys_spectrum_port_runner.gd` | Quick + Full |
| Original PHYS-3-A, same-q lattice, Coastal reconstruction, normals, fallback, moving/freeze/resume | `phys3_coastal_probe_runner.gd` | Unchanged Quick + Full |
| 2G total moving-weather dX/dt, fixed states, choppiness derivative, independent numerical oracle | `phys_weather_velocity_runner.gd` | Existing smoke in Quick, full matrix in Full |
| 2I coverage feather and internal validity-mask transitions | `phys_coastal_coverage_runner.gd`, plus `--internal-only` | Quick + Full |
| 2J fixed counterexample and native double traces | `phys_world_parity_runner.gd` | Quick + Full |
| 2J 2016-point calm/current/storm/moving/wrap/fold sweep | Same runner `--sweep` | Full |
| 2H branch ownership, controlled folds, rapid versions, trajectories | `phys_branch_continuity_runner.gd` | Quick + Full |
| 2H moving Production clock/weather/contacts/pause | `phys_branch_live_runner.gd` | Quick + Full |
| Runtime weather endpoint H0 identity, GPU lattice packets, phase reset, pause | `phys_weather_runner.gd` | Quick + Full |
| Latest-wins, mixed bands, frozen clock, resume and reader shutdown | `phys_recovery_runner.gd` | Sweep + steady + load |

Correctness precedes performance. The world gate remains **1e-8 m**, inversion acceptance **1 mm**, and all existing thresholds/points/seeds/oracles stay unchanged. The direct spectral solver remains the oracle; its validation cost is excluded from gameplay timing. Existing GPU correctness probes read tiny buffers only. The new benchmark has no texture readback.

## Performance plan

| Test | Full measured ticks | Quick measured ticks | Warmup |
|---|---:|---:|---:|
| Workers 3 / 4 / 5 / 6; request8 capability probe | 3600 per supported count | 600 per supported count when requested | 180 |
| Steady | 10000 | 600 | 180 |
| Artificial 2 / 4 ms main-thread CPU load | 3600 each | 600 each | 180 |
| Minimal-render dynamic weather | 2400 | 600 | 180 |
| Production renderer + mirror + weather, default thread | 3600 | 600 | 180 |
| Same, separate render thread | 3600 | 600 | 180 |
| Sustained renderer/mirror/weather | 30000 | Omitted | 180 |

Worker selection ranks field-age p99 then producer p99; records mean/p50/p95/p99/max, stale >=1/2/3 counts, coalescing, main-thread waiting and child CPU-time evidence. It sets only this native instance's runtime worker count. Production defaults remain unchanged. Full always sweeps; Quick defaults to four workers. Full sustained run lasts **at least 500 seconds (8m20s)** at 60 Hz, longer if rendering cannot keep up; overall Full takes substantially longer because correctness oracles and multiple runs precede it.

The current native pool clamps requests to **1–6** workers. The load probe verifies requested versus actual counts in its own process and restores the initial value. Request8 is recorded as unsupported (actual6), never mislabeled as an eight-worker benchmark. Supported3 is included as a nearby coarse-partition candidate. Expanding the native pool belongs to a separate measured implementation phase, not preparation.

`phys_target_performance_runner.gd` records build/age/wait/query/contact/weather/poll timing, coherent version/time metadata, first/final thirds and stage traces. It uses Production `Ocean.get_wave_time()` and the existing one-tick latest-wins request API, with immutable published snapshots. No direct oracle in timing loops. Weather cycles calm → storm → calm → direction change using existing three-second ramps and endpoint recipes every 600 ticks; steady tests do not alter sea state.

Material N4/N16/N64, cold world N4 and warm contact N4 timings use the prepared mirror; sample packing/validity are checked. Independent ordinary/Coastal/folded four-contact timings reuse the authoritative controlled contact benchmark. `phys_target_contact_cost_runner.gd` adds local/global recovery distributions through a validation subclass; normal continuation remains separate from exceptional recovery. Live mixed-path timing is labeled packet timing and is not substituted for pure warm continuation timing.

## Frozen integrated renderer configuration

The new benchmark world subclasses **`validation/ocean_benchmark.gd`**, the actual representative Production benchmark world used by `validation/ocean_benchmark.tscn`; it disables only that harness's automatic sweep/quit. Real ocean clipmap, FFT solvers, island geometry, camera, sun and environment remain present.

| Setting | Value |
|---|---|
| Godot / native | Official Godot4.7.1 editor binary; native `template_release`, debug-engine flag recorded |
| Renderer / API | Forward+ / D3D12; runtime verified |
| Resolution | 1920×1080 window, viewport scale1, bilinear scaling at native resolution |
| VSync / cap | Off / unlimited |
| Camera | Position(0,8,16), rotation degrees(-12,0,0), parent benchmark camera properties |
| FFT | LONG+MID+SHORT, N256 each, full band mask |
| Coastal | On, authoritative validation Coastal bake |
| Seed / initial weather | 20260820, rough validation profile, Hs2.574m, wind18m/s, direction5.71° |
| Geometry / features | Island, sun/island shadows, surface detail, crest/surface foam, optics and SSPR on |
| Other systems | Breakers, spindrift, underwater off; no jetski/forces |
| Environment | Existing benchmark environment: background(.04,.10,.16), ambient(.35,.48,.60)×.8, Filmic; sun(-42,-28,0), energy3 |
| Dynamic resolution / upscaling | Disabled; scale1; no quality reduction |
| Physics | 60Hz; 180-tick minimum warmup excluded |
| Render thread | Default versus `--render-thread separate` as separate owned runs |

GPU and CPU render timings use RenderingServer viewport timer counters, **not GPU texture readback**. CPU render timer is distinct from total main-thread frame time. Frame-wall ms/FPS are captured simultaneously. Unsupported or zero GPU timer data is marked unavailable; it cannot qualify acceptance. No game-wide FPS gate is invented.

Timer reads execute on the render thread and deliver counters to the main thread asynchronously. Reading these getters on the main thread in separate mode forces RenderingServer synchronization every frame and invalidates a fair comparison; the local smoke exposed this and the harness corrected it. Owned worlds are retired before engine shutdown with render-thread completion callbacks, without global RD submit/sync.

**Separate-thread qualification:** Godot4.7.1 explicitly reports this mode as experimental. Local GTX970 integrated smoke still exposed Production GPU resource teardown `Bad address index` and engine uniform-set/finalize errors after timing finished, despite orderly owned-world retirement. This optional mode is therefore **UNSAFE / UNQUALIFIED on the development PC**, not a passing performance result. Its complete logs and raw unqualified capture are retained. The runner attempts it, excludes erroneous-process timings from acceptance, and continues the mandatory default-renderer tests. No Production fix is included in preparation. Target support/safety must be tested again; an unsafe separate mode cannot be recommended or selected as the production default.

## Memory and sustained-run interpretation

At N256, three bands, known native payload estimates from current source are:

| Payload | Bytes |
|---|---:|
| One packed spatial snapshot (6 complex pairs per band) | 18,874,368 |
| Triple packed snapshots | 56,623,104 |
| Triple retained Production H0 (RGBA float32) | 9,437,184 |
| Six endpoint-difference double arrays per band | 9,437,184 |
| Builder spectra + transform scratch | 37,748,736 |
| Builder phase/rotor/evolved arrays (8 doubles per node) | 12,582,912 |

These are known payloads, **not a complete native allocator measurement**. Cascade coefficients, immutable endpoint/config objects, plans, allocator overhead and transient first spatial snapshot must be accounted through process/private-memory evidence; no API exposes an exact total. The old native `get_dynamic_field_info()[3]` counts unpacked fields and may return zero once packed snapshots are active; the report retains that value and separately derives packed payloads instead of claiming zero memory use.

Tick/stage/frame capture storage is allocated before warmup; sparse weather-event and memory-sample capture growth is labeled validation-only. Per-tick native snapshots are reused. The report includes process private/working bytes/CPU seconds every five seconds, native fixed payloads and capture counters. Compare first/final thirds and periodic weather endpoints to distinguish weather ownership leaks from known capture memory. Actual leak/thermal verdict requires review of these traces; the script never substitutes a flat payload estimate for proof that memory does not grow.

## Output / portable metric schema

Default output: `.godot/target_validation/<UTC-run-id>/`, ignored by Git. Schema version1, times in ms, age in physics ticks, bytes explicit, machine identity separate from physical results. Linux/Steam Deck can reuse these fields with a different process/preflight orchestrator; no Steam Deck validation is performed here.

`environment.json`, `native_build.json`, `correctness.json`, `worker_sweep.json`, `steady_10000.json`, `load_2ms.json`, `load_4ms.json`, `weather.json`, `branch_controlled.json`, `branch_contacts.json`, `branch_live.json`, `integrated_renderer.json`, `integrated_renderer_separate.json`, `sustained_30000.json`, `summary.json`, `REPORT.md`, `logs/*`, plus per-run tick/stage/process-memory traces. Quick retains filename contracts but reports actual counts600, never masquerading as10000; SmokeOnly contains only load/package/integrated smoke results.

The runner populates this tracked report's generated execution section and writes the complete machine-specific summary/report into the ignored directory. JSON/logs/DLLs/objects/dependency checkout remain generated local content.

## Target acceptance review

Only **Full on exact i7-13650HX + RTX4070 Laptop** can enter target acceptance review. Require unchanged correctness, fresh verified build, integrated producer p99<16.667ms, sustainable60Hz with no accumulating >=2-tick backlog, negligible queries/advance, measured renderer coexistence, no memory leak or unexplained thermal collapse. A target run cannot automatically receive PASS while leak/thermal evidence remains unreviewed. `REVIEW REQUIRED` is intentional, and missing evidence stays pending. A failed mandatory suite halts acceptance.

Strong indicators are reported separately: steady mean≤8ms, steady p99≤12ms, integrated weather p99<16.667ms, age p99~1tick or less and normal max<2ticks, N4 query/contact well below.2ms. AC gaming profile preferred; never changed by the script. No arbitrary game FPS acceptance requirement.

## Old-PC comparison only

Final i7-5820K/GTX970 reference ranges from the PHYS-OPT-2 producer/weather reports: steady mean approximately9–10ms (2G base10.16ms), p99 approximately11.5–13.6ms (2G13.57ms); live weather mean11.5–12.2ms; queries approximately.01–.03ms. Compare target absolute values and ratios against the whole range, with identical context. Heavy diagnostic 2J live-contact runs reported higher producer tails and startup age; those are retained in their report and are not silently replaced by the fastest no-load number. Integrated renderer timing cannot be compared with historical CPU-only timing as if their loads were identical.

## Repository manifest and roadmap

Required in Git: all existing native sources/build scripts/descriptor template, Production adapters and deterministic Coastal shaders, retained-bake/H0 authority, unchanged physics runners/probes, new orchestration/benchmark support and this report.

Downloaded: pinned godot-cpp checkout. Generated: bindings, native objects/DLL/active descriptor, imports, benchmark captures. Local cache: `.godot/`, `.codebase-memory/`. Both `.gitignore` and `.gdignore` concerns remain separate; dependency checkout is excluded from Git and Godot scanning.

Pending, unchanged:

1. Crest G / Spindrift clamp[0,1] discrepancy.
2. P3D.1 travelling phase after TIME-1 in fully initialized Ocean/Carrier scene.
3. P3E handoff after TIME-1 in fully initialized Ocean/Carrier scene.
4. TIME-1 instrumentation disposition: remove, move to validation/debug, or intentionally retain.

Next: execute and review target validation. PHYS-4 jetski forces remain blocked until target acceptance. No master merge.
