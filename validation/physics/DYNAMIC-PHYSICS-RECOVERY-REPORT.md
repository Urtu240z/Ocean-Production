# Dynamic CPU FFT recovery — old development PC

## Scope and result

Validated checkpoint on `wip/phys-opt-2`, starting from
`b5ca017587d14cbfc7e859fd1332032e69b32470`. Native build identifier:
`PHYS-RECOVERY-3-band-weather-v2`.

Hardware: Intel i7-5820K / GTX 970. Godot 4.7.1, Forward+, D3D12;
MSVC 19.44 x64, Windows SDK 10.0.26100.0, SCons 4.11.1,
godot-cpp 10.0.0-stable / API 4.7, pinned at
`507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`.

**Scheduler and source synchronization recovery passed.** The complete FFT
mirror remains the implementation to continue developing. It retains all modes
and all three bands, deterministic Coastal sampling and the direct spectral
oracle. No gameplay forces, master merge or quality reduction is included.

This is a validated foundation, not a claim that every buoyancy integration
contract is closed. Weather-envelope velocity and inversion branch ownership
remain explicit requirements below.

## Root cause and repair

The completed/ready state prevented a producer from starting its next request
while a finished snapshot awaited its slightly future Production timestamp.
With render-clock jitter this wasted complete physics intervals, even when the
FFT itself finished in time. Discarding late same-configuration results also
discarded useful monotonic progress.

The publisher now has three preallocated buffers, independent build and ready
states, one in-flight build and one latest-request mailbox. A future ready field
can wait while the spare builds the latest target. Publication chooses the
newest due coherent field and releases older ready buffers. The worker consumes
the mailbox after a writable buffer is available. It never replays a FIFO.

Snapshots contain LONG/MID/SHORT, exact retained H0, configuration version,
generation and simulation time. A same-configuration late completion can advance
the published state. Obsolete configurations, canceled future requests and
regressing times are rejected. No additional predictive lookahead was added.

Render-thread spectrum readers retain publisher ownership atomically. Shutdown
detaches it and joins the producer before clearing its builders. A concurrent
reader finishes from immutable snapshot metadata, including gravity. The
shutdown-reader test passed in every sustained/load/hitch run.

## Sustained freshness and cost

All runs used five persistent FFT workers, FULL LONG/MID/SHORT and active Coastal.
There were 180 warmup physics ticks. Queries were timed separately from the
producer. Artificial load is main-thread CPU work after sampling.

| Run | Ticks | Build mean / p95 / p99 / max, ms | Age mean / p95 / p99 / max, ticks |
|---|---:|---|---|
| No added load | 10,000 | 10.162 / 11.484 / 13.571 / 18.251 | 0.861 / 1.123 / 1.141 / 1.162 |
| 2 ms load | 3,600 | 9.239 / 11.004 / 14.273 / 16.894 | 0.168 / 0.904 / 0.930 / 1.002 |
| 4 ms load | 3,600 | 9.117 / 10.678 / 11.887 / 15.426 | 0.780 / 1.103 / 1.119 / 1.136 |

| Run | Single material query mean / p95 / max, ms | Main advance mean / p95 / max, us | Requests / coalesced | Age >=1 / >=2 / >=3 tick counts |
|---|---|---|---|---|
| No added load | 0.01463 / 0.022 / 0.069 | 1.593 / 3 / 45 | 10,000 / 44 | 963 / 0 / 0 |
| 2 ms load | 0.01476 / 0.023 / 0.070 | 1.626 / 3 / 16 | 3,600 / 13 | 6 / 0 / 0 |
| 4 ms load | 0.01486 / 0.023 / 0.042 | 1.571 / 3 / 27 | 3,600 / 0 | 807 / 0 / 0 |

No mixed bands, invalid samples, timestamp regressions or native crashes were
observed. Pause/resume and shutdown ownership checks passed. Timing tails are
reported. An earlier repeated scheduler checkpoint also observed an isolated
1.398 ms single-query scheduling outlier.

