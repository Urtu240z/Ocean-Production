# White filament relief — 18 October 2026

The existing Ocean projected foam material now gives its white filaments an apparent rounded height, fine procedural puffs, soft cavity shading and a separate diffuse/specular finish. Calm blue material is preserved. Running Foam uses the same relief only to the extent it is white. Existing saved Running Foam and splash enable states are retained.

Controls: **Ocean → Hull Foam → White Foam Relief**. Defaults are enabled, apparent height 0.035 m, detail size 0.12 m, cavity strength 0.35, white roughness 0.78 and white specular 0.18. Height describes shading relief, not mesh displacement. The silhouette, waterline, CPU Lite, buoyancy and wave deformation are unchanged. Disable the relief checkbox to restore the previous foam finish.

The bump derives its main profile from the existing stochastic filament mask. Fine puff noise follows the existing two-phase transport and local deformation. World-space surface gradients keep the result aligned to sloping water and the camera. Derivatives are evaluated outside divergent coverage branches, then expensive shading is restricted to white pixels. Gradients are bounded and unresolved distant detail fades. No extra texture, texture lookup, mesh, field, simulation or per-vehicle CPU loop is introduced.

## Validation

- `foam_relief_material_check.gd` renders the actual projected fragment with fixed inputs. White lit output and normals change; calm blue and underwater images are byte-identical with relief off/on. Final white average image difference: 0.01106; normal output difference: 0.00474. These are whole-frame normalized RGB averages, not perceptual quality scores.
- `foam2d_ocean_authoring_check.gd` validates all six forwarded Ocean controls, their numerical values and disabled-state save/load. Existing resource independence and saved settings remain covered.
- `foam_relief_scene_check.gd` checks the material variants and renders the production scene with one and six vehicles. The original run disabled scene processing but did not freeze RigidBody3D simulation. That was insufficient to keep the view constant. The harness now explicitly freezes rigid bodies; the original timing table below is withdrawn as a controlled frozen-view comparison. Use the corrected comparison in `foam_pattern_speed_2026_10_18.md`.

The newer revision also applies relief to white-tinted calm foam, improves the pattern and adds speed whitening. The six original relief controls are retained. A further validation fix was needed because Production uses its own PAUSABLE mode: freezing the root and bodies still allowed Ocean/pigment updates. Both earlier timing comparisons are withdrawn as frozen-view measurements. The current harness freezes all descendants and asserts an unchanged history update count; see `foam_fresh_wake_2026_10_18.md`. Twelve-vehicle driving/physics performance remains a separate validation item.

Raw logs, material close-ups and fixed production-view captures are under `temp/foam_relief/`. No screenshot or temporary fixture is an addon dependency. Existing uncommitted artist edits to the Jet Ski scene and side-splash appearance are preserved separately; tests only mutate duplicated appearance resources in memory.
