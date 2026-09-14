# Waterline Shore Reference

This is an isolated Godot reference scene. It does not import or depend on the production ocean, P5, 2G, FFT, coastal, foam, spray, or bubbles modules.

Run `res://waterline_reference/waterline_shore_reference.tscn`.

## Ported math boundary

The traced runtime route is:

`MF_Shore_Gen3 (Shore Displacement) -> MF_Ocean_Displacement_Gen4 (Result) -> M_Water_Surface_Gen4 (WPO)`.

This scene ports the shore displacement branch after its Shore Manager inputs. The manager input is temporarily emulated with a finite, straight shore:

- distance/mask: analytic 0..1 band along local Z;
- direction: `(0, -1)` in Godot XZ;
- Waterline texture: external EXR at the AUDIT path, never stored in this repository.

`Shore Wave Displacement=(500,1,800)` is read as Unreal centimeters. In the traced `MF_Shore_Gen3` displacement branch, only R/X and B/Z are referenced: X scales planar surge and Z scales vertical displacement. G/Y has no reference in that branch.

The shader exposes the explicit Unreal-to-Godot mapping: Unreal `(X,Y,Z)` becomes Godot `(X,Z,Y)` and centimeters are multiplied by `0.01`.

## Traced `MF_Shore_Gen3` displacement operations

The following is a direct pseudocode transcription of the material nodes that feed the `Shore Displacement` output. Names in parentheses are Unreal graph nodes.

```text
ws_coordinates = world_position.xy + shore_offset                 (Add_1; Unreal XY, cm)
center_mask = ScaleUVsByCenter(ws_coordinates, 0.9).mask          (MaterialFunctionCall_10)

rt = sample_linear(RT_Shore, ws_coordinates)                     (TextureSample_0)
shore_direction = vec2(rt.g, rt.b) * center_mask                 (AppendVector_12, Multiply_6)
distance_mask = rt.r * center_mask                               (Reroute_11, Multiply_17)

wave = sample_linear(T_PL_Wave_1_Disp, shore_uv)                 (TextureSample_2)
wave_profile = vec3(shore_direction * wave.r, wave.b)            (Multiply_37, AppendVector_8)
amplitude = vec3(displacement.x, displacement.x, displacement.z) (AppendVector_3, AppendVector_4)

profile_displacement = wave_profile * amplitude                  (Multiply_35)
profile_displacement *= DistanceField(distance_mask, shallow_blend)
                                                                    (MaterialFunctionCall_8, Multiply_2)
profile_displacement *= saturate(deep_clamp * distance_mask)     (Multiply_7, Saturate_1, Multiply_33)
profile_displacement *= shore_wind_mask                           (Multiply_25)

shore_displacement = profile_displacement + shore_surge_waves    (Add_7)
```

`shore_surge_waves` is a separate named branch in the same function. The reference shader keeps its finite, deterministic equivalent behind the input boundary rather than inventing a new breaker profile.

### Channel facts

- `RT_Shore.R`: distance-mask source used by the displacement branch.
- `RT_Shore.G/B`: planar shore-direction vector used by the horizontal branch.
- `RT_Shore.A`: not sampled by this `MF_Shore_Gen3` displacement branch.
- `T_PL_Wave_1_Disp.R`: multiplies the planar direction before amplitude scaling.
- `T_PL_Wave_1_Disp.B`: becomes the vertical profile before Z amplitude scaling.
- `T_PL_Wave_1_Disp.G/A`: not consumed by this branch.

`RT_Shore_Capture` is not sampled directly by `MF_Shore_Gen3`; it belongs to the Shore Manager's capture/processing stage that produces the `RT_Shore` data consumed above.
