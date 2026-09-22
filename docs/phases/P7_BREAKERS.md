# P7 — Breakers

## Phase 1 — Main Mesh Deformation

P7 Phase 1 deforms only the existing Coastal LONG contribution of
`OceanClipmapSurface`. It does not add a solver, RenderingDevice owner, bake
format, texture, viewport, particles, foam, spray, churn, secondary lip, query
representation, or waterline representation.

`Ocean.breakers` is authoring-only and defaults to `false`. The effective state
requires all of: Breakers requested, Coastal waves active, a valid Coastal data
dictionary, and the LONG cascade active. The shader variant is therefore
`*:*:*:nobreaker` for every ineffective case and `*:*:*:breaker` only for the
valid Coastal LONG case. The regular OFF material is
`base:fallback:flat:nobreaker` and is the existing P0–P6 shader source with
only inert P7 markers; it has no P7 uniforms, varyings, texture samples, vertex
math, or fragment normal reconstruction.

The Breaker variant consumes existing Coastal channels only: `field.g` for
shoaling, `field.a` and warp safety for authority, `warp.z` for compression,
`metrics.r` for depth, `metrics.g` for wavelength, and `phase.yz/.a` for local
direction/reached authority. It additionally samples the existing LONG normal
at the same Coastal-warped coordinate, so its three additional samples are
`coastal_phase`, `coastal_metrics`, and `normal_long`.

The environment gate combines valid/reached Coastal authority, a shallow-to-
deep depth window, shoaling, and positive safe Jacobian compression.

## Runtime direction contract (P2.5)

The baked `coastal_phase` texture is a Coastal propagation snapshot, not the
runtime FFT direction authority. Its channels are:

- `phase.r`: signed phase/profile coordinate used for crest localization.
- `phase.g`: baked Coastal render-direction X component.
- `phase.b`: baked Coastal render-direction Z component.
- `phase.a`: reached/valid mask (`1` for reached Coastal samples).

The texture is created by the Coastal propagation bake and is cached by
`OceanCoastalRuntime.activate()`. Changing the runtime wind rebuilds the FFT
configuration and spectrum, but does not rebuild this bake, so `phase.yz` must
not define a new BreakerCarrier's absolute runtime orientation.

P2.5 obtains the current LONG propagation vector from
`OpenOceanFFT._wave_configs[0].wind_direction`. In the FFT evolution shader,
`phase = -omega * time`, so the positive `k` direction is the visual travel
direction: the config vector is propagation *towards*, not wind *from*.

When Coastal is valid, `coastal_warp` is `F(world_xz) = sample_xz` and its
Jacobian is `J = d(sample_xz) / d(world_xz)` packed as
`[J00, J01, J10, J11]`. The carrier transforms a LONG sample-space direction
with `inverse(J) * d_sample`; invalid/outside Coastal data falls back to the
current LONG vector.

## Validation event reacquire (P2.6)

Production events capture their LONG/Coastal frame once and keep it frozen for
the event lifetime. The validation-only forced event may be reacquired when
`validation_auto_reacquire_on_long_direction_change` is enabled and the
published LONG vector changes by more than 0.5 degrees. Reacquire is gated by a
new `OpenOceanFFT` `published_generation`, so the forced event cannot capture a
direction from the retired FFT configuration. The normal validation acquisition
path is reused; the old event is cleared briefly and the next event receives a
new sequence ID.

## P5 material parameterization (P3A-A)

P5 keeps its authored non-monotonic `(s, y)` Catmull-Rom curve, including the
single fold-back region. Only its material traversal changes: a 4096-sample
arc-length LUT inverts normalized curve distance back to the original spline
parameter before sampling. P0-P4 and P6-P7 retain the original
uniform-by-control-point sampler. The VDM channel contract and the 256x64
Carrier validation grid are unchanged.

Classification is P3A-A: the dominant defect was material parametrization, not
the authored Catmull-Rom curve. Uniform and centripetal spline audits retain a
single coherent `[+, -, +]` fold; centripetal sampling was not adopted because
it did not improve the curvature audit.

## P4/P5/P6 material correspondence (P3B)

The pre-P3B audit found three different meanings for the same horizontal VDM
coordinate: P4 and P6 used uniform control-point traversal, while P5 used a
4096-sample arc-length traversal. At 1024 common samples this produced:

