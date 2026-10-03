# PHYS-OPT-2J — deterministic WORLD scalar/batch parity

**PHYS-OPT-2J: PASS. PHYS-3-A. PHYS-OPT-2H final status: PASS.**

The historical 22.38 nm blocker is reproduced and corrected. The final 2,016-case
WORLD matrix has max 4.56 nm, below the unchanged 10 nm gate. No geometry,
tolerance, contact ownership or gameplay-force change.

## Scope and starting state

Started from clean `wip/phys-opt-2` at `b4aa5c0141befa35d0fce131cb91953935a06535`.
Machine: i7-5820K / GTX 970, Godot 4.7.1, Forward+, D3D12; native MSVC 19.44 x64,
Windows SDK 10.0.26100.0, template_release. No master merge or gameplay integration.

This fixes the legacy **direct spectral** WORLD APIs. The Dynamic CPU FFT contact
continuation solver and PHYS-OPT-2H ownership policy are separate and unchanged.

## Exact reproduction before the fix

The starting source was rebuilt and linked before reproducing. The unchanged
PHYS-3 runner passed at its naturally selected runtime time; the fixed historical
counterexample still failed the unchanged 1e-8 m WORLD parity gate.

| Quantity | Starting DLL |
|---|---|
| Time | 0.473258666666665 s |
| Source material q | (37.1350555419922, 81.040283203125) m |
| World target, identical promoted float32 input to both APIs | (36.1558113098145, 80.8663330078125) m |
| Scalar solved q | (37.1344925828409, 81.0401076972668) m |
| Batch solved q | (37.1344927081359, 81.0401077135163) m |
| Scalar residual | 0.000487678233625823 m |
| Batch residual | 0.000487571603190158 m |
| Iterations / validity | 2 / valid, both APIs |
| Batch minus scalar D.xyz | (-1.691773598988533e-8, -6.932720980623586e-9, -1.2915240987787513e-8) m |
| Vector displacement difference | 2.23847251845655e-8 m |
| Material scalar/batch max, four-point packet | 5.95492825514708e-14 m |

## Call-path divergence map

Both APIs acquire the same prepared direct-core state at the exact requested
simulation time, use world XZ as the initial seed, 5 cm centered derivatives for
Newton, the same 1 mm residual acceptance and iteration limits, and the same
undamped Newton algebra. There is no backtracking in either legacy solver.
The final Coastal physical sample uses its existing 1 cm derivative contract.

The scalar route is `sample_world_with_material_q -> sample_prepared_ ->
accumulate_ / finite_jacobian_`. The default batch route is `sample_batch ->
sample_batch_prepared -> solve_avx2_batch_ -> evaluate_avx2_batch_`.

The diagnostic records native double results **before** Godot packing, iteration
rows, displacement/velocity/derivative controls at identical q, and prepared-state
provenance. Before/after time, configuration, core and per-band data addresses and
Coastal array addresses were identical. Legacy direct queries do not acquire an
asynchronous published FFT snapshot, so there is no published-generation race in
this case. Godot packing was not the source of the discrepancy.

### Cause 1: finite-difference phase identity across a periodic seam

At iteration 0, scalar/SIMD differences are ordinary rounding (~1e-13). At
iteration 1 the first meaningful discrepancy is the horizontal Jacobian `ja`:

For completeness, the first recorded arithmetic difference is already iteration
0 height: scalar 0.0559943786971755 versus batch 0.0559943786971756 m (about
9.7e-17 m at capture precision). The same iteration's largest Jacobian difference
is 4.93e-13. Both start from identical q and residual. Those ordinary SIMD/scalar
rounding differences remain after the fix; the seam identity below explains the
much larger systematic discrepancy that broke the historical gate.

| | Scalar | Batch | Difference |
|---|---:|---:|---:|
| ja | 0.867504694078297 | 0.867503659216663 | -1.03486163405e-6 |
| jc | -0.0792858265041943 | -0.079285859080152 | -3.2576e-8 |

