# PHYS-1 status report

**Classification: PHYS-1-B-BUILD.** Production is at the expected base `c38569626375200f38a5e13132df058529234e55`. SCons is now available from the bundled Python runtime, and the Production clock passed a direct CLI rate/freeze/resume check. The native build remains blocked because Windows has no usable C++ compiler or SDK and the expected external `godot-cpp` checkout is absent. The active GDExtension descriptor/library was therefore not generated or loaded. No commit or push was made.

## A. Candidate code reused

Copied the candidate's `ocean_query_core.*`, `ocean_query_native.*`, `ocean_query_simd_avx2.*`, `ocean_query_patch_core.*`, registration files, SConstruct, Windows build script, and GDExtension template into `addons/ocean/physics/native/ocean_query/`. Coastal and patch code is retained as source but is not enabled by the Stage A harness or included in the native build source list. Legacy standalone candidate benchmark scripts remain available for audit under a `.gdignore` because their old Ocean Lab resource paths do not exist in Production.

## B. Files adapted

* `addons/ocean/fft/open_ocean_fft.gd`: retains the final LONG H0 byte array uploaded to the GPU and exposes an experimental initialization snapshot. This is CPU-side; it adds no per-frame readback and does not alter visual dispatch.
* `addons/ocean/physics/phys1_spectrum_adapter.gd`: converts that exact final H0 plus LONG config into the candidate's frequency/coefficient arrays. It creates no random values and does not evaluate JONSWAP.
* Candidate C++: adds direct material-q scalar and batch methods using the existing spectral evaluator.
* `validation/physics/phys1_stage_a.gd`: deterministic 16-point, four-time GPU-readback harness; reports component max, mean absolute, and RMS errors, temporal derivative comparisons, and scalar/batch parity.
* `validation/physics/PHYS-1-MAPPING.md`: records the source mapping and scale contract.

## C. GPU/native mathematical mapping

The derivation, FFT indexing, signs, conjugate partner, checkerboard parity, normalization, coordinate-origin rotation, choppiness coefficients, and Y-up normal convention are in [PHYS-1-MAPPING.md](PHYS-1-MAPPING.md). A key coordinate detail is that Production samples the displacement map at `q/domain + 0.5`; the adapter rotates both temporal H0 terms by the corresponding half-domain phase before invoking the unchanged candidate core.

## D. Shared spectrum

The same final RGBA32F H0 bytes are uploaded to Production's GPU solver and retained on CPU for PHYS-1. The adapter unpacks those bytes and derives signed `k`, `omega`, and geometry coefficients. Production's deterministic generator remains the sole spectrum and random authority.

## E–F. Material-q and temporal parity

**Not measured.** The native extension did not compile/load, so GPU-vs-native errors, GPU precision floor, temporal errors, and surface-velocity finite-difference metrics are unavailable. The harness samples four actual `Ocean.get_wave_time()` values once executable.

## G–I. Inverse, normals, and surface velocity

World-XZ inverse, normal comparison, and further Stage B work were not started because Stage A did not run and has no measured pass result. The direct-query output retains the candidate's analytic geometric normal and labels its temporal displacement derivative as `surface_velocity`.

## J–L. Batch, performance, and AVX2

The harness contains direct scalar/batch numerical checks for 1, 4, 8, and 16 points. No measurements were obtained. Release performance for 1–64 points and inverse-query throughput, as well as AVX2 parity/speed, remain unvalidated because no Windows C++ toolchain/SDK or godot-cpp checkout is present. SCons was installed temporarily and is available for a later build.

## M. Regressions and checks

