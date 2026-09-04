# P5 — Reflections / SSPR

Authority is the active Ocean V3 route in `Water Race Ocean Lab`: Project,
Resolve, Temporal and mip generation run in a `CompositorEffect` at
`PRE_TRANSPARENT`, before the transparent water surface.

Production creates an `OceanSSPR` only while **Systems > Reflections** is on.
It owns the compositor attachment and the RenderingDevice resources. The target
size is `ceil(internal viewport * 0.40)`, Project/Resolve/Temporal use 8×8
groups, candidates are `uint`, raw/final/temporal-history color is RGBA16F and
depth history is R16F. The final texture has a mip chain. Kawase and Near SSR
are deliberately absent from the active path.

Project rejects sky and invalid depth. Resolve writes HDR linear RGB with alpha
as confidence, including the V3 local hole fill confidence of 0.35. A miss is
`vec4(0)`. Temporal reprojects the ocean plane and starts invalid after resize,
enable and resource recreation; its effective settings are enabled, 0.12 weight
and 0.035 depth threshold.

The material keeps `shading_normal_world` for FFT macro distortion and derives
`visual_normal` explicitly for Godot's view-space `NORMAL`. P2/P3 foam changes
the final roughness, so it attenuates SSPR; it does not destabilize projection.
P4 continues to use its view-space refraction normal. `RADIANCE.rgb` carries
the graded SSPR result and `RADIANCE.a` carries confidence: zero confidence
preserves Godot PBR/environment/IBL rather than displaying black.

Effective V3/Lab defaults: base roughness 0.08, range 80–300 m, distortion 1,
edge fade 0.25, exposure −1.5 EV, saturation 0.36, SSPR weight 0.55 and
environment specular boost 0.65. Water IOR is 1.333 (F0 0.020373).

OFF is structural: the surface returns to its base or P4-only shader first,
then the compositor detaches and all SSPR buffers, texture views, pipelines and
shaders are released. Resize retires the old published view before release and
only publishes a completed new final target.

`res://validation/p5_reflections.tscn` provides red, blue/green, white and dark
objects at near/far/grazing positions. `p5_reflections_runtime_validation.gd`
performs 20 OFF→ON cycles. Eric granted the visual pass manually after
confirming the reflection behavior and fallback confidence path.

## Estado

```yaml
Structural: PASS
Runtime: PASS
Visual: PASS — Eric
Performance: PASS — measured
```

## PERFORMANCE

The official P5 measurement was temporary and was deleted before the P5 commit.
It used the same light P2/P3/P4-style validation workload for every state, not
the heavy Kloofendal HDRI, SSAO/SSIL, Glow, Fog or Paradise fixture. The metric
is the average wall-clock interval between frame callbacks; it is not GPU time.

| Campo | Valor |
| --- | --- |
| Hardware | Intel i7-13650HX; NVIDIA GeForce RTX 4070 Laptop GPU |
| Godot / renderer | Godot 4.7 stable official `5b4e0cb0`; Forward+ / D3D12 |
| Resolution | 1920x1080 |
| Render scale | 1.00 |
| VSync / FPS cap | OFF / `Engine.max_fps = 0` |
| Camera | Fixed P0 `FreeCamera`, origin `(0, 8, 16)`, fixed orientation; process disabled; no input |
| Seed / profiles | P0 seed `20260820`; same Wave Profile, Quality Profile and scene for all states |
| Runtime state | Open Ocean FFT ON; Crest ON; Surface Foam ON; Coastal OFF; Optics OFF |
| Warmup / measurement | 3.0 s / 5.0 s per state |
| Metric | Average wall-clock frame interval; FPS is `1000 / average_frame_ms` |

Three alternating OFF/ON pairs were measured in one session:

| Pair | SSPR OFF | SSPR ON |
| ---: | ---: | ---: |
| 1 | 1.831 ms / 546.2 FPS | 2.068 ms / 483.6 FPS |
| 2 | 2.124 ms / 470.9 FPS | 2.223 ms / 449.9 FPS |
| 3 | 1.898 ms / 527.0 FPS | 2.129 ms / 469.7 FPS |
| Average | **1.951 ms / 512.6 FPS** | **2.140 ms / 467.3 FPS** |

| P5 marginal cost | Value |
| --- | ---: |
| Delta ON − OFF | +0.189 ms |
| Delta FPS | -45.3 FPS |
| Frame-interval increase | +9.69 % |
| Sample range | OFF 1.831–2.124 ms; ON 2.068–2.223 ms |

The OFF path was verified as the base shader with no `reflection_sspr_texture`,
screen/depth hints, `OceanSSPR` owner, compositor effect or published SSPR
texture. The ON path was verified as the dynamic SSPR material variant with
SSPR sampling, an attached `OceanSSPREffect` at `PRE_TRANSPARENT`, valid
Project/Resolve/Temporal/Downsample pipelines, a final target, mip chain and
published reflection texture. This is a measured marginal wall-clock result,
not a GPU-cost claim.

The temporary measurement script and any runtime benchmark configuration were
removed. Production has no benchmark dependency or addon performance/debug code.