Current domains are LONG 512 m, MID 137 m, SHORT 37 m; all N=256. At the first
Newton accepted q, SHORT FFT-q X is 18.4584312805879 m. Its +5 cm position crosses
the canonical +18.5 m seam and wraps to -18.4915687194121 m.

The fused batch stencil used `sin(k*epsilon)/epsilon`, an identity for an
**unwrapped** Fourier phase. The authoritative retained wave numbers are float32;
`exp(i*k*L)` is only approximately one for those actual values. The scalar solver
evaluates the four wrapped coordinates. Assuming exact periodic phase identity
therefore changed the batch Jacobian. A same-q open-ocean control reproduced the
entire ~1.03486e-6 difference; explicitly evaluated AVX2 offsets matched the scalar
offsets near numerical precision. FMA, packing, snapshot identity, convergence
policy and branch selection did not explain this error.

Correction: retain the fused stencil where it is valid; detect a stencil crossing
any enabled band's periodic seam and evaluate the existing four wrapped offsets
there. Do not alter retained k, H0, wrapping, domains or thresholds.

### Cause 2: scalar tail ignored the requested Newton stencil

The broader storm replay exposed another mismatch. As the active Newton group
compacted below four points, `evaluate_avx2_batch_` returned through
`evaluate_true_batch_`. That routine computes final physical derivatives (1 cm
for Coastal), ignoring the requested 5 cm Newton stencil. At storm iteration 4,
batch `ja` was 0.99270538923855 versus scalar 0.992462051382285; the scalar
tail matched the physical 1 cm derivative rather than the Newton derivative.
The packet's final WORLD difference reached 1.6604748e-7 m.

Correction: let the shared stencil path handle scalar tails as well as SIMD
groups, preserving the requested epsilon. This neither tightens the 1 mm budget
nor adds a root polish, reseed, root enumeration or a new branch policy.
The same storm packet then reached max 3.40060021348359e-12 m, with zero validity
or iteration mismatches.

### Cause 3: negative offset arithmetic at a near-singular trajectory

The expanded moving-weather matrix exposed a separate valid case at alpha=0.5,
time 0.473258666666665 s, target (713.074279785156, -769.187744140625) m. Both
APIs converged in seven iterations, but the displacement difference was
2.92362062364982e-8 m. At iteration 0 the Jacobian differed by up to 7.9e-12;
the determinant later reached 0.009808884, amplifying the initial rounding.

Batch constructed the negative stencil coordinate as `(q + epsilon) - 2*epsilon`;
scalar used `q - epsilon`. For both coordinates of this target these expressions
differ by one double ULP, 1.1368683772161603e-13 m. Same-q controls using the
four explicitly constructed offsets reduced the Jacobian difference to ~4e-14.

Correction: construct each negative offset directly from the saved original q,
using the scalar expression. No final root polish or new successful-root replay
policy was necessary. In the identical 144-point batch the case falls to
3.291106484162818e-9 m, with q difference 7.574972339459801e-10 m, seven
iterations in both paths, and residuals 0.000419602858250246 / 0.000419601363941135 m.
The remaining difference is SIMD/scalar rounding amplified by this trajectory;
it is below the unchanged gate and not an omitted sample.

### Nonconvergent cold-query output determinism

The expanded set deliberately adds internal valid/invalid warp-mask transitions.
Some cold legacy inversions there remain invalid after all 12 iterations in
both APIs. At target (271.149230957031, -995.921691894531) m, four identical SIMD
lanes start with displacement differences only 4.94e-15 m and Jacobian differences
1.12e-12. The unresolved trajectory amplifies these: q differs ~9.84e-10 m at
iteration 3, ~1.48e-5 m at iteration 5, and ~112.53 m after iteration 12.
Both outputs are invalid; their displacement differs 0.764573 m in this focused
packet. This is amplification along a nonconvergent Newton trajectory, not a new
surface difference, packing error or successful root disagreement.

For a failed **cold-seeded** batch lane, the final result is now obtained with
the unchanged scalar solver and the identical cold seed. It keeps the original
iteration/residual budget and reports its real validity and residual. The original
SIMD trial remains in diagnostic traces and the replay count is reported.
No failed samples are dropped. Successful SIMD solves have no replay; arbitrary
non-cold warm seeds and the separate 2H continuation solver retain their policy.

