# PHYS-OPT-2A — CPU FFT mirror prototype

Status: parity-validated synchronous prototype with a persistent worker pool.
The direct native spectral solver remains the reference oracle. This document
records the audited Production contract and current limits; it does not certify
PHYS-OPT-2A acceptance.

## Production FFT contract (runtime: Godot 4.7.1)

| Band | N | Domain L | dx | Stockham stages | 2D complex IFFTs |
|---|---:|---:|---:|---:|---:|
| LONG | 256 | 512 m | 2 m | 8 per axis / 16 passes | 6 |
| MID | 256 | 137 m | 0.53515625 m | 8 per axis / 16 passes | 6 |
| SHORT | 256 | 37 m | 0.14453125 m | 8 per axis / 16 passes | 6 |

`open_ocean_fft.gd` builds each final spectrum and retains the exact RGBA32F H0
bytes uploaded to its GPU solver. H0 `xy` is H0(k), `zw` is the paired
opposite-wave source. `evolve_spectrum.glsl` computes

```text
k = (texel - N/2) * 2π/L
ω = sqrt(g |k|)
H(k,t) = H0(k)e^(-iωt) + H0(-k)e^(+iωt)
Dx = (-i H) * (kx/|k|) * (-choppiness)
Dz = (-i H) * (kz/|k|) * (-choppiness)
```

It also writes spectral derivatives for horizontal displacement. The renderer
uses positive-twiddle Stockham IFFT stages, then `assemble_maps.glsl` applies
`1/N²` and `(-1)^(x+y)`; displacement texture channels are R=Dx, G=height,
B=Dz, A=per-band Jacobian. Render normals use centered geometry differences.
The renderer does not publish surface velocity; the native direct oracle
derives velocity from the same H0 and ω state.

The texel lattice is indexed by FFT-q `iL/N`. External material-q maps to it
using the established per-band offset `L/2 - L/(2N)`, periodic wrap, then
manual periodic bilinear sampling. No camera or GPU resource is used by the
CPU sampler.

## Direct native oracle

`OceanQueryNative` is configured by `phys1_spectrum_adapter.gd` from the exact
retained Production H0 snapshot. It also derives the matching k grid, gravity
frequency, choppiness coefficients and per-band material-q conversion. This
prototype builds from those already configured native `Cascade` arrays; it
does not regenerate H0 or copy GPU data back.

## Coastal

The existing CPU Coastal snapshot contains authoritative shoaling, valid-mask,
warp coordinate, determinant and warp-valid bake arrays with their independent
origins/extents and dimensions. `OceanQueryCore::CoastalRuntime::sample` does
deterministic bilinear sampling and computes field confidence. Coastal modifies
LONG only: sample open LONG and warped/deep LONG, blend by confidence, apply the
confidence-scaled shoaling multiplier, then add MID and SHORT at the original
material-q. The mirror prototype reuses that bake sampler and samples its
dynamic LONG field at the returned warp coordinate.

## Runtime configuration limitation found in audit

Changing Ocean wind, direction, Hs, or profile band parameters currently queues
an authoring rebuild. After a 0.15 s debounce `Ocean._rebuild_if_ready()` saves
wave time, shuts down OpenOceanFFT, and initializes it again. The H0 evolve
shader has a current/target spectrum blend input, but the active solver binds
the same H0 RID as both current and target and sends zero blend alpha. Thus the
current Production path does not yet provide a smooth in-place weather-spectrum
transition contract for the CPU mirror to follow. A CPU-only transition would
desynchronize render and physics; this must be solved as shared/versioned
Production configuration before declaring dynamic weather support.

## Local reference findings

- Water Race has CPU water query/provider code but no CPU mirror of its ocean
  Stockham FFT in the searched gameplay/runtime source.
- Water Race Ocean Lab Phase 2A is a direct CPU spectral oracle, not a periodic
  CPU FFT mirror. Its notes confirm reuse of exact uploaded H0, positive
  Stockham twiddles, `1/N²`, checkerboard origin handling, analytic velocity,
  and spectral derivatives. These are useful conventions, not code copied into
  Production.
- No Tidewater checkout was present under the accessible Desktop repositories.

## Prototype shape

Six packed complex inverse transforms per band recover twelve real periodic
fields: height, Dx, Dz, height derivatives, four horizontal derivatives, and
three velocity components. Packing `F+iG` halves the transform count from the
unpacked twelve-real-field formulation. Field evolution and transforms use
preallocated buffers and a process-persistent worker pool (five workers on the
12-logical-processor development CPU); each call still waits synchronously for
the complete snapshot. There is no double buffer or asynchronous prepare-ahead
publication yet.

## Old development PC prototype measurements

Machine: Intel i7-5820K / GTX 970, Godot 4.7.1, N=256 per band. The runner
compared 64 exact FFT-lattice points per band against both the direct spectral
oracle and Production GPU texels, plus hardware-filtered off-grid samples.

| Band | Build alone in latest run | Direct-oracle max lattice displacement error | Max velocity component error | GPU lattice displacement max error | GPU filtered off-grid max error |
|---|---:|---:|---:|---:|---:|
| LONG | 22.20 ms | 3.06e-6 m | 5.53e-6 m/s | 21.9e-6 m | 1.604 mm |
| MID | 31.94 ms | 3.05e-7 m | 6.88e-7 m/s | 1.60e-6 m | 0.148 mm |
| SHORT | 27.25 ms | 1.18e-7 m | 7.71e-7 m/s | 0.342e-6 m | 0.0478 mm |

The combined LONG+MID+SHORT+Coastal snapshot took 49.064 ms wall time with
five persistent workers (58.336 ms with eleven workers). The reported per-band
evolution/transform profile values sum task elapsed time and overlap; they are
not additive wall time. The synchronous snapshot therefore misses the 16.667 ms
physics deadline by about 2.94x even with the better worker count. Query batches
with Coastal measured 0.045, 0.176, 0.625, and 2.146 ms for N=4, 16, 64, and 256
respectively. Material scalar/batch comparisons passed; world-XZ batch completed
64/64 with maximum residual 0.998 mm. At a multi-root location the recovered q
differs from the seed q by about 0.75 m, while the direct oracle also converges
to a different nearby root; the reported residual remains below 1 mm.

Actual GPU off-grid samples are the renderer-equivalent filtered-surface
comparison. The separate maximum 0.0321 m displacement and 0.0753 m/s velocity
differences versus the continuous arbitrary-q direct oracle are expected lattice
interpolation differences, not FFT lattice-generation error. GPU texture
readback is not used by the CPU field builder; existing tiny validation probes
are used only for parity.

## Runtime and scheduling gates still open

The synchronous CPU snapshot is mathematically validated but too slow for one
physics tick. Main-thread wait remains the full 49.064 ms because the pool joins
before returning. Persistent worker execution exists, but there is no immutable
configuration publication, double-buffered field swap, deadline/missed-tick
accounting, or proof of a field no older than one tick.

Production wind/Hs/direction/profile changes currently rebuild OpenOceanFFT
after a debounce, and its active solver does not blend a current H0 into a target
H0. No shared in-place sea-state transition is available for the CPU mirror to
follow. A native-only interpolation would create renderer/physics divergence, so
runtime calm-to-storm continuity remains unvalidated and unsupported by this
prototype. PHYS-OPT-2A is therefore PARTIAL, not a production integration gate.
