# P7 Phase 2C1 — Fixed World-Space Vector Displacement Breaker Lab

This isolated scene proves a synthetic breaker shape on the production ocean
clipmap. It uses the real FFT LONG/MID/SHORT surface and a lab-only shader
variant; there is no fake water renderer, secondary mesh, ribbon, readback, or
per-frame topology work.

The VDM is generated once at startup as a 256 × 256 `Image.FORMAT_RGBAH`
`ImageTexture`. Its signed meter contract is our own convention:

* R — tangent displacement (m)
* G — vertical displacement (m)
* B — propagation-axis displacement (m)
* A — breaker authority / flatten mask (0..1)

The synthetic shape uses an explicit C1 Catmull–Rom plunging profile. The
control points are `(v, target_s_m, target_y_m)`:

```text
(0.00, -6.00, 0.00)  (0.12, -5.10, 0.05)  (0.25, -3.75, 0.25)
(0.38, -2.25, 0.80)  (0.50, -0.70, 1.75)  (0.60,  0.65, 2.75)
(0.68,  1.75, 3.35)  (0.74,  2.65, 3.45)  (0.79,  3.20, 2.90)
(0.84,  2.85, 2.10)  (0.89,  2.15, 1.25)  (0.93,  1.85, 0.65)
(0.96,  3.60, 0.20)  (1.00,  6.00, 0.00)
```

For each texel, `source_s = (v - 0.5) * 12.0`, then the signed displacement
is encoded as:

```text
G = target_y
B = target_s - source_s
R = 0
A = lateral_authority * smoothstep(0.00, 0.08, v)
    * (1.0 - smoothstep(0.96, 1.00, v))
```

The lateral authority is `1 - smoothstep(0.78, 1.0, abs(lateral))`, preserving
the central wavefront while fading only its outer edges. The deliberate
non-monotonic target-s section `3.20 -> 2.85 -> 2.15 -> 1.85` creates the
backward curl before the profile returns through `3.60 -> 6.00`.

The breaker frame is captured once from the initial camera: origin is 18 m in
front of it, propagation is the projected camera-forward direction, width is
18 m and length is 12 m. Camera movement never updates that frame.

Inside the VDM box, the lab attenuates the existing base displacement with
`surface_displacement *= 1 - breaker_mask * 0.90` and then adds the vector
offset in tangent/up/propagation world axes. Modes are BASE, FLATTEN_ONLY,
VDM_ONLY, and COMBINED (keys 5–8 respectively; COMBINED is default). Keys 1–4
remain available to the validation FFT cascade gate.
