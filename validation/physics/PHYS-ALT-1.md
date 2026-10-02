# PHYS-ALT-1 — reproducible sparse hull-spectrum experiment

This is an experimental query instance. The normal `OceanQueryNative` remains
the full direct spectral authority. Production rendering and gameplay are unchanged.
The measured decision is in [PHYS-ALT-1-REPORT.md](PHYS-ALT-1-REPORT.md).

## Build and run

Use the existing pinned godot-cpp/MSVC bootstrap from the repository root:

```powershell
./validation/physics/setup_native_windows.ps1
```

Set `$GodotExe` to a local Godot 4.7.1 executable, then run:

```powershell
& $GodotExe --path . --rendering-method forward_plus --rendering-driver d3d12 `
  --log-file "$PWD/.godot/phys_alt1_run.log" `
  --script res://validation/physics/phys_alt1_runner.gd
```

Optional focused runs append `-- --verification`, `-- --motion`, `-- --forces`,
or `-- --performance`. They produce ignored JSON under `.godot/`:

| Run | Output |
|---|---|
| Default: four sea states, global/quota/fixed selection, surface/hull metrics, weather, forces | `phys_alt1.json` |
| Scalar/batch, fallback, open/world timings, selection cost | `phys_alt1_verification.json` |
| Four continuous 240-tick hull trajectories | `phys_alt1_motion.json` |
| Offline authoritative Water Race buoyancy/drag law | `phys_alt1_force.json` |
| Warmed sparse preparation and Coastal batch/scalar timings | `phys_alt1_performance.json` |

The runner instantiates Production once, retains its exact final H0 and Coastal
bake arrays, and performs no GPU readback. Weather endpoints use Production's
unique JONSWAP/Hasselmann generator and cascade seed derivation. Generating those
full endpoints is validation setup; their cost is reported. Runtime coefficient
blending is a separate O(K) operation. The renderer is not changed to upload those
weather endpoints, so this experiment does not claim a complete production weather
integration.

## Explicit native API

Create a separate `OceanQueryNative` instance and call:

```gdscript
var sparse = ClassDB.instantiate("OceanQueryNative")
assert(sparse.configure_hull_sparse(full_authority, hull_points, 128, 0))
sparse.ensure_prepared(ocean.get_wave_time())
var samples = sparse.sample_material_q_batch(ocean.get_wave_time(), contact_points)
```

`budget` counts retained FFT lattice rows. Opposite-index pairs are selected
together, normally consuming two rows. Both traveling H0 identities are retained;
normalization remains the original `1/N²`, with no energy compensation.
`minimum_per_band` reserves that many rows per band before spending the remainder
globally. The experiment compares zero quota against four rows per band.

`get_sparse_mode_ids()` returns `(band << 32) | original_lattice_index`.
`get_sparse_selection_stats()` returns:

1. Three retained row counts (LONG/MID/SHORT).
2. Six retained expected variance fractions (heave/pitch/roll height, then velocity).
3. An optimistic omitted-heave RMS fraction from a separate heave-only top-K rank.

`blend_sparse_sources(from, to, alpha)` updates only retained H0 and choppiness
coefficients, with immutable mode identities and unchanged omega/k. It requires
the same lattice/domain/gravity in both endpoints. It invalidates prepared time
coefficients so the next query evolves the current state at its supplied time.
It copies no Coastal raster and creates no worker or spatial snapshot.

The reused open-ocean kernel has analytical spectral derivatives. The exact
existing 1 cm Coastal composite stencil and 5 cm world Newton stencil operate on
the small retained subset. Scalar and AVX2 over four query points are measured
separately. C++ working buffers are reused after warmup; Godot's returned packed
output still allocates once per batch, and timings include that wrapper cost.

## Hull and force provenance

Water Race source revision: `09051c918450740e2590daae8e8521b365cdefdb`.

- `game/gameplay/vehicles/jet_ski_01/jet_ski_01.tscn`: 300 kg, 1.2 × 3.1 m hull;
  markers `(-0.45,-0.15,-1.15)`, `(0.45,-0.15,-1.15)`,
  `(-0.5,-0.15,1.05)`, `(0.5,-0.15,1.05)`.
- `game/gameplay/vehicles/common/systems/jet_ski_water_physics_system.gd`:
  actual point buoyancy, normal damping, deep-submersion limit, tangential drag.
- `game/world/water/ocean/ocean_3d.gd`: signed depth = surface height − point Y.

The standalone runner contains the audited force equations and constants, so it
does not require copying the Water Race checkout. Force A/B uses the same world
contacts, body pose, velocity, angular velocity and submarine factor 1 for both
surfaces. It does not integrate a trajectory or apply gameplay forces.

## Interpretation

Four discrete contacts do not implement a continuous hull-area low-pass filter.
Their heave response has lobes; pitch and roll have different response functions.
Selection is evaluated against all three excitations and vertical velocity.
The report separates source/kernel correctness, approximation error, runtime cost,
and weather-integration limitations. A fast inaccurate subset is a negative result.