The final steady run narrowly exceeds the earlier <=10 ms producer mean goal
(10.162 ms); its p99 remains below 15 ms. This is not claimed as a strict pass of
every old performance goal. Freshness and main-thread budgets are the measured
recovery gates, without a quality concession.

The age is `(Production wave_time - published field_time) / (1/60)`, clamped to
zero. This is an explicit approximately one-tick pipeline. The preferred exact
one-tick p99 is slightly exceeded by the render-driven clock; maximum age stayed
below 1.17 ticks in these normal/load runs. Frame alignment explains why added
load does not produce a monotonic age distribution. Samples are never labeled
with a time they have not been built for.

The legacy deadline counter counted 957 / 1 / 807 misses respectively. It uses a
strict age boundary and is not a FIFO/backlog count. The separate >=1 counts can
differ at nanosecond rounding boundaries. Both are retained in raw captures.

### Deliberate process hitch

A separate 1,200-tick run blocked the main thread for 250 ms. Production's
render-driven clock subsequently jumped about nine physics ticks. Maximum age
was 9.827 ticks, with three observations >=3 ticks. This is outside the normal
producer freshness envelope and is not hidden.

The next useful publication reduced age to 1.530 ticks; the following two were
1.001 and 1 tick. Nine requests coalesced. The producer jumped to latest rather
than accumulating missed ticks. Mean build was 9.263 ms, p99 14.567 ms, maximum
16.936 ms. Arbitrary process suspension cannot guarantee a <=2-tick age.

## Runtime sea-state authority

The opt-in weather adapter privately prepares immutable spectrum endpoints on
one persistent worker. It reuses the exact Production seed/hash/Gaussian,
JONSWAP/Hasselmann equations, amplitude/common scale, MID fill and band scales.
The existing authoring/lifecycle API keeps its behavior.

Native H0 generation was compared with the existing GDScript implementation at
three sea states and all three bands: **zero different float32 values and zero
direct-output error**. Native generation took 69.108–77.574 ms; the legacy
generator took 1,972.865–2,087.683 ms in that focused run. This is configuration
preparation, not an every-tick cost.

The runtime recipe was also checked against the actual Production initializer,
including its wind-driven/manual-Hs choice: byte identity passed.
The adapter rejects an initial mirror whose H0/lattice/weather metadata does
not match that renderer. Its setup contract uses `set_production_spectrum`,
preventing generic spectral-array setup from uploading default weather metadata.

| Runtime state | Hs / wind / direction / LONG choppiness | Background prepare, ms | CPU/oracle lattice max | GPU/CPU lattice vector max, m |
|---|---|---:|---:|---:|
| Calm | 0.8 m / 4 m/s / 20 deg / 0.8 | 179.918 | 2.069e-6 | 3.659e-6 |
| Storm | 3.0 m / 18 m/s / 75 deg / 2.0 | 186.217 | 5.593e-6 | 2.325e-5 |
| Calm again | 0.8 m / 4 m/s / 20 deg / 0.8 | 176.909 | 1.599e-6 | 4.217e-6 |

The CPU/oracle column is the maximum absolute error over checked displacement
and velocity components; its units depend on the component. GPU checks used
16 exact lattice nodes per band per state and tiny asynchronous validation
buffers. No full texture or production query readback was introduced.

CPU, renderer and prepared endpoint H0 bytes matched exactly. The same solver
nodes and displacement RIDs remained alive: no scene reload or Ocean.initialize()
during transitions. H0/choppiness evolve over an intentional three-second ramp.
Their phase identity and Production simulation-time authority are preserved.

Rapid requests coalesced to serial 6, with only that newest pending target
accepted. Four configuration phase-history resets occurred. Pausing inside a
ramp froze it; resuming completed it. An active ramp completes before accepting
a newly prepared destination, preventing a stale-source jump.

Preparation took approximately 0.18–0.19 seconds in this correctness run before a requested
ramp starts; it is asynchronous, not an instantaneous weather update. The main
request took 0.709–0.827 ms. In the normal single renderer-thread mode, weather
poll/upload work averaged 2.606 ms, p95 4.424 ms, max 13.495 ms. This cost remains
visible and requires budgeting before gameplay integration.

