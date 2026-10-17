extends "res://validation/ocean_benchmark.gd"
## Reuse the authoritative benchmark world without its automatic feature sweep.
func _ready() -> void:
	_resolution = Vector2i(1920, 1080)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(_resolution)
	get_viewport().scaling_3d_scale = 1.0
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	_build_base_world()
	_ensure_ocean()
	_apply_base_state()
	_apply_state({"mask": CascadeState.FULL, "coastal": true, "crest_foam": true,
		"surface_foam": true, "optics": true, "reflections": true, "surface_detail": true})
	_ensure_island()
	_set_island_shadow(true)
	_sun.shadow_enabled = true

func physics_ocean() -> Node:
	return _ocean

func contract() -> Dictionary:
	return {"source_harness": "res://validation/ocean_benchmark.tscn", "camera_position": [0,8,16],
		"camera_rotation_degrees": [-12,0,0], "resolution": [1920,1080], "vsync": false,
		"fps_cap": 0, "dynamic_resolution": false, "upscaling": false,
		"bands": "LONG+MID+SHORT N256", "coastal": true, "optics": true, "SSPR": true,
		"crest_foam": true, "surface_foam": true, "surface_detail": true, "breakers": false,
		"spindrift": false, "underwater": false, "island": true, "shadows": true,
		"profile": PROFILE_PATH, "seed": 20260820, "Hs": 2.574, "wind": 18.0, "direction": 5.71,
		"debug_engine": OS.is_debug_build(), "physics_hz": 60}
