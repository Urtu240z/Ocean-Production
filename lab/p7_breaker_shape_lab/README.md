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

The synthetic shape uses `lateral = u * 2 - 1`, a lateral envelope fading from
0.70 to 1.0, rear/front fades at 0.08/0.22 and 0.92/1.0, and Gaussian-like
crest/nose lobes centered at 0.62/0.74. The signed amplitudes are:

```text
G = (2.8 * crest - 1.4 * falling_tip) * envelope
B = (3.0 * nose - 0.8 * smoothstep(0.84, 0.98, v)) * envelope
R = 0
A = envelope
```

The breaker frame is captured once from the initial camera: origin is 18 m in
front of it, propagation is the projected camera-forward direction, width is
18 m and length is 12 m. Camera movement never updates that frame.

Inside the VDM box, the lab attenuates the existing base displacement with
`surface_displacement *= 1 - breaker_mask * 0.90` and then adds the vector
offset in tangent/up/propagation world axes. Modes are BASE, FLATTEN_ONLY,
VDM_ONLY, and COMBINED (keys 5–8 respectively; COMBINED is default). Keys 1–4
remain available to the validation FFT cascade gate.