* Production base HEAD matched the requested commit; Ocean Production had no tracked edits before this task. The unrelated untracked `.codebase-memory/` directory was left untouched.
* Godot `script_check` passed for `open_ocean_fft.gd`, the new spectrum adapter, and the Stage A harness.
* Godot runtime reported ready for both `validation/p0_open_ocean.tscn` (P0) and `addons/ocean/ocean.tscn` after the Production-side change.
* Godot MCP runtime-console inspection returned `AUTH_FAILED` because the editor registry has no token path. The existing `validation/addon/ocean_live_clock_check.gd` passed when run directly through Godot 4.7.1 CLI. An additional temporary direct-CLI check confirmed Production clock freeze and resume; native evaluation remains untested because the extension is unavailable.
* The two Water Race model edits present before this task were preserved.

## N–O. Classification and Git

`PHYS-1-B-BUILD` remains the result: the native extension cannot be built or loaded in this environment. No material-q pass is claimed, Stage B remains gated, and no commit SHA exists because PHYS-1 validation is incomplete.

## PHYS-1.0 build/runtime unblock audit (2026-09-29)

### A. Build environment

* Compiler: none found (`cl.exe`, `clang-cl`, `clang++`, `g++`, `vswhere`, and Visual Studio installation roots absent).
* Compiler version: unavailable.
* Windows SDK: not found under either Windows Kits 10 location; SDK registry roots and environment variables were absent.
* Architecture: Windows x86_64 target; `PROCESSOR_ARCHITECTURE=AMD64` had to be set in the SCons subprocess environment because the Codex command shell omitted it.
* Python: 3.12.14 at `C:\Users\Eric\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`.
* SCons: 4.11.1, installed under the temporary directory `C:\Users\Eric\AppData\Local\Temp\phys1-scons`; verified `scons.exe` at `C:\Users\Eric\AppData\Local\Temp\phys1-scons\bin\scons.exe` from the same shell as Python.
* `python --version` and `scons --version` both succeeded from that shell.

### B. Native build declaration and attempt

* Production base is `c38569626375200f38a5e13132df058529234e55`; the Ocean Lab reference checkout is branch `master`, commit `16a1a2f3c0a937e62e1e82e71121008ff12c7307`.
* The candidate build consists of `addons/ocean/physics/native/ocean_query/SConstruct` and `build_windows_release.bat`. It expects `godot-cpp` as an external sibling at `addons/ocean/physics/native/godot-cpp`, overridable by `GODOT_CPP_PATH`. It is neither a declared submodule nor a vendored dependency. No `godot-cpp` revision is pinned in either repository; the candidate `.gitignore` refers to an unversioned `native/godot-cpp` checkout/archive.
* The SConstruct passes `api_version="4.7"`. Production declares Godot feature `4.7`; the installed executable reports `4.7.1.stable.official.a13da4feb`. This is the explicit compatibility contract; there is no exact dependency revision to report or select from repository metadata.
* The target is `platform=windows target=template_release`, Windows x86_64. Expected output is `addons/ocean/physics/native/ocean_query/bin/ocean_query_native.windows.template_release.x86_64.dll`. The generated active descriptor is `addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension`; the template entry symbol is `ocean_query_native_library_init`, and the class registered by the extension is `OceanQueryNative`.
* Exact command, from the native source directory: `python -m SCons platform=windows target=template_release godot_cpp_path=../godot-cpp`.
* Result: exit code 2 after 0.889 s. With the architecture environment supplied, SCons stopped because `addons/ocean/physics/native/godot-cpp/SConstruct` is missing. No C++ compilation/link occurred; the DLL and active `.gdextension` do not exist. Generated bindings and godot-cpp build status: unavailable because the checkout is absent.

### C. Godot runtime

* Godot 4.7.1 was run directly through CLI; no MCP dependency was used for the clock tests. The existing live-clock script loaded the project and passed. The successful headless run logged a Windows root-certificate-store warning. An initial attempt without a prepared temporary `user://logs` directory crashed in Godot's crash-log setup; rerunning with a temporary AppData/log directory passed. No repository files were used for that runtime setup.
* The active `.gdextension` descriptor and DLL are absent, so no native library load was attempted. Direct Stage A CLI startup confirmed `OceanQueryNative` is not registered and stopped at its expected class-registration guard; instantiation, dependency resolution, and native startup stability remain unverified.
* Godot MCP status remains `AUTH_FAILED` for runtime-console inspection due to the missing token path.

