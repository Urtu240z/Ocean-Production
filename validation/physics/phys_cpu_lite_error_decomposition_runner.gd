extends SceneTree

## Decomposes true retained-spectrum loss from grid reconstruction at real replay contacts.
const WORLD := preload("res://gameplay/jet_ski_ocean.tscn")
const VARIANTS := [
	{"name": "A_128_128_64_BILINEAR", "n": [128, 128, 64], "modes": [0, 0, 0]},
	{"name": "B_128_128_128_BILINEAR", "n": [128, 128, 128], "modes": [0, 0, 0]},
	{"name": "C_256_128_128_BILINEAR", "n": [256, 128, 128], "modes": [0, 0, 0]},
	{"name": "D_128_128_128_CUBIC", "n": [128, 128, 128], "modes": [1, 1, 1]},
]
const SELECTED_TICKS := 8
var _world: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var state := "storm" if OS.get_cmdline_user_args().has("--state=storm") else (
		"normal" if OS.get_cmdline_user_args().has("--state=normal") else "current_production")
	var path := "res://.godot/phys_cpu_lite_contact_trace_%s.json" % state
	if not FileAccess.file_exists(path): _fail("missing trace " + path); return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary: _fail("invalid trace json"); return
	var trace: Dictionary = parsed
	var groups := _group_rows(trace.get("rows", []))
	var selected := _select_groups(groups)
	_world = WORLD.instantiate()
	_world.physics_water_backend = 1
	_world.compare_cpu_backends = false
	_world.contact_debug = false
	_world.follow_camera = false
	var ocean: Node = _world.get_node("Production/Ocean")
	ocean.set("coastal", false)
	ocean.set("breakers", false)
	if state != "current_production":
		ocean.set("sea_state_mode", 1)
		ocean.set("significant_wave_height_m", 3.0 if state == "storm" else 1.8)
		ocean.set("wind_speed_mps", 18.0 if state == "storm" else 8.0)
		ocean.set("wind_direction_degrees", 75.0 if state == "storm" else 35.0)
		ocean.set("wave_height_scale", 1.16 if state == "storm" else 1.0)
		ocean.set("swell", 0.8 if state == "storm" else 1.0)
	root.add_child(_world)
	for _frame in 360:
		await process_frame
		if bool(_world.get("ready_to_drive")): break
	if not bool(_world.get("ready_to_drive")): _fail("provider failed to initialize"); return
	var provider: Node = _world.get_node("PhysicalWater")
	var native: Object = provider.get("native")
	var output := {"status": "CAPTURED_REVIEW_REQUIRED", "state": state,
		"samples": 0, "selected_ticks": [], "selection": "8 evenly spaced tick groups from the actual Full CPU contact trace; all recorded contacts per tick",
		"variants": []}
	for variant: Dictionary in VARIANTS:
		var per_band: Array = []
		for _band in 3:
			per_band.append({"spectral_height": [], "spectral_vertical_velocity": [],
				"spectral_gradient_x": [], "spectral_gradient_z": [], "spectral_normal_degrees": [],
				"spatial_height": [], "spatial_vertical_velocity": [], "spatial_gradient_x": [],
				"spatial_gradient_z": [], "spatial_normal_degrees": []})
		var aggregate := _new_aggregate()
		for group: Dictionary in selected:
			var contacts: Array = group.rows
			var positions := PackedVector3Array()
			for record: Dictionary in contacts: positions.append(_world_pos(record))
			if not bool(native.call("build_dynamic_physics_fields", float(group.time))):
				_fail("full direct field build failed at time %.6f" % float(group.time)); return
			var full: PackedFloat64Array = native.call("sample_dynamic_spectrum_oracle_batch", positions, false)
			if full.size() != 1 + positions.size() * 13: _fail("full direct oracle returned invalid data"); return
			if not bool(native.call("build_dynamic_physics_lite", float(group.time), PackedInt32Array(variant.n))):
				_fail("reduced grid build failed for " + String(variant.name)); return
			var retained: PackedFloat64Array = native.call("sample_dynamic_spectrum_oracle_batch", positions, true)
			var grid: PackedFloat64Array = native.call("sample_dynamic_lite_bands", positions, PackedInt32Array(variant.modes))
			if retained.size() != full.size() or grid.size() != full.size(): _fail("reduced oracle returned invalid data"); return
			for index in positions.size():
				var offset := 1 + index * 13
				var full_g := Vector2.ZERO
				var retained_g := Vector2.ZERO
				var grid_g := Vector2.ZERO
				for band in 3:
					var b := offset + 1 + band * 4
					var fh := full[b]; var fvy := full[b + 1]; var fdx := full[b + 2]; var fdz := full[b + 3]
					var rh := retained[b]; var rvy := retained[b + 1]; var rdx := retained[b + 2]; var rdz := retained[b + 3]
					var gh := grid[b]; var gvy := grid[b + 1]; var gdx := grid[b + 2]; var gdz := grid[b + 3]
					var metrics: Dictionary = per_band[band]
					metrics.spectral_height.append(fh - rh)
					metrics.spectral_vertical_velocity.append(fvy - rvy)
					metrics.spectral_gradient_x.append(fdx - rdx)
					metrics.spectral_gradient_z.append(fdz - rdz)
					metrics.spectral_normal_degrees.append(_normal_angle(fdx, fdz, rdx, rdz))
					metrics.spatial_height.append(rh - gh)
					metrics.spatial_vertical_velocity.append(rvy - gvy)
					metrics.spatial_gradient_x.append(rdx - gdx)
					metrics.spatial_gradient_z.append(rdz - gdz)
					metrics.spatial_normal_degrees.append(_normal_angle(rdx, rdz, gdx, gdz))
					full_g += Vector2(fdx, fdz)
					retained_g += Vector2(rdx, rdz)
					grid_g += Vector2(gdx, gdz)
					aggregate.spectral_height.append(fh - rh)
					aggregate.spectral_vy.append(fvy - rvy)
					aggregate.spatial_height.append(rh - gh)
					aggregate.spatial_vy.append(rvy - gvy)
				aggregate.spectral_normal.append(_normal_vec_angle(full_g, retained_g))
				aggregate.spatial_normal.append(_normal_vec_angle(retained_g, grid_g))
			output.samples += positions.size()
			output.selected_ticks.append({"tick": group.tick, "time": group.time, "contacts": positions.size()})
		var band_results: Array = []
		for band in 3:
			var result := {}
			for metric: String in per_band[band]: result[metric] = _stats(per_band[band][metric])
			band_results.append(result)
		var aggregate_results := {}
		for metric: String in aggregate: aggregate_results[metric] = _stats(aggregate[metric])
		output.variants.append({"name": variant.name, "resolutions": variant.n,
			"interpolation_modes": variant.modes, "per_band": band_results,
			"all_band_total": aggregate_results})
	var file := FileAccess.open("res://.godot/phys_cpu_lite_error_decomposition_%s.json" % state, FileAccess.WRITE)
	if file == null: _fail("could not write decomposition output"); return
	file.store_string(JSON.stringify(output, "\t")); file.close()
	print("PHYS_CPU_LITE_DECOMPOSITION=res://.godot/phys_cpu_lite_error_decomposition_%s.json" % state)
	quit(0)

