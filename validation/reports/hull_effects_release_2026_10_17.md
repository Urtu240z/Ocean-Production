# Hull effects consolidation — 2026-10-17

## Scope

Projected hull foam and persistent wake history, animated filaments and irregular feathered contours, independent running-foam reinforcement, continuous visual hull waves, independent Bow Spray / Splash / Tail Jet controls and previews, curved nozzle-local tail volume, progressive water-contact recovery and finite airborne residual-water sputters.

Ocean authoring is organized into Hull Foam, Running Foam and Hull Waves. Spray authoring uses Bow Spray, Splash and Tail Jet. Export labels, groups, enum choices, public tooltips and live effect controls are English. Existing serialized property keys, appearance overrides, vehicle transforms and user-disabled side-splash/running-foam states are retained. Two invalid null entries from an older foam-resource save were removed so the documented 30 Hz / 0.20 m defaults apply.

This release does not add physical feedback from hull waves, another FFT, new contact meshes or changes to driving/camera tuning. The native Windows/Linux binaries are unchanged. Original and F1/F2 shader/history/compute sources are preserved with SHA-256 provenance in the Ocean addon. Their fixed-condition comparison modes are available to validation; production Inspector choices are combined/contact/wake.

## Validation

Windows, Godot 4.7.1, Forward+, D3D12, NVIDIA RTX 4070 Laptop GPU.

- Ocean authoring: 67 controls, group uniqueness, numeric frequency enum, independent Ocean resources, disabled-state preservation and real scene save/load: PASS.
- Foam live controls: 41 widgets, 25 live material checks, save/load, running-foam independence, no retired contact visuals and original bow spray retained: PASS.
- Hull spray controls: independent appearance profiles, all original Bow Spray appearance exports, 24 variant switches, three cached atlases, material updates, save/load, editor previews without throttle, horizontal trajectory and shared static mesh: PASS.
- Packaging: all functional resource dependencies remain inside addons; development scenes, caches, raw source sprite folders and native build products excluded. SHA-256 manifest generated: PASS.
- Ocean-only clean project: fresh import and runtime without Jet Ski, MCP, gameplay, validation or development temp folders: PASS.
- Combined clean project: fresh import, real hull/handle models, shared water provider, live hull foam/waves, spray anchors, renewed emission after wind change, 60 Hz selection and throttle: PASS.
- Preserved original and F1/F2 comparison startup/render/cleanup in the clean combined project, fixed sea conditions: PASS. Historical spectrum-rebuild limitations remain outside production Inspector choices.

The first combined runtime was launched before model import completed. That run was rejected. The corrected test explicitly checks both model nodes; the subsequent fully imported execution and the final current/reference runs completed without errors or warnings. Historical texture cleanup now releases the director's material wrappers before the FFT-owned legacy textures disappear.

## Foam frequency measurements from the preceding accepted revision

Two runs per combination, 900 frames / 180 warm-up, no fixed FPS, rates ordered 30/60/60/30, reversed vehicle-count order, no captures. Spray and running reinforcement off; visual waves on with rise 0.1 s and duration 20 s.

| Vehicles | Hz | Mean real frame ms | Process CPU ms/frame | Visual update CPU ms/frame | Viewport GPU ms/frame | History GPU ms/update |
|---|---|---|---|---|---|---|
| 1 | 30 | 6.94 | 5.89 | 0.120 | 2.784 | 0.0177 |
| 1 | 60 | 7.66 | 5.66 | 0.125 | 2.788 | 0.0181 |
| 6 | 30 | 8.48 | 8.81 | 0.253 | 2.796 | 0.0254 |
| 6 | 60 | 9.91 | 10.13 | 0.304 | 2.817 | 0.0253 |

These figures predate this authoring/portability cleanup and are not claimed as a new performance certification. The user's separate game remained active, and inputs were scheduled by frame rather than identical physical trajectory. Process CPU sums all threads; viewport GPU is not necessarily full-frame GPU. One-vehicle 60 Hz runs varied from 6.94 to 8.38 ms. Thirty Hz remains the default.

The foam history allocates 4 MiB at every rate and vehicle count. Short-window static RAM growth averaged about 1.28 MiB for one vehicle at both rates; six vehicles averaged 7.41 MiB at 30 Hz and 13.49 MiB at 60 Hz. Process private memory ended below its initial value in all runs. These short windows do not establish long-term leak freedom. The real GPU cadence contract conserved two seconds of transport at 20/30/60 Hz with a synthetic 144 FPS clock.

## Reproduction and transfer

Run `tools/package_water_addons.py --out <new-directory>` to create separate Ocean/Jet Ski ZIPs, a file/hash manifest and clean OceanOnly/TestAddons projects. Import each project fully before runtime validation. Copy `validation/addon_portability_check.gd` into the clean root for automated checking; it is not shipped inside either addon. Use `-- --ocean-only` for Ocean alone, or `-- --reference=original` / `f1f2` for fixed-condition archived comparisons.

Export presets must include `*.glsl,*.inc,*.source`. Full controls and integration instructions live in each addon's INSTALLATION.md and CONTROLS.md. Optional early-iteration comparator factories still require their local development snapshots; the consolidated original/F1-F2 references and normal tests do not depend on those optional snapshots.

Current release consolidation is Windows-validated. Earlier WSL/Linux software-renderer checks do not certify Steam Deck hardware, gamepad or Linux export performance.
