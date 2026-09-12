# P7 Phase 2C2C3 — Auto-placed Coastal → Waterline VDM Breaker Lab

The lab first loads the temporary local reference at
`res://temp/waterline_source/T_PL_Wave_1_Disp_source.bin`. It accepts the
512 × 512 RGBA16F payload and reports `VDM SOURCE: WATERLINE RAW`. If that
file is missing, the existing authored EXR and then the procedural VDM are
used.

The scene enables the existing Coastal bake at
`res://validation/p4_paradise/coastal_bake.tres` while leaving legacy
production Breakers disabled. Waterline alpha is intentionally not used as
authority (it is 1.0 everywhere). At startup the lab scans the baked
bathymetry once, selects water closest to `2.5 m` within `1.5–4.0 m`, and
centres a fixed `32 m × 32 m` test patch there. For Waterline RAW, that
rectangle only limits the visual test patch; all placement data comes from real
Coastal: depth supplies the shore-distance coordinate U, and Coastal phase
supplies the shore direction and stable world-space tangent for V.

The Waterline displacement contract is:

* R → horizontal displacement along real Coastal Shore Direction
* B → vertical displacement
* G → unused in primary geometry
* propagation scale 6.0, vertical scale 18.0

Keys `5–8` select BASE, FLATTEN_ONLY, VDM_ONLY, and COMBINED. The default
startup mode is VDM_ONLY (key `7`). Waterline U/V flips are locked OFF. The
frame is fixed after auto-placement; there is no time, animation, camera
tracking, CPU readback, topology rebuild, secondary mesh, normal texture, or
foam integration.

The Waterline files are proprietary temporary data. They remain under
`temp/waterline_source/`, which is excluded through `.git/info/exclude` and is
never committed or included in a build.

This isolated scene proves a localized authored breaker shape on the production
ocean clipmap. It uses the real FFT LONG/MID/SHORT surface and a lab-only shader
variant; there is no fake water renderer, secondary mesh, ribbon, readback, or
per-frame topology work.

The procedural fallback is generated once at startup as a 256 × 256
`Image.FORMAT_RGBAH` `ImageTexture` and retains its own local RGB contract. The
temporary Waterline source is sampled from the real Coastal shore-space field:

* R — horizontal Coastal Shore Direction displacement (m)
* B — vertical displacement (m)
* G — not used for primary geometry
* A — ignored for authority (non-authoritative source alpha)

The procedural fallback shape uses four connected cubic Bezier sections (A `0.00–0.40`,
B `0.40–0.65`, C `0.65–0.84`, D `0.84–1.00`) with standard cubic evaluation.
The sections are:

```text
A: (-6.00,0.00) (-4.50,0.00) (-2.30,0.65) (-0.80,1.80)
B: (-0.80,1.80) (0.35,2.85) (1.85,3.75) (2.85,3.20)
C: (2.85,3.20) (3.45,2.75) (3.00,1.55) (1.60,0.95)
D: (1.60,0.95) (1.20,0.65) (3.20,0.15) (6.00,0.00)
```

For each fallback texel, `source_s = (v - 0.5) * 12.0`, then the signed displacement
is encoded as `B = target_s - source_s`, `G = target_y`, `R = 0`, with the
authority mask below. The deliberate backward movement in Section C and the
start of D creates the curl before the forward reconnection.

```text
R = 0
G = target_y
B = target_s - source_s
A = lateral_authority * smoothstep(0.00, 0.08, v)
    * (1.0 - smoothstep(0.96, 1.00, v))
```

The fallback lateral authority is `1 - smoothstep(0.82, 1.0, abs(lateral))`, preserving
the central wavefront while fading only its outer edges. A static phase shift
of `0.010 * sin(lateral * PI * 2) + 0.004 * sin(lateral * PI * 5 + 0.7)` and a
`0.035 * sin(lateral * PI * 3 + 1.2)` crest scale break perfect extrusion.
Tangent displacement is `0.11 * sin(lateral * PI * 2) * lateral_authority`.

The breaker frame is captured once at startup from the selected bathymetry
point. Its limiter direction is the normalized bathymetry depth gradient
(falling back to initial camera-forward if degenerate); this direction only
orients the local rectangular safety limiter. Coastal phase remains the sole
Waterline displacement direction. Camera movement never updates the frame.

Inside the local VDM box, the lab attenuates the existing base displacement with
`surface_displacement *= 1 - breaker_mask * 0.90` and then adds the vector
offset. Waterline RAW uses R along the real Coastal Shore Direction and B upward;
the procedural fallback retains its own tangent/up/propagation contract.
Modes are BASE, FLATTEN_ONLY, VDM_ONLY, and COMBINED (keys 5–8 respectively;
VDM_ONLY is the Waterline proof default). Keys 1–4 remain available to the
validation FFT cascade gate.

For Waterline RAW, Coastal depth is translated to U with near/far depths
`0.25 / 8.0 m`. Ownership is depth-only Waterline style:
`smoothstep(0.25, 0.75, depth) * (1 - smoothstep(6.0, 10.0, depth))`.
`field.a`, Coastal confidence, `phase_info.a` and VDM alpha do not gate this
lab ownership mask. The world-space along-shore period is `18.0 m`; no time,
panning or camera tracking is involved.
