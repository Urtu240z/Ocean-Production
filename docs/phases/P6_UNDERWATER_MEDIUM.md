# P6 — Underwater Medium

## Camera-medium waterline

P6 separates the raw rasterized ocean face from the final camera-medium mask.
The raw same-camera clipmap raster has open-ocean LONG, MID and SHORT FFT
parity, including horizontal chop, ring topology and stitch indices. It writes
front-facing/air side as `1`, back-facing/water side as `0`, and separately
stores reverse-Z ocean depth for an exact visible water exit.

Each frame, one GPU camera-state compute invocation samples those same repeat
displacement textures. It applies four fixed-point inverse-horizontal-chop
iterations to solve `P(q).xz = camera.xz`, then writes signed camera height,
dynamic surface height and validity to a P6-owned storage buffer. No CPU FFT,
OceanQuery, readback, synchronization, camera offset or second camera is used.

The final P6 compute uses `enter_margin_m` and `exit_margin_m` from the existing
medium profile:

- above the exit margin, the final mask is full-screen white (air);
- below the enter margin, it is full-screen black (water);
- only in the dead-band does raw raster side make the moving FFT split; pixels
  outside raw coverage fall back to the signed camera height.

If the camera-state query is invalid, normal mode safely falls back to the raw
face classification and debug mode displays magenta. The raw ocean depth never
controls medium membership. It only shortens a water pixel's optical path when
the valid raw face is water, preserving the exact ocean exit when looking up
from underwater. Above water receives no P6 medium adjustment.

The former fullscreen horizon classifier has been retired. Coastal P6 parity is
pending; this path intentionally covers open ocean only.

## Lifecycle and validation

P6 owns its camera-state shader, pipeline, 16-byte storage buffer, raster
targets and pipelines. They exist only while **Underwater Medium** is enabled;
the state buffer is resize-independent while screen targets are recreated on
resize. Shared FFT textures are sampled but never freed by P6.

Set **Waterline Mask Debug** to validate: clearly above water is entirely
white, clearly below water is entirely black, and only an actual local crossing
shows the exact moving FFT boundary. Final visual approval remains with Eric.
