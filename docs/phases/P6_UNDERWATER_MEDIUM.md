# P6 — Underwater Medium

## Waterline architecture

P6 uses an isolated GPU raster pass for the waterline. It references the same
already-built `ArrayMesh` resources as the visible `OceanClipmapSurface` and
uses the active surface shader's unchanged vertex path. Consequently the mask
has the visible ocean's LONG, MID and SHORT displacement, horizontal chop,
clipmap LOD rings and stitch indices; it does not build a second mesh or run a
second FFT solver.

Two HDR `SubViewport` colour targets are rasterized with their own 3D depth
attachments:

- mask: front-facing surface is `1` (air side), back-facing surface is `0`
  (underwater side), with culling disabled;
- ocean depth: the matching rasterized `FRAGCOORD.z` value, used as the ocean
  entry point by the compositor.

The P6 compositor reads the two targets alongside resolved scene colour/depth.
In debug mode, black is air and white is the rasterized underwater region. In
normal mode, Beer–Lambert absorption and scattering use the distance from the
ocean entry point to the resolved scene point. This is one-entry optical
handling only; multiple crossings and transparent-object treatment remain out
of scope.

The game `Camera3D` is never offset, reparented or otherwise mutated. The
isolated pass copies its current view and projection into its own raster world
so both target pixels correspond to the visible rendering. There is no CPU FFT,
GPU readback, `RenderingDevice.sync()`, screen-space horizontal plane or
near-plane FFT classifier.

## Scope and lifecycle

The current raster mask has open-ocean parity. Coastal deformation is excluded:
do not claim coastal waterline parity yet.

When **Systems > Underwater Medium** is enabled, P6 attaches the compositor
effect and prewarms its shader, compute pipeline, sampler and parameter buffer
on the render thread. The raster targets are retried until both RenderingDevice
RIDs are valid; no invalid RID is published as success. Turning the system off
detaches the effect and destroys the P6 raster owners; P6 owns no persistent
RenderingDevice resources while off.

## Validation

Open `validation/p6_underwater_medium.tscn`, enable **Systems > Underwater
Medium**, and set **Waterline Mask Debug** to inspect the binary mask. At the
waterline, rotate the camera and let waves move across it: the boundary should
be the rasterized ocean silhouette. Turn debug off to test the existing medium
values. Visual approval remains with Eric.