func _group_rows(rows: Array) -> Array[Dictionary]:
	var by_tick: Dictionary = {}
	var groups: Array[Dictionary] = []
	for row: Dictionary in rows:
		var tick := int(row.tick)
		if not by_tick.has(tick):
			by_tick[tick] = {"tick": tick, "time": float(row.simulation_time), "rows": []}
			groups.append(by_tick[tick])
		by_tick[tick].rows.append(row)
	return groups

func _select_groups(groups: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if groups.is_empty(): return result
	for i in SELECTED_TICKS:
		var index := mini(groups.size() - 1, int((float(i) + 0.5) * groups.size() / SELECTED_TICKS))
		result.append(groups[index])
	return result

func _new_aggregate() -> Dictionary:
	return {"spectral_height": [], "spectral_vy": [], "spatial_height": [],
		"spatial_vy": [], "spectral_normal": [], "spatial_normal": []}

func _world_pos(row: Dictionary) -> Vector3:
	var p: Array = row.world_position
	return Vector3(float(p[0]), float(p[1]), float(p[2]))

func _normal_angle(ax: float, az: float, bx: float, bz: float) -> float:
	return rad_to_deg(Vector3(-ax, 1.0, -az).normalized().angle_to(Vector3(-bx, 1.0, -bz).normalized()))

func _normal_vec_angle(a: Vector2, b: Vector2) -> float:
	return _normal_angle(a.x, a.y, b.x, b.y)

func _stats(source: Array) -> Dictionary:
	if source.is_empty(): return {"count": 0}
	var values: Array[float] = []
	var sum := 0.0
	var square := 0.0
	for item in source:
		var value := absf(float(item))
		values.append(value); sum += value; square += value * value
	values.sort()
	return {"count": values.size(), "mean": sum / values.size(), "rms": sqrt(square / values.size()),
		"p90": values[ceili(values.size() * 0.90) - 1], "p95": values[ceili(values.size() * 0.95) - 1],
		"p99": values[ceili(values.size() * 0.99) - 1], "max": values.back()}

func _fail(message: String) -> void:
	printerr("PHYS_CPU_LITE_DECOMPOSITION_FAIL=" + message)
	quit(1)
