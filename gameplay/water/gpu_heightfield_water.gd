extends WaterSurfaceProvider3D
## Four contacts share one coherent packet. No on-demand CPU water sampling.
const Query = preload("res://addons/ocean/physics/gpu/ocean_surface_query.gd")
var fft: Node
var query: RefCounted
var latest: Dictionary = {}
var points := PackedVector3Array()
var samples: Array[Dictionary] = []
var result_age := -1
var ages: Array[int] = [] # validation opt-in only
var all_ages: Array[int] = []
var input_ages: Array[int] = []
var record_metrics := false
var unavailable_ticks := 0
var invalid_contacts := 0
var accepted_batches := 0
var minimum_generation := 0

func configure(ocean: Node) -> void:
	fft = ocean.get_node("OpenOceanFFT")
	query = fft.enable_gpu_surface_queries()
	query.set_validation_metrics_enabled(record_metrics)

func begin_contacts(body_transform: Transform3D, local_points: PackedVector3Array) -> void:
	if query == null or fft == null: return
	var tick := Engine.get_physics_frames()
	var completed: Dictionary = query.consume(tick) if query != null else {}
	var epoch: RefCounted = fft.get("_gpu_generation")
	if epoch == null: return
	var bands: Array = epoch.get_runtime_spectrum() if epoch != null else []
	# Initial production fields use config 0 until runtime weather metadata is
	# published. Match the query producer's explicit startup contract.
	var config := int(bands[0].configuration_version) if bands.size() == 3 else 0
	if not completed.is_empty() and int(completed.generation) >= minimum_generation and int(completed.ocean_epoch) == epoch.generation and int(completed.config_version) == config:
		latest = completed
		accepted_batches += 1
	points.clear()
	for p in local_points: points.append(body_transform * p)
	# Water age starts at the authoritative FFT publication's physics tick.
	# Contact-input age is recorded separately: no coordinate/time prediction.
	result_age = tick - int(latest.field_tick) if not latest.is_empty() else -1
	var coordinate_age := tick - int(latest.submit_tick) if not latest.is_empty() else -1
	if record_metrics and coordinate_age >= 0 and input_ages.size() < 20000: input_ages.append(coordinate_age)
	if record_metrics and result_age >= 0 and all_ages.size() < 20000: all_ages.append(result_age)
	samples.clear()
	var coherent: bool = not latest.is_empty() and int(latest.ocean_epoch) == epoch.generation and int(latest.config_version) == config
	if coherent and result_age >= 0 and result_age <= 2 and coordinate_age >= 0 and coordinate_age <= 2:
		for i in 4:
			var sample := Query.decode_heightfield(latest.bytes, i)
			if not sample.valid: invalid_contacts += 1
			samples.append(sample)
		if record_metrics and ages.size() < 20000: ages.append(result_age)
	else:
		unavailable_ticks += 1
	if query != null and points.size() == 4: query.submit(Query.pack_heightfield(points), tick)

func sample_water(world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	var out := out_sample.reset() if out_sample != null else WaterSample3D.new()
	if samples.size() != 4: return out
	var nearest := -1
	var distance := INF
	for i in 4:
		var d := points[i].distance_squared_to(world_position)
		if d < distance: nearest = i; distance = d
	if nearest < 0 or distance > 0.0001: return out
	return _fill(out, samples[nearest], world_position)

func has_usable_contacts() -> bool:
	return samples.size() == 4

func invalidate_contacts() -> void:
	latest.clear(); samples.clear()
	if query != null: minimum_generation = int(query.get_stats().submitted) + 1

func sample_propulsion_water(world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	var out := out_sample.reset() if out_sample != null else WaterSample3D.new()
	if samples.size() != 4 or not samples[2].valid or not samples[3].valid: return out
	# Rear-contact immersion gates the existing rear jet. No fifth GPU query.
	var average: Dictionary = samples[2].duplicate()
	average.surface_world_y = (samples[2].surface_world_y + samples[3].surface_world_y) * 0.5
	average.surface_vertical_velocity = (samples[2].surface_vertical_velocity + samples[3].surface_vertical_velocity) * 0.5
	average.normal = (samples[2].normal + samples[3].normal).normalized()
	return _fill(out, average, world_position)

func _fill(out: WaterSample3D, sample: Dictionary, world_position: Vector3) -> WaterSample3D:
	if not sample.valid: return out
	var y := float(sample.surface_world_y)
	var vy := float(sample.surface_vertical_velocity)
	var normal: Vector3 = sample.normal
	if not is_finite(y) or not is_finite(vy) or not normal.is_finite():
		push_error("Non-finite PHYSICAL_HEIGHTFIELD sample"); return out
	out.valid = true
	out.surface_position = Vector3(world_position.x, y, world_position.z)
	out.signed_depth = y - world_position.y
	out.normal = normal
	out.velocity = Vector3(0, vy, 0)
	out.provider = self
	return out