This is an exceptional bounded replay, not a root search or added refinement on
every normal query. It can be expensive in this legacy direct oracle and is
explicitly separate from the cheap Dynamic CPU FFT gameplay/contact sampler.
The broad sweep reports invalid counts as well as parity so equality of invalid
outputs cannot be mistaken for inversion success.

## Deterministic sweep configuration

The final matrix uses 144 points at each of two fixed times, 0.473258666666665
and 2.25 s, in seven spectral states: current Production, calm, storm,
direction-dominant change, and calm/storm H0 interpolation at alpha 0.25, 0.5,
0.75. This is 2,016 WORLD and 2,016 material comparisons. Intermediate H0 values
use the existing linear float32 endpoint interpolation and deterministic seed.

Each packet includes 64 Coastal bake locations, 16 coverage-edge points, 24
periodic seam points spanning all three band domains, six open-ocean points,
five historical-fold neighbors, 12 coverage-feather points, 16 internal warp
valid/invalid transition points, and one padding duplicate. The mask-transition
locations come from the actual retained bake, not a favorable hand-picked set.

The full runner can execute serially with `--sweep`. Final correctness runs were
partitioned with `--matrix-part=base`, `fixed`, and `moving`, retaining identical
points, times and state construction; fixed/moving partitions can run concurrently.
Performance measurements use only the isolated base run, never concurrent runs.
Statistics must be aggregated over individual errors, not means of packet percentiles.

Successful-root agreement is distinguished from output agreement for cold solves
that remain invalid. The suite retains every failed sample and reports validity,
iteration and solved-q differences; a matched invalid result is not a recovered
world root. Contact branch ownership is checked separately by the unchanged 2H
controlled/live suites.

### Final broad parity results

All three partitions pass with the final v2 native build. WORLD errors below are
aggregated from each individual captured double displacement, not packet percentiles.

| WORLD displacement difference, m | Result |
|---|---:|
| Count | 2,016 |
| Mean | 6.29163e-12 |
| p95 | 4.00643e-13 |
| p99 | 2.80094e-12 |
| Max | 4.55646e-9 |
| Solved-q maximum difference | 6.05982e-9 |
| Validity mismatches | 0 |
| Iteration-count mismatches | 0 |
| Root mismatches, q difference >1 cm | 0 |
| Default batch vs identically cold-seeded warm batch, all output fields | 0 |

Material displacement parity across 2,016 queries has max 4.40840034833355e-12 m.
The historical four-point material max stays 5.95492825514708e-14 m.

| State | WORLD max at 0.473258666666665 s, m | WORLD max at 2.25 s, m | Invalid both, total |
|---|---:|---:|---:|
| Current | 3.90329e-12 | 4.00117e-12 | 14 |
| Calm | 1.63439e-12 | 2.28183e-10 | 3 |
| Storm | 3.40060e-12 | 7.64220e-12 | 13 |
| Direction | 4.74067e-12 | 1.31556e-10 | 10 |
| Moving alpha 0.25 | 4.55646e-9 | 3.42926e-12 | 11 |
| Moving alpha 0.5 | 3.29111e-9 | 1.43462e-12 | 15 |
| Moving alpha 0.75 | 1.82139e-11 | 4.19141e-9 | 13 |

All 79 invalid cold outputs occur in the 224 internal warp-mask-transition cases.
The remaining 1,937 comparisons are valid in both APIs. There are no invalid
outputs among coverage-edge, coverage-feather, open-ocean, periodic-seam or
historical-fold-neighbor test points. The maximum WORLD error comes from a valid
mask-transition solve; the failed-cold canonicalization does not remove it.