The weather test also deliberately blocks on slow direct-oracle regressions,
then resumes the render-driven clock. Its aggregate age includes these startup,
freeze and oracle work: p95 1 tick, p99 2.103, max 11.451. Those numbers
are reported separately from the unbiased sustained runs above; they must not
be presented as a continuous gameplay weather freshness guarantee.

### Continuous weather producer and freshness

A separate runner measures calm -> storm -> calm without freezing or doing
oracle/probe work in its timed loop. It exposed a real extra producer cost:
serial H0/coefficient composition outside FFT tasks averaged 8.441 ms. The
profiled total was 18.436 ms (another run averaged 20.037 ms), with age p95
2.091 ticks. This cost was not merely a validation hitch.

Composition now runs inside the same three persistent band preparation jobs,
before evolution, and uses four-mode AVX2 double arithmetic where supported.
The exact float32 H0 round trip and operation order are retained; a scalar
fallback remains. No additional job barrier, modes or lower precision were
introduced. Composition is parallelized/fused, not removed from the accounting.

| Candidate | Build mean / p95 / p99, ms | Age p95 / p99 / max, ticks |
|---|---|---|
| Serial composition | 18.436 / 22.402 / 23.157 | 2.091 / 2.120 / 2.176 |
| Coarse band composition | 13.753 / 15.964 / 17.026 | 1.000 / 1.102 / 2.097 |
| Band + AVX2 composition | 11.493 / 13.050 / 15.819 | 0.954 / 1.008 / 1.974 |

The final continuous run covered 571 physics ticks plus 180 warmup ticks. No
snapshot aged >=2 ticks, no bands mixed and all three ramps completed. Mean
query time was 0.02970 ms, p95 0.037 ms. Background preparation took
144.367 / 148.623 / 161.667 ms. During active weather, single-thread renderer
poll/upload averaged 3.615 ms, p95 4.366 ms, max 14.182 ms.

A final repeat after adding the initial metadata guard covered 573 transition
ticks: build mean/p95/p99/max 12.195 / 13.843 / 15.999 / 19.083 ms; age
mean/p95/p99/max 0.403 / 1.007 / 1.045 / 1.943 ticks; no >=2-tick ages and no
mixed bands. The repeat's variation is retained rather than selecting only the
fastest timing.

Wall-stage mean/p99: preparation batch 5.589 / 9.158 ms; transform batch
5.898 / 7.511 ms; outside those batches 0.005 / 0.007 ms. The latter improvement
means the serial work moved into parallel band preparation; it does not mean
H0 interpolation became free. Weather producer mean remains above the earlier
10 ms steady-state goal, but its measured freshness stayed bounded.

At an intermediate alpha in each correctness ramp, 768 independently calculated
scalar float32 H0 values were compared against the SIMD-composed snapshot:
zero differences in all three states (2,304 checks). The original FFT dimensions,
eighteen packed 2D transforms per full snapshot and field set remain unchanged.

## Correctness and inversion

The original PHYS-3 runner finished **PHYS-3-A**, without threshold changes:

- World inversion: 64/64; residual max 0.000794187 m; iterations mean 2.250,
  p95/max 3.
- Direct scalar/batch material max 3.310e-12 m; world max 3.794e-12 m.
- Exact open-ocean fallback error: zero.
- Original normal check max 8.212e-5.
- 8,192-point interpolation-matched deterministic geometry comparison:
  vector mean 6.838e-8 m, p99 1.308e-6 m, max 3.731e-5 m.
- Moving time, 1x, freeze and resume passed.

Across each of the three live weather states, mirror scalar/batch material and
world differences were exactly zero. All 64 cold world inversions converged in
each state; maximum horizontal residual stayed below 0.001 m. Normal checks
against finite differences of the final mirror surface had max 1.202e-7.

Mirror world inversion now backtracks Newton steps against the same residual.
The 5 cm derivative stencil and 1 mm tolerance are unchanged. Failed cold starts
can try deterministic seeds within a bound derived from the same lattice's
horizontal displacement. Successful first attempts incur no such search. Warm
starts preserve local continuation and report failure instead of changing branch.

