# Hull surface effects

Select **Ocean** in the scene. All controls belong to Ocean; no separate foam node needs authoring. Existing serialized property keys and saved appearance values are preserved.

## Hull Foam

- **Enabled / Mode**: combined hull contact and wake, contact only, or wake only. Historical original/F1-F2 references are available to validation scripts under fixed sea conditions, outside the production Inspector choices.
- **Appearance**: Water Tint, White Color, Opacity, Tint Strength, Calm Foam Strength, Roughness, Specular and Normal Strength.
- **White Foam Relief**: Enabled; Height M (apparent height, default 0.035 m); Detail Size M (default 0.12 m); Cavity Strength (default 0.35); and independent white Roughness / Specular (0.78 / 0.18). Rounded strand normals and small soft cavities make the white foam react to light. Lower Height M for a subtler result, increase Detail Size M for larger puffs, or disable this subgroup's effect to recover the previous material.
- **Agitation and Whitening**: whitening threshold/transition, white strength, impact sensitivity and agitation decay. Calm foam stays visible without requiring fast wind.
- **Speed Whitening**: Low Speed White Strength (default 0.30) and High Speed White Strength (default 1.0) multiply White Strength. White Low Speed Kmh (5) and White High Speed Kmh (35) bound a smooth transition. Both strengths at 1 restore the previous white intensity. Only the white coverage changes; agitation, blue filaments, coverage and transport retain their existing behavior. Existing Running Foam remains independently controlled.
- **Fresh Wake**: Enabled, Strength (default 1.0) and Settling S (0.8 s). At speed, newly emitted pigment beside the whole wet hull fills the filament gaps with dense white, including its center and forward section. The soft leading edge remains inside the existing contact footprint. It relaxes smoothly back to the configured older wake over Settling S, independently of the wake's total lifetime. The same Speed Whitening speed thresholds gate this phase, but its white intensity is independent of High Speed White Strength. It does not whiten stationary contact or require Filament Deformation/Speed. Disable it or set Strength to zero to retain the previous pattern everywhere.

The fresh core also uses a rougher finish, softer strand normals and reduced fine relief/cavity shading so its white fill is not broken up again by reflective strand detail. These changes relax with the same phase. The emitter refreshes pigment already underneath the moving stern, not just previously empty texels. It never paints a premade triangle ahead of travel. Restart the scene after importing this revision: the metadata texture format changes from R16F to RG16F, so an already-running history must be recreated.
- **Generation and Irregularity**: Patch Size controls fine strands; values such as 0.85 now use continuous warped coordinates rather than blending independently randomized triangle cells. White Patch Strength (default 0.65) mixes broad irregular pockets into the strands; White Patch Size M (1.8 m) scales those pockets independently. Variation, Edge Irregularity, Edge Fade and Emission retain their roles.
- **Motion and Wake**: Wake Update Hz (20/30/60; default 30), Wake Emission Forward M (default 0.20 m towards the bow), Initial Width M, Lifetime S, Outward Speed, Impact Outward Boost and Wake Opening Degrees. Filament Deformation/Speed animate the internal strands; Motion Strength/Speed control optional drift of the whole patch.

The frequency controls both deposition and GPU transport. Actual rendering FPS limits the achievable frequency. Emission is normalized by elapsed time; choosing 60 Hz does not intentionally double density. Wake opening affects new deposits; old foam retains its stored velocity. Initial width and lifetime are independent of opening angle.

White Foam Relief is a shading treatment in the existing Ocean material. Its height is visual rather than geometry displacement: it does not change the waterline, buoyancy or silhouette. It follows the existing transported/animated filaments, affects only their white coverage, and also supports white Running Foam when enabled. Calm blue filaments retain their previous finish. Subpixel detail fades with distance to limit sparkle. The effect adds procedural math and surface derivatives, with no extra foam textures, texture lookups, meshes or simulation.

White water tint and calm foam that has been tinted white now receive the same pocket/relief treatment. They also respect Speed Whitening. This avoids a smooth white tint layer hiding the detailed foam underneath. Blue tint retains its original material response. For visible small puffs start with Relief Height M around 0.035–0.06, Detail Size M 0.12–0.20, Roughness around 0.8 and Specular around 0.2. A detail size of 0.8 m produces broad undulations rather than small foam bubbles. During play, use the **Remote** Ocean Inspector to adjust the running instance directly; Local edits author the scene used for the next run unless live editing forwards them.

## Running Foam

Independent speed-based reinforcement around the hull. **Speed Response**, **Appearance** and **Coverage** contain its activation, speed curve, smoothing, color, whitening, roughness, specular, normals, width, length and edge fade. The user's disabled state is retained. This reinforcement does not change resting foam or wake generation.

## Hull Waves

Visual displacement on the existing Ocean surface. **General** contains activation, maximum combined height (up to 2 m) and debug view. **Wake** contains crest height/width/wavelength, outward speed, duration (up to 20 s), rise, spatial Birth Distance M, fade, response and speed thresholds. **Impacts** controls landing ripples independently.

The wake starts at the existing bow contacts. Birth Distance M softens its onset spatially without hiding it behind a long rise delay. A continuous live segment follows the bow; archived segments blend without repeated transverse ridges. Short rise times use up to 60 Hz for the visual wave field. This does not change FFT cadence.

Waves remain visual by default. The experimental **Physics** subgroup can add their height, slope and vertical water velocity to authoritative water queries, allowing the existing buoyancy to respond. It is disabled by default and requires an updated native extension. See `../../physics/water/HULL_WAVES.md` for self-wake protection, limits, test scene and platform requirements.

The same surface handles geometry, shading and foam; no extra contact mesh, floating plane or second wave simulation is created. Foam and wave fields survive wind-driven Ocean reconstruction and rebind to every cached material variant.

## Live review and export

The optional playground uses **Foam Settings [F7]**. Its labels are English; Save Settings writes the assigned standalone resource. The Ocean Inspector exposes the complete authoring controls, including wave controls and update frequency. F8 is not used as an effect shortcut.

Keep the entire addon folder. Export presets must include `*.glsl,*.inc,*.source` because shaders and preserved comparison sources are read at runtime. Frozen original/F1-F2 sources live in `references/`, with provenance hashes; no development `temp/` folder is needed.

The shared foam history is 512², 128 m wide, and occupies 6 MiB regardless of vehicle count: 4 MiB for pigment/velocity/agitation plus a 2 MiB RG16F companion for premultiplied birth speed and fresh aft pigment. Fresh Wake adds 1 MiB to the preceding speed-history implementation. Both channels use the existing localized stamping/transport dispatches and the same material texture sample. Speed stays with deposited pigment while freshness decays; stopping one boat does not dim another boat's wake. The companion sample is skipped only when both speed strengths match and Fresh Wake is inactive. Wave fields are allocated only while enabled. Performance results and limitations are recorded in the repository's release validation report.
