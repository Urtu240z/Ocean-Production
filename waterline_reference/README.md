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

## Traced `Displacement BreakUp`

The next material-function stage is `MF_Ocean_Displacement_Gen4`. Its `Use Displacement BreakUp` static switch has these two exact graph branches:

```text
base = upstream ocean displacement                              (Reroute_34)
base_components = BreakOutFloat3Components(base)                (MaterialFunctionCall_0)

breakup_z = Lerp(-WaveHeight, +WaveHeight, selector)            (Multiply_0, LinearInterpolate_3)
breakup = MakeFloat3(base.x, base.y, base.z + breakup_z)        (Add_2, MaterialFunctionCall_10)

ocean_displacement = UseDisplacementBreakUp ? breakup : base    (StaticSwitchParameter_3)
result = ocean_displacement + ShoreDisplacement                 (Add_9)
```

Thus BreakUp is not a planar displacement and it does not change the traced Shore profile. It adds only to the Unreal Z component of the **ocean** vector before `Add_9` contributes Shore Displacement; Unreal Z is Godot Y. This isolated scene has no ocean-simulation input, so `base = (0,0,0)`, then preserves the exact final `+ ShoreDisplacement` topology.

`WaveHeight` is the `Wave Height` scalar parameter selected by the graph's `Use in Blueprint?` switch. That scalar has no non-zero default written in the exported function. For the visible comparison the scene uses the non-artistic Waterline fallback `Water_Parameters[Water Height] = 15 cm`; its value is exposed as `breakup_wave_height_cm`. Set it to `0` to reproduce the literal unconfigured scalar default.

## Traced `Displacement BreakUp 4 Way`

`Use Displacement BreakUp 4 Way` does not add a separate displacement. It only replaces `selector` above:

```text
selector (4 Way off) = sample(Displacement_Contrast, panner(worldXY / WaterTile, WaveSpeed)).r

uv = worldXY / (-abs(WaterTile))                                (Divide_2, ComponentMask_13)
t  = WaveSpeed * Time                                           (Multiply_2)

selector (4 Way on) =
  sample(Displacement_Contrast, uv + t*( 0.1,  0.1)).r +
  sample(Displacement_Contrast, uv + (0.418100, 0.354800) + t*(-0.1, -0.1)).r +
  sample(Displacement_Contrast, uv + (0.864861, 0.148384) + t*(-0.1,  0.1)).r +
  sample(Displacement_Contrast, uv + (0.651340, 0.751638) + t*( 0.1, -0.1)).r
                                                                    (WS_Texture_4WayChaos)
```

`WS_Texture_4WayChaos` sums four RGBA texture samples (`Add_6`, `Add_7`, `Add_8`); the caller's `ComponentMask_2.R` consumes its red result, which is algebraically the four red samples shown above. `Displacement_Contrast` is sRGB in Waterline and the Godot sampler explicitly preserves that decode. The source values are `Wave Speed = 0.09` and `Wave Tile = 2000 cm` (20 m), and are exposed in the scene without optimization.

Both `T_PL_Wave_1_Disp.exr` and `Displacement_Contrast.tga` are local AUDIT references outside this repository. Neither is versioned here.

## Comparison controls

Run the scene and press:

- `1` — `BASE SHORE`: `MF_Shore_Gen3` branch only.
- `2` — `SHORE + BREAKUP`: adds the exact BreakUp Z branch, then Shore through the original `Add_9` topology.
- `3` — `SHORE + BREAKUP + 4 WAY`: same BreakUp branch, with its selector replaced by the exact four-way source function.

The camera is created and aimed automatically at the shore crest on startup. The `8 m × 6 m` plane is fixed at 128 × 96 quads, preserving 0.0625 m continuous spacing in all three modes.
