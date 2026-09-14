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
