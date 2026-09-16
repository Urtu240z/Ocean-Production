# H2.2 — FFT normal scale parity

## Resource ownership audit

- `GPUStockhamFFT` owns the transient `RenderingDevice` resources for one
  cascade: H0, ping-pong images, displacement, normal, and optional Crest
  images. They are created, dispatched, and freed on the render thread.
- `OpenOceanFFT` owns the active GPU generation and its generation identity.
  It is the only owner allowed to retire a generation and publish its ready
  RIDs to the persistent `Texture2DRD` wrappers.
- The neutral displacement, neutral normal, and neutral Crest RIDs are owned
  by the active generation. Their wrappers are persistent presentation
  objects; they are bound only after `neutral_ready` for the current
  generation.
- Crest Foam resources follow the same generation rule. Surface Foam owns its
  own GPU resources and `OpenOceanFFT` only binds its ready RIDs, with a
  cached RID per wrapper.
- `OceanClipmapSurface` owns material bindings and samples published textures;
  it never owns or frees the underlying `RenderingDevice` RIDs.

## Normal contract

`assemble_maps.glsl` reconstructs each FFT normal in authored Ocean Space,
including the horizontal displacement/choppiness derivatives. For the final
presentation transform `S = diag(H, V, H)`, the surface geometry applies `H`
to X/Z and `V` to Y, so consumers use the inverse-transpose normal:

```text
normalize(vec3(N.x / H, N.y / V, N.z / H))
```

The shader writes this as `vec3(N.x * V / H, N.y, N.z * V / H)` before
normalization. LONG, MID, SHORT, Coastal-warped LONG, Breakers, optical wave
slope, and the Spindrift particle normal consumer use the same contract.
Surface Detail A/B is authored as a separate world-space detail layer and is
not transformed a second time.

Underwater Medium, Waterline, and Bubbles consume displacement/readback data,
not the FFT normal maps, so they require no normal transform. SSPR and Coastal
retain their existing resource/coordinate ownership; only the Coastal-warped
normal sample inside the Surface material is transformed.

Scale changes only update presentation uniforms and effective wave domains;
they do not rebuild FFT textures or change spectrum, choppiness, timing, or
foam authority.
