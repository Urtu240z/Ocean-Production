# Local wave areas

Instance `res://addons/ocean/areas/ocean_wave_area_3d.tscn` in your level.
Select the Area3D root to edit its local wave climate. Edit its CollisionShape3D
to fit a harbor, channel or island passage. Its horizontal footprint is the
full-strength local zone. **Blend Distance M extends outside that footprint**;
increasing it never dilutes the center. Box height and vertical position do not
affect blending. The default Box is 150×60×100 m, with a 15 m exterior transition.

Assign **Ocean** explicitly, or parent the area under Ocean. When there is only
one Ocean in the scene, sibling areas bind automatically. Multiple Oceans
require an explicit target unless Ocean is an ancestor.

| Control | Meaning |
| --- | --- |
| Wave Height M | Significant height of the randomized wind-wave band. Set all three band heights to 0 for calm water. |
| Wavelength M | Length of the dominant local wave, in world metres. |
| Wave Speed | Wind-wave phase speed multiplier; swell and ripples have their own speed controls. |
| Wind Direction Degrees | Direction of propagation in world XZ: 0 toward +X, 90 toward +Z. |
| Wind Speed Mps | Adds wind-driven phase transport to the local wave train. Height remains an independent control. |
| Choppiness | Bounded crest harmonic: larger values sharpen crests. |
| Directional Spread | Angular spread of the randomized wave spectrum. |
| Blend Distance M | Width of the exterior feather in world metres; the core stays fully local. |
| Wave Priority | Higher values override lower values, with their own smooth border. |
| Phase Seed | Stable phase variation between different areas. |
| Wave Components | 4–24 independent wind-wave components; more components reduce regular wave trains. |
| Wavelength / Height Variation | Random variation in component lengths and energies. |
| Wind Height Influence | How much wind speed changes the wind-wave height; 0 keeps the authored height independent. |
| Cross Sea Amount / Angle | Adds a crossing wave direction to the wind-wave band. |
| Wave Group Strength / Size / Speed | Moving groups of stronger and weaker waves. |
| Swell Height / Wavelength / Direction / Speed | Independent long-wave band with three components. |
| Ripple Height / Wavelength / Speed | Independent short-wave band with four components. |
| Influence | Overall local-climate weight; 0 restores the exterior. |
| Local Foam Strength | Scales the attenuation of existing global crest/residual foam. |
| Surface Detail Strength | Remaining global micro-normal detail; 0 keeps only the local wave normals. |

Start a harbor with height 0.1–0.3 m, wavelength 4–10 m, speed 0.5–1 and
choppiness 0–0.4. For a channel, use an elongated Box and point the wind along
its axis. Increase blend distance at the entrance. The three **Starting Presets**
buttons provide a sheltered harbor, channel and island passage. Presets change
wave settings only; they retain your shape, position, target Ocean and wind
direction. Shape XZ scale and yaw are used; height, pitch and roll do not change
the horizontal footprint. Enlarging the feather can overlap nearby zones.
Supported shapes are Box, Sphere and Cylinder; CollisionPolygon3D is unsupported.

The exterior is the existing Ocean FFT, including its coastal bake. Within an
area, a seeded broadband analytic climate replaces its height: up to 24 wind-wave
components, plus 3 swell and 4 ripple components. The
same height, slopes and vertical speed are used by the visible surface and the
authoritative CPU water provider. The edge gradient is included in the normals,
and the underwater camera sensor and waterline mesh use the same local heights.
Hull wake waves are added after this climate, so boats still disturb calm water.
The simulation clock is Ocean's clock; pausing global waves pauses local waves.
All surface shader variants, including the foam director's preserved sources,
receive the same area hooks. The coefficients remain stable until a setting
changes; rebuilding the material does not reseed or restart local waves.

This is not a separate JONSWAP FFT per area. Choppiness sharpens the local
heightfield; it does not create horizontal Gerstner folds. The outside FFT mesh
retains its horizontal parameterization, with local heights evaluated at the
final world XZ. Local waves do not run through the offline coastal solver.
FFT-derived whitecap/residual foam is attenuated by the local wave steepness;
boat foam remains independent. Breaker carriers, GPU validation query modes and
spindrift emission still use the global FFT field. Disable these optional global
effects when evaluating a sheltered-water setup that would expose them.

Up to **8 active collision shapes per Ocean** are uploaded. Extra shapes of
lower priority are omitted with a warning. Equal priorities have stable node-path
ordering. Disabling/deleting an area restores the exterior climate. No rebake is
needed. Save your level to retain its areas and settings. Editor preview uses
Ocean's Preview Time; runtime uses its live wave clock.
