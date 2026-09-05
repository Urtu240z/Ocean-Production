# P6 — Waterline Mask Prototype

## Current objective

P6 is temporarily a GPU-only waterline-mask validation pass. It does not run
Beer–Lambert absorption or scattering. The presentation is binary:

- black (`0`): air-facing ocean surface, or no ocean surface;
- white (`1`): underwater-facing ocean surface.

This must be visually approved before the optical medium is reconnected.

## Authority and method

The post-transparent effect reads the resolved depth produced by the existing
double-sided ocean clipmap. For each depth pixel it samples the same LONG, MID
and SHORT displacement and normal maps, domains, and fade ranges supplied to
the current surface shader. It recognizes the visible ocean surface by its
resolved position and evaluates its facing from the same weighted FFT normal.

The result is written every debug frame to an effect-owned `R8_UNORM` mask and
presented directly as black/white. It therefore follows the already-rasterized
clipmap silhouette; it does not create a second ocean mesh, a substitute FFT,
or a second camera.

Coastal modifications remain out of scope for this prototype.

## Camera and threading

`Camera3D` is read only by Godot's render-scene data to construct the
per-frame GPU packet. P6 never offsets, reparents, or otherwise writes camera
state. There is no CPU FFT evaluator, GPU readback, `RenderingDevice.sync()`,
or OceanQuery route.

The effect prewarms its shader, compute pipeline, sampler, and parameter buffer
on the render thread when **Systems > Underwater Medium** is enabled. The R8
mask is allocated and resized only on that same render thread. Turning the
system off detaches the effect and frees all effect-owned RIDs.

## Source publication

`OpenOceanFFT` retries source publication until all six solver-owned RIDs are
valid: LONG/MID/SHORT displacement plus LONG/MID/SHORT normals. It publishes
them once, and never treats `RID()` as success. The compositor refuses to form
a uniform set until that complete source set exists, with at most one delayed
startup warning.

## Validation

Open `validation/p6_underwater_medium.tscn`, enable **Systems > Underwater
Medium**, and leave **Waterline Mask Prototype > Waterline Mask Debug** on.
With the camera exactly at a wave, inspect the black air-facing and white
underwater-facing portions while rotating and while the waves move. Test
crossings, then turn the system off and on again to confirm resource lifecycle.

Structural: PASS. Headless runtime: PASS. Visual waterline match: PENDING ERIC.
