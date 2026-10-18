# Hull-wave physics: preserve the emitting vehicle's flotation

Validated on Windows with Godot 4.7.1, 18 October 2026.

## Cause and correction

The old native self-protection mask began fading at zero age and zero distance
from the consumer's center. Most bow/stern samples therefore still received
some recent own-wave trough, slope and vertical water velocity. Enabling Hull
Waves physics fed this deformation back into the emitting hull's buoyancy and
pitch, despite an almost unchanged surface height directly at its center.

The mask now has a neutral inner region over the complete nearby hull for the
configured Self Delay S and Self Radius M. It restores the contribution smoothly
over the next equal time/distance interval. Spatial/time derivatives use the same
mask. Defaults and saved settings are unchanged: 0.8 seconds and 3 metres.
Own waves are fully restored by 1.6 seconds or outside 6 metres at those defaults.
Other owners and unowned surface queries are unchanged. Setting delay to zero
still disables protection. Rendering, static buoyancy, draft, motor parameters
and the base Ocean surface have not been adjusted to compensate for the issue.

## Validation

- `hull_wave_self_flotation_check.gd`: full production vehicle, motor, emitter
  and shipping native sampler on flat authoritative water. Before the fix,
  physics enabled lowered mean cruising height from 0.227497 m to 0.117195 m
  (110.301 mm), changed pitch and reduced forward speed. After the fix both
  trials have identical height, pitch and speed, with 40 emitted packets.
- The same test with `--production`: real production scene, CPU Ocean provider
  and Inspector property route. Off: 0.225306 m; on: 0.227497 m; off again:
  0.227497 m. The 2.191 mm difference is upwards, within the 5 mm tolerance.
- `hull_wave_self_mask_check.gd`: exact neutral height/slopes/vertical velocity
  over the recent own-wave hull footprint; other owners, older own waves and
  zero-delay bypass retained. Maximum derivative error: 0.00000656.
- `hull_wave_physics_contract.gd`: 432 CPU/GPU reference points passed; original
  ownership, old own-wave coupling, composition and invalid publication checks
  passed. Maximum height mismatch: 0.000695 m.
- Windows release extension rebuilt successfully; `git diff --check` passed.

The Windows DLL is updated. Restart an editor/game that already loaded the old
extension to use the correction. No Linux binary was rebuilt for this change.