| Region | Comparisons | WORLD max, m | Invalid both |
|---|---:|---:|---:|
| Coastal bake interior/mask/fold set | 896 | 7.6442e-12 | 0 |
| Coverage edge | 224 | 1.2708e-13 | 0 |
| Periodic X seam | 168 | 1.7058e-13 | 0 |
| Periodic Z seam | 168 | 7.1504e-14 | 0 |
| Open ocean | 84 | 1.3156e-10 | 0 |
| Historical fold neighbors | 70 | 6.4387e-14 | 0 |
| Coverage feather | 168 | 1.0049e-12 | 0 |
| Internal warp validity transition | 224 | 4.5565e-9 | 79 |
| Padding duplicates | 14 | 5.8051e-14 | 0 |

Percentiles and region values reconstructed from JSON double captures can differ
in the last digits from native in-process packet metrics. This serialization
rounding is far below the unchanged 1e-8 m gate.

## Why this is not a geometry change

The scalar authority, spectra, retained wave numbers, displacement and Coastal
formula remain unchanged. The batch API now evaluates the derivative contract
already used by the scalar API. SIMD/FMA remain enabled. No global FMA switch,
quality concession, extra FFT, GPU readback or new physical root policy is used.

## Exact case after the correction

Native ID: `PHYS-OPT-2J-world-numerics-v2`.
Final linked DLL SHA-256: `7A7217F4FB3C855EAD91786D459CC79436DE59DF5F40DC84DE5B181C3A1CDCC5`.
The unchanged historical runner also reports `gate_passed=true` at the fixed time,
with WORLD max 1.44814566696745e-13 m and unchanged gate 1e-8 m.

- Historical point: scalar and batch solved q both record
  (37.1344925828409, 81.0401076972668) m; residuals
  0.000487678233625823 and 0.000487678233619812 m, iterations 2/2, both valid.
- Native double displacement differs approximately 2e-15 m at that historical
  point; the whole four-point packet max is 1.44814563497827e-13 m.
- Material four-point max remains 5.95492825514708e-14 m.
- Native-to-Godot packing difference: 0.
- Same-q controls over all historical trace positions: displacement max
  1.9984e-14 m; velocity max 4.8003e-14 m/s; requested 5 cm Newton Jacobian max
  4.2590e-13. Physical 1 cm derivatives and Newton 5 cm derivatives are labelled
  separately rather than incorrectly compared as one field contract.
- No cold-failure replay occurs in the historical valid packet.
- Focused nonconvergent mask packet: four cold replays, scalar/batch difference
  exactly 0, packing difference 0. All four retain invalid status, 12 iterations
  and the scalar residual 0.0306673649339933 m; inversion success is not claimed.

## Physical before/after control

Compared the original current-weather 116-point capture to the corresponding
points in the expanded set at identical time and world inputs. The original
padding duplicate maps back to point 0; adding edge/mask points does not change
the identity of the 115 distinct control points.

| Maximum difference | Scalar before/after | Batch before/after |
|---|---:|---:|
| Material q, m | 0 | 1.26344e-7 |
| Displacement vector, m | 0 | 2.23847e-8 |
| Velocity vector, m/s | 0 | 4.59677e-8 |
| Unit normal vector | 0 | 1.47804e-7 |
| Horizontal Jacobian determinant | 0 | 8.81899e-8 |
| Residual, m | 0 | 1.06630e-7 |
| Iteration count | 0 | 0 |

All 116 control outputs are valid. The scalar physical result is unchanged; the
small batch correction removes the measured derivative-contract discrepancy.

## Provisional direct WORLD timings — i7-5820K

Identical frozen scene, world targets, full three-band Coastal configuration and
fixed time; three warmed repeats. These are expensive **direct oracle** timings,
not the Dynamic CPU FFT gameplay-query cost.

| Workload | Before mean, ms | After mean, ms |
|---|---:|---:|
| Scalar N1 | 1123.143 | 1153.072 |
| Scalar loop N4 | 2150.088 | 2211.557 |
| Scalar loop N16 | 10447.226 | 11048.647 |
| Batch N1, scalar dispatch | 1188.175 | 1189.342 |
| Batch N4 | 719.182 | 186.724 |
| Batch N16 | 346.470 | 324.075 |