| Pair | Mean displacement | P95 | Max | Max location |
| --- | ---: | ---: | ---: | ---: |
| P4 -> P5 | 0.870977 | 1.606277 | 1.695892 | `u=0.681329` |
| P5 -> P6 | 0.774075 | 1.620727 | 1.673416 | `u=0.484848` |

P3B keeps P5 as the reference and derives one shared material coordinate from
its 4096-sample arc-length LUT. The material intervals are constrained by the
same ordered landmarks in every phase: rear attachment, crest apex, fold
onset, foldback/recovery, and front attachment. P4 and P6 receive 4096-sample
landmark-anchored LUTs; P0-P3 and P7 are unchanged. This is a shared
correspondence, not independent arc-length normalization.

The measured landmark coordinates are:

| Landmark | P4 | P5 | P6 |
| --- | ---: | ---: | ---: |
| Rear attachment | 0.000000 | 0.000000 | 0.000000 |
| Crest apex | 0.467643 | 0.467643 | 0.467643 |
| Fold onset | 0.558486 | 0.558486 | 0.558486 |
| Foldback/recovery | 0.692796 | 0.692796 | 0.692796 |
| Front attachment | 1.000000 | 1.000000 | 1.000000 |

These are material coordinates. The corresponding curve parameters used by the
new LUTs are P4 `[0.000000, 0.535775, 0.634432, 0.739438, 1.000000]`, P5
`[0.000000, 0.379487, 0.511111, 0.709402, 1.000000]`, and P6
`[0.000000, 0.457387, 0.655433, 0.766056, 1.000000]`.

The new correspondence audit gives:

| Pair | Mean displacement | P95 | Max | Neighbor-vector mean | Neighbor-vector P95 | Neighbor-vector max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| P4 -> P5 | 0.553781 | 0.912145 | 1.130847 | 0.004556 | 0.009640 | 0.012194 |
| P5 -> P6 | 0.812456 | 1.694084 | 1.720565 | 0.005619 | 0.012210 | 0.014701 |

The P4/P5 displacement and both neighbor-vector discontinuity measures
improve materially. P5->P6 has a larger raw displacement tail because collapse
is a stronger authored shape change, but it has no localized correspondence
spike and its neighbor-vector field remains smooth.

The exact-phase CPU contract preflight on the same 256x64 carrier grid was:

| Metric | P4 | P5 | P6 |
| --- | ---: | ---: | ---: |
| Mean edge stretch | 1.089172 | 1.152436 | 1.088272 |
| P95 | 1.682983 | 1.639072 | 1.640779 |
| Max | 2.461183 | 2.190717 | 2.154064 |
| Min ratio | 0.113388 | 0.135802 | 0.031545 |
| Extreme-area | 973 | 114 | 1205 |
| Degenerate | 0 | 0 | 0 |
| Near-degenerate | 0 | 0 | 30 |
| Winding discontinuities | not recorded | 242 | not recorded |

P5 values are the exact carrier report. P4/P6 values are the deterministic
CPU mirror of the same carrier attachment equation; winding was intentionally
not promoted from the mirror because its sign convention is not the exact
carrier report convention. The P6 near-degenerate count is the limiting
collapse metric and is present at the exact endpoint, not introduced by the
material correspondence.

P4, P5, and P6 retain one significant `[+, -, +]` longitudinal derivative
sequence (two reversals); no unexpected micro-fold sequence was introduced.
The P5 silhouette is unchanged (`mean=0`, `max=0` in the generator audit).
The same-coordinate silhouette deltas for the reparameterized phases are P4
`mean=0.604827`, `max=1.359475`, and P6 `mean=0.358960`, `max=1.161302`;
these are material redistribution deltas, not new authored control points.

For manual transition review, set `breaker_vdm_validation_phase` from `4.0`
to `5.0` for P4->P5, then from `5.0` to `6.0` for P5->P6. The validation
shader already interpolates fractional phase values, so `phase = 4.0 + t` or
`phase = 5.0 + t`, with `t` stepped by `0.01`, isolates geometry and does not
invoke lifecycle, detector, refractory, or event arbitration.

