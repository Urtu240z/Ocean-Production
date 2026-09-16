# H2.3 — Clipmap GPU bounds and culling contract

## Scope

This phase hardens culling bounds for the GPU-deformed clipmap surface. It does not alter the FFT spectrum, amplitudes, foam thresholds, optical parameters, wave timing, mesh topology, stitching, or any of the Spindrift, SSPR, Coastal, Waterline, or Bubbles paths.

## Audited ownership

The runtime ownership chain is:

| Resource | Owner | Publication/consumer rule |
| --- | --- | --- |
| FFT internal RIDs (`H0`, ping-pong images, pipelines, uniform sets) | `GPUStockhamFFT`, on the render thread | Created, used, and freed by the solver. They never become surface texture bindings. |
| FFT displacement, normal, and Crest Foam output RIDs | One `GPUStockhamFFT` solver for one `OceanGPUResourceGeneration` | A solver may expose these RIDs only after its generation is ready. Retired callbacks shut the solver down and cannot publish. |
| Neutral displacement, neutral normal, and neutral Crest RIDs | `OceanGPUResourceGeneration`, on the render thread | The generation creates and frees them as a group. They are published only after all three are valid and the generation is still current. |
| `Texture2DRD` wrappers | `OpenOceanFFT`, on the main thread after readiness publication | Wrappers receive the RIDs of the current published generation only; the surface consumes these wrappers during its initialization. |
| Clipmap `ArrayMesh` resources and `MeshInstance3D` nodes | `OceanClipmapSurface` | Each level owns its instance and mesh reference. The authored mesh AABB is expanded into the exact local-space GPU culling AABB. |
| Local Breaker refinement `MultiMesh` resources and `MultiMeshInstance3D` nodes | `OceanRefinementBatcher` / `OceanClipmapSurface` | The batcher owns the MultiMeshes and applies the shared culling AABB to both the MultiMesh resource and every instance. |

The surface is initialized only from the generation publication path. Bounds are local to each geometry instance, so following the camera changes the instance transform without requiring a per-frame AABB rebuild.

## Bounds contract

`OceanClipmapSurface._update_clipmap_culling_bounds()` is the single update point. It runs after all production levels exist and after changes to `clipmap_geometry_scale`, `surface_scale`, or the ocean-space contract. A signature cache skips redundant updates.

For every level `L0..Ln`, including ring/stitch geometry, the authored `ArrayMesh.get_aabb()` is transformed according to the shader contract:

- X/Z are scaled by `clipmap_geometry_scale` (`H`).
- Y is scaled by `ocean_surface_scale` (`V`).
- The resulting AABB is expanded by the maximum GPU displacement allowance.

FFT allowance is derived from the effective per-band significant wave heights and choppiness. When breakers are effective, the allowance also includes the breaker profile limits. The breaker shader scales its authored wavelength by `H` and applies the final horizontal displacement scale again; the culling allowance therefore preserves that `H²` contract. The vertical breaker allowance follows the profile’s vertical-lift limit and `V`.

The existing small `extra_cull_margin` remains `4.0 m` as a safety margin. No giant culling margin is used as a substitute for bounds.

The same principle covers diagnostic breaker topology/refinement instances and the Local Breaker refinement MultiMesh path. Local Breaker tiles retain their explicit `Basis.IDENTITY.scaled(Vector3(H, 1, H))` transform; their batch AABB is authored in the already-scaled tile space and expanded only by the displacement allowance.

## Automated validation

`validation/ocean_clipmap_gpu_bounds_runtime.gd` performs a renderer-independent contract pass over six levels, all H/V combinations (`0.5`, `1`, `2`, `4`), pitch samples (`-25`, `-10`, `0`, `10`, `25`, `40`), identity checks for instance/mesh resources, baseline restoration, and 16 rapid Crest/rebuild/shutdown/initialize cycles. If a RenderingDevice is available it additionally drives the P0 scene through repeated Crest toggles, profile changes, rebuilds, and generation-readiness checks.

Markers emitted by the test are:

- `OCEAN_CLIPMAP_GPU_BOUNDS_AUDIT_PASS`
- `OCEAN_CLIPMAP_CULLING_PITCH_PASS`
- `OCEAN_CLIPMAP_BOUNDS_CONTRACT_PASS`
- `OCEAN_CLIPMAP_RUNTIME_BOUNDS_PASS`
- `OCEAN_CLIPMAP_BOUNDS_SANITY_PASS`
- `OCEAN_CLIPMAP_GPU_LIFECYCLE_PASS`

The GPU block reports `OCEAN_CLIPMAP_GPU_RUNTIME_BLOCKED` when the host cannot provide a global RenderingDevice; that is an environment limitation, not a passing GPU validation result.