N4 batch improves ~3.85x because the scalar tail no longer computes nested final
1 cm derivatives when 5 cm Newton displacement stencils are requested. N16 is
about 6.5% faster in this run. The scalar source algorithm is unchanged; three repeats
show run-to-run timing variation and do not establish an independent scalar
performance improvement. No performance acceptance for other hardware is claimed.
The deterministic replay cost is confined to unresolved cold direct queries;
these normal benchmark targets are valid.

## Unchanged PHYS-3 regression

Result: **PHYS-3-A**, original runner exit 0, no thresholds, points, seed, timing
logic or oracle changes. Frozen wave time in this run: 0.461801666666666 s;
the separate fixed historical replay prevents reliance on a favorable runtime time.

| Check | Result |
|---|---|
| Material scalar/batch, 64 | max 3.40035898743762e-12 m |
| WORLD scalar/batch, 64 | max 3.92418693026531e-12 m |
| WORLD inversions | 64/64 valid, zero failed cases |
| Horizontal residual | mean 0.0001661273 / p95 0.0007560474 / max 0.0009589325 m |
| Newton iterations | mean 2.234375 / p95 3 / max 4 |
| q recovery | max 0.0009643567 m |
| Outside Coastal fallback, six points | exactly 0 difference versus PHYS-2 open |
| Normal FD, 16 points, epsilon 0.01 m | mean 1.0704e-5 / p95 6.2665e-5 / max 6.2665e-5 unit-vector error |
| 1x / 0x / resume | all true |
| Moving packet request-time association | true |

Renderer-equivalent lattice-interpolated Coastal reconstruction remains separate
from continuous direct-spectral sampling:

| GPU vs native lattice-interpolated displacement | Mean / p95 / max, m |
|---|---|
| Coastal LONG interior, 64 | 0.000278806 / 0.000868805 / 0.001844466 |
| Combined interior, 64 | 0.000284504 / 0.000780620 / 0.001838283 |
| Combined border, 16 | 0.000118612 / 0.000383634 / 0.000383634 |
| Combined moving, 16 | 0.000222073 / 0.000490444 / 0.000490444 |
| Combined 8,192 scan | 0.000457616 / 0.001116062 / 0.002842028 |

The scan p99 is 0.001561971 m. Explicit manual FFT/Coastal reconstruction residual
max is 3.0287445e-5 m in the interior, 1.2832764e-5 m on the border and
1.7873128e-5 m in the moving packet. Native continuous versus GPU filtered
combined interior max is 0.070496656 m, the separately reported discretization /
filtering difference, not scalar/batch error. The unchanged suite accepts the
renderer-equivalent comparison. This phase does not alter renderer filtering.

## PHYS-OPT-2H final replay

Both original suites pass after PHYS-3-A, on the final v2 DLL.

| Suite | Updates | Continued | Local reacquire | Global reacquire | Failed | Branch jumps |
|---|---:|---:|---:|---:|---:|---:|
| Controlled moving/weather trajectories | 9,360 | 9,351 | 9 | 0 | 0 | 0 |
| Controlled frozen roots A/B | 1,200 | 1,200 | 0 | 0 | 0 | 0 |
| Controlled alternate owned root at same target | 120 | 117 | 3 | 0 | 0 | 0 |
| Live Production clock/weather | 4,800 | 4,796 | 2 | 2 | 0 | Not independently enumerated |

Controlled contact scalar/batch output difference is exactly 0; ownership order
A/B/A/B at one target passes with q error 0. Rapid configuration version 6 is
coherent. The controlled border trajectory has 780/780 continuations, zero
failures and zero jumps. Live has no contact failures at any of its four tracks,
including the former Coastal boundary problem. Mixed snapshots and backwards
time counts are both zero. Thirty paused ticks preserve fields/contact time and
q exactly, with zero reacquisition; resume and four live weather states pass.

The live runner has no independent branch oracle; its global reacquisitions must
not be labelled zero root changes. Its largest q delta is 1.950738 m at tick 29
in a reported **global reacquisition**, and the other global reacquisition is
1.111665 m at tick 685. These are visible policy outcomes, not hidden failures.
Controlled branch-jump counts use the unchanged owned-branch oracle and are zero.
PHYS-OPT-2H meets its final acceptance with PHYS-3-A now restored.

