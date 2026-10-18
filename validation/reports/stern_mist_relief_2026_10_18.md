# Procedural microdroplet relief — 18 October 2026

Added optional normal-map lighting to Stern Mist. A dedicated 128×128 seamless NoiseTexture2D uses FastNoiseLite (seed 731, frequency 0.035, three octaves), As Normal Map and Bump Strength 2. Billboard normal transforms now match the billboard geometry. Normal strength 0.55, tiling 3, roughness 0.28 and specular 0.35 are exposed and enabled on the saved Jet Ski material; the relief toggle restores the prior diffuse-only shading path.

Mist scalar noise is now isolated in stern_mist_noise.tres with the artist's seed, frequency and ramp, rather than interpreting the shared bow distortion texture's RGB normals as scalar noise. The shared texture itself remains untouched. No image bitmap is generated. Artist particle counts, lifetime, emission geometry, ramp, saved opacity and speed controls are preserved.

The GPU relief fixture loads the actual saved Jet Ski material, renders a fixed particle and compares relief off/on, changed directional-light orientation, zero normal strength and disabled specular. Captured flat/relief/moved-light images were inspected. The native world-space/ramp GPU regression passes. Full-playground appearance remains an artistic assessment under its own light and opacity settings.
