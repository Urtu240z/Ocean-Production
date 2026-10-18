# Boundary tsunami — 2026-10-18

Implemented in Ocean Production. Existing playground/sea tuning is preserved;
no Test Add-ons files were changed. The optional scene is
`addons/ocean/events/boundary_tsunami.tscn`.

## Reference and behaviour

Read the original Water Race `BoundaryWipeoutController3D` and `EventWave3D`, plus
the Paradise Island boundary setup: radius 800 m, spawn distance 1200 m and a
10 m event-wave amplitude multiplied by 6. The old implementation spawned a
directional front and requested the existing wipeout context on crest crossing.

The new default radius is editable (1000 m); amplitude 60 m. The new front is a
converging circular crest around an explicitly selected map centre. It cannot be
sidestepped and closes faster than the target's measured radial escape speed,
with a catch deadline. It stays active on re-entry. Detection ignores altitude.

The render and CPU profile share the same asymmetric Gaussian crest and leading
trough. The waveform is a scripted additive event, not another FFT or a full
hydrodynamic tsunami simulation. The real surface builder injects it into all
variants, including hull foam. CPU contacts receive height, slope and vertical
speed after local FFT and hull-wave overlays. The underwater shader samples the
same world-space event profile. The wave extends the mesh's culling bounds.

The wave-state buffer now has 1152 bytes (previous local FFT buffer 1104 plus
three event vec4 parameters). Existing six local FFT sampler bindings are reused;
the event itself allocates no textures and performs no GPU readback.

## Jet Ski integration

The portable Jet Ski had the wipeout API/context but no WipeoutSystem scene.
The adapter now uses a host-provided system when present, otherwise a lazy
standalone fallback locks controls, applies the incident impulse/tumble, and
returns to the recorded/assigned safe pose after four seconds. Ordinary manual
ejection still does not gain an unrelated fallback. No rider ragdoll was added.
Recovery Point can explicitly select safe water; the last-resort radial return
does not collision-test islands, so a marker is recommended for real maps.

## Validation

Godot 4.7.1, RTX 4070 Laptop, Forward+/D3D12:

- `tsunami_boundary_check.gd`: PASS for stationary, 100 m/s outward, 100 m/s inward
  and lateral escape. Each target is caught once before the deadline. Covers a
  nonzero centre, altitude independence, swept crest alignment, recovery/rearm,
  real Jet Ski context adapter and standalone control-lock/recovery fallback.
- Analytic slopes vs finite differences: maximum error 0.000527. Vertical velocity
  vs a moving-wave finite difference: maximum error 0.00491 m/s (away from the
  asymmetric width join's discontinuous second derivative).
- `tsunami_render_check.gd`: PASS on the real generated hull-foam material.
  CPU height error 0 m; GPU underwater sensor error 0.00000382 m at a
  59.47955 m crest. Verifies surface publication and at least 75 m of event culling
  allowance. Screenshot: `temp/tsunami/surface.png`.
  Perspective screenshot near rider height: `temp/tsunami/approaching.png`.
- `tsunami_jet_ski_check.gd`: PASS with the real standalone Jet Ski scene and
  Ocean connection. Fallback activates, real controls lock, reset completes once,
  controls unlock and the vehicle returns to the supplied safe pose.

Logs are under `temp/tsunami_*.log`. An auxiliary headless editor import logged
a Windows hot-reload DLL copy conflict while another process owned the temporary
library; the subsequent actual runtime tests loaded the native extension and
passed. No native binary was modified.

`local_fft_states_check.gd` also passes after the integration: H0 relative error
0, CPU/GPU local-height error 0.00984 m, including local FFT mixing, full chop,
independent scales, underwater sensing and continuous speed changes.
