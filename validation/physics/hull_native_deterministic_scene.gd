extends "res://validation/physics/perf_contact_deterministic_scene.gd"
const RecordingGeometry = preload("res://validation/physics/hull_native_recording_geometry.gd")
var installed := false

func begin_tick() -> void:
	super()
	if not recording or installed: return
	for body in replay_bodies:
		var physics: Node = body.get("water_physics_system")
		var old: RefCounted = physics.hull_buoyancy
		var geometry := RecordingGeometry.new()
		geometry.cells = old.cells
		geometry.local_points = old.local_points
		geometry.total_volume_m3 = old.total_volume_m3
		geometry.geometry_generation = old.geometry_generation
		geometry.geometry_backend = int(option("--hull-geometry","0"))
		physics.hull_buoyancy = geometry
	installed = true

func end_tick() -> void:
	var before := replay_rows.size()
	super()
	if replay_rows.size() == before: return
	var diagnostic := []
	for i in replay_bodies.size():
		var geometry: RefCounted = replay_bodies[i].get("water_physics_system").hull_buoyancy
		var values := []
		for cell in 12:
			if geometry.recorded_ticks[cell] == Engine.get_physics_frames():
				var value: Dictionary = geometry.recorded[cell]
				values.append({"volume":value.volume,"center":vector(value.center),"depth":value.depth})
			else: values.append(null)
		replay_rows[-1].bodies[i]["hull_cell_geometry"] = values
		diagnostic.append({"backend":geometry.geometry_backend,"native_batches":geometry.native_batch_count,
			"fallbacks":geometry.native_fallback_count,"uploads":geometry.native_geometry_uploads})
	replay_rows[-1]["hull_backend_diagnostics"] = diagnostic
