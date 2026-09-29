# PHYS-1 LONG GPU/native mapping

## Spectrum source and indexing

Production remains the only spectrum authority. `OpenOceanFFT.initialize()` builds LONG H0 through `JonswapHasselmannSpectrum`, applies LONG band amplitude and the common wave-height amplitude, then uploads those same RGBA32F bytes to the LONG compute solver. PHYS-1 retains an exact CPU copy of that final upload for initialization/rebuild-time validation; it performs no per-frame GPU readback.

For resolution `N`, domain `L`, row-major index `i=yN+x`:

* `k=(x-N/2, y-N/2) * 2π/L`; `k=0` remains a zero mode.
* H0 channels are `(Re H0(k), Im H0(k), Re H0(-k), Im conj(H0(-k)))`, exactly as `_pack_h0` writes them. The GPU does no independent spectrum or Gaussian generation.
* `ω=sqrt(g |k|)` and temporal terms are `A=H0(k)e^{-iωt}`, `B=conj(H0(-k))e^{+iωt}`. GPU evolution forms `H=A+B`.
* Stockham performs the positive-angle inverse transform on each axis. Its unnormalised result is multiplied by `1/N²` in map assembly.
* The centered frequency grid is de-centered by the GPU checkerboard `(-1)^(x+y)`. The adapter supplies that same sign as the candidate's `parity`, with unit `weight`.
* GPU material UV is `q/L + 1/2`; therefore a texture location queried at material coordinate `q` represents Fourier coordinate `q+(L/2,L/2)`. The adapter rotates both H0 temporal terms by `exp(i k·(L/2,L/2))` (exactly `±1` on this grid) before passing them to the unchanged candidate evaluator.

## Displacement and derivatives

With `H(q,t)=Σ parity·(A+B)e^{ik·q}/N²`, Production's shader computes:

* `Y = Re(H)`.
* `X = Re(i H) * choppiness * kx/|k| = -Im(H) * choppiness * kx/|k|`.
* `Z = Re(i H) * choppiness * ky/|k| = -Im(H) * choppiness * ky/|k|`.

The candidate scalar core accumulates the equivalent real/imaginary products with coefficients `a1=-choppiness*kx/|k|`, `a2=-choppiness*ky/|k|`, `cij=ai*kj`, signed `k`, `parity`, and `inv_n2=1/N²`. The query returns the geometric Y-up normal from analytic derivatives and the temporal derivative of displacement (`surface_velocity`).

## Scale contract (single application)

| Parameter | GPU location | CPU query location | Application count |
|---|---|---|---:|
| `long_band_scale` | Multiplies the LONG H0 amplitude before common scaling/upload | Already present in the exported final H0; no extra multiplier | 1 |
| `wave_height_scale` | Multiplies common H0 amplitude in the wind-driven path | Already present in the exported final H0; no extra multiplier | 1 |
| `ocean_scale` / `ocean_surface_scale` | Multiplies final GPU vertex Y displacement | Must multiply queried Y/vertical velocity once only for world-space presentation; raw parity compares Ocean Space | 0 in raw parity, 1 in world-space conversion |
| `clipmap_geometry_scale` | Scales material sample XZ and final GPU horizontal displacement | Input `q` is already the scaled material coordinate; multiply native X/Z once only for world-space presentation | 0 additional input transform; 0 in raw Ocean-Space comparison |
| LONG choppiness | GPU evolve shader's horizontal `iH` terms | Native `a1/a2` coefficients | 1 |

The harness compares raw LONG Ocean-Space displacement at the GPU material sample coordinate, then reports the scale values. Defaults are unity for the initial parity run.

## Explicitly deferred

The material-q comparison precedes inverse world-XZ solving. MID, SHORT, Coastal, Breakers, buoyancy, and visual detail normals remain outside the LONG-only PHYS-1.3 validation.

## Canonical material-q / FFT-q contract

External Production-facing physics callers use **material-q**, the Ocean-Space coordinate consumed by `world_uv(q, L) = q / L + 0.5`. The pure spectral evaluator consumes **FFT-q**, the coordinate used by its Fourier phase.

For each configured band, with runtime domain `L` and resolution `N`:

```text
texel_size = L / N
material_to_fft_offset = L / 2 - texel_size / 2
fft_q = wrap_periodic(material_q + material_to_fft_offset, L)
```

Production wraps periodically to `[-L/2, +L/2)`. The offset is derived from the retained LONG snapshot at native-adapter setup; it is not a constant. At LONG `L=512 m`, `N=256`, it evaluates to `255 m` per axis.

The sole conversion implementation is `OceanQueryNative::material_q_to_fft_q_`. Scalar material queries, material-query batches, and every iteration of the Production-facing world-XZ adapter call it once immediately before spectral evaluation. World-XZ Newton state and returned material-q remain in material coordinates. The translation has identity derivative, so the spectral slope/Jacobian/normal values remain unchanged apart from evaluating them at the converted coordinate. `OceanQueryCore::accumulate_` remains a renderer-independent FFT-q evaluator.

The GPU parity probe records both material-q and derived FFT-q. It samples the published LONG output directly at lattice texels for core parity, and uses a separate repeat-linear sampler only for off-grid rendered-interpolation measurements.
