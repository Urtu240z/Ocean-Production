# Jet Ski Inspector

Names and sections are in English. Hover over a property label for its Spanish explanation, units and relevant mode. Gameplay values and existing scene overrides are retained.

Enable **Project → Project Settings → Plugins → Jet Ski Inspector** to filter controls by the selected mode. The supplied example project enables it automatically. This editor plugin is optional at runtime; disabling it shows the full property list without changing the vehicle.

**Show All Mode Settings** reveals controls for other buoyancy modes and disabled assists. Hiding a property never resets it. The Inspector uses Godot's normal editors, scene overrides and Undo/Redo.

| Location | Controls |
|---|---|
| Vehicle root → Water | Ocean reference; alternate provider paths |
| Buoyancy / Water Response | Hull V1 or Legacy support; Legacy angular response |
| Heavy Hull | Heavy response, inertia and wave inclination; visible in Heavy mode |
| Hull Assist / Water Entry | Normal Hull V1 assists, running trim, pitch limit, nose recovery and landing penetration |
| Mass and Inertia / Water Resistance | Rider inertia and water drag |
| Propulsion | Drive Mode, custom engine values and contact dependence |
| Steering / Rider Control | Turn continuity, lean, virtual rider authority and limits |
| Diving / Tricks | Dive behavior, preload, ejection and air correction |
| Contact Detection / Recovery | Contact confirmation, landing signals and reset limits |
| ProductionSetup | Provider configuration, input bindings and production mode switches |
| Systems/WaterPhysicsSystem | Hull volume sampling and lower level water response |
| BowSprayRoot | Independent Bow Spray, Splash and Tail Jet profiles and preview |
| CameraRig / VisualRoot | Camera and visual-only motion |
| Ocean | Hull Foam, Running Foam and Hull Waves |

## Engine presets

**Drive Mode → Custom (Stock)** uses the saved forward/reverse force and thrust falloff controls. **Sport** and **Race** use their existing predefined values, so the custom controls are hidden. Race remains the default. This cleanup does not change driving forces or physics formulas.

## Compatibility

Legacy and Heavy are functioning alternatives, not deleted code. Their controls appear when the corresponding mode is selected. Normal Hull V1 does not use the old per-point spring settings.

The reserved `droplets_atlas` property was never used by the spray renderer and is no longer offered as an editable control. Its stored value remains readable for old scenes. WaterPhysicsSystem's `buoyancy_draft_offset_m` is also stored internally: the vehicle's draft mode sets it at startup, so it is no longer presented as an independent tuning option.

Root gameplay scripts remain non-tool scripts. The Inspector filter runs only in the editor and adds no per-frame gameplay work. Most root physics settings are applied on startup; use a new run to assess changes reliably.
