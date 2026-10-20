# Tsunami underwater alignment — 2026-10-19

Reviewed the supplied 4.84 s MP4. The view switches abruptly to the underwater
medium around 1.5–2 s while approaching the tsunami front. Extracted frames are
under `temp/tsunami_video/`; the original recording is unchanged.

## Reproduced cause

The CPU tsunami profile and visible surface use the current shared
`tsunami_math.gdshaderinc`. The underwater sensor and raster loaded cached
`RDShaderFile.get_spirv()` results compiled on October 18. Changing an included
formula did not refresh those imported shader binaries. They retained the old
full-circle profile and interpreted `shape.w` as a trough offset, whereas the
current formula uses that component for the arc angle.

The deterministic D3D12 reproduction used a 60 m tsunami, 30/90 m asymmetric
widths and a 240-degree arc. Before the fix:

| Probe | Current visible/CPU water Y | Cached underwater water Y | Result |
|---|---:|---:|---|
| Camera Y=5, 40 m before crest | 1.2373 m | 10.0333 m | Incorrectly UNDERWATER_SAFE |
| Leading trough | -13.4901 m | 0.1663 m | Incorrect surface geometry |
| Outside arc | 0 m | 59.9998 m | Underwater despite no wave |
| Arc feather, camera Y=30 | 16.6826 m | 59.9998 m | Incorrectly UNDERWATER_SAFE |

## Fix

The sensor and raster now compile the current source at pipeline preparation,
as the underwater medium already does. Canonical stage bodies are ShaderInclude
resources shared by the `.glsl` entry points and the runtime compiler; there is
no duplicate wave formula and no dependency on stale imported SPIR-V. Explicit
preloads retain all include dependencies when exporting the addon. Expanded
source is the cache key, so successful compiles are reused across instances.
No compilation or source expansion is added to steady per-frame rendering.

No thresholds, timing delays, camera placement, tsunami profile settings or
gameplay scene values were changed. Existing unrelated pending edits to the
tsunami arc/controller and caustics were retained.

## Validation

`validation/tsunami_waterline_alignment_check.gd` on Godot 4.7.1, Forward+/D3D12,
RTX 4070 Laptop:

- Before: 12 assertion failures, including early underwater and phantom off-arc water.
- After: PASS across nine camera locations: leading water/trough, air before the
  front, submerged front/crest, above the back, outside arc and feather/arc edge.
- Maximum GPU sensor vs current CPU profile height difference: **0.000235 m**.
- The camera at Y=5 over the 1.2373 m front remains **AIR_SAFE**; submerged
  locations enter **UNDERWATER_SAFE**. Off-arc locations stay air.
- Real native water contacts match the current profile within 0.001 m.

Logs: `temp/tsunami_alignment_before.log`, `temp/tsunami_alignment_final.log`.
The regression writes `temp/tsunami_alignment_result.json` with per-case values.

The ordinary local FFT/contact regression also passes
(`temp/local_fft_waterline_source_regression.log`, H0 relative error 0,
CPU/GPU local height error 0.00984 m). Shader bodies/uniforms are split into flat
includes because this Godot RDShaderFile importer does not recursively expand
nested includes. Runtime and compatibility entry points preserve identical
declaration order. The live detector no longer uses those imported binaries.