The CPU preflight at `dt=0.01` measured P4->P5 temporal displacement as
`mean=0.010212`, `P95=0.022418`, `max=0.029883` at material coordinate
`u=0.694118`; the worst mesh metrics occur at the endpoint phases, not in an
interior pop. P5->P6 has the same smooth temporal field (`mean=0.017592`,
`P95=0.040710`, `max=0.041597`, worst `t=0.10`, `u=0.252199`); its endpoint
P6 metrics remain the limiting case (`min ratio=0.031545`,
`near-degenerate=30`, `degenerate=0` in the CPU mesh mirror). The exact P5 carrier validation remains
`mean=1.152436`, `P95=1.639072`, `max=2.190717`, `min ratio=0.135802`,
`extreme-area=114`, `degenerate=0`, `near-degenerate=0`, and `winding=242`.

The sampled fold evolution was monotonic in the expected direction: P4->P5
foldback grows from approximately `0.85 m` at `t=0.0` to `1.59 m` at
`t=1.0`, while maximum height grows from `3.12 m` to `3.72 m`. P5->P6
foldback falls from `1.59 m` to approximately `0.95 m`, while maximum height
falls from `3.72 m` to `2.11 m`. The forward attachment remains at the shared
material end and no extra derivative reversal was observed.

Classification remains pending final editor/playtest visual confirmation:
P3B-A is applicable only if both manual transitions are visually continuous;
otherwise the result is P3B-B with the failing transition named. No P3B-C
condition was observed in the correspondence audit.

## Lateral breaker crest propagation (P3C-A)

The existing controls were audited before changing geometry. In the lifecycle
solver, `breaker_lateral_propagation_speed_mps` already means physical lateral
transport in metres per second, while `breaker_lateral_continuity_m` is the
physical continuity sampling radius used to connect nearby foam support. Neither
control previously modulated Carrier vertices or the carrier suppression mask.
P3C reuses both meanings explicitly: continuity provides the seed half-width and
the feather width, while speed expands the active half-width from event age.

The Carrier remains one `256x64` mesh. Its material-coordinate point is still
computed with SAME-Q and P3B's P4/P5/P6 correspondence; only the residual is
multiplied by a lateral envelope:

```text
active_half_width(age) = min(seed_half_width + speed_mps * age,
                              target_half_width)
lateral_authority = 1 - smoothstep(active_half_width,
                                    active_half_width + feather_width,
                                    abs(lateral_s - seed_offset))
carrier_final = carrier_base + profile_authority
                              * lateral_authority
                              * breaker_residual
```

For deterministic validation, `validation_lateral_progress` maps `0..1` from
seed width to target width without using lifecycle. Runtime uses `event_age_s`
independently from the P4/P5/P6 phase. `target_half_width` is derived from the
existing 32 m crest span (`16 m` per side), and `seed_offset` remains zero in
this single-breaker phase while the contract is ready for a future offset.

The H5 validation profile currently has speed `8 m/s`, duration `2 s`, and
continuity `3 m`. Therefore its initial full width is `6 m`, growth is `8 m`
per side per second, and the unclamped age-2 result would be `38 m` full. The
derived 32 m target clamps the actual final width to `32 m`. For the resource
defaults (`4 m/s`, `0.8 s`) the corresponding result is `6 m` initial, `3.2 m`
growth per side, and `12.4 m` full at the end of the event.

The measured manual P5 exact contract on the unchanged 256x64 grid is:

| Progress | Active width | Mean stretch | P95 | Max | Min ratio | Extreme area | Degenerate | Near-degenerate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.00 | 6.0 m | 1.076473 | 1.494514 | 2.686695 | 0.159375 | 61 | 0 | 0 |
| 0.10 | 8.6 m | 1.087472 | 1.512779 | 2.644965 | 0.097620 | 100 | 0 | 0 |
| 0.25 | 12.5 m | 1.104446 | 1.570116 | 2.674160 | 0.069289 | 93 | 0 | 0 |
| 0.50 | 19.0 m | 1.132555 | 1.644529 | 2.660292 | 0.133246 | 51 | 0 | 0 |
| 0.75 | 25.5 m | 1.156979 | 1.704813 | 2.977618 | 0.177419 | 54 | 0 | 0 |
| 1.00 | 32.0 m | 1.152436 | 1.639072 | 2.190717 | 0.135802 | 114 | 0 | 0 |

