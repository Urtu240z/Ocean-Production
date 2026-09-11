# P7 Phase 2C2 — Authored 2D VDM

`blender_generate_breaker_vdm.py` is an offline-only authoring script for the
synthetic P7 breaker VDM. It does not import or reproduce any proprietary
Waterline asset or data.

Run from the repository root with Blender:

```text
blender -b --python tools/breaker_vdm_authoring/blender_generate_breaker_vdm.py
```

The script writes `addons/ocean/breakers/assets/breaker_plunging_test_v01.exr`
at 512 × 256, RGBA OpenEXR, 16-bit half-float, linear color space. RGB values
are signed meters and A is a 0..1 authority mask:

```text
R = tangent displacement (m)
G = vertical displacement (m)
B = propagation displacement (m)
A = authority / flatten mask
```

The profile uses the four connected cubic Bezier sections from Phase 2C1C and
broad deterministic lateral variation: ±0.035/±0.015 phase shifts in V,
approximately ±10% crest scale, ±0.35 m nose variation, ±0.22 m curl variation,
and up to 0.30 m tangent meander. The authority fades smoothly at the rear,
front, and outer lateral edges, with a small coherent edge irregularity. No
white noise, per-column randomness, animation, or runtime generation is used.

Godot prefers this EXR when it exists. At lab startup it checks for 512 × 256
RGBAH/RGBAF import and reports `VDM SOURCE: EXTERNAL EXR`; otherwise it uses the
existing procedural fallback and reports `VDM SOURCE: PROCEDURAL FALLBACK`.
The EXR must remain linear and floating point; do not enable lossy color
compression or sRGB conversion for this displacement asset.
