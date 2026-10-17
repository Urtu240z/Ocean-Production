# Editor preview validation

Temporary EditorPlugin test harness; not part of either distributed addon.
It opens a fixture, captures the real editor viewport and closes that test editor.
Do not enable this plugin in a production editor session.

Reuse a clean installation project containing the current Ocean/Jet Ski addons.
Copy `plugin.cfg` and `plugin.gd` into its `addons/preview_probe/`, copy
`preview_probe.tscn` to its root, and enable only this test plugin:

```ini
[editor_plugins]
enabled=PackedStringArray("res://addons/preview_probe/plugin.cfg")
```

Launch the editor with a real Forward+ renderer:

```text
Godot --editor --path <clean-project> res://preview_probe.tscn --audio-driver Dummy -- --result-dir=<evidence-directory>
```

Checks editor preview publication, fixed material time, no repeated FFT builds or
dispatches while idle, SSPR attachment/dispatch on the editor camera, unchanged
scene WorldEnvironment compositor, exclusion of generated nodes from scene
serialization, Preview Time changes, nested resource edits, material-only updates
without FFT rebuild, shader roughness uniform, ON/OFF and compositor teardown.
The default output directory is `user://ocean_editor_preview_validation/`.