The full-width row exactly reproduces the P3A P5 report. No lateral step adds
degenerate or near-degenerate triangles; the maximum P95 is `1.704813`, close
to the validated P5 `1.639072`. Winding discontinuities range from `166` to
`242`; the P5 fold remains the expected `[+, -, +]` and is not counted as a
lateral error.

At every progress, vertices beyond the lateral authority envelope satisfy
`carrier_final - carrier_base = 0` on both frontiers (`0 m` measured error).
The maximum sampled frontier slope delta is `1.054451` on the left and
`2.469006` on the right in the local lateral grid derivative; the asymmetry is
from the authored P5 fold, not a discontinuity in the authority function.
The feather is `3 m`, equal to the existing continuity control; the previous
`1.5 m` trial reached a `4.95` edge-stretch spike and was rejected.

Suppression receives the same event origin, forward, tangent, and active width.
It uses a margin of one lateral Carrier vertex spacing (`32/63 = 0.507937 m`)
and the same feather plus that margin. Thus the suppression core widths are
`7.0159`, `9.6159`, `13.5159`, `20.0159`, `26.5159`, and `33.0159 m` for the
six rows above; at progress `1.0` the physical Carrier bounds still cap the
visible footprint at its existing 32 m span. There is no fixed 32 m hole at
seed progress.

Manual runtime review passed at progress `0.0`, `0.1`, `0.25`, `0.5`, `0.75`,
and `1.0`; the screenshot at seed progress shows only the central lip section
while the rest of the ocean remains visible. Two rotated validation frames
also preserved the same widths while following the tangent axis. The event-age
path is separate from phase age and preserves the configured duration in
seconds; no phase wave, multi-breaker, pool, detector, or allocation logic was
added. No new compute pass, full-resolution texture, or production readback was
added; the GPU path adds only the local lateral distance/envelope calculation
and the CPU path adds no per-frame allocation beyond the existing validation
report when explicitly requested.

P3C classification: **P3C-A**. The lip is localized, expands smoothly, the
suppression footprint follows it, P5/P3B geometry is preserved, and no
significant geometry regression was measured.

## P6 collapse geometry stabilization (P3C.1)

The P3B P6 endpoint was re-audited on the exact `256x64` Carrier contract
before changing the authored profile. The failure was not a seam, attachment,
or P3C lateral-envelope failure. The `30` near-degenerate triangles form two
principal mirrored edge strips at the reverse-slope fold, plus two isolated
shoulder cells:

| Cluster | `profile_u/material_m` | `crest_v` | `target_s` / `target_y` | `ds/dm` / `dy/dm` | edge ratio | area ratio |
| --- | --- | --- | --- | --- | --- | --- |
| fold edge A | `0.644444..0.657516` | `0.058201..0.068783` | `1.494518..1.625997` / `0.396490..0.419374` | `-9.939` / `-3.249` | `0.031317..1.101446` | worst `0.031878` |
| fold edge A mirror | `0.644444..0.657516` | `0.931217..0.941799` | same | same | `0.031317..1.095496` | worst `0.031915` |
| fold edge B | `0.609150..0.618301` | `0.058201..0.068783` | `1.917673..2.013677` / `0.467391..0.485180` | `-10.164` / `-3.662` | `0.033512..1.252020` | worst `0.040214` |
| fold edge B mirror | `0.609150..0.618301` | `0.931217..0.941799` | same | same | `0.033512..1.266741` | worst `0.039836` |
| shoulder cells | `0.679739..0.681046` | `0.084656` / `0.915344` | `1.334314..1.339642` / `0.356242..0.358465` | about `-4.27..-3.89` / `-3.164` | `0.042657..1.228` | `0.048705..0.049727` |

The broad extreme-area cluster spans `material_m=0.558170..0.700654`,
`crest_v=0.058201..0.941799`, `target_s=1.310527..2.259821 m`, and
`target_y=0.323805..0.601191 m`; it contains `1204` triangles. The primary
classification is **C: material parameterization**, amplified by **D: the
intentional P6 reverse-slope fold**. It is not A (lateral propagation), B
(attachment/seam), or an added P3D topology feature.

P6-A keeps every P6 control point, the `[+, -, +]` fold, the shared material
landmarks, and the P5-to-P6 material correspondence. It changes only the
within-segment `t6(m)` distribution: each shared landmark interval is sampled
by local curve arc length and receives a smooth finite-derivative bias
`a + 0.14*a*(1-a)^2`. There is no independent global arc-length
normalization. The P6 LUT used by the atlas is now this P6-A LUT; P5 and P4
remain unchanged.