Folded source cases were found (one in calm, one in storm). Cold inversion can
recover another valid branch: q-recovery maxima were 0.163 m and 0.283 m despite
sub-mm residual. These are reported, not counted as proof of unique inversion.
Coastal geometry was not flattened or clamped. A consumer must select a branch
continuation/rejection policy before force integration.

### Query batch timings in the weather regression

| State | Material N4, ms | Material N16, ms | Cold world N4, ms |
|---|---:|---:|---:|
| Calm | 0.01324 | 0.05140 | 0.13506 |
| Storm | 0.01333 | 0.05138 | 0.17232 |
| Calm again | 0.01314 | 0.05260 | 0.11646 |

These are focused old-PC measurements, with expensive direct-oracle validation
excluded from query timing. They are not renderer performance acceptance.

## Integration contracts still to close

1. A gameplay consumer must use the explicit published snapshot time and known
   one-tick pipeline, rather than assuming current render time.
2. Velocity currently includes the instantaneous spectral phase derivative. It
   excludes the derivative of the changing weather envelope/choppiness; total
   moving-envelope velocity needs an explicit addition/validation before forces.
3. Folded Coastal mappings need a gameplay branch/rejection policy.
4. Weather preparation latency and renderer upload tails need separate budgeting.

The full direct solver, FFT quality, native band-mask API and existing Coastal
formula remain intact. `wip/phys-alt-1` and `wip/phys-opt-1` are preserved.

## Reproduction and repository hygiene

Run the tracked Windows native bootstrap/build, then use PowerShell 7:

```powershell
./validation/physics/run_dynamic_physics_validation.ps1 -GodotExe '<Godot 4.7.1 executable>' -SteadyTicks 10000 -LoadTicks 3600 -IncludeDirectOracle
```

The complete eight-stage correctness/weather/steady/load/hitch/oracle wrapper
passed with the current build guard. Logs and
captures are generated under ignored `.godot`; DLLs, objects and godot-cpp remain
ignored. No machine-specific path is embedded in the scripts. The existing SCons
warning about `godot_cpp_path` remains build hygiene debt; the validated sibling
checkout is still used.

Existing certificate-store, MCP registry permission/lock and D3D12 shader-cache
write diagnostics occurred in this environment. No native load/crash or physics
validation error occurred. They are not removed or misreported as clean console
output.

Source changes include scheduler ownership, exact native H0 import/generation,
the opt-in weather adapter, in-place renderer H0 updates and validation. Culling
bounds grow conservatively during weather changes; topology/LOD is unchanged.
The renderer's wave-time accessor distinguishes current phase time from the
retained spectrum snapshot time. See `DYNAMIC-PHYSICS-RUNTIME.md` for API contracts.

### Separate renderer-thread diagnostic

The final source also passed the complete weather/Coastal/world/batch test with
Godot's `--render-thread separate` option. All endpoint H0 bytes remained equal,
no bands mixed, all world inversions converged and CPU/GPU lattice residuals
remained at the same numerical scale. Main weather poll mean/p95/max were
0.241 / 0.577 / 3.121 ms in that mode. No project setting was permanently changed.
Its aggregate age still includes the deliberately slow oracle/startup work
(max 15.308 ticks); this diagnostic is an ownership/parity check, not a sustained
freshness acceptance run.

```powershell
godot --path . --rendering-method forward_plus --rendering-driver d3d12 --render-thread separate --script res://validation/physics/phys_weather_runner.gd -- --separate-render-test
```

## Mandatory pending roadmap

- Crest G / Spindrift clamp discrepancy.
- P3D.1 travelling phase after TIME-1 in an initialized Ocean/Carrier scene.
- P3E handoff after TIME-1 in an initialized Ocean/Carrier scene.
- TIME-1 audit instrumentation: decide whether to remove, move to validation/debug
  or retain intentionally.

None of these items or actual jetski forces was changed in this checkpoint.
