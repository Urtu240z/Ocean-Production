# Ocean surface shadow contrast — 2026-10-20

The visible ocean already receives Godot's directional shadows on direct lighting.
The environment and reflections can leave the shaded water bright. This change
adds optional contrast using the native directional shadow attenuation, without
replacing the visible material's PBR lighting or Fresnel calculation.

## Control and implementation

- Ocean → Surface → Shadow Strength, range 0–1, addon default 0.
- Production `p0_open_ocean.tscn` sets 0.45; the Hull playground inherits it.
- 0 removes the transparent next pass entirely. Existing native PBR shadows remain.
- The next pass draws black with alpha = strength × air blend × native shadow mask.
  Directional lights combine by maximum mask. Point/spot lights retain their normal
  material lighting; they do not contribute to this optional contrast pass.
- It reuses the visible mesh and exact vertex shader, including FFT, local areas,
  tsunami and projected hull waves. It also preserves the replacement-breaker
  fragment cutout before shading. No new shadow atlas or reflection pass is added.
- Uniform changes are forwarded to the active receiver; material replacement
  rebinds it, including the Hull Foam runtime variants.
- Underwater air blend 0 gives alpha 0. Optics/Snell/TIR code is unchanged.
- Cast Shadows remains a separate option controlling whether the ocean occludes
  light. Shadow Strength controls contrast of received directional shadows.
- The sun transform, shadow range, bias and normal bias are unchanged.

The contrast also darkens reflected light under a shadow. This is an artistic
presentation control, rather than a change to PBR light transport. It cannot
create an occlusion absent from Godot's shadow map or improve atlas resolution.

## Validation

Godot 4.7.1, Forward+, D3D12, actual saved
`validation/hull_wave_physics_playground.tscn`, frozen after normal initialization.
`validation/ocean_shadow_receiver_runtime.gd` exits 0:

| Check | Result |
| --- | --- |
| Tsunami, strength 0 → 0.45 | 91,268 pixels darken by more than 0.01 mean RGB |
| Boat shadow on water only, excluding visible boat/self-shading | 99 pixels darken from added contrast; native caster toggle changes 620 pixels |
| Sun shadows disabled, strength 0 → 0.45 | Image bytes exactly equal; no artificial shadow |
| Physical tsunami samples and packed buffer | Exactly equal before/after strength change |
| Strength toggle | Adds/removes next pass live |
| Optics/reflections toggles and Planar/SSPR switch | Receiver and strength retained; no shader errors |
| Underwater/air presentation | Receiver air-blend uniform 0/1 |
| Original sun settings | Unchanged |

The boat is lifted to y=2 in the render fixture and made shadow-only to isolate
its footprint on the water. This proves reception independently of self-shading;
it is not a guarantee that every afloat camera angle exposes a large boat shadow.
The tsunami is a fixed production-scale arc (radius 1220 m, height 60 m).
No fixture transform is saved to a production scene.

Additional checks pass:

- `production_reflection_state_runtime.gd --scene=res://validation/hull_wave_physics_playground.tscn`
  (Roughness regression, Optics and reflection variants).
- TestAddons `release_smoke.gd --complete` exits 0 after copying all five changed
  addon files and verifying equal hashes. No release ZIP is regenerated.
- `git diff --check`.

The existing invalid UID warning for `foam2d/default_style.tres` remains; Godot
resolves the resource using its path. It is unrelated to this change.

## Cost: short GPU check, not a full benchmark

At 960×540, frozen scene, 30 settling frames + 90 measured frames per window:

| Setting | Viewport GPU p50 | Viewport GPU p95 | Total draw calls p50 |
| --- | ---: | ---: | ---: |
| Strength 0 | 2.766 ms | 2.818 ms | 65 |
| Strength 0.45 | 3.007 ms | 3.035 ms | 75 |
| Strength 0, repeat | 2.765 ms | 2.810 ms | 65 |

The extra pass costs about 0.24 ms in this fixture and adds 10 visible draws.
An earlier short run measured about 0.22 ms. These are viewport GPU times, not
whole-frame times or a prediction for other resolutions. No FPS gain is claimed.

Generated captures and machine-readable results are kept locally under
`temp/shadow_receiver/`: `tsunami_before.png`, `tsunami_after.png`, `boat_before.png`,
`boat_after.png`, `boat_absent.png`, `no_shadow_before.png`, `no_shadow_after.png`,
and `results.json`. Rerunning the validation refreshes them.

Only rendering scripts, the production surface contrast option and this
validation/report are part of the change. Preexisting local Hull playground and
reflection-profile edits remain outside the commit. No physics or C++ changes.
