# Standard buoyancy and local-wave waterline — 18 October 2026

Baseline: master `1ca34e3`. Validated with Godot 4.7.1, Windows D3D12, RTX 4070 Laptop GPU.

## Inspector

**Buoyancy Physics** is the standard display name. Root response/trim controls use that group. The old model selectors, Four Point support/angular controls and Heavy Hull settings are collected at the end under **Legacy → Show Legacy Settings**. The switch only controls editing visibility; it does not activate another model or reset saved settings. The general Show All Mode Settings checkbox cannot bypass it. An already-active old model produces an Inspector notice.

Legacy-only controls on WaterPhysicsSystem and ProductionSetup are likewise separated and respect the vehicle's Legacy editing switch. The root, setup and water-physics function bodies are unchanged. Internal enum integers, property keys and diagnostic identifiers remain compatible. The HUD uses the new readable names.

`jet_ski_authoring_check.gd` passed: 180 root exports, 151 normally shown, 441 documented editable exports throughout Jet Ski, explicit Legacy gating, group membership, default preservation and save/load equality. The isolated native Godot Inspector probe passed with an empty error log: all-mode viewing cannot bypass Legacy, and changing visibility retains the standard mode.

The production-scene buoyancy smoke passed with zero errors: the standard default, twelve finite-volume hull cells, finite forces, the renamed HUD and explicit switching to/from the retained four-point comparison path were exercised.

## Waterline correction

Previously, underwater rasterized and sampled FFT/coastal/breaker deformation but omitted local hull waves. The visible surface could therefore rise above or fall below the boundary used by the underwater effect.

Ocean now forwards the existing current/previous hull-wave atlas RIDs, origins, interpolation fraction, cap and display mode to the underwater effect. Both the camera sensor and waterline raster consume one render-callback snapshot. Visible Ocean and underwater share a pure sampling helper, including interpolation, soft height limiting and distance/border fade. The height is added in world metres after horizontal FFT deformation; sensor inversion still solves only the base horizontal displacement. Camera tangent normals include the local height gradient.

Texture RIDs are borrowed, validated on the render thread and never freed by underwater. Disabled, invalid or retired sources bind existing fallback textures with local displacement disabled. No additional wave atlas, simulation, FFT, mesh, CPU water query or gameplay GPU readback is introduced. The added rendering work is atlas sampling in the existing waterline vertex pass and the one-invocation camera sensor. This change has not been advertised as a measured performance optimization.

## GPU regression

`hull_wave_waterline_runtime.gd` passed in an isolated standalone addon project, with an empty error log:

| Case | Expected local height | Camera GPU height |
|---|---:|---:|
| Disabled | 0 m | 0 m |
| Crest / temporal blend | 0.600 m | 0.599854 m |
| Depression | −0.800 m | −0.799683 m |
| Soft cap | 0.999898 m | 0.999898 m |
| Visual-only waves | 0.400 m | 0.399963 m |
| Previous frame | 0.100 m | 0.099976 m |
| Atlas border fade | 0.500 m | 0.500 m |
| Outside atlas | 0 m | 0 m |
| Retired/invalid atlas | 0 m | 0 m |

For the eight flat cases, sampled raster face sides matched the expected side of the local surface. Actual raster exit depth was inverse-projected with the renderer's matrix: maximum height error was **0.316 mm**. The curved atlas-border case checks camera height instead of claiming a flat raster surface.

A real analytic impact packet was also baked with the existing hull-wave field. Its camera height matched the atlas within 2 mm and its tangent normal matched an independent bilinear/finite-difference reference within 0.02 vector distance. This validates a non-flat generated wave in addition to synthetic constant-height cases.

Live publication, wind rebuild, atlas replacement and disabling deformation passed. The standalone combined addon portability smoke also passed with the saved physical-wave preset and an empty error log. Screenshots and raw logs are local validation artifacts under `temp/underwater_hull/`; the test itself creates its own evidence and does not save scene or artist-resource changes.

Full multi-vehicle performance approval remains separate, as documented in `physical_hull_waves_2026_10_18.md`. Linux rendering was not tested for this change.
