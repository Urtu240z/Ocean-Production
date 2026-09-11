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
| Secondary lip geometry | pending visual review |
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
or advances less; actual overturn/curl remains reserved for future secondary
lip geometry. No topology, texture, compute, or resource changes were made.

Visual: PENDING — Eric.

## Phase 2A — Pre-Lip

Phase 2A adds a narrow forward crest nose to the existing main mesh. The
internal signal derives from the approved crest shape:
`pre_lip_core = pow(clamp(crest_core, 0.0, 1.0), 2.5)`. It is activated only
where the Breaker already exists, and its extra forward displacement is added
before the existing fold-safe onset and smooth horizontal cap. The rear
shoulder is released by the internal factor `pre_lip_rear_release = 0.45`,
creating a forward lean without moving any main-mesh vertex backwards.

Pre-lip lift is composed with the existing crest lift and remains under the
single existing vertical safety cap. There is no downward curl or detached
geometry; true overturn/lip geometry is reserved for Phase 2B. The small
residual Phase-1 extreme-profile join remains a known visual note — deferred.
No new samples, topology, or resources were added. Visual: PENDING — Eric.

## Phase 2B — Secondary Lip Geometry

Phase 2B adds one `BreakerLip` `MeshInstance3D` owned by
`OceanClipmapSurface`. It shares the existing `_levels[0].mesh` ArrayMesh, so
there is one additional near-field draw and no duplicate topology or clipmap
level. Its cached shader is built from the same surface source and P7 injection
path, reusing the existing LONG/MID/SHORT, Coastal, Breaker, and Phase 2A
inputs and texture references.

The lip is a narrow upper-crest band shaped by `lip_root`, `lip_throw_shape`,
and `lip_drop_shape`. It receives the forward throw and the true downward
overturn; the primary ocean mesh never receives the downward curl. Visibility
requires effective Breakers, valid Coastal/LONG data, a profile, and both
`pre_lip_strength` and `lip_strength` greater than zero. A camera-centered edge
fade and an early fragment discard prevent the shared carrier from appearing as
a second ocean sheet. Production defaults keep `lip_strength = 0.0`, so the
secondary draw is hidden. Foam and spray are not included; query/physics parity
remains pending. Visual: PENDING — Eric.

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