### D. Clock

* Existing direct CLI clock test: at 1.0x, `wave_delta=0.536080`, `frame_delta=0.536080`, measured scale `1.0000`, Ocean/FFT parity error `0`; its 1.75x case also passed.
* Direct CLI freeze/resume check: at 1.0x, `t0=0.142121`, `t1=0.475588`, `elapsed=0.333467`, scale `1.0000`; with `wave_speed_multiplier=0`, `t0=t1=0.475588` and FFT time matched; after resuming at 1.0x, `t0=0.482488`, `t1=0.689489`, `elapsed=0.207001`, scale `1.0000`. Result: `PHYS1_CLOCK_FREEZE_RESUME PASS`.
* Production Ocean and `OpenOceanFFT` shared clock: confirmed at runtime. Native time and shared native evaluation clock: not confirmed because the native object could not be loaded. Native query methods take an explicit `wave_time` argument; no independent clock is exercised by the source-level query interface.

### E–H. Stage A parity and performance

* Same LONG spectrum is wired through the retained final Production H0 upload bytes and the adapter, but same-source runtime evaluation is not confirmed.
* Material-q samples and error metrics: none; test was gated on the native class.
* World-XZ inversion, iteration counts, errors, and failed inversions: not run.
* Batch runtime, CPU timings, allocations, and performance benchmark: not run. No production GPU readback was added; the existing synchronous readback is confined to the Stage A validation harness.

### I. Result and Git

* Result: `PHYS-1-B-BUILD`. The runtime-only Production clock check passed, but native build/load remains blocked by missing MSVC/Windows SDK and the unpinned, absent `godot-cpp` dependency. Numerical parity is not classified from static inspection.
* Files changed by this audit: this report only. Earlier PHYS-1 Stage A adaptation files remain uncommitted as listed above.
* Commit: `NONE`. Push: `NOT NEEDED`.

## PHYS-1.1 native toolchain + first load follow-up (2026-09-29)

This section supersedes the PHYS-1.0 dependency/SCons availability details above.

### A. Toolchain

* The host is Windows x64. Visual Studio Installer, VS Build Tools, `vswhere`, `cl.exe`, and `vcvars64.bat` were not present in the inspected standard/custom installation paths or registry entries.
* Microsoft’s signed VS 2022 Build Tools bootstrapper was verified. A silent install returned 1602; a second visible passive attempt with administrator elevation returned “the user has canceled the operation.” No Build Tools or Windows SDK were installed. No Developer Command Prompt environment is available.
* Python 3.12.14 is now in a user-local venv at `C:\Users\Eric\AppData\Local\phys1-python312\Scripts\python.exe`. SCons 4.11.1 is pinned in that venv and verified with `python -m SCons --version`; no venv/package files are in the repository.

### B. godot-cpp

* Installed the source archive for tag `10.0.0-stable` at `addons/ocean/physics/native/godot-cpp`. The upstream release identifies commit `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`; the downloaded archive SHA-256 is `C763A08B8EC18DAE300CD54BB8848FAF1A5FD11DA629449D16649A72A1884727`.
* The repository SConstruct supplies `api_version="4.7"`. SCons accepted that value, generated 2,135 binding files, and advanced to compilation. This confirms configuration/binding generation, not a successful godot-cpp build.
* The local dependency is an untracked tag source archive, not a Git checkout with local `.git` metadata. Do not stage or commit it.

### C–D. Build contract, descriptor, and result

