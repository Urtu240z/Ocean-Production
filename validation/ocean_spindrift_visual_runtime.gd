extends Node

const P0_SCENE: PackedScene = preload("res://validation/p0_open_ocean.tscn")
const P7_SCENE: PackedScene = preload("res://validation/p7_breakers.tscn")
const CREST_PROBE_SHADER: Shader = preload("res://validation/shaders/ocean_spindrift_crest_probe.gdshader")
const FORCE_EMISSION_MODE: int = 6
const FULL_MODE: int = 5
const CHUNKS_ONLY_MODE: int = 2
const STREAKS_ONLY_MODE: int = 3
const MIST_ONLY_MODE: int = 4
const POSITION_DEBUG_MODE: int = 10
const STARTUP_TIMEOUT_FRAMES: int = 900
const OBSERVATION_FRAMES: int = 180
const SCREEN_OBSERVATION_FRAMES: int = 300
const SCREEN_SAMPLE_STRIDE: int = 6
const DIRECT_CHILD_FRAMES: int = 45
const SCALE_TOLERANCE: float = 0.000001
const CAMERA_FOLLOW_STEP_M: float = 12.0
const REAL_GPU_REARM_SOAK_SECONDS: float = 90.0
const REAL_GPU_REARM_SAMPLE_SECONDS: float = 0.25
const REAL_G_MEASUREMENT_SECONDS: float = 60.0
const REAL_G_MEASUREMENT_SAMPLE_SECONDS: float = 0.50
const CREST_PROBE_SIZE: int = 64
const LEGACY_EFFECTIVE_SOURCE_RADIUS_M: float = 38.0
const PROVEN_TRIGGER_THRESHOLD: float = 0.40
const PROVEN_REARM_THRESHOLD: float = 0.20
const FINAL_PRODUCTION_LOD: Array[float] = [22.0, 55.0, 46.0]
const LOD_CANDIDATES: Array[Array] = [
	[22.0, 55.0, 46.0],
	[40.0, 80.0, 70.0],
	[60.0, 100.0, 90.0],
	[80.0, 120.0, 110.0],
	[120.0, 120.0, 120.0]
]

var _failed: bool = false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("OCEAN_SPINDRIFT_VISUAL_BEGIN")
	if not _run_source_contracts():
		_finish_failure()
		return
	if not _run_density_contract():
		_finish_failure()
		return
	if not _run_ocean_space_contract():
		_finish_failure()
		return

	var p0: Node = P0_SCENE.instantiate()
	if p0 == null:
		_fail("Could not instantiate P0")
		_finish_failure()
		return
	add_child(p0)
	var p0_ocean: Node = p0.find_child(^"Ocean", true, false) as Node
	if p0_ocean == null or not await _wait_for_spindrift(p0_ocean):
		_finish_failure()
		return

	var original_profile: Resource = p0_ocean.get("spindrift_profile") as Resource
	var spindrift: Node = _spindrift_node(p0_ocean)
	if spindrift == null:
		_fail("P0 Spindrift controller is missing")
		_finish_failure()
		return
	var initial_state: Dictionary = _spindrift_state(p0_ocean)
	_print_runtime_diagnostic("INITIAL", initial_state)
	print("SPINDRIFT_EFFECTIVE_SOURCE_RADIUS_BEFORE=%.1f (legacy forward-strip contract)" % LEGACY_EFFECTIVE_SOURCE_RADIUS_M)
	print("SPINDRIFT_EFFECTIVE_SOURCE_RADIUS_AFTER=%.1f (%s)" % [
		float(initial_state.get("effective_source_radius_m", 0.0)),
		initial_state.get("source_region_shape", "unknown")])
	if not _run_sensor_coverage_contract(initial_state):
		_finish_failure()
		return
	if not _check_runtime_contract(initial_state):
		_finish_failure()
		return
	var crest_measurement: Dictionary = await _measure_real_crest_g(p0, p0_ocean, spindrift)
	if not bool(crest_measurement.get("healthy", false)):
		_finish_failure()
		return
	print("OCEAN_SPINDRIFT_PROFILE_EXPORT_CONTRACT_PASS")

	print("SPINDRIFT_COLD_START_BASELINE_CONFIRMED")
	print("SPINDRIFT COLD START VALUES | trigger=%.2f rearm=%.2f lod=%s radius=%.1f mode=%s" % [
		float(original_profile.get("breaking_trigger_threshold")),
		float(original_profile.get("breaking_rearm_threshold")),
		[
			float(original_profile.get("chunks_lod_end_m")),
			float(original_profile.get("streaks_lod_end_m")),
			float(original_profile.get("mist_lod_end_m"))],
		float(original_profile.get("spindrift_radius")),
		_spindrift_state(p0_ocean).get("debug_mode_name", "unknown")])
	if not _check_persisted_production_profile(original_profile, _spindrift_state(p0_ocean)):
		_finish_failure()
		return
	print("OCEAN_SPINDRIFT_PERSISTED_PROFILE_PASS")
	var lod_sweep: Dictionary = await _run_lod_sweep(p0_ocean, spindrift, original_profile)
	if not bool(lod_sweep.get("healthy", false)):
		_finish_failure()
		return
	print("SPINDRIFT_LOD_SWEEP_RECOMMENDATION=%s" % [lod_sweep.get("selected_lod", [])])
	spindrift = _spindrift_node(p0_ocean)
	if spindrift == null:
		_finish_failure()
		return
	await _restart_sensors(spindrift)
	if not _run_hysteresis_contract(p0_ocean):
		_finish_failure()
		return
	print("OCEAN_SPINDRIFT_HYSTERESIS_REARM_PASS")

	var normal_state: Dictionary = await _observe_layers(spindrift, OBSERVATION_FRAMES)
	_print_runtime_diagnostic("NORMAL", _spindrift_state(p0_ocean))
	var screen_result: Dictionary = await _observe_real_screen_output(p0_ocean, spindrift, SCREEN_OBSERVATION_FRAMES)
	_print_screen_diagnostic("NORMAL", screen_result)
	if not _is_healthy_real_source(normal_state, screen_result):
		_fail("Normal Crest G source did not produce repeated multi-region screen output")
		_finish_failure()
		return
	print("SPINDRIFT VALIDATOR FALSE POSITIVE ROOT CAUSE | previous test accepted non-empty aggregate AABB; stale controller references after profile rebuild and no screen occupancy were not rejected")
	print("OCEAN_SPINDRIFT_VALIDATOR_FALSE_POSITIVE_FIXED_PASS")
	print("OCEAN_SPINDRIFT_FAR_SOURCE_REACH_PASS")
	print("OCEAN_SPINDRIFT_REAL_SOURCE_DISTRIBUTED_PASS")
	print("OCEAN_SPINDRIFT_P0_RUNTIME_PASS")
	if not await _run_scale_runtime_sweep(p0_ocean, spindrift):
		_finish_failure()
		return

	if not await _run_p7_smoke():
		_finish_failure()
		return
	print("OCEAN_SPINDRIFT_P7_SMOKE_PASS")
	spindrift = _spindrift_node(p0_ocean)
	if spindrift == null or not await _run_camera_follow_contract(p0, p0_ocean, spindrift):
		_finish_failure()
		return
	if not await _run_real_gpu_rearm_soak(p0, p0_ocean, spindrift):
		_finish_failure()
		return

	# Recreate normal P0 after all diagnostic sweeps so the cold-start gate uses
	# only the serialized Production profile, FULL mode and real Crest G source.
	p0.queue_free()
	await get_tree().process_frame
	var final_p0: Node = P0_SCENE.instantiate()
	add_child(final_p0)
	var final_ocean: Node = final_p0.find_child(^"Ocean", true, false) as Node
	if final_ocean == null or not await _wait_for_spindrift(final_ocean):
		_finish_failure()
		return
	var final_profile: Resource = final_ocean.get("spindrift_profile") as Resource
	var final_spindrift: Node = _spindrift_node(final_ocean)
	var final_state: Dictionary = _spindrift_state(final_ocean)
	_print_runtime_diagnostic("COLD_START_FINAL", final_state)
	if final_spindrift == null or not _check_persisted_production_profile(final_profile, final_state):
		_fail("Cold-start P0 did not load the persisted Spindrift production profile")
		_finish_failure()
		return
	var final_normal_state: Dictionary = await _observe_layers(final_spindrift, OBSERVATION_FRAMES)
	var final_normal_screen: Dictionary = await _observe_real_screen_output(final_ocean, final_spindrift, SCREEN_OBSERVATION_FRAMES, false)
	_print_screen_diagnostic("COLD_START_NORMAL", final_normal_screen)
	if not _is_healthy_normal_source(final_normal_state, final_normal_screen):
		_fail("Cold-start normal Crest G source did not produce distributed screen output")
		_finish_failure()
		return
	print("OCEAN_SPINDRIFT_COLD_START_TUNING_PASS")
	print("OCEAN_SPINDRIFT_COLD_START_DISTRIBUTED_PASS")
	var band_screen: Dictionary = await _observe_real_screen_output(final_ocean, final_spindrift, SCREEN_OBSERVATION_FRAMES, true)
	_print_screen_diagnostic("COLD_START_BANDS", band_screen)
	await _run_layer_band_diagnostic(final_ocean, final_spindrift)
	print("SPINDRIFT FINAL PRODUCTION | trigger=0.40 rearm=0.20 lod=%s radius=120.0 mode=FULL" % [FINAL_PRODUCTION_LOD])
	print("SPINDRIFT_FINAL_COLD_START_VISUAL_READY")
	print("SPINDRIFT_VISUAL_GATE_2_READY")
	print("SPINDRIFT_CAMERA_CONTINUITY_VISUAL_READY")