The 4096-sample curve audit is:

| Metric | P6 P3B LUT | P6-A LUT |
| --- | ---: | ---: |
| `ds/dm` min / P05 / P95 / max | `-11.325359 / -9.510861 / 20.557968 / 25.817548` | `-7.936050 / -7.668782 / 17.711739 / 24.616059` |
| `dy/dm` min / P05 / P95 / max | `-15.160604 / -10.908469 / 7.518428 / 8.216011` | `-21.608005 / -10.163046 / 8.037832 / 9.072492` |
| arc derivative min / P95 / max | `2.939158 / 20.964314 / 26.640093` | `7.927846 / 21.087538 / 24.617561` |
| max curvature | `37.171374` | `51.304664` |
| material reversal interval | `0.558974..0.692796` | `0.558974..0.692552` |
| reversal count | `1` coherent interval | `1` coherent interval |

The finite derivative audit confirms that P6-A does not introduce a micro-fold
or remove the intended `ds/dm` reversal. The control points and silhouette are
unchanged; only parameter density within the existing landmark segments moves.

The exact P6 Carrier results are:

| Metric | P6 P3B | P6-A |
| --- | ---: | ---: |
| Mean edge stretch | `1.088272` | `1.085732` |
| P95 edge stretch | `1.640811` | `1.451127` |
| Max edge stretch | `2.151577` | `1.993751` |
| Min edge ratio | `0.031317` | `0.100333` |
| Extreme-area triangles | `1204` | `462` |
| Degenerate | `0` | `0` |
| Near-degenerate | `30` | `0` |

The P5->P6 transition was re-run as `phase=5+t`, `t=0..1`, `dt=0.01`, on
1024 shared material samples using the carrier-scaled residual field. The
result is `mean=0.009844`, `P95=0.018117`, `max=0.018692`, worst
`t=0.05`, `material_m=0.727273`; no interior discontinuity was observed.
The final P5 exact report remains `mean=1.152436`, `P95=1.639072`,
`max=2.190717`, `min=0.135802`, `extreme-area=114`, `degenerate=0`,
`near-degenerate=0`, `winding=242`. The P3C full-width row remains identical
to that P5 report.

P3C.1 classification: **P3C.1-A**. P6-A alone clears the collapse gates,
preserves the collapse/fold contract and P5->P6 correspondence, and requires
no P6-B control-point edit.

## Phase 1B — Shape Continuity

Phase 1B separates Coastal breaking authority from local wave shape:
`breaker_environment_strength` is the clamped environment gate, while the
crest uses `crest_core = pow(crest_gate, crest_curve)` exactly once. A smooth
upper-wave support is used for the shoulders and face:

```text
upper_wave_support = smoothstep(-0.25 * crest_height_start_m,
                                max(crest_height_start_m, 0.001),
                                long_displacement.y)
```

The upper front face uses `front_face_gate * upper_wave_support`, so it can
compress toward the crest without independently qualifying as a crest. The
opposite slope uses the same support and follows the crest forward at the
internal `rear_follow_ratio = 0.25`. The resulting deformation is:

```text
crest_forward    = wavelength * forward_push * crest_core * environment
front_compression = wavelength * face_compression * front_face_support * environment
rear_follow       = wavelength * forward_push * 0.25 * rear_shoulder_support * environment
delta_s = clamp(crest_forward + rear_follow - front_compression,
                ± wavelength_m * max_horizontal_fraction)
long_displacement.xz += local_direction * delta_s
long_displacement.y  += min(positive_crest_height * crest_lift_scale
                            * crest_core * environment,
                            positive_crest_height * max_vertical_lift_scale)
```

The crest moves forward, the selected forward face moves back toward it, and
the rear shoulder follows gently. Only positive LONG crests receive lift; MID
and SHORT remain unchanged. The Breaker variant still reconstructs a derivative
geometric normal, but it is now a secondary correction: its maximum blend into
the smooth FFT/Coastal normal is 25%. `normal_follow_strength = 1` therefore
means the maximum safe Phase-1 contribution, not a full normal replacement.

