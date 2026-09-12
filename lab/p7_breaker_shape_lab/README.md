# P7 Phase 2C2C1 — Waterline Shore-Space VDM Breaker Lab

The lab first loads the temporary local reference at
`res://temp/waterline_source/T_PL_Wave_1_Disp_source.bin`. It accepts the
512 × 512 RGBA16F payload and reports `VDM SOURCE: WATERLINE RAW`. If that
file is missing, the existing authored EXR and then the procedural VDM are
used.

Waterline alpha is intentionally not used as authority (it is 1.0 everywhere).
For the Waterline RAW adapter, the fixed LAB frame is treated as a synthetic
shore field: `U = breaker_shape_uv.y` is shore distance/propagation and
`V = breaker_shape_uv.x` is along-shore/lateral. The temporary authority is
bounds × shallow/deep distance gates. The Waterline displacement contract is:

* R → horizontal displacement along the synthetic Shore Direction
* B → vertical displacement
* G → unused in primary geometry
* propagation scale 6.0, vertical scale 18.0

Keys `5–8` select BASE, FLATTEN_ONLY, VDM_ONLY, and COMBINED. The default
startup mode is VDM_ONLY (key `7`). Key `0` toggles Waterline U flip and key
`9` toggles Waterline V flip; both are OFF by default. The frame remains fixed
in world space; there is no time, animation, camera tracking, CPU readback,
topology rebuild, secondary mesh, normal texture, or foam integration.

The Waterline files are proprietary temporary data. They remain under
`temp/waterline_source/`, which is excluded through `.git/info/exclude` and is
never committed or included in a build.

This isolated scene proves a localized authored breaker shape on the production
ocean clipmap. It uses the real FFT LONG/MID/SHORT surface and a lab-only shader
variant; there is no fake water renderer, secondary mesh, ribbon, readback, or
per-frame topology work.

The procedural fallback is generated once at startup as a 256 × 256
`Image.FORMAT_RGBAH` `ImageTexture` and retains its own local RGB contract. The
temporary Waterline source is sampled in shore-space as described above:

* R — horizontal Shore Direction displacement (m)
* B — vertical displacement (m)
* G — not used for primary geometry
* A — ignored for authority (non-authoritative source alpha)

The synthetic shape uses four connected cubic Bezier sections (A `0.00–0.40`,
B `0.40–0.65`, C `0.65–0.84`, D `0.84–1.00`) with standard cubic evaluation.
The sections are:

```text
A: (-6.00,0.00) (-4.50,0.00) (-2.30,0.65) (-0.80,1.80)
B: (-0.80,1.80) (0.35,2.85) (1.85,3.75) (2.85,3.20)
C: (2.85,3.20) (3.45,2.75) (3.00,1.55) (1.60,0.95)
D: (1.60,0.95) (1.20,0.65) (3.20,0.15) (6.00,0.00)
```

For each texel, `source_s = (v - 0.5) * 12.0`, then the signed displacement
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

The lateral authority is `1 - smoothstep(0.82, 1.0, abs(lateral))`, preserving
the central wavefront while fading only its outer edges. A static phase shift
of `0.010 * sin(lateral * PI * 2) + 0.004 * sin(lateral * PI * 5 + 0.7)` and a
`0.035 * sin(lateral * PI * 3 + 1.2)` crest scale break perfect extrusion.
Tangent displacement is `0.11 * sin(lateral * PI * 2) * lateral_authority`.

The breaker frame is captured once from the initial camera: origin is 18 m in
front of it, propagation is the projected camera-forward direction, width is
18 m and length is 12 m. Camera movement never updates that frame.

Inside the VDM box, the lab attenuates the existing base displacement with
`surface_displacement *= 1 - breaker_mask * 0.90` and then adds the vector
offset. Waterline RAW uses R along the synthetic Shore Direction and B upward;
the procedural fallback retains its own tangent/up/propagation contract.
Modes are BASE, FLATTEN_ONLY, VDM_ONLY, and COMBINED (keys 5–8 respectively;
VDM_ONLY is the Waterline proof default). Keys 1–4 remain available to the
validation FFT cascade gate.