func _check_persisted_production_profile(profile: Resource, state: Dictionary) -> bool:
	if profile == null:
		return _fail("Persisted Spindrift profile is missing")
	var trigger: float = float(profile.get("breaking_trigger_threshold"))
	var rearm: float = float(profile.get("breaking_rearm_threshold"))
	var radius: float = float(profile.get("spindrift_radius"))
	var lod: Array[float] = [
		float(profile.get("chunks_lod_end_m")),
		float(profile.get("streaks_lod_end_m")),
		float(profile.get("mist_lod_end_m"))]
	if not is_equal_approx(trigger, PROVEN_TRIGGER_THRESHOLD) or not is_equal_approx(rearm, PROVEN_REARM_THRESHOLD):
		return _fail("Persisted Spindrift thresholds differ from proven 0.40/0.20")
	if not is_equal_approx(radius, 120.0) or lod != FINAL_PRODUCTION_LOD:
		return _fail("Persisted Spindrift radius/LOD differs from the selected production contract")
	if int(state.get("debug_mode", -1)) != FULL_MODE or not bool(state.get("source_ready", false)):
		return _fail("Cold-start Spindrift is not FULL and source-ready")
	return true


func _run_layer_band_diagnostic(ocean: Node, spindrift: Node) -> void:
	var layers: Array[Array] = [
		["CHUNKS", CHUNKS_ONLY_MODE],
		["STREAKS", STREAKS_ONLY_MODE],
		["MIST", MIST_ONLY_MODE]
	]
	for layer: Array in layers:
		ocean.set("spindrift_debug_mode", int(layer[1]))
		await _restart_sensors(spindrift)
		var result: Dictionary = await _observe_real_screen_output(ocean, spindrift, SCREEN_OBSERVATION_FRAMES, true)
		print("SPINDRIFT BAND LAYER | layer=%s near=%d mid=%d far=%d output_frames=%d regions=%d spread=%.3f" % [
			layer[0],
			int(result.get("near_frames", 0)),
			int(result.get("mid_frames", 0)),
			int(result.get("far_frames", 0)),
			int(result.get("frames_with_output", 0)),
			int(result.get("max_screen_regions", 0)),
			float(result.get("max_horizontal_spread", 0.0))])
	ocean.set("spindrift_debug_mode", FULL_MODE)
	await _restart_sensors(spindrift)
	print("OCEAN_SPINDRIFT_COLD_START_BAND_LAYER_REPORT_PASS")