* No SConscript files are present. The PHYS-1 `SConstruct` expects the sibling `../godot-cpp` (or `GODOT_CPP_PATH`), compiles `src/ocean_query_core.cpp`, `src/ocean_query_native.cpp`, `src/register_types.cpp`, and the AVX2 translation unit, then targets `bin/ocean_query_native.windows.template_release.x86_64.dll`.
* `ocean_query_native.gdextension` is generated by an SCons command after the library succeeds; it is not the compiler output and is not a checked-in descriptor. `ocean_query_native.gdextension.template` is the repository source. The template has the required entry symbol and Windows x86_64 template_release mapping. The active descriptor and DLL are currently absent.
* The active descriptor’s generated filename was missing from the local native `.gitignore`; added ignore entries for it and its `.uid` so build products do not get staged accidentally.
* Build command: `python -m SCons platform=windows target=template_release godot_cpp_path=../godot-cpp`, from `addons/ocean/physics/native/ocean_query`, using the local Python venv and `PROCESSOR_ARCHITECTURE=AMD64`. Exit code 2 after 28.267 seconds. Binding generation completed, but Windows could not find the compiler command while compiling native and godot-cpp objects. No link or DLL was produced.

### E–G. Godot load, clock, and material-q gate

* Godot 4.7.1 direct CLI class-registration check printed `PHYS1_NATIVE_CLASS registered=false`. Instantiation was skipped because the class was absent. No native DLL load or native crash test could occur.
* The Production Ocean/OpenOceanFFT 1.0x, freeze, and resume clock checks remain passed from PHYS-1.0. Native time forwarding, native freeze/resume, and native independent-clock behavior were not runtime-tested; PHYS-1 Stage A and the material-q smoke test were not run.

### H–I. Result and Git

* Result remains `PHYS-1.1-B-BUILD`. The remaining blocker is the canceled VS Build Tools elevation; without MSVC/Windows SDK, the extension cannot link or load. No numerical parity classification is made.
* No Visual Studio, SDK, Python venv, SCons package, godot-cpp checkout/archive, or generated binding files should be committed. The only PHYS-1.1 repository edit is the native `.gitignore` entry above, alongside the updated report. No commit; push not needed.

## PHYS-1.1 continuation: MSVC build, native load, and runtime gate (2026-09-29)

### A. Toolchain and build

