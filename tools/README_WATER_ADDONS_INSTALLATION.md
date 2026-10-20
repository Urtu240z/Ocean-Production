# Water Race addons — 20 October 2026

Use **Godot 4.7.1 or later compatible 4.7 builds**, Forward+, and a RenderingDevice
GPU. The descriptor declares ABI minimum 4.7; this release is tested with 4.7.1.
Compatibility/OpenGL and Mobile are not validated. The native libraries require
Windows or Linux **x86-64 with AVX2**. Other architectures are not supplied.

## Install

- **Ocean_Addon.zip**: extract at the project root to obtain `addons/ocean/`.
  Ocean works independently of Jet Ski. No MCP plugin or autoload is needed.
- **JetSki_Addon.zip**: extract at the root alongside **Ocean**. Jet Ski requires
  Ocean; this archive is not a standalone installation.
- **WaterRace_Addons_Complete.zip**: recommended; extract at the root to obtain
  both addon folders. Do not add a containing folder around `addons/`.

Preserve `.uid`, `.import`, shaders/includes, presets, texture paths and letter
case. Let Godot regenerate its own `.godot/` cache. Detailed documentation is in
each addon's `INSTALLATION.md`; visual controls are documented beside the effects.

## New project and example

Copy `addons/jet_ski/examples/project.godot.example` to the project root as
`project.godot` **only for a new project**. Open/import with Godot, then run
`res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn`. This installs default input
actions only when they are missing and uses the existing camera and driving.
The optional Jet Ski Inspector plugin can be enabled in Project Settings → Plugins.

For an existing project select Forward+, **Jolt Physics**, physics **60 Hz** and
physics interpolation. Configure inputs without overwriting your existing map:
W/S throttle/brake/reverse, A/D steer, arrows rider lean, R reset, T recover,
E eject; camera C, wheel/+/- and PageUp/PageDown. The addon installs missing
actions and respects existing bindings, including deliberately empty bindings.

Instantiate `res://addons/ocean/ocean.tscn`. Ocean-only hosts must provide their
own Camera3D, environment and light. Instantiate
`res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn` and assign its **Water → Ocean**
reference to that Ocean. A code host can call `vehicle.configure_ocean(ocean)`
before adding the vehicle. All vehicles share the Ocean/provider. The demo
illustrates startup. Missing native water keeps the vehicle suspended safely.

Production retains CPU Lite 128/128/128 cubic, Async 3 workers and native C++
HULL V1 geometry. LEGACY_4POINT remains a separate available physics model.
No release packaging change retunes buoyancy, handling, waves or visual effects.

## Native libraries and exports

The descriptor is `addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension`.
Its `bin/` folder contains the matching Windows release DLL and Linux release SO;
both register OceanQueryNative and HullBuoyancyGeometryNative. The release
descriptor selects the same platform library for editor, debug and release.
Keep the descriptor and both libraries intact. Jet Ski adds no separate library.
Linux library ABI/build details and third-party notices remain in Ocean's native
source and `LINUX.md`. No native recompilation is needed for this release.

Export with **`*.glsl,*.inc,*.source`** included. These files are opened at runtime.
Enable **Ocean Shader Export** in Project Settings → Plugins before exporting.
The supplied example project enables it. It adds raw GLSL beside the normal
imported SPIR-V resources; runtime FileAccess consumers need the original text.
Importing/playing Ocean does not require this editor-only export hook. Jet Ski's
Inspector plugin remains optional and serves a separate purpose.
Use `addons/jet_ski/examples/export_presets.cfg.example` as a starting point for
a new project's export presets. Copy it to root as `export_presets.cfg`, choose
your own output path and install matching Godot export templates. Keep addon
resources selected. An addon ZIP is source/assets for installation, not a game
executable or PCK. The generated release manifest records archive/native hashes,
the exact source commit and the actual test results.

Windows graphical installation and Linux native loading are tested separately.
See `manifest.json` beside the ZIPs for this release's results. Steam Deck hardware,
AMD Vulkan rendering and a selected Steam Linux Runtime export remain pending;
no Steam Deck performance or controller certification is claimed.
