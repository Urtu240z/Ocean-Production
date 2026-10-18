# Jet Ski Inspector

Names and sections are in English. Hover over a property label for its Spanish explanation, units and relevant mode. Gameplay values and existing scene overrides are retained.

Enable **Project → Project Settings → Plugins → Jet Ski Inspector** to filter controls by the selected mode. The supplied example project enables it automatically. This editor plugin is optional at runtime; disabling it shows the full property list without changing the vehicle.

**Buoyancy Physics** is the standard physics model. **Legacy → Show Legacy Settings** is a separate, disabled-by-default authoring switch for the old models. It reveals their selectors and controls without activating them. **Show All Mode Settings** can reveal disabled assists, but cannot bypass the Legacy switch. Hiding a property never resets it. The Inspector uses Godot's normal editors, scene overrides and Undo/Redo.

| Location | Controls |
|---|---|
| Vehicle root → Water | Ocean reference; alternate provider paths |
| Buoyancy Physics / Water Entry | Standard hull response, running trim, pitch limit, nose recovery and landing penetration |
| Legacy → Physics Model | Old model selectors; Buoyancy Physics + Standard selects the current physics |
| Legacy → Four Point Support / Four Point Angular Response | Old point spring and angular response controls |
| Legacy → Heavy Hull / Heavy Wave Inclination | Heavy response, inertia and wave inclination |
| Mass and Inertia / Water Resistance | Rider inertia and water drag |
| Propulsion | Drive Mode, custom engine values and contact dependence |
| Steering / Rider Control | Turn continuity, lean, virtual rider authority and limits |
| Diving / Tricks | Dive behavior, preload, ejection and air correction |
| Contact Detection / Recovery | Contact confirmation, landing signals and reset limits |
| ProductionSetup | Provider configuration, input bindings and production mode switches |
| Systems/WaterPhysicsSystem | Hull volume sampling and lower level water response |
| BowSprayRoot | Independent Bow Spray, Splash, Tail Jet and Stern Mist profiles and preview |
| CameraRig / VisualRoot | Camera and visual-only motion |
| Ocean | Hull Foam, Running Foam and Hull Waves |

## Engine presets

**Drive Mode → Custom (Stock)** uses the saved forward/reverse force and thrust falloff controls. **Sport** and **Race** use their existing predefined values, so the custom controls are hidden. Race remains the default. This cleanup does not change driving forces or physics formulas.

## Compatibility

Legacy and Heavy remain stored for compatibility. Their controls stay together in Legacy and appear only after Show Legacy Settings is enabled and the corresponding mode is selected. Existing scenes that use an old model retain it and show an Inspector notice. Buoyancy Physics does not use the old per-point spring settings. Internal enum/property identifiers are unchanged so saved scenes and integrations remain compatible.

The reserved `droplets_atlas` property was never used by the spray renderer and is no longer offered as an editable control. Its stored value remains readable for old scenes. WaterPhysicsSystem's `buoyancy_draft_offset_m` is also stored internally: the vehicle's draft mode sets it at startup, so it is no longer presented as an independent tuning option.

Root gameplay scripts remain non-tool scripts. The Inspector filter runs only in the editor and adds no per-frame gameplay work. Most root physics settings are applied on startup; use a new run to assess changes reliably.
