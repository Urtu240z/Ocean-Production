# Hull surface effects

Select **Ocean** in the scene. All controls belong to Ocean; no separate foam node needs authoring. Existing serialized property keys and saved appearance values are preserved.

## Hull Foam

- **Enabled / Mode**: combined hull contact and wake, contact only, or wake only. Historical original/F1-F2 references are available to validation scripts under fixed sea conditions, outside the production Inspector choices.
- **Appearance**: Water Tint, White Color, Opacity, Tint Strength, Calm Foam Strength, Roughness, Specular and Normal Strength.
- **Agitation and Whitening**: whitening threshold/transition, white strength, impact sensitivity and agitation decay. Calm foam stays visible without requiring fast wind.
- **Generation and Irregularity**: patch size, variation, edge irregularity, edge fade and emission. Feathered world-coherent contours avoid rectangular stamp boundaries.
- **Motion and Wake**: Wake Update Hz (20/30/60; default 30), Wake Emission Forward M (default 0.20 m towards the bow), Initial Width M, Lifetime S, Outward Speed, Impact Outward Boost and Wake Opening Degrees. Filament Deformation/Speed animate the internal strands; Motion Strength/Speed control optional drift of the whole patch.

The frequency controls both deposition and GPU transport. Actual rendering FPS limits the achievable frequency. Emission is normalized by elapsed time; choosing 60 Hz does not intentionally double density. Wake opening affects new deposits; old foam retains its stored velocity. Initial width and lifetime are independent of opening angle.

## Running Foam

Independent speed-based reinforcement around the hull. **Speed Response**, **Appearance** and **Coverage** contain its activation, speed curve, smoothing, color, whitening, roughness, specular, normals, width, length and edge fade. The user's disabled state is retained. This reinforcement does not change resting foam or wake generation.

## Hull Waves

Visual displacement on the existing Ocean surface. **General** contains activation, maximum combined height (up to 2 m) and debug view. **Wake** contains crest height/width/wavelength, outward speed, duration (up to 20 s), rise, spatial Birth Distance M, fade, response and speed thresholds. **Impacts** controls landing ripples independently.

The wake starts at the existing bow contacts. Birth Distance M softens its onset spatially without hiding it behind a long rise delay. A continuous live segment follows the bow; archived segments blend without repeated transverse ridges. Short rise times use up to 60 Hz for the visual wave field. This does not change FFT cadence.

Waves remain visual: they do not affect water queries, buoyancy, driving or camera. The same surface handles geometry, shading and foam; no extra contact mesh, floating plane or second wave simulation is created. Foam and wave fields survive wind-driven Ocean reconstruction and rebind to every cached material variant.

## Live review and export

The optional playground uses **Foam Settings [F7]**. Its labels are English; Save Settings writes the assigned standalone resource. The Ocean Inspector exposes the complete authoring controls, including wave controls and update frequency. F8 is not used as an effect shortcut.

Keep the entire addon folder. Export presets must include `*.glsl,*.inc,*.source` because shaders and preserved comparison sources are read at runtime. Frozen original/F1-F2 sources live in `references/`, with provenance hashes; no development `temp/` folder is needed.

The shared foam history is 512², 128 m wide, and occupies 4 MiB regardless of vehicle count. Wave fields are allocated only while enabled. Performance results and limitations are recorded in the repository's release validation report.
