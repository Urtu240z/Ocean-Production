extends "res://validation/physics/perf_contact_real_scene_profile.gd"
var selected := false
var stage_us := PackedInt64Array([0,0,0,0,0])
var hull_rows: Array = []
var previous_batches := {}

func wait_seconds(seconds: float) -> void:
	if not selected and is_instance_valid(world) and world.ready_to_drive:
		var bodies: Array = [boat]
		bodies.append_array(extra_boats)
		for body in bodies:
			body.get("water_physics_system").hull_buoyancy.geometry_backend = int(option("--hull-geometry","0"))
		selected = true
	await super(seconds)

func perf2_record_span(stage: int, frame_id: int, tick_id: int, started: int, finished: int, calls: int) -> void:
	super(stage,frame_id,tick_id,started,finished,calls)
	if measured and stage in [2,3,4]: stage_us[stage] += finished-started

func end_tick() -> void:
	super()
	var native_tetra_ns := 0
	var native_total_ns := 0
	var fallbacks := 0
	var uploads := 0
	var batches := 0
	var bodies: Array = [boat]
	bodies.append_array(extra_boats)
	for body in bodies:
		var geometry: RefCounted = body.get("water_physics_system").hull_buoyancy
		var id: int = body.get_instance_id()
		var advanced: bool = geometry.native_batch_count != int(previous_batches.get(id,geometry.native_batch_count))
		previous_batches[id] = geometry.native_batch_count
		fallbacks += geometry.native_fallback_count
		uploads += geometry.native_geometry_uploads
		batches += geometry.native_batch_count
		if measured and advanced and geometry.geometry_backend == 1:
			var profile: PackedInt64Array = geometry.native_geometry_profile()
			if profile.size() == 3:
				native_total_ns += profile[0]
				native_tetra_ns += profile[1]
	if not measured: return
	hull_rows.append([Engine.get_physics_frames(),stage_us[2],stage_us[3],stage_us[4],native_tetra_ns,native_total_ns,fallbacks,uploads,batches])
	stage_us.fill(0)

func measure(label: String, point: Vector3, velocity: Vector3, rotate: bool, seconds: float) -> void:
	hull_rows.clear(); stage_us.fill(0)
	await super(label,point,velocity,rotate,seconds)
	cases[-1]["hull_geometry"] = hull_rows.duplicate(true)
	cases[-1]["hull_backend"] = int(option("--hull-geometry","0"))