### Live diagnostics retained, outside this numerical correction

Live N4 contact queries: mean 0.1273225 ms, p95 0.197, p99 0.248, max 2.817.
Live producer: mean 12.864965 ms, p95 17.013, p99 20.642, max 22.429.
Field age: mean 0.477069 ticks, p95 1.044444, p99 1.979824, max 9.428664.
The largest age occurs at startup tick 10; ticks 8/9 also reach 9.3. The next
largest is 2.83576 at tick 23. These diagnostics are not removed or presented as
a freshness optimization. Producer/async/contact code is unchanged in this phase;
target validation must remeasure scheduling and update latency separately.
Live horizontal residual max is 0.0009979348 m, within the existing 1 mm budget.

## Reproduction commands

Build through the existing MSVC x64 environment and SCons build contract:

```powershell
python -m SCons -C addons/ocean/physics/native/ocean_query platform=windows target=template_release godot_cpp_path=../godot-cpp build_library=no -j 6
```

Run Godot 4.7.1 with `--path <repo> --rendering-method forward_plus
--rendering-driver d3d12 --script res://validation/physics/<runner>`:

| Runner | Purpose |
|---|---|
| phys3_legacy_world_parity_runner.gd | Unchanged fixed historical gate; inspect `gate_passed`, diagnostic exit alone is insufficient |
| phys_world_parity_runner.gd | Native double and Newton trace of exact historical four-point packet |
| phys_world_parity_runner.gd `-- --storm-proof` | Focused compaction/storm diagnosis |
| phys_world_parity_runner.gd `-- --sweep` | Broad deterministic WORLD and material parity, before/after timings |
| phys3_coastal_probe_runner.gd | Original unchanged PHYS-3 acceptance suite |
| phys_branch_continuity_runner.gd | Original controlled PHYS-OPT-2H suite |
| phys_branch_live_runner.gd | Original 1200-tick live clock/weather/boundary suite |

`run_dynamic_physics_validation.ps1 -IncludeDirectOracle` includes the fixed
historical gate and new sweep. Captures, native DLL and build products remain
generated locally, ignored and uncommitted.

## Changed source and hygiene

- `ocean_query_core.cpp/.h`: guarded wrapped stencil, correct scalar-tail stencil,
  direct negative offsets, deterministic failed cold output and opt-in traces.
- `ocean_query_native.cpp/.h`: validation binding/provenance and current build ID.
- `phys_native_build_contract.gd`: matching stale-DLL guard identifier.
- `phys_world_parity_runner.gd`: fixed replay, per-iteration controls and broad matrix.
- `run_dynamic_physics_validation.ps1`: includes the deterministic WORLD matrix.
- This report: diagnosis, measurements, limitations and reproduction.

The original PHYS-3 and 2H runners, Production shader/Coastal geometry, weather,
FFT field producer and contact continuation policy are unchanged.
`git diff --check` is clean. Captures match `.gitignore: .godot/`; DLL matches
the native `bin/` rule; the generated runner UID matches
`/validation/physics/*.gd.uid`. Explicit-path staging only; no dependency,
generated binary/cache or unrelated user file belongs in this commit.

## Git delivery

Commit message: **Unify scalar and batch world inversion numerics**.
Branch/destination: `wip/phys-opt-2` / `origin/wip/phys-opt-2`.
This report belongs to that implementation commit; obtain the exact SHA with
`git log -1 --format=%H`. Delivery checks compare local HEAD to the remote branch
and verify a clean worktree. No master merge, generated artifacts or PHYS-4 work.

## Pending roadmap — unchanged

- Crest G / Spindrift clamp discrepancy.
- P3D.1 travelling phase after TIME-1 in an initialized Ocean/Carrier scene.
- P3E handoff after TIME-1 in an initialized Ocean/Carrier scene.
- TIME-1 audit instrumentation: later decide removal, relocation to validation/debug, or intentional retention.

NEXT: target-machine validation. Only after that comes PHYS-4 jetski force
integration. No final performance acceptance for that machine is claimed here.