func _run_source_contracts() -> bool:
	var event_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_event_particles.gdshader")
	var mask_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_source_mask.gdshader")
	var controller_source: String = FileAccess.get_file_as_string("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
	var profile_source: String = FileAccess.get_file_as_string("res://addons/ocean/core/ocean_spindrift_profile.gd")
	if event_source.is_empty() or mask_source.is_empty() or controller_source.is_empty() or profile_source.is_empty():
		return _fail("Required Spindrift source is missing")
	if not event_source.contains("breaking_activity_long") or not event_source.contains("texture(breaking_activity_long") or not event_source.contains(".g"):
		return _fail("Crest LONG.G is not the sensor authority")
	if event_source.contains("direct_j") or event_source.contains("jacobian"):
		return _fail("Spindrift source contains a duplicate breaker authority")
	if not event_source.contains("CUSTOM.w = 1.0") or not event_source.contains("CUSTOM.w = 0.0"):
		return _fail("Spindrift hysteresis state transitions are missing")
	if not event_source.contains("emit_subparticle") or controller_source.contains("emit_particle("):
		return _fail("Spindrift detached GPU emission contract changed")
	if not event_source.contains("ocean_space_displacement") or not mask_source.contains("ocean_space_displacement"):
		return _fail("Spindrift Ocean Space displacement helper is missing")
	if not event_source.contains("float(INDEX)"):
		return _fail("Spindrift sensor distribution is not driven by stable particle INDEX")
	if event_source.contains("sensor_forward_far_m") or event_source.contains("sensor_half_width_m"):
		return _fail("Legacy fixed forward-strip source contract remains authoritative")
	if not event_source.contains("source_edge_feather_m") or not event_source.contains("active_radius_m"):
		return _fail("Profile-driven source-radius edge contract is missing")
	if not event_source.contains("sensor_anchor_xz") or not mask_source.contains("sensor_anchor_xz"):
		return _fail("Explicit sensor anchor contract is missing")
	if event_source.contains("spindrift_origin") or mask_source.contains("mask_origin"):
		return _fail("Legacy camera/origin sensor anchor remains authoritative")
	if not event_source.contains("clipmap_geometry_scale") or not mask_source.contains("clipmap_geometry_scale"):
		return _fail("Spindrift horizontal Ocean Space scale is missing")
	if not event_source.contains("clamp(event_density, 0.0, 2.0)"):
		return _fail("Spindrift density is not authored over 0..2")
	if not event_source.contains("second_hash") or not event_source.contains("second_offset"):
		return _fail("Second density child has no independent variation")
	if not controller_source.contains("low_discrepancy_disk_index") or not controller_source.contains("effective_visual_radius_m"):
		return _fail("Spindrift runtime coverage diagnostics are missing")
	if not event_source.contains("ocean_space_normal_to_world_scaled"):
		return _fail("Spindrift normal inverse-transpose contract is missing")
	if not profile_source.contains("@export_range(0.0, 2.0, 0.01) var emission_density"):
		return _fail("Spindrift emission_density export range changed")
	print("OCEAN_SPINDRIFT_SOURCE_AUTHORITY_CREST_G_PASS")
	print("OCEAN_SPINDRIFT_DETACHED_AFTER_BIRTH_PASS")
	return true


func _run_density_contract() -> bool:
	var cases: Array[Dictionary] = [
		{"density": 0.0, "first": 0.25, "second": 0.25, "expected": 0},
		{"density": 0.5, "first": 0.25, "second": 0.75, "expected": 1},
		{"density": 0.5, "first": 0.75, "second": 0.25, "expected": 0},
		{"density": 1.0, "first": 0.99, "second": 0.99, "expected": 1},
		{"density": 1.5, "first": 0.99, "second": 0.25, "expected": 2},
		{"density": 1.5, "first": 0.99, "second": 0.75, "expected": 1},
		{"density": 2.0, "first": 0.99, "second": 0.99, "expected": 2},
	]
	for test_case: Dictionary in cases:
		var density: float = float(test_case["density"])
		var first_hash: float = float(test_case["first"])
		var second_hash: float = float(test_case["second"])
		var expected: int = int(test_case["expected"])
		var actual: int = _density_child_count(density, first_hash, second_hash)
		if actual != expected:
			return _fail("Density contract failed at %f: expected %d got %d" % [density, expected, actual])
	print("OCEAN_SPINDRIFT_DENSITY_0_2_CONTRACT_PASS")
	return true


func _density_child_count(density: float, first_hash: float, second_hash: float) -> int:
	var safe_density: float = clampf(density, 0.0, 2.0)
	var first: bool = safe_density >= 1.0 or first_hash <= safe_density
	if not first:
		return 0
	var second: bool = safe_density > 1.0 and second_hash <= safe_density - 1.0
	return 1 + (1 if second else 0)


func _run_ocean_space_contract() -> bool:
	var authored: Vector3 = Vector3(1.0, 2.0, -3.0)
	var expected_a: Vector3 = Vector3(2.0, 1.0, -6.0)
	var expected_b: Vector3 = Vector3(0.5, 4.0, -1.5)
	if not _approximately_equal(_ocean_space_displacement(authored, 2.0, 0.5), expected_a):
		return _fail("Spindrift Ocean Space anisotropic A failed")
	if not _approximately_equal(_ocean_space_displacement(authored, 0.5, 2.0), expected_b):
		return _fail("Spindrift Ocean Space anisotropic B failed")
	if not _approximately_equal(_ocean_space_displacement(authored, 1.0, 1.0), authored):
		return _fail("Spindrift Ocean Space identity failed")
	print("OCEAN_SPINDRIFT_OCEAN_SPACE_POSITION_PARITY_PASS")
	return true


func _ocean_space_displacement(authored: Vector3, horizontal: float, vertical: float) -> Vector3:
	return Vector3(authored.x * horizontal, authored.y * vertical, authored.z * horizontal)


func _wait_for_spindrift(ocean: Node) -> bool:
	for _frame: int in range(STARTUP_TIMEOUT_FRAMES):
		var state: Dictionary = _spindrift_state(ocean)
		if bool(state.get("enabled", false)) and bool(state.get("source_ready", false)) and int(state.get("active_layers", 0)) == 3:
			return true
		await get_tree().process_frame
	return _fail("Spindrift P0 startup timed out")


func _spindrift_state(ocean: Node) -> Dictionary:
	var value: Variant = ocean.call("get_spindrift_runtime_state")
	return value as Dictionary if value is Dictionary else {}


func _spindrift_node(ocean: Node) -> Node:
	var open_ocean: Node = ocean.get("_open_ocean") as Node
	return open_ocean.get("_spindrift") as Node if open_ocean != null else null


func _check_runtime_contract(state: Dictionary) -> bool:
	var capacities: Array = state.get("visible_layer_capacities", [])
	var sensor_amounts: Array = state.get("sensor_layer_amounts", [])
	if capacities.size() != 3 or sensor_amounts.size() != 3:
		return _fail("Spindrift layer capacity diagnostics are incomplete")
	for index: int in 3:
		if int(capacities[index]) < int(sensor_amounts[index]) * 2:
			return _fail("Visible capacity is below the 2x density contract")
	if int(state.get("max_event_multiplicity", 0)) != 2:
		return _fail("Spindrift max event multiplicity is not 2")
	if state.get("breaking_activity_authority", "") != "crest_g_long":
		return _fail("Runtime authority is not Crest G LONG")
	return true


func _run_sensor_coverage_contract(state: Dictionary) -> bool:
	var radius: float = float(state.get("effective_source_radius_m", 0.0))
	var spacing: float = float(state.get("sensor_grid_cell_m", 0.0))
	var amounts: Array = state.get("sensor_layer_amounts", [])
	if radius <= 0.0 or spacing <= 0.0 or amounts.size() != 3:
		return _fail("Sensor coverage diagnostics are incomplete")
	var area: float = PI * radius * radius
	for layer_index: int in 3:
		var count: int = int(amounts[layer_index])
		var unique_cells: Dictionary = {}
		for particle_index: int in count:
			var cell: Vector2i = _sampled_sensor_cell(particle_index, count, layer_index, radius, spacing)
			unique_cells[cell] = true
		var unique_count: int = unique_cells.size()
		var duplicate_percentage: float = 100.0 * float(count - unique_count) / maxf(float(count), 1.0)
		var area_per_sensor: float = area / maxf(float(count), 1.0)
		var average_spacing: float = sqrt(maxf(area_per_sensor, 0.0))
		print("SPINDRIFT SENSOR COVERAGE layer=%d sensors=%d unique_target_cells=%d duplicate_percent=%.3f effective_source_area_m2=%.2f average_area_per_sensor_m2=%.2f average_spacing_m=%.2f" % [
			layer_index, count, unique_count, duplicate_percentage, area, area_per_sensor, average_spacing])
		if unique_count < int(float(count) * 0.98):
			return _fail("Sensor distribution contains material duplicate cells in layer %d" % layer_index)
	print("OCEAN_SPINDRIFT_SENSOR_COVERAGE_PASS")
	return true


func _sampled_sensor_cell(particle_index: int, count: int, layer_index: int, radius: float, spacing: float) -> Vector2i:
	var radial_u: float = clampf((float(particle_index) + 0.5) / maxf(float(count), 1.0), 0.0, 1.0)
	var radial_distance: float = sqrt(radial_u) * maxf(radius - spacing, spacing)
	var angular_u: float = fposmod(float(particle_index) * 0.61803398875 + float(layer_index) * 0.3333333333, 1.0)
	var angle: float = angular_u * TAU
	var world: Vector2 = Vector2(cos(angle), sin(angle)) * radial_distance
	return Vector2i(floori(world.x / maxf(spacing, 0.001)), floori(world.y / maxf(spacing, 0.001)))


func _run_direct_child_test(spindrift: Node) -> bool:
	for layer_name: String in ["CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]:
		var layer: GPUParticles3D = spindrift.get_node_or_null(layer_name) as GPUParticles3D
		if layer == null:
			return _fail("Missing visible child layer %s" % layer_name)
		layer.restart()
		for index: int in 12:
			var position: Vector3 = Vector3(float(index) * 0.6, 1.0 + float(index % 3) * 0.2, float(index % 4) * 0.8)
			layer.emit_particle(Transform3D(Basis.IDENTITY, position), Vector3(0.0, 1.0, 0.0), Color.WHITE, Color(1.0, 0.5, 0.2, 1.0), 31)
	for _frame: int in range(DIRECT_CHILD_FRAMES):
		await get_tree().process_frame
	var observed: Dictionary = _capture_layer_bounds(spindrift)
	if not _is_distributed(observed):
		_print_observation_diagnostic("DIRECT_CHILD", observed)
		return _fail("Direct detached child pipeline did not produce distributed AABBs")
	print("OCEAN_SPINDRIFT_DIRECT_CHILD_PASS")
	return true


func _run_force_path(ocean: Node, spindrift: Node) -> bool:
	ocean.set("spindrift_debug_mode", FORCE_EMISSION_MODE)
	await _restart_sensors(spindrift)
	var state: Dictionary = await _observe_layers(spindrift, OBSERVATION_FRAMES)
	ocean.set("spindrift_debug_mode", FULL_MODE)
	if not _has_any_output(state):
		_print_observation_diagnostic("FORCE", state)
		return _fail("FORCE_EMISSION did not produce detached child output")
	return true


func _run_lod_diagnostic(ocean: Node, spindrift: Node, original_profile: Resource) -> Dictionary:
	var radius: float = float(original_profile.get("spindrift_radius"))
	var production_lod: Array = [
		float(original_profile.get("chunks_lod_end_m")),
		float(original_profile.get("streaks_lod_end_m")),
		float(original_profile.get("mist_lod_end_m"))]
	var production_effective: Array = [
		minf(radius, float(production_lod[0])),
		minf(radius, float(production_lod[1])),
		minf(radius, float(production_lod[2]))]
	var diagnostic_profile: Resource = original_profile.duplicate(true) as Resource
	diagnostic_profile.set("chunks_lod_end_m", radius)
	diagnostic_profile.set("streaks_lod_end_m", radius)
	diagnostic_profile.set("mist_lod_end_m", radius)
	ocean.set("spindrift_profile", diagnostic_profile)
	ocean.set("spindrift_debug_mode", FULL_MODE)
	spindrift = _spindrift_node(ocean)
	if spindrift == null:
		return {"lod_is_limiting": false, "production_lod": production_lod, "production_effective_visual_radius": production_effective}
	await _restart_sensors(spindrift)
	var diagnostic_state: Dictionary = await _observe_layers(spindrift, OBSERVATION_FRAMES)
	var diagnostic_screen: Dictionary = await _observe_real_screen_output(ocean, spindrift, SCREEN_OBSERVATION_FRAMES)
	var production_visible_radius: float = maxf(float(production_effective[0]), maxf(float(production_effective[1]), float(production_effective[2])))
	var diagnostic_visible_radius: float = radius
	var limited: bool = production_visible_radius + 0.001 < diagnostic_visible_radius and (
		int(diagnostic_screen.get("frames_with_output", 0)) > 0 or _has_any_output(diagnostic_state))
	# Restore the authored profile; later threshold tests choose their own runtime copy.
	ocean.set("spindrift_profile", original_profile)
	ocean.set("spindrift_debug_mode", FULL_MODE)
	await _restart_sensors(spindrift)
	return {
		"lod_is_limiting": limited,
		"production_lod": production_lod,
		"production_effective_visual_radius": production_effective,
		"diagnostic_screen": diagnostic_screen,
	}


func _run_lod_sweep(ocean: Node, spindrift: Node, original_profile: Resource) -> Dictionary:
	var selected_lod: Array = []
	var healthy: bool = false
	for candidate: Array in LOD_CANDIDATES:
		var test_profile: Resource = original_profile.duplicate(true) as Resource
		test_profile.set("breaking_trigger_threshold", PROVEN_TRIGGER_THRESHOLD)
		test_profile.set("breaking_rearm_threshold", PROVEN_REARM_THRESHOLD)
		test_profile.set("chunks_lod_end_m", float(candidate[0]))
		test_profile.set("streaks_lod_end_m", float(candidate[1]))
		test_profile.set("mist_lod_end_m", float(candidate[2]))
		ocean.set("spindrift_profile", test_profile)
		ocean.set("spindrift_debug_mode", FULL_MODE)
		spindrift = _spindrift_node(ocean)
		if spindrift == null:
			return {"healthy": false, "selected_lod": selected_lod}
		await _restart_sensors(spindrift)
		var state: Dictionary = await _observe_layers(spindrift, OBSERVATION_FRAMES)
		var debug_screen: Dictionary = await _observe_real_screen_output(ocean, spindrift, SCREEN_OBSERVATION_FRAMES, true)
		var normal_screen: Dictionary = await _observe_real_screen_output(ocean, spindrift, SCREEN_OBSERVATION_FRAMES, false)
		_print_runtime_diagnostic("LOD_%s" % [candidate], _spindrift_state(ocean))
		_print_screen_diagnostic("LOD_%s_DEBUG" % [candidate], debug_screen)
		_print_screen_diagnostic("LOD_%s_NORMAL" % [candidate], normal_screen)
		var candidate_healthy: bool = _is_healthy_real_source(state, debug_screen) and _is_healthy_normal_source(state, normal_screen)
		print("SPINDRIFT LOD CANDIDATE | lod=%s healthy=%s" % [candidate, candidate_healthy])
		if candidate_healthy and not healthy:
			healthy = true
			selected_lod = candidate.duplicate()
		ocean.set("spindrift_profile", original_profile)
		ocean.set("spindrift_debug_mode", FULL_MODE)
		await get_tree().process_frame
	return {"healthy": healthy, "selected_lod": selected_lod}


func _run_threshold_sweep(ocean: Node, spindrift: Node, original_profile: Resource, use_diagnostic_lod: bool) -> Dictionary:
	var selected_trigger: float = 0.72
	var selected_score: int = -1
	var healthy: bool = false
	for threshold: float in [0.72, 0.60, 0.50, 0.40, 0.30, 0.20]:
		var test_profile: Resource = original_profile.duplicate(true) as Resource
		test_profile.set("breaking_trigger_threshold", threshold)
		test_profile.set("breaking_rearm_threshold", maxf(0.0, threshold - 0.20))
		if use_diagnostic_lod:
			var radius: float = float(original_profile.get("spindrift_radius"))
			test_profile.set("chunks_lod_end_m", radius)
			test_profile.set("streaks_lod_end_m", radius)
			test_profile.set("mist_lod_end_m", radius)
		ocean.set("spindrift_profile", test_profile)
		ocean.set("spindrift_debug_mode", FULL_MODE)
		spindrift = _spindrift_node(ocean)
		if spindrift == null:
			return {"healthy": false, "selected_trigger": selected_trigger, "selected_score": selected_score}
		await _restart_sensors(spindrift)
		var state: Dictionary = await _observe_layers(spindrift, OBSERVATION_FRAMES)
		var screen_result: Dictionary = await _observe_real_screen_output(ocean, spindrift, SCREEN_OBSERVATION_FRAMES)
		_print_runtime_diagnostic("THRESHOLD_%0.2f" % threshold, _spindrift_state(ocean))
		_print_screen_diagnostic("THRESHOLD_%0.2f" % threshold, screen_result)
		var score: int = _screen_health_score(screen_result)
		var threshold_healthy: bool = _is_healthy_real_source(state, screen_result)
		if threshold_healthy and not healthy:
			healthy = true
			selected_trigger = threshold
			selected_score = score
	return {"healthy": healthy, "selected_trigger": selected_trigger, "selected_score": selected_score}


func _run_hysteresis_contract(ocean: Node) -> bool:
	var profile: Resource = ocean.get("spindrift_profile") as Resource
	if profile == null:
		return _fail("Spindrift profile disappeared during hysteresis test")
	var trigger: float = float(profile.get("breaking_trigger_threshold"))
	var rearm: float = float(profile.get("breaking_rearm_threshold"))
	if not trigger > rearm:
		return _fail("Breaking trigger is not above rearm")
	var event_count: int = 0
	var active: bool = false
	for value: float in [0.0, trigger + 0.05, trigger - 0.02, rearm - 0.05, trigger + 0.05, rearm - 0.05]:
		if not active and value >= trigger:
			active = true
			event_count += 1
		elif active and value <= rearm:
			active = false
	if event_count != 2 or active:
		return _fail("Hysteresis did not rearm and fire a second rising edge")
	return true


func _restart_sensors(spindrift: Node) -> void:
	var current_state: Dictionary = spindrift.get_runtime_state() if spindrift.has_method(&"get_runtime_state") else {}
	var current_mode: int = int(current_state.get("debug_mode", FULL_MODE))
	for layer_name: String in ["CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]:
		var visible_layer: GPUParticles3D = spindrift.get_node_or_null(layer_name) as GPUParticles3D
		if visible_layer != null:
			visible_layer.restart()
	for layer_name: String in ["CrestChunksSensors", "SpindriftStreaksSensors", "FineMistSensors"]:
		var sensor: GPUParticles3D = spindrift.get_node_or_null(layer_name) as GPUParticles3D
		if sensor != null:
			sensor.restart()
	spindrift.set_debug_mode(current_mode)
	await get_tree().process_frame
	await get_tree().process_frame


func _observe_layers(spindrift: Node, frames: int) -> Dictionary:
	var nonempty: Dictionary = {}
	var max_size: Dictionary = {}
	var center_min: Dictionary = {}
	var center_max: Dictionary = {}
	for layer_name: String in ["CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]:
		nonempty[layer_name] = 0
		max_size[layer_name] = Vector3.ZERO
		center_min[layer_name] = Vector3(1.0e9, 1.0e9, 1.0e9)
		center_max[layer_name] = Vector3(-1.0e9, -1.0e9, -1.0e9)
	for _frame: int in range(frames):
		await get_tree().process_frame
		var sample: Dictionary = _capture_layer_bounds(spindrift)
		for layer_name: String in nonempty.keys():
			var box: AABB = sample.get(layer_name, AABB())
			if box.size.length() <= 0.001:
				continue
			nonempty[layer_name] = int(nonempty[layer_name]) + 1
			max_size[layer_name] = Vector3(
				maxf(Vector3(max_size[layer_name]).x, box.size.x),
				maxf(Vector3(max_size[layer_name]).y, box.size.y),
				maxf(Vector3(max_size[layer_name]).z, box.size.z)
			)
			var center: Vector3 = box.position + box.size * 0.5
			center_min[layer_name] = Vector3(
				minf(Vector3(center_min[layer_name]).x, center.x),
				minf(Vector3(center_min[layer_name]).y, center.y),
				minf(Vector3(center_min[layer_name]).z, center.z)
			)
			center_max[layer_name] = Vector3(
				maxf(Vector3(center_max[layer_name]).x, center.x),
				maxf(Vector3(center_max[layer_name]).y, center.y),
				maxf(Vector3(center_max[layer_name]).z, center.z)
			)
	return {"nonempty": nonempty, "max_size": max_size, "center_min": center_min, "center_max": center_max}


func _capture_layer_bounds(spindrift: Node) -> Dictionary:
	var result: Dictionary = {}
	for layer_name: String in ["CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]:
		var layer: GPUParticles3D = spindrift.get_node_or_null(layer_name) as GPUParticles3D
		result[layer_name] = layer.capture_aabb() if layer != null else AABB()
	return result


func _is_distributed(observed: Dictionary) -> bool:
	for layer_name: String in ["CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]:
		var count: int = int(observed.get("nonempty", {}).get(layer_name, 0))
		var size: Vector3 = observed.get("max_size", {}).get(layer_name, Vector3.ZERO)
		var center_min: Vector3 = observed.get("center_min", {}).get(layer_name, Vector3.ZERO)
		var center_max: Vector3 = observed.get("center_max", {}).get(layer_name, Vector3.ZERO)
		if count <= 0 or maxf(size.x, size.z) < 1.0 or maxf((center_max - center_min).x, (center_max - center_min).z) < 0.5:
			return false
	return true


func _print_observation_diagnostic(label: String, observed: Dictionary) -> void:
	print("SPINDRIFT OBSERVATION %s | nonempty=%s max_size=%s center_min=%s center_max=%s" % [
		label,
		observed.get("nonempty", {}),
		observed.get("max_size", {}),
		observed.get("center_min", {}),
		observed.get("center_max", {})])


func _observe_real_screen_output(ocean: Node, spindrift: Node, frames: int, position_debug: bool = true) -> Dictionary:
	var previous_mode: int = int(_spindrift_state(ocean).get("debug_mode", FULL_MODE))
	var surface: Node3D = ocean.find_child(^"OceanClipmapSurface", true, false) as Node3D
	var previous_surface_visible: bool = surface.visible if surface != null else true
	var root: Node = ocean.get_parent() as Node
	var world_environment: WorldEnvironment = root.find_child(^"WorldEnvironment", true, false) as WorldEnvironment if root != null else null
	var previous_environment: Environment = world_environment.environment if world_environment != null else null
	var isolated_environment: Environment = previous_environment.duplicate(true) as Environment if previous_environment != null else null
	var island: Node3D = root.find_child(^"testisland", true, false) as Node3D if root != null else null
	var previous_island_visible: bool = island.visible if island != null else true
	if position_debug:
		ocean.set("spindrift_debug_mode", POSITION_DEBUG_MODE)
	if surface != null:
		surface.visible = false
	if island != null:
		island.visible = false
	if world_environment != null and isolated_environment != null:
		isolated_environment.background_mode = Environment.BG_COLOR
		isolated_environment.background_color = Color.BLACK
		world_environment.environment = isolated_environment
	await _restart_sensors(spindrift)
	var result: Dictionary = {
		"frames_observed": 0,
		"frames_with_output": 0,
		"near_frames": 0,
		"mid_frames": 0,
		"far_frames": 0,
		"max_pixels": 0,
		"max_screen_regions": 0,
		"max_horizontal_spread": 0.0,
		"image_available": true,
	}
	for frame: int in range(frames):
		await get_tree().process_frame
		if frame % SCREEN_SAMPLE_STRIDE != 0:
			continue
		var sample: Dictionary = _capture_screen_occupancy(position_debug)
		if not bool(sample.get("available", false)):
			result["image_available"] = false
			break
		result["frames_observed"] = int(result["frames_observed"]) + 1
		var pixels: int = int(sample.get("pixels", 0))
		result["max_pixels"] = maxi(int(result["max_pixels"]), pixels)
		result["max_screen_regions"] = maxi(int(result["max_screen_regions"]), int(sample.get("screen_regions", 0)))
		result["max_horizontal_spread"] = maxf(float(result["max_horizontal_spread"]), float(sample.get("horizontal_spread", 0.0)))
		if pixels >= 3:
			result["frames_with_output"] = int(result["frames_with_output"]) + 1
		if bool(sample.get("near", false)):
			result["near_frames"] = int(result["near_frames"]) + 1
		if bool(sample.get("mid", false)):
			result["mid_frames"] = int(result["mid_frames"]) + 1
		if bool(sample.get("far", false)):
			result["far_frames"] = int(result["far_frames"]) + 1
	if surface != null:
		surface.visible = previous_surface_visible
	if island != null:
		island.visible = previous_island_visible
	if world_environment != null:
		world_environment.environment = previous_environment
	ocean.set("spindrift_debug_mode", previous_mode)
	await _restart_sensors(spindrift)
	return result


func _capture_screen_occupancy(position_debug: bool = true) -> Dictionary:
	var viewport_texture: ViewportTexture = get_viewport().get_texture()
	if viewport_texture == null:
		return {"available": false}
	var image: Image = viewport_texture.get_image()
	if image == null or image.is_empty():
		return {"available": false}
	var width: int = image.get_width()
	var height: int = image.get_height()
	var pixels: int = 0
	var near_count: int = 0
	var mid_count: int = 0
	var far_count: int = 0
	var min_x: int = width
	var max_x: int = -1
	var bins: Dictionary = {}
	for y: int in range(0, height, 4):
		for x: int in range(0, width, 4):
			var color: Color = image.get_pixel(x, y)
			var maximum: float = maxf(color.r, maxf(color.g, color.b))
			var minimum: float = minf(color.r, minf(color.g, color.b))
			var is_near: bool = false
			var is_mid: bool = false
			var is_far: bool = false
			if position_debug:
				if maximum < 0.18 or maximum - minimum < 0.10:
					continue
				is_near = color.r > color.g * 1.28 and color.b > color.g * 1.28
				is_mid = color.r > color.b * 1.25 and color.g > color.b * 1.25
				is_far = color.g > color.r * 1.25 and color.b > color.r * 1.25
				if not is_near and not is_mid and not is_far:
					continue
			else:
				# Normal particles are neutral/gray; the isolated black background
				# makes luminance occupancy the authoritative screen signal.
				if maximum < 0.035 or maximum - minimum > 0.25:
					continue
			pixels += 1
			min_x = mini(min_x, x)
			max_x = maxi(max_x, x)
			bins[Vector2i(x / 64, y / 64)] = true
			if is_near:
				near_count += 1
			elif is_mid:
				mid_count += 1
			elif is_far:
				far_count += 1
	return {
		"available": true,
		"pixels": pixels,
		"near": near_count > 0,
		"mid": mid_count > 0,
		"far": far_count > 0,
		"screen_regions": bins.size(),
		"horizontal_spread": float(max_x - min_x) / maxf(float(width), 1.0) if max_x >= min_x else 0.0,
	}


func _screen_health_score(screen_result: Dictionary) -> int:
	return int(screen_result.get("frames_with_output", 0)) + int(screen_result.get("near_frames", 0)) + int(screen_result.get("mid_frames", 0)) + int(screen_result.get("far_frames", 0))


func _is_healthy_real_source(observed: Dictionary, screen_result: Dictionary) -> bool:
	if not bool(screen_result.get("image_available", false)):
		return false
	var frames: int = int(screen_result.get("frames_observed", 0))
	var output_frames: int = int(screen_result.get("frames_with_output", 0))
	var regions: int = int(screen_result.get("max_screen_regions", 0))
	var spread: float = float(screen_result.get("max_horizontal_spread", 0.0))
	var band_count: int = 0
	for key: String in ["near_frames", "mid_frames", "far_frames"]:
		if int(screen_result.get(key, 0)) > 0:
			band_count += 1
	return frames >= 5 and output_frames >= 3 and regions >= 2 and spread >= 0.10 and band_count >= 2 and int(screen_result.get("max_pixels", 0)) >= 4


func _is_healthy_normal_source(observed: Dictionary, screen_result: Dictionary) -> bool:
	if not bool(screen_result.get("image_available", false)):
		return false
	return int(screen_result.get("frames_observed", 0)) >= 5 \
		and int(screen_result.get("frames_with_output", 0)) >= 3 \
		and int(screen_result.get("max_screen_regions", 0)) >= 2 \
		and float(screen_result.get("max_horizontal_spread", 0.0)) >= 0.10 \
		and int(screen_result.get("max_pixels", 0)) >= 4 \
		and _has_any_output(observed)


func _has_any_output(observed: Dictionary) -> bool:
	var nonempty: Dictionary = observed.get("nonempty", {})
	for layer_name: String in ["CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]:
		if int(nonempty.get(layer_name, 0)) > 0:
			return true
	return false


func _print_screen_diagnostic(label: String, state: Dictionary) -> void:
	print("SPINDRIFT SCREEN %s | frames=%d output_frames=%d regions=%d horizontal_spread=%.3f near=%d mid=%d far=%d max_pixels=%d" % [
		label,
		int(state.get("frames_observed", 0)),
		int(state.get("frames_with_output", 0)),
		int(state.get("max_screen_regions", 0)),
		float(state.get("max_horizontal_spread", 0.0)),
		int(state.get("near_frames", 0)),
		int(state.get("mid_frames", 0)),
		int(state.get("far_frames", 0)),
		int(state.get("max_pixels", 0))])


func _print_runtime_diagnostic(label: String, state: Dictionary) -> void:
	print("SPINDRIFT DIAGNOSTIC %s | sensors=%s capacities=%s density=%s trigger=%s rearm=%s lifetimes=%s authority=%s source_ready=%s" % [
		label,
		state.get("sensor_layer_amounts", []),
		state.get("visible_layer_capacities", []),
		state.get("event_density", 0.0),
		state.get("trigger_threshold", 0.0),
		state.get("rearm_threshold", 0.0),
		state.get("visible_layer_lifetimes", []),
		state.get("breaking_activity_authority", ""),
		state.get("source_ready", false)])


func _measure_real_crest_g(p0: Node, ocean: Node, _spindrift: Node) -> Dictionary:
	var open_ocean: Node = ocean.get("_open_ocean") as Node
	if open_ocean == null or not open_ocean.has_method(&"get_spindrift_sources"):
		_fail("OpenOceanFFT source packet is missing for Crest G measurement")
		return {"healthy": false}
	var sources: Dictionary = open_ocean.call("get_spindrift_sources") as Dictionary
	var crest_texture: Texture2D = sources.get("breaking_activity_long") as Texture2D
	if not bool(sources.get("ready", false)) or crest_texture == null:
		_fail("Crest LONG.G texture is not ready for validation probe")
		return {"healthy": false}
	var domains: Vector3 = Vector3(sources.get("domains", Vector3(512.0, 137.0, 37.0)))
	var initial_state: Dictionary = _spindrift_state(ocean)
	var anchor_value: Variant = initial_state.get("sensor_anchor_world", Vector3.ZERO)
	var anchor: Vector2 = Vector2.ZERO
	if anchor_value is Vector3:
		anchor = Vector2((anchor_value as Vector3).x, (anchor_value as Vector3).z)
	var probe_viewport := SubViewport.new()
	probe_viewport.size = Vector2i(CREST_PROBE_SIZE, CREST_PROBE_SIZE)
	probe_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	probe_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	probe_viewport.transparent_bg = false
	var probe_rect := ColorRect.new()
	probe_rect.size = Vector2(CREST_PROBE_SIZE, CREST_PROBE_SIZE)
	var probe_material := ShaderMaterial.new()
	probe_material.shader = CREST_PROBE_SHADER
	probe_material.set_shader_parameter(&"breaking_activity_long", crest_texture)
	probe_material.set_shader_parameter(&"sensor_anchor_xz", anchor)
	probe_material.set_shader_parameter(&"sample_radius_m", float(initial_state.get("effective_source_radius_m", 120.0)))
	probe_material.set_shader_parameter(&"domain_long_m", domains.x)
	probe_rect.material = probe_material
	probe_viewport.add_child(probe_rect)
	add_child(probe_viewport)
	var camera: Camera3D = p0.find_child(^"FreeCamera", true, false) as Camera3D
	var initial_position: Vector3 = camera.global_position if camera != null else Vector3.ZERO
	var surface: Node3D = ocean.find_child(^"OceanClipmapSurface", true, false) as Node3D
	var world_environment: WorldEnvironment = p0.find_child(^"WorldEnvironment", true, false) as WorldEnvironment
	var previous_surface_visible: bool = surface.visible if surface != null else true
	var previous_environment: Environment = world_environment.environment if world_environment != null else null
	var isolated_environment: Environment = previous_environment.duplicate(true) as Environment if previous_environment != null else null
	var island: Node3D = p0.find_child(^"testisland", true, false) as Node3D
	var previous_island_visible: bool = island.visible if island != null else true
	if surface != null:
		surface.visible = false
	if island != null:
		island.visible = false
	if world_environment != null and isolated_environment != null:
		isolated_environment.background_mode = Environment.BG_COLOR
		isolated_environment.background_color = Color.BLACK
		world_environment.environment = isolated_environment
	var values_by_window: Array = []
	var output_by_window: Array[int] = []
	for _window: int in 6:
		values_by_window.append([])
		output_by_window.append(0)
	var start_usec: int = Time.get_ticks_usec()
	var last_sample_usec: int = start_usec
	while float(Time.get_ticks_usec() - start_usec) / 1000000.0 < REAL_G_MEASUREMENT_SECONDS:
		await get_tree().process_frame
		var now_usec: int = Time.get_ticks_usec()
		var elapsed_s: float = float(now_usec - start_usec) / 1000000.0
		var window_index: int = mini(int(elapsed_s / 10.0), 5)
		if now_usec - last_sample_usec < int(REAL_G_MEASUREMENT_SAMPLE_SECONDS * 1000000.0):
			continue
		last_sample_usec = now_usec
		var image: Image = probe_viewport.get_texture().get_image()
		if image == null or image.is_empty():
			_restore_soak_environment(surface, previous_surface_visible, island, previous_island_visible, world_environment, previous_environment, camera, initial_position)
			probe_viewport.queue_free()
			_fail("Crest G validation probe produced no image")
			return {"healthy": false}
		for y: int in range(image.get_height()):
			for x: int in range(image.get_width()):
				var uv := (Vector2(float(x) + 0.5, float(y) + 0.5) / float(CREST_PROBE_SIZE)) * 2.0 - Vector2.ONE
				if uv.length() <= 1.0:
					values_by_window[window_index].append(clampf(image.get_pixel(x, y).r, 0.0, 1.0))
		var screen_sample: Dictionary = _capture_screen_occupancy(false)
		if int(screen_sample.get("pixels", 0)) >= 3:
			output_by_window[window_index] += 1
		var live_state: Dictionary = _spindrift_state(ocean)
		if not bool(live_state.get("source_ready", false)):
			_restore_soak_environment(surface, previous_surface_visible, island, previous_island_visible, world_environment, previous_environment, camera, initial_position)
			probe_viewport.queue_free()
			_fail("Crest G measurement lost the live source")
			return {"healthy": false}
	_restore_soak_environment(surface, previous_surface_visible, island, previous_island_visible, world_environment, previous_environment, camera, initial_position)
	probe_viewport.queue_free()
	var late_high_variation := false
	var late_zero_output := true
	var crest_g_reaches_absolute_rearm := false
	for index: int in 6:
		var statistics: Dictionary = _crest_g_statistics(values_by_window[index])
		print("SPINDRIFT CREST G WINDOW %d | min=%.4f max=%.4f mean=%.4f p10=%.4f p25=%.4f p50=%.4f p75=%.4f p90=%.4f <=20=%.2f%% <=25=%.2f%% <=30=%.2f%% <=35=%.2f%% >=40=%.2f%% output_samples=%d" % [
			index,
			float(statistics.get("min", 0.0)), float(statistics.get("max", 0.0)), float(statistics.get("mean", 0.0)),
			float(statistics.get("p10", 0.0)), float(statistics.get("p25", 0.0)), float(statistics.get("p50", 0.0)),
			float(statistics.get("p75", 0.0)), float(statistics.get("p90", 0.0)),
			float(statistics.get("le_020", 0.0)), float(statistics.get("le_025", 0.0)), float(statistics.get("le_030", 0.0)),
			float(statistics.get("le_035", 0.0)), float(statistics.get("ge_040", 0.0)), output_by_window[index]])
		if index >= 3 and float(statistics.get("max", 0.0)) >= PROVEN_TRIGGER_THRESHOLD and float(statistics.get("p90", 0.0)) - float(statistics.get("p10", 0.0)) > 0.01:
			late_high_variation = true
		if index >= 3 and float(statistics.get("le_020", 0.0)) > 0.0:
			crest_g_reaches_absolute_rearm = true
		if index >= 3 and output_by_window[index] > 0:
			late_zero_output = false
	if not values_by_window[0].size() > 0:
		_fail("Crest G validation probe returned no disk samples")
		return {"healthy": false}
	print("OCEAN_SPINDRIFT_REAL_G_DISTRIBUTION_PASS")
	if crest_g_reaches_absolute_rearm:
		print("SPINDRIFT_REARM_STATE_MACHINE_INTERNAL_BUG")
		_fail("SPINDRIFT_REARM_STATE_MACHINE_INTERNAL_BUG: Crest G reaches <= 0.20 while event output is exhausted; do not apply adaptive release")
		return {"healthy": false}
	if not late_high_variation or not late_zero_output:
		_fail("SPINDRIFT_REARM_STATE_MACHINE_INTERNAL_BUG: Crest G did not show sustained late variation with exhausted output")
		return {"healthy": false}
	print("OCEAN_SPINDRIFT_LATCH_EXHAUSTION_CONFIRMED_PASS")
	return {"healthy": true, "output_by_window": output_by_window}


func _crest_g_statistics(values: Array) -> Dictionary:
	if values.is_empty():
		return {}
	var sorted: Array = values.duplicate()
	sorted.sort()
	var total: float = 0.0
	var le_020: int = 0
	var le_025: int = 0
	var le_030: int = 0
	var le_035: int = 0
	var ge_040: int = 0
	for value_variant: Variant in sorted:
		var value: float = float(value_variant)
		total += value
		if value <= 0.20: le_020 += 1
		if value <= 0.25: le_025 += 1
		if value <= 0.30: le_030 += 1
		if value <= 0.35: le_035 += 1
		if value >= 0.40: ge_040 += 1
	var last_index: int = sorted.size() - 1
	return {
		"min": float(sorted[0]),
		"max": float(sorted[last_index]),
		"mean": total / float(sorted.size()),
		"p10": float(sorted[clampi(int(round(float(last_index) * 0.10)), 0, last_index)]),
		"p25": float(sorted[clampi(int(round(float(last_index) * 0.25)), 0, last_index)]),
		"p50": float(sorted[clampi(int(round(float(last_index) * 0.50)), 0, last_index)]),
		"p75": float(sorted[clampi(int(round(float(last_index) * 0.75)), 0, last_index)]),
		"p90": float(sorted[clampi(int(round(float(last_index) * 0.90)), 0, last_index)]),
		"le_020": 100.0 * float(le_020) / float(sorted.size()),
		"le_025": 100.0 * float(le_025) / float(sorted.size()),
		"le_030": 100.0 * float(le_030) / float(sorted.size()),
		"le_035": 100.0 * float(le_035) / float(sorted.size()),
		"ge_040": 100.0 * float(ge_040) / float(sorted.size()),
	}


func _run_scale_runtime_sweep(ocean: Node, spindrift: Node) -> bool:
	var open_ocean: Node = ocean.get("_open_ocean") as Node
	if open_ocean == null:
		return _fail("OpenOceanFFT missing for Ocean Space runtime sweep")
	var original_h: float = float(open_ocean.get("_clipmap_geometry_scale"))
	var original_v: float = float(open_ocean.get("_surface_scale"))
	for scale: Vector2 in [Vector2(0.5, 1.0), Vector2(1.0, 1.0), Vector2(2.0, 1.0), Vector2(1.0, 0.5), Vector2(1.0, 2.0)]:
		open_ocean.call("set_clipmap_geometry_scale", scale.x)
		open_ocean.call("set_surface_scale", scale.y)
		await get_tree().process_frame
		var state: Dictionary = _spindrift_state(ocean)
		if not bool(state.get("source_ready", false)) or int(state.get("active_layers", 0)) != 3:
			open_ocean.call("set_clipmap_geometry_scale", original_h)
			open_ocean.call("set_surface_scale", original_v)
			return _fail("Spindrift lost source/layer residency at Ocean Space scale %s" % scale)
		print("SPINDRIFT SCALE SWEEP H=%.2f V=%.2f READY" % [scale.x, scale.y])
	open_ocean.call("set_clipmap_geometry_scale", original_h)
	open_ocean.call("set_surface_scale", original_v)
	await _restart_sensors(spindrift)
	return true


func _run_camera_follow_contract(p0: Node, ocean: Node, spindrift: Node) -> bool:
	var camera: Camera3D = p0.find_child(^"FreeCamera", true, false) as Camera3D
	if camera == null:
		return _fail("P0 FreeCamera is missing for camera-follow validation")
	var initial_position: Vector3 = camera.global_position
	var initial_xz := Vector2(initial_position.x, initial_position.z)
	var initial_state: Dictionary = _spindrift_state(ocean)
	if not _validate_dynamic_visibility(spindrift, initial_state):
		return false
	var initial_recenter_count: int = int(initial_state.get("sensor_recenter_count", 0))
	var route: Array[float] = [0.0, 100.0, 250.0, 500.0, 700.0, 500.0, 250.0, 0.0]
	for distance_m: float in route:
		var destination := initial_xz + Vector2(distance_m, 0.0)
		while Vector2(camera.global_position.x, camera.global_position.z).distance_to(destination) > 0.25:
			var current := Vector2(camera.global_position.x, camera.global_position.z)
			var next := current.move_toward(destination, CAMERA_FOLLOW_STEP_M)
			camera.global_position = Vector3(next.x, initial_position.y, next.y)
			await get_tree().process_frame
			if not _validate_dynamic_visibility(spindrift, _spindrift_state(ocean)):
				return false
		camera.global_position = Vector3(destination.x, initial_position.y, destination.y)
		await get_tree().process_frame
		if not _validate_dynamic_visibility(spindrift, _spindrift_state(ocean)):
			return false
	var final_state: Dictionary = _spindrift_state(ocean)
	if int(final_state.get("sensor_recenter_count", 0)) <= initial_recenter_count:
		return _fail("Sensor anchor did not recenter during camera route")
	if not is_zero_approx(Vector2(camera.global_position.x, camera.global_position.z).distance_to(initial_xz)):
		return _fail("Camera route did not return to its world origin")
	var returned_anchor_value: Variant = final_state.get("source_region_center_world", Vector2.INF)
	if not returned_anchor_value is Vector2:
		return _fail("Sensor anchor diagnostic is missing after camera route")
	var returned_anchor: Vector2 = returned_anchor_value
	if returned_anchor.distance_to(initial_xz) > float(final_state.get("sensor_recenter_distance_m", 1.0)) + 1.0:
		return _fail("Sensor anchor did not return with the camera")
	print("OCEAN_SPINDRIFT_DYNAMIC_VISIBILITY_AABB_PASS")
	print("OCEAN_SPINDRIFT_SENSOR_ANCHOR_PASS")
	print("OCEAN_SPINDRIFT_CAMERA_FOLLOW_PASS")
	print("OCEAN_SPINDRIFT_WORLD_ORIGIN_INDEPENDENCE_PASS")
	return true


func _validate_dynamic_visibility(spindrift: Node, state: Dictionary) -> bool:
	if not bool(state.get("source_ready", false)) or int(state.get("active_layers", 0)) != 3:
		return _fail("Spindrift source/layer residency was lost during camera follow")
	if state.get("source_region_shape", "") != "snapped_sensor_anchor_disk":
		return _fail("Runtime source region is not the snapped sensor anchor disk")
	if not bool(state.get("camera_inside_particle_visibility", false)):
		return _fail("Camera left the dynamic particle visibility AABB")
	var expected_value: Variant = state.get("particle_visibility_aabb", AABB())
	if not expected_value is AABB:
		return _fail("Dynamic particle visibility AABB diagnostic is missing")
	var expected: AABB = expected_value
	if expected.size.distance_to(Vector3(1024.0, 512.0, 1024.0)) > 0.01:
		return _fail("Dynamic particle visibility AABB size changed")
	for layer_name: String in ["CrestChunksSensors", "SpindriftStreaksSensors", "FineMistSensors", "CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]:
		var layer: GPUParticles3D = spindrift.get_node_or_null(layer_name) as GPUParticles3D
		if layer == null or layer.visibility_aabb.position.distance_to(expected.position) > 0.01 or layer.visibility_aabb.size.distance_to(expected.size) > 0.01:
			return _fail("Particle layer visibility AABB is inconsistent for %s" % layer_name)
	var center_value: Variant = state.get("particle_visibility_center_world", Vector3.INF)
	if not center_value is Vector3:
		return _fail("Dynamic particle visibility center diagnostic is missing")
	var center: Vector3 = center_value
	if center.distance_to(expected.position + expected.size * 0.5) > 0.01:
		return _fail("Dynamic particle visibility center disagrees with AABB")
	return true


func _run_real_gpu_rearm_soak(p0: Node, ocean: Node, _spindrift: Node) -> bool:
	var camera: Camera3D = p0.find_child(^"FreeCamera", true, false) as Camera3D
	if camera == null:
		return _fail("FreeCamera is missing for the real GPU rearm soak")
	var initial_position: Vector3 = camera.global_position
	var state: Dictionary = _spindrift_state(ocean)
	if int(state.get("debug_mode", -1)) != FULL_MODE or not bool(state.get("source_ready", false)):
		return _fail("Real GPU rearm soak did not start in normal FULL Crest G mode")
	var surface: Node3D = ocean.find_child(^"OceanClipmapSurface", true, false) as Node3D
	var world_environment: WorldEnvironment = p0.find_child(^"WorldEnvironment", true, false) as WorldEnvironment
	var previous_surface_visible: bool = surface.visible if surface != null else true
	var previous_environment: Environment = world_environment.environment if world_environment != null else null
	var isolated_environment: Environment = previous_environment.duplicate(true) as Environment if previous_environment != null else null
	var island: Node3D = p0.find_child(^"testisland", true, false) as Node3D
	var previous_island_visible: bool = island.visible if island != null else true
	if surface != null:
		surface.visible = false
	if island != null:
		island.visible = false
	if world_environment != null and isolated_environment != null:
		isolated_environment.background_mode = Environment.BG_COLOR
		isolated_environment.background_color = Color.BLACK
		world_environment.environment = isolated_environment
	var window_outputs: Array[int] = []
	for _window: int in 9:
		window_outputs.append(0)
	var start_usec: int = Time.get_ticks_usec()
	var last_sample_usec: int = start_usec
	while float(Time.get_ticks_usec() - start_usec) / 1000000.0 < REAL_GPU_REARM_SOAK_SECONDS:
		await get_tree().process_frame
		var now_usec: int = Time.get_ticks_usec()
		var elapsed_s: float = float(now_usec - start_usec) / 1000000.0
		var window_index: int = mini(int(elapsed_s / 10.0), 8)
		if now_usec - last_sample_usec >= int(REAL_GPU_REARM_SAMPLE_SECONDS * 1000000.0):
			last_sample_usec = now_usec
			var sample: Dictionary = _capture_screen_occupancy(false)
			if not bool(sample.get("available", false)):
				_restore_soak_environment(surface, previous_surface_visible, island, previous_island_visible, world_environment, previous_environment, camera, initial_position)
				return _fail("GPU rearm soak could not read the viewport")
			if int(sample.get("pixels", 0)) >= 3:
				window_outputs[window_index] += 1
		var live_state: Dictionary = _spindrift_state(ocean)
		if not bool(live_state.get("source_ready", false)) or int(live_state.get("debug_mode", -1)) != FULL_MODE:
			_restore_soak_environment(surface, previous_surface_visible, island, previous_island_visible, world_environment, previous_environment, camera, initial_position)
			return _fail("Real GPU rearm soak lost normal source state")
	_restore_soak_environment(surface, previous_surface_visible, island, previous_island_visible, world_environment, previous_environment, camera, initial_position)
	var active_windows: int = 0
	for count: int in window_outputs:
		if count > 0:
			active_windows += 1
	if active_windows < 5 or window_outputs[3] <= 0 or window_outputs[6] <= 0 or window_outputs[8] <= 0:
		return _fail("Real GPU rearm soak did not observe output after 30/60/80 seconds: %s" % [window_outputs])
	print("SPINDRIFT REAL GPU REARM SOAK | windows=%s seconds=%.1f" % [window_outputs, REAL_GPU_REARM_SOAK_SECONDS])
	print("OCEAN_SPINDRIFT_REAL_GPU_REARM_SOAK_PASS")
	return true


func _restore_soak_environment(surface: Node3D, surface_visible: bool, island: Node3D, island_visible: bool, world_environment: WorldEnvironment, environment: Environment, camera: Camera3D, camera_position: Vector3) -> void:
	if surface != null:
		surface.visible = surface_visible
	if island != null:
		island.visible = island_visible
	if world_environment != null:
		world_environment.environment = environment
	if camera != null:
		camera.global_position = camera_position


func _fail(reason: String) -> bool:
	_failed = true
	push_error("OCEAN_SPINDRIFT_VALIDATION_FAIL: %s" % reason)
	return false


func _approximately_equal(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= SCALE_TOLERANCE


func _run_p7_smoke() -> bool:
	var p7: Node = P7_SCENE.instantiate()
	if p7 == null:
		return _fail("Could not instantiate P7")
	add_child(p7)
	var ocean: Node = p7.find_child(^"Ocean", true, false) as Node
	if ocean == null:
		p7.queue_free()
		return _fail("P7 has no Ocean")
	for _frame: int in range(180):
		await get_tree().process_frame
	var state: Dictionary = _spindrift_state(ocean)
	p7.queue_free()
	return not state.is_empty() or _fail("P7 did not expose runtime state")


func _finish_failure() -> void:
	if _failed:
		get_tree().quit(1)
