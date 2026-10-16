extends RefCounted
## Geometry history selects real intersections; short seams only bridge A/B or recovery.
const HISTORY_STRIDE := 9
const SEAM_SECONDS := 0.12
var history := PackedFloat64Array()
var field_time := -1.0
var last_samples: Array[WaterSample3D] = []
var seam_from: Array[WaterSample3D] = []
var seam_elapsed := PackedFloat32Array()
var previous_fallback := PackedByteArray()
var last_tick := -1
var mode_seam_pending := false


func reset() -> void:
	history.clear()
	field_time = -1.0
	last_samples.clear()
	seam_from.clear()
	seam_elapsed.clear()
	previous_fallback.clear()
	last_tick = -1
	mode_seam_pending = false


func change_mode() -> void:
	history.clear()
	field_time = -1.0
	mode_seam_pending = true


func clone_sample(sample: WaterSample3D) -> WaterSample3D:
	var copy := WaterSample3D.new()
	copy.valid = sample.valid
	copy.surface_position = sample.surface_position
	copy.signed_depth = sample.signed_depth
	copy.normal = sample.normal
	copy.velocity = sample.velocity
	copy.provider = sample.provider
	copy.sample_time_seconds = sample.sample_time_seconds
	copy.sample_physics_tick = sample.sample_physics_tick
	return copy


func publish(samples: Array[WaterSample3D], positions: PackedVector3Array,
		geometry_rows: PackedFloat64Array, next_time: float, physics_delta: float) -> Array[WaterSample3D]:
	if samples.size() != positions.size(): return samples
	var count := samples.size()
	if last_samples.size() != count:
		reset()
		last_samples.resize(count)
		seam_from.resize(count)
		seam_elapsed.resize(count)
		seam_elapsed.fill(SEAM_SECONDS)
		previous_fallback.resize(count)
	var tick := Engine.get_physics_frames()
	var delta := physics_delta if tick != last_tick else 0.0
	var next_history := PackedFloat64Array()
	if geometry_rows.size() == 1 + count * 11:
		next_history.resize(count * HISTORY_STRIDE)
		next_history.fill(NAN)
	for index in count:
		var sample := samples[index]
		var row := 1 + index * 11
		var geometric := not next_history.is_empty() and geometry_rows[row] > 0.5
		var fallback := not next_history.is_empty() and not geometric
		var branch_jump := geometric and geometry_rows[row + 10] > 1.5
		var old: WaterSample3D = last_samples[index]
		# Teleports/layout changes must not carry an old water plane to a new location.
		var nearby := old != null and old.valid and Vector2(old.surface_position.x - positions[index].x,
			old.surface_position.z - positions[index].z).length() < 3.0
		if nearby and sample.valid and (mode_seam_pending or
				((branch_jump or fallback != bool(previous_fallback[index])) and seam_elapsed[index] >= SEAM_SECONDS)):
			seam_from[index] = clone_sample(old)
			seam_elapsed[index] = 0.0
		if not nearby: seam_elapsed[index] = SEAM_SECONDS
		if geometric:
			var offset := index * HISTORY_STRIDE
			next_history[offset] = positions[index].x
			next_history[offset + 1] = positions[index].z
			next_history[offset + 2] = geometry_rows[row + 1]
			next_history[offset + 3] = geometry_rows[row + 5]
			next_history[offset + 4] = geometry_rows[row + 6]
			for axis in 3: next_history[offset + 5 + axis] = geometry_rows[row + 7 + axis]
			next_history[offset + 8] = geometry_rows[row + 2]
		seam_elapsed[index] = minf(SEAM_SECONDS, seam_elapsed[index] + delta)
		var origin: WaterSample3D = seam_from[index]
		if sample.valid and origin != null and seam_elapsed[index] < SEAM_SECONDS:
			var t := seam_elapsed[index] / SEAM_SECONDS
			var weight := t * t * (3.0 - 2.0 * t)
			var moved := positions[index] - origin.surface_position
			var previous_y := origin.surface_position.y + origin.velocity.y * seam_elapsed[index] \
				- (origin.normal.x * moved.x + origin.normal.z * moved.z) / maxf(0.15, origin.normal.y)
			sample.surface_position.y = lerpf(previous_y, sample.surface_position.y, weight)
			sample.signed_depth = sample.surface_position.y - positions[index].y
			sample.normal = origin.normal.lerp(sample.normal, weight).normalized()
			sample.velocity = origin.velocity.lerp(sample.velocity, weight)
		last_samples[index] = clone_sample(sample)
		previous_fallback[index] = int(fallback)
	history = next_history
	field_time = next_time
	last_tick = tick
	mode_seam_pending = false
	return samples