`validation/p7_breakers.tscn` reuses P0's environment, FreeCamera and dev
panel, assigns P4's external valid Coastal bake, enables Coastal/LONG/Breakers,
and deliberately keeps its extreme local diagnostic profile's normal-follow
strength at zero for silhouette review.

## Status

| Area | State |
| --- | --- |
| Structural | pending senior review |
| Runtime | pending senior review |
| Visual | PENDING — Eric |
| Performance | NOT REQUESTED |
| Waterline parity | PENDING |
| Physics/query parity | PENDING |
| Secondary lip geometry | retired after failed 2B2/2B3 prototypes |
| Spray/churn/foam injection | FUTURE |

Promotion blocker: visual deformation approval must be followed by a P7 parity
phase for waterline and query/physics representation before Breakers can become
part of the normal FULL production profile.

## Phase 1C — Fold-Safe Join

Phase 1C makes the continuity envelope wavelength-scaled rather than deriving
its width from the crest detection threshold. The internal span is
`max(crest_height_full_m, wavelength_m * 0.05)`, and the join uses
`smoothstep(-0.50 * span, 0.50 * span, long_displacement.y)`. Crest detection
therefore no longer controls join width.

The main-mesh longitudinal deformation is now non-negative:
`delta_s = clamp(delta_s_raw, 0.0, wavelength_m * max_horizontal_fraction)`.
Front compression is hold-back of forward motion, not backwards travel. The
crest advances, the rear shoulder follows, and the front face stays in place
or advances less; actual overturn/curl remains reserved for the future
localized Breaker Shape. No topology, texture, compute, or resource changes
were made.

Visual: PENDING — Eric.

## Phase 2A — Pre-Lip

Phase 2A adds a narrow forward crest nose to the existing main mesh. The
internal signal derives from the approved crest shape and is restricted to the
forward-facing side of the wave. Its extra forward displacement is added
before the existing fold-safe onset and smooth horizontal cap, without moving
any main-mesh vertex backwards.

Pre-lip lift is composed with the existing crest lift and remains under the
single existing vertical safety cap. There is no downward curl or detached
geometry; true overturn/lip geometry is reserved for the redesigned localized
Breaker Shape. No new samples, topology, or resources were added. Visual:
PENDING — Eric.

## Phase 2A Final Cleanup — One-Sided Main Breaker

The main Breaker carrier is now strictly one-sided. A narrow directional
transition gates `crest_core` with the front downslope, producing
`directional_crest_core`; the pre-lip and both lift terms use the corresponding
`directional_pre_lip_core`. The longitudinal equation is
`delta_s = crest_forward + pre_lip_forward - front_compression`; the rear
shoulder remains the underlying FFT/Coastal wave with no P7 follow or lift.
Breaker normal support uses only the directional crest and front-face support.

The validation profile remains available for main-breaker review. The public
`lip_strength`, `lip_forward_fraction`, and `lip_drop_scale` fields are retained
as reserved authoring concepts for the redesigned localized Breaker Shape; they
perform no secondary draw or shader work. Visual: PENDING — Eric.

## Phase 2B — Secondary Lip Geometry (Retired)

Phase 2B2 independent patchlets failed continuity: neighboring pieces had no
topological continuity and did not form a stable lip. Phase 2B3 then connected
the pieces into a camera-centered wavefront, but per-frame GPU crest searches
produced camera-dependent visibility, unstable shape, and non-production
geometry. Both secondary procedural approaches are removed; no fallback remains.

The explicit architectural conclusion is:

> FFT/Coastal will determine WHERE / WHEN a breaker occurs.
> A dedicated localized Breaker Shape will determine HOW the breaker deforms.

This direction is conceptually consistent with the public Horizon Forbidden
West approach of localized surface deformation assembled and controlled along
wavefronts; no proprietary Waterline internals are assumed.

## P7 Phase 2C — Localized Breaker Shape (Design Only)

The next prototype will keep the base ocean and Coastal authority, derive a
stable world-space breaker wavefront, and evaluate local wave coordinates where
`s` is the propagation axis and `r` is the wavefront tangent:

```text
base ocean + Coastal
    ->
stable world-space breaker wavefront
    ->
local wave coordinates:
    s = propagation axis
    r = wavefront tangent
    ->
lifecycle-controlled localized deformation
    ->
optional future baked deformation atlas/LUT
```

