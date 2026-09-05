# P6 — Waterline Mask Prototype

## Current objective

P6 uses a GPU-only, full-screen waterline-region classifier. Its debug
presentation is binary:

- black (`0`): the screen pixel begins in air at the camera near plane;
- white (`1`): the screen pixel begins in water at the camera near plane.

With **Waterline Mask Debug** off, Beer–Lambert absorption and scattering use
the existing P6 profile values only in white/water pixels. Air pixels return
without touching the resolved scene color.

## Authority and method

For every screen pixel, the post-transparent effect reconstructs the world
position on the camera near plane through P6's inverse view-projection path.
Godot 4.7 reversed-Z uses depth `1.0` for that plane. The effect then evaluates
the same LONG, MID and SHORT displacement maps, domains, and fade ranges used
by the current open-ocean clipmap. A pixel is white precisely when its near
plane position is below the resulting dynamic surface height.

The result is written every frame to an effect-owned `R8_UNORM` mask. When
debug is enabled it is presented directly as black/white. The classifier itself
does not inspect resolved scene depth, surface normals, front/back faces, or
nearby mask pixels; it does not create a second ocean mesh, a substitute FFT,
or a second camera.

With debug disabled, the existing P6 resolved-depth/world reconstruction and
Beer–Lambert/scattering formula run only where the mask is water. This optical
path is intentionally approximate during partial submersion: it has no dynamic
ocean-entry depth yet. Transparent-object underwater handling is likewise out
of scope for this validation.

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
Medium**, and leave **Waterline Mask Prototype > Waterline Mask Debug** off to
test the masked medium. Turn it on only to inspect the binary region. With the
camera exactly at a wave, inspect the air/underwater boundary while rotating
and while the waves move. Test crossings, then turn the system off and on again
to confirm resource lifecycle.

Structural: PASS. Headless runtime: PASS. Visual waterline match: PENDING ERIC.

## Near-plane mask audit watchlist

The open-ocean region classifier remains intentionally simpler than a second
ocean raster pass. Before it becomes the permanent P6 classifier, validate it
at steep choppy crests, clipmap LOD transitions, extreme pitch/yaw, different
FOVs and viewport sizes, and the far horizon. Watch specifically for near-plane
edge artefacts, one-pixel holes, LOD overlaps or gaps, horizon fill failures,
meniscus needs, transparent-object interactions, and disagreement caused by
horizontal wave displacement.

This mask classifies only the air/water region. It does **not** provide ocean
entry depth, which will still be needed for a correct partial-submersion optical
path. Coastal deformation is also deliberately not part of this open-ocean
prototype. If a repeatable visual mismatch appears, report it before replacing
this route with an exact-geometry raster mask/depth architecture.