* Initialized the installed VS 2022 x64 environment with `VC\Auxiliary\Build\vcvars64.bat`. `cl.exe` resolved to `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe`, compiler 19.44.35229; `link.exe` resolved to the matching Hostx64\x64 directory. `VSCMD_ARG_TGT_ARCH=x64`, `INCLUDE` and `LIB` were set, and Windows SDK 10.0.26100.0 was selected from `C:\Program Files (x86)\Windows Kits\10\`.
* Python 3.12.14 and SCons 4.11.1 were invoked from `C:\Users\Eric\AppData\Local\phys1-python312\Scripts\python.exe`.
* From `addons/ocean/physics/native/ocean_query`, ran `python -m SCons platform=windows target=template_release godot_cpp_path=../godot-cpp` with that x64 developer environment active. Wall time: 8:02.7; exit code 0. SCons emitted one warning that `godot_cpp_path` was an unknown command-line variable; it nevertheless used the sibling dependency, generated/built bindings, compiled all four PHYS-1 native translation units, and linked the extension. No C++ compiler errors were reported.
* `godot-cpp` is tag `10.0.0-stable`, commit `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`, at `addons/ocean/physics/native/godot-cpp`, targeting API 4.7. `api_version=4.7` was accepted. Target: Windows x86_64 `template_release`.
* Generated extension: `addons/ocean/physics/native/ocean_query/bin/ocean_query_native.windows.template_release.x86_64.dll`, 458,752 bytes, SHA-256 `0DB7BC365E8A8DBB6F6A5E82FE497CB0A4746DEE16B6251182C09221D13D37AD`. `dumpbin` confirms PE machine x64 and exported entry `ocean_query_native_library_init`.

### B. Descriptor and direct Godot load

* SCons generated the active `ocean_query_native.gdextension` from its checked-in template only after linking. It contains `entry_symbol = "ocean_query_native_library_init"` and maps Windows x86_64 to the exact DLL above.
* Godot 4.7.1 stable (`a13da4feb`) launched directly from its console executable. The descriptor must be explicitly loaded as a Resource; merely placing it in the project tree does not register the extension. The existing Stage A harness now loads this descriptor before its class check.
* Direct CLI result: `PHYS1_GDEXTENSION_RESOURCE loaded=true`, `PHYS1_NATIVE_CLASS registered=true`, `PHYS1_NATIVE_INSTANCE created=true`, exit code 0. The only Godot console error was the existing Windows root-certificate-store warning; no extension load error, unresolved symbol, dependency error, or native crash occurred.

### C. Native clock gate

* The runtime harness supplied `Ocean.get_wave_time()` to `sample_material_q_batch()` each time. At 1x, Ocean/native input advanced from `0.352283` to `0.602915`; at 0x, both remained `0.602915`; after resuming at 1x, both advanced to `0.853260`. All five native calls returned output. Result: shared Production wave clock confirmed, including freeze/resume.
* Native sampling accepts `simulation_time` from its caller. Source search found `std::chrono::steady_clock` only for optional query profiling durations; no native phase clock controls wave evaluation.

### D. LONG material-q smoke gate and stopping point

* The smoke initialized the native query from Production's retained final LONG H0 snapshot (`resolution=256`, `domain_size=512 m`, `65,536` modes; adapter setup returned `ok=true`) and issued four same-material-q native batch samples.
* The GPU comparison could not complete. The existing Stage A readback calls `submit()`/`sync()` on the global RenderingDevice, which Godot rejects (`Only local devices can submit and sync`). The Production displacement RID also lacks `TEXTURE_USAGE_CAN_COPY_FROM_BIT`, so `texture_get_data()` rejects it. The comparison produced no X/Y/Z or vector error metrics. No Production resource was changed to permit readback, and no numerical divergence is claimed.
* Per the phase gate, world-XZ inversion, full material-q Stage A, batch/performance benchmarking, and parity classification were not run. The harness capture path must be resolved without changing Production readback behavior before those gates can run.

### E. Result and Git

* Build and native load gates passed; the required material-q smoke did not complete because the validation harness cannot capture the Production GPU displacement with its current readback calls. Result remains `PHYS-1.1-B-BUILD` (validation blocked; no numerical classification).
* This continuation added only explicit descriptor loading to `validation/physics/phys1_stage_a.gd`. The DLL, active generated descriptor, godot-cpp checkout/build outputs, and local environment remain uncommitted. Existing unrelated and prior PHYS-1 work was preserved. Commit: `NONE`. Push: `NOT NEEDED`.

## PHYS-1.2 validation-only global-RD probe (2026-09-29)

### A–B. Production source and probe

* Source RID: `OpenOceanFFT._solvers[0].displacement_rid`; runtime lifecycle state confirmed it equals the published LONG `Texture2DRD.texture_rd_rid` used by the surface. The test disabled MID, SHORT, Coastal, and breakers. Source is the final spatial LONG displacement, after inverse Stockham and map assembly, not a spectrum/ping-pong/normal/foam resource.
* Source format/dimensions: `R32G32B32A32_SFLOAT`, 256×256, domain 512 m. The assembly shader writes `(X displacement, Y displacement, Z displacement, Jacobian)`. It applies checkerboard `(-1)^(x+y)` and `1/N²`; horizontal channels already include LONG choppiness. The surface samples `world_uv(q,L)=q/L+0.5` with repeating UVs.
* Added `phys1_gpu_probe.glsl`, `phys1_gpu_probe.gd`, and `phys1_gpu_probe_runner.gd` under `validation/physics/`. The compute shader uses integer `imageLoad` from the global RD LONG texture and writes only N `vec4`s to a temporary N×16-byte result buffer. Coordinates use a small temporary N×8-byte storage buffer.
* Dispatch and resource operations use `RenderingServer.call_on_render_thread`; results use `buffer_get_data_async`. No local RD, global `submit()`/`sync()`, `texture_get_data()`, full texture transfer, or Production texture readback flags were used. Result sizes were 64 B (4), 1,024 B (64), and 256 B (16). Async callback latency was 2–3 process frames.

### C–G. Time association and measured same-q results

* The static suite froze the Production clock at `0.303819333333333` and verified it stayed unchanged over rendered frames. Each packet saved request ID, that exact time, q/texel data, and native batch result before scheduling GPU work. Test D used a moving sample at `0.320486`.
* Request IDs 1–4 completed on frames 9→12, 12→14, 14→16, and 16→19. All packets marked `same_time_proven=true`; callbacks compared against their stored native results, not callback-time wave time.
* Component statistics below are absolute error mean / p95 / max; `signed` is mean `(GPU − native)`. Vector statistics are mean / p95 / max error magnitude.

| Packet | Samples | X mean / p95 / max (signed mean) | Y mean / p95 / max (signed mean) | Z mean / p95 / max (signed mean) | Vector mean / p95 / max |
|---|---:|---|---|---|---|
| A frozen | 4 | 1.347588 / 3.079156 / 3.079156 (1.347588) | 0.514301 / 1.147751 / 1.147751 (0.101276) | 0.562191 / 0.791997 / 0.791997 (0.104921) | 1.739276 / 3.135335 / 3.135335 |
| B frozen | 64 | 1.112115 / 2.637934 / 3.956417 (-0.009869) | 0.467207 / 1.054338 / 1.185333 (0.008154) | 0.477456 / 1.366775 / 1.803220 (0.004737) | 1.445799 / 2.649607 / 4.218774 |
| C wrap | 16 | 2.784393 / 3.079161 / 3.079161 (2.784393) | 0.352989 / 0.902620 / 0.902620 (0.352988) | 0.540964 / 0.662044 / 0.662044 (-0.540964) | 2.889076 / 3.135339 / 3.135339 |
| D moving | 16 | 0.725980 / 2.844454 / 2.844454 (-0.069945) | 0.400716 / 1.217808 / 1.217808 (-0.010619) | 0.391863 / 0.957679 / 0.957679 (-0.021816) | 1.061961 / 3.113265 / 3.113265 |

* Example A sample: q `(-223,-207)` m → texel `(16,24)`, GPU `(0.317738,0.725307,-0.834937)`, native same-q `(-0.316619,-0.422444,-0.505344)`. The report JSON contains all q, wrapped q, texel, raw RGBA, interpreted XYZ, native XYZ, and signed errors for every sample.

### H. Diagnosis

* The mismatch is a material-coordinate origin/index mapping error. Production surface UV maps texel center `(i,j)` to `q=((i+0.5)/N-0.5)L`. The spatial Stockham output at integer image index `(i,j)` has Fourier phase coordinates `(iL/N,jL/N)`. With N=256, L=512 m, the analytically derived coordinate difference is `q_fft = q + (L/2 - L/(2N), L/2 - L/(2N)) = q + (255 m,255 m)`.
* As a diagnostic only, the runner also evaluated native queries at this derived FFT-lattice coordinate while retaining the unchanged GPU samples. Residual vector max was `1.43e-5` for A, `1.89e-5` for B, `2.30e-5` for wrap C, and `1.66e-5` for moving D. This isolates the same-q failure to the coordinate origin/texel-center interpretation and is consistent with GPU float32 versus native float64. The diagnostic coordinates do not count as same-q parity and do not pass the PHYS-1 gate.
* Because the derived mapping matches without changing axes, channels, signs, normalization, choppiness, H0, or time, those are not the cause. Periodic wrapping also remains consistent under the derived mapping, including the boundary packet. The spectral implementation was not modified or tuned.

### I–K. Result and next gate

* Result: `PHYS-1-B` — the probe works and reveals a real same-material-q coordinate-origin divergence. The GPU probe/capture is not a harness failure.
* Same-material-q parity: **failed**. World-XZ inversion: **not allowed yet**; batch/performance Stage A also remain gated.
* No Production physics, spectrum, texture usage, readback behavior, or timing code was changed. The build hygiene warning about `godot_cpp_path` remains recorded, not changed.
* Probe files and this report remain uncommitted; the report includes the validation-only diagnostic mapping but no change to runtime coefficients or query mathematics. Commit: `NONE`. Push: `NOT NEEDED`.

## PHYS-1.3 canonical coordinate contract (2026-09-29)

### Contract and implementation

* External queries now accept Production **material-q**. The pure `OceanQueryCore` spectral evaluator still consumes **FFT-q**. The Production-facing `OceanQueryNative` adapter holds the runtime LONG `L` and `N` and owns the one conversion helper:

  ```text
  texel_size = L / N
  offset = L/2 - texel_size/2
  fft_q = wrap(material_q + offset, L), with wrap in [-L/2, +L/2)
  ```

* For the active LONG band `L=512 m`, `N=256`, texel size is `2 m`, and derived offset is `255 m` on each axis. No `255` constant is used in code. Periodic tests covered `-L`, `-L/2`, just below `-L/2`, ±epsilon, zero, just below `+L/2`, `+L/2`, `+L`, and a coordinate three domains away. All outputs stayed in the canonical interval; shifting test inputs by `2L` changed the converted result by at most `1.14e-13 m`.
* Conversion lives in the GDExtension adapter, outside `accumulate_`. Scalar material-q, material-q batch, the scalar world-XZ Newton evaluations and their final surface query, and world-XZ batch entry points use that helper. The inversion variable and returned q remain material-q; the conversion is applied once for each spectral evaluation. Slope/Jacobian/normal derivatives are evaluated at FFT-q; the coordinate map is a translation and has identity derivative. No Production renderer, texture layout, H0, FFT normalization, sign, or choppiness edits were made.
* Runtime caller search found the PHYS-1 harness as the only repository GDScript caller of these native query APIs. The breaker-only query stays on its existing breaker path and was not modified. Future buoyancy callers should use `sample_material_q`/`sample_material_q_batch` for material coordinates or `sample_world` for world-XZ.

### Frozen and moving same-material-q results

The exact-texture global-RD probe was rerun unchanged for grid-aligned packets. The request stores its Production wave time and native values before dispatch; callback comparisons use that saved record. GPU probe results use async result-buffer readback only, with 64/1,024/256/256-byte buffers and 2–3 frame latency. No full texture readback, local RD, global `submit()`/`sync()`, or Production readback flag was used.

Component values are absolute error mean / p95 / max in meters; `signed` is mean `(GPU − native)`. Vector values are mean / p95 / max magnitude.

| Packet | Samples | X (signed mean) | Y (signed mean) | Z (signed mean) | Vector |
|---|---:|---|---|---|---|
| A frozen, t=0.450000 | 4 | 7.654e-6 / 1.488e-5 / 1.488e-5 (-6.700e-6) | 2.787e-6 / 3.994e-6 / 3.994e-6 (-1.445e-6) | 3.185e-6 / 4.292e-6 / 4.292e-6 (-1.956e-6) | 9.128e-6 / 1.599e-5 / 1.599e-5 |
| B frozen, t=0.450000 | 64 | 5.398e-6 / 1.466e-5 / 1.681e-5 (3.047e-7) | 2.503e-6 / 5.126e-6 / 7.033e-6 (-1.616e-7) | 3.066e-6 / 8.643e-6 / 1.049e-5 (-5.306e-8) | 7.534e-6 / 1.582e-5 / 1.758e-5 |
| C wrap, t=0.450000 | 16 | 1.040e-5 / 1.967e-5 / 1.967e-5 (-1.040e-5) | 2.887e-6 / 5.871e-6 / 5.871e-6 (2.250e-6) | 2.264e-6 / 3.219e-6 / 3.219e-6 (1.677e-6) | 1.132e-5 / 1.991e-5 / 1.992e-5 |
| D moving, t=0.466667 | 16 | 5.801e-6 / 1.609e-5 / 1.609e-5 (-2.179e-6) | 1.336e-6 / 3.248e-6 / 3.248e-6 (-3.241e-7) | 2.674e-6 / 7.331e-6 / 7.331e-6 (1.282e-7) | 7.193e-6 / 1.654e-5 / 1.654e-5 |

All requests marked same-time proven. A–C used the unchanged frozen time; D compared a moving-time request at its recorded time. There were no wrap failures or systematic axis/sign offsets. The residual scale matches GPU float32 output against native float64 evaluation.

### Off-grid rendered interpolation

The surface shader declares LONG displacement `repeat_enable, filter_linear` and samples `world_uv(q,L)=q/L+0.5`. A separate validation compute probe used a repeat-linear sampler on the same published LONG RID. At 16 frozen off-grid positions, GPU linear sampling versus native exact spectral evaluation had vector error mean / p95 / max `0.01636 / 0.04685 / 0.04685 m`. A diagnostic bilinear interpolation of the four neighboring native lattice values reduced it to `0.000403 / 0.000885 / 0.000885 m`. This is the rendered texture interpolation difference, distinct from grid-aligned spectral parity.

### World-XZ and batch gate

The LONG-only world adapter solved in material-q and converted each spectral evaluation once. At 16 lattice-aligned targets constructed from the Production GPU displacement, all inversions converged. Material-q recovery error mean / p95 / max was `0.000129 / 0.000575 / 0.000575 m`; residual was `0.000137 / 0.000622 / 0.000622 m`; iterations mean / p95 / max was `1.94 / 3 / 3`. Native displacement versus the Production GPU sample was `0.0000198 / 0.0000754 / 0.0000754 m`. Failed inversions: `0`. World-XZ scalar and batch outputs matched exactly on the 16-sample workload. Material-q batch and scalar results also had zero difference on the 16 checked samples in packet B.

For the 64-sample material-q workload, one batch call took `200,945 µs`; 16 scalar calls took `48,465 µs` on this validation run. The native batch evaluator reuses its output workspace and uses a stack coordinate pair per sample; it does not allocate or read back per sample. The returned PackedFloat64Array remains one result allocation per API call. Timings are a local smoke measurement, not a general performance claim.

### Build, runtime, result

* Rebuilt the existing Windows `template_release` target with MSVC 19.44 x64 and Windows SDK 10.0.26100.0. Command: `python.exe -m SCons platform=windows target=template_release godot_cpp_path=../godot-cpp` from `addons/ocean/physics/native/ocean_query`, under `VsDevCmd.bat -arch=x64 -host_arch=x64`; exit 0, 19.52 s. DLL: `bin/ocean_query_native.windows.template_release.x86_64.dll`, 416,768 bytes. The known ignored SCons variable warning remains build-hygiene debt.
* Godot 4.7.1 CLI loaded the extension, registered and instantiated `OceanQueryNative`, and completed every probe/inversion without a native-load error or crash. The only console error was the pre-existing Windows root-certificate-store warning; probe exit code was 0.
* No Production rendering code or spectrum math changed. The source changes in this phase are native adapter/query wrapper and validation files. The generated DLL, godot-cpp build outputs, active descriptor, imported shader caches, generated `.uid` files, and JSON captures are not being committed. Existing `open_ocean_fft.gd` and `.codebase-memory/` changes remain untouched. Commit: `NONE`. Push: `NOT NEEDED`.

**PHYS-1.3 result: `PHYS-1.3-A`.** Same-material-q LONG parity passes at floating-point residuals; wrap and moving-time packets pass; the off-grid difference is explained by Production's linear texture filtering; world-XZ inversion and batch parity pass. World-XZ inversion is now allowed for the LONG-only Stage A. MID, SHORT, Coastal, breakers, buoyancy, and GPU readback remain outside this phase.
