# P6 — Waterline Mask Prototype

## Current objective

P6 is temporarily a GPU-only, full-screen waterline-region validation pass. It
does not run Beer–Lambert absorption or scattering. The presentation is binary:

- black (`0`): the screen pixel begins in air at the camera near plane;
- white (`1`): the screen pixel begins in water at the camera near plane.

This must be visually approved before the optical medium is reconnected.

## Authority and method

For every screen pixel, the post-transparent effect reconstructs the world
position on the camera near plane through P6's inverse view-projection path.
Godot 4.7 reversed-Z uses depth `1.0` for that plane. The effect then evaluates
the same LONG, MID and SHORT displacement maps, domains, and fade ranges used
by the current open-ocean clipmap. A pixel is white precisely when its near
plane position is below the resulting dynamic surface height.

The result is written every debug frame to an effect-owned `R8_UNORM` mask and
presented directly as black/white. It does not inspect resolved scene depth,
surface normals, front/back faces, or nearby mask pixels; it does not create a
second ocean mesh, a substitute FFT, or a second camera.

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

`OpenOceanFFT` retries source publication until all three solver-owned LONG,
MID and SHORT displacement RIDs are valid. It publishes them once, and never
treats `RID()` as success. The compositor refuses to form a uniform set until
that complete source set exists, with at most one delayed startup warning.

## Validation

Open `validation/p6_underwater_medium.tscn`, enable **Systems > Underwater
Medium**, and leave **Waterline Mask Prototype > Waterline Mask Debug** on.
With the camera exactly at a wave, inspect the black air-facing and white
underwater-facing portions while rotating and while the waves move. Test
crossings, then turn the system off and on again to confirm resource lifecycle.

Structural: PASS. Headless runtime: PASS. Visual waterline match: PENDING ERIC.