Phase 2C is design-only for now. It is world-space, not camera-centered; it
does not use arbitrary crest argmax searches every frame, CPU readback, or
per-frame topology rebuilds. The first prototype needs no secondary mesh. The
Breaker Shape owns the geometry silhouette, while FFT/Coastal owns underlying
water motion and activation authority. A possible lifecycle is:
`SWELL`, `STEEPEN`, `LEAN`, `LIP`, `PLUNGE`, `COLLAPSE`.

## Phase 1D — Smooth Activation

Phase 1D separates spatial activation from deformation amplitude. The existing
physical `environment_gate` is converted to a smooth activation envelope with
`breaker_activation = smoothstep(0.0, 1.0, clamp(environment_gate, 0.0, 1.0))`.
`breaker_profile_strength` is no longer part of that spatial gate; it becomes
`breaker_amplitude = clamp(breaker_profile_strength, 0.0, 2.0)` and scales the
crest advance, front hold-back, rear follow, and crest lift magnitudes only.
Thus strength changes deformation amplitude, not where the breaker turns on.
The existing horizontal and vertical safety clamps remain authoritative, with
no new samples, topology, or resources. Visual: PENDING — Eric.

## Phase 1E — C1 Smooth Join

The lower longitudinal onset is now a smooth positive transition instead of a
hard lower clamp. Negative `delta_s_raw` still produces exactly zero, while
values just above zero use an internal onset width of
`max(wavelength_m * 0.03, horizontal_limit * 0.08)` and approach the original
positive displacement with a smooth first derivative. The upper safety limit
also uses a smooth cap beginning at 85% of `horizontal_limit`; no hard upper
clamp is reintroduced. Consequently `delta_s >= 0` remains fold-safe while
both ends of the permitted interval are approached continuously. No topology,
texture, compute, or resource changes were made. Visual: PENDING — Eric.

## P3D — Travelling Breaker Phase

P3D keeps `update_breaker_lifecycle.glsl` as the only production local-age
authority. Its contract is unchanged: R is front activity/arrival, G is
history, B is local normalized age, and A is event energy or negative
refractory state. A lifecycle texel that has not yet been reached starts with
`B = 1`, so the Carrier now gates arrival with `R > 0` and uses B only after
arrival. Production phase is therefore `phase_position = 4 + 2 * B`, with no
P4 displacement before arrival.

The Carrier Inspector exposes validation-only `validation_travelling_phase_enabled`
and `validation_travelling_time_s`. This mirror derives arrival and local age
from the same profile speed, seed continuity, and event duration as P3C and
the lifecycle dispatch. It does not replace production lifecycle sampling.
`TRAVELLING_PHASE` debug colors are black for inactive, blue for P4, yellow
for P5, and red for P6. The existing manual override remains valid for exact
4.0, 4.5, 5.0, 5.5, and 6.0 checks.

The CPU validation report is exposed by
`BreakerCarrier.get_travelling_phase_validation_report()` and covers the
requested times `0.0, 0.2, 0.4, 0.6, 0.8, 1.0` and crest positions
`0, ±2, ±4, ±6, ±8, ±12` metres. It also reports lateral phase deltas,
phase-caused neighbor displacement, full 2D edge/area metrics, frontier and
P4/P5 and P5/P6 join contracts, and the unchanged P5/P6 fold report.

Lifetime audit: at the default 4 m/s and 3 m continuity, the active carrier
frontier needs up to `(16 - 3) / 4 = 3.25 s` after the seed to reach the
target half-width, or `4.75 s` from the seed for the outer carrier frontier.
The current configured lifecycle/event lease is `0.80 s`, and the CPU Carrier
retires its event at that lease. This is a P3E lease/handoff issue, not a
reason to change `breaker_event_duration_s` in P3D.

Suppression audit: the Carrier visibility path now uses lifecycle R/B, while
the base-ocean suppression shader still uses its existing A/B energy path.
That possible handoff mismatch is intentionally reported for P3E and is not
altered here. P5 and P6 source profiles, VDM generation, and material
correspondence remain unchanged.

Classification: **P3D-B** — travelling phase mapping is implemented and
validated at the contract level, while the pre-existing Carrier lease and
base-ocean suppression handoff require the later P3E pass. No automatic P3E
work is included.
