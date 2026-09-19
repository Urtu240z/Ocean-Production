extends Node

const P0_SCENE: PackedScene = preload("res://validation/p0_open_ocean.tscn")
const P7_SCENE: PackedScene = preload("res://validation/p7_breakers.tscn")
const CREST_PROBE_SHADER: Shader = preload("res://validation/shaders/ocean_spindrift_crest_probe.gdshader")
const PERIODICITY_PROBE_SHADER: Shader = preload("res://validation/shaders/ocean_spindrift_periodicity_probe.gdshader")
const SENSOR_TELEMETRY_SHADER: Shader = preload("res://validation/shaders/ocean_spindrift_sensor_telemetry.gdshader")
const FORCE_EMISSION_MODE: int = 6
const FULL_MODE: int = 5
const CHUNKS_ONLY_MODE: int = 2
const STREAKS_ONLY_MODE: int = 3
const MIST_ONLY_MODE: int = 4
const POSITION_DEBUG_MODE: int = 10
const STARTUP_TIMEOUT_FRAMES: int = 900
const SCALE_TOLERANCE: float = 0.000001
const CAMERA_FOLLOW_STEP_M: float = 12.0
const CREST_PROBE_SIZE: int = 64
const PROVEN_TRIGGER_THRESHOLD: float = 0.40
const PROVEN_REARM_THRESHOLD: float = 0.20
const LONG_PERIOD_M: float = 2560.0
const LONG_DOMAIN_M: float = 512.0
const SENSOR_GRID_PERIOD_M: float = 2.5
const FINAL_PRODUCTION_LOD: Array[float] = [22.0, 55.0, 46.0]
## The telemetry viewport must resolve one sensor quad, and the child viewport
## must resolve one detached child, so both are sized from the layer geometry
## instead of from the whole source disk.
const TELEMETRY_VIEWPORT_SIZE: int = 256
const TELEMETRY_QUAD_M: float = 2.0
const SENSOR_TELEMETRY_LAYER_BIT: int = 12
const CHILD_VIEWPORT_RADIUS_M: float = 60.5
const CHILD_VIEWPORT_LAYER_BIT: int = 15
const TELEMETRY_SAMPLE_SECONDS: float = 0.25
const SOAK_SECONDS: float = 120.0
const SOAK_WINDOW_SECONDS: float = 10.0
## A layer whose own visual footprint holds fewer sensors than this cannot show
## crest-tied spray: the footprint would be sampled by almost nothing.
const MIN_FOOTPRINT_SENSORS: int = 8
## The low-discrepancy lattice is uniform by area, so some cell sharing is
## expected once a layer is concentrated on its own footprint. This bound only
## rejects a lattice that spends a large share of its budget on repeated cells.
const MAX_LATTICE_DUPLICATE_PERCENT: float = 25.0

var _failed: bool = false
## Every stage that actually executed, printed before the final gate line so a
## claim can never be inherited from a stage that did not run.
var _stages: Array[String] = []


func _stage(name: String) -> void:
	_stages.append(name)
	print("SPINDRIFT_STAGE | %s" % name)


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("OCEAN_SPINDRIFT_VISUAL_BEGIN")
	if not _run_source_contracts():
		_finish_failure()
		return
	if not _run_child_pool_source_contract():
		_finish_failure()
		return
	if not _run_art_contract():
		_finish_failure()
		return
	if not _run_density_contract():
		_finish_failure()
		return
	if not _run_ocean_space_contract():
		_finish_failure()
		return
	if not _run_ocean_space_recenter_source_contract():
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

	var spindrift: Node = _spindrift_node(p0_ocean)
	if spindrift == null:
		_fail("P0 Spindrift controller is missing")
		_finish_failure()
		return
	var initial_state: Dictionary = _spindrift_state(p0_ocean)
	_print_runtime_diagnostic("INITIAL", initial_state)
	if not _check_persisted_production_profile(p0_ocean.get("spindrift_profile") as Resource, initial_state):
		_finish_failure()
		return
	if not _run_sensor_coverage_contract(initial_state):
		_finish_failure()
		return
	if not _check_runtime_contract(initial_state):
		_finish_failure()
		return
	_report_particle_rates(spindrift)
	if not _check_artwork_binding(spindrift):
		_finish_failure()
		return
	if not await _run_scale_runtime_sweep(p0_ocean, spindrift):
		_finish_failure()
		return
	# Stationary origin observation of the real sensors and of their children.
	var origin_window: Dictionary = await _run_sensor_observation(
		p0_ocean, spindrift, 30.0, "ORIGIN")
	if not _judge_sensor_observation(origin_window, true):
		_finish_failure()
		return
	print("OCEAN_SPINDRIFT_ORIGIN_SENSOR_EVENT_PASS")
	p0.queue_free()
	await get_tree().process_frame
	var final_p0: Node = P0_SCENE.instantiate()
	add_child(final_p0)
	var final_ocean: Node = final_p0.find_child(^"Ocean", true, false) as Node
	if final_ocean == null or not await _wait_for_spindrift(final_ocean):
		_finish_failure()
		return
	var final_spindrift: Node = _spindrift_node(final_ocean)
	if final_spindrift == null or not await _run_final_continuity_validation(final_p0, final_ocean, final_spindrift):
		_finish_failure()
		return
	if not await _run_p7_smoke():
		_finish_failure()
		return
	print("OCEAN_SPINDRIFT_P7_SMOKE_PASS")
	var gate_state: Dictionary = _spindrift_state(final_ocean)
	if not bool(gate_state.get("source_ready", false)) or int(gate_state.get("active_layers", 0)) != 3 or int(gate_state.get("debug_mode", -1)) != FULL_MODE:
		_finish_failure()
		return
	print("OCEAN_SPINDRIFT_P0_RUNTIME_PASS")
	print("SPINDRIFT_STAGES_EXECUTED | %s" % [_stages])
	print("SPINDRIFT_PRODUCTION_CONTINUITY_VISUAL_READY")
	print("SPINDRIFT_FUNCTIONAL_GATE_READY")


func _check_persisted_production_profile(profile: Resource, state: Dictionary) -> bool:
	_stage("persisted_production_profile")
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
	var densities: Array[float] = [
		float(profile.get("chunks_amount")),
		float(profile.get("streaks_amount")),
		float(profile.get("mist_amount"))]
	var lifetimes: Array[float] = [
		float(profile.get("chunks_lifetime")),
		float(profile.get("streaks_lifetime")),
		float(profile.get("mist_lifetime"))]
	var runtime_lifetimes: Array = state.get("visible_layer_lifetimes", []) as Array
	for index: int in 3:
		if runtime_lifetimes.size() == 3 and not is_equal_approx(float(runtime_lifetimes[index]), lifetimes[index]):
			return _fail("P0 visible lifetime %d is not the authored %.3f s" % [index, lifetimes[index]])
	print("SPINDRIFT PERSISTED PRODUCTION PROFILE | trigger=%.2f rearm=%.2f radius=%.1f lod=%s amounts=%s lifetimes=%s" % [
		trigger, rearm, radius, lod, densities, lifetimes])
	if int(state.get("debug_mode", -1)) != FULL_MODE or not bool(state.get("source_ready", false)):
		return _fail("Cold-start Spindrift is not FULL and source-ready")
	print("OCEAN_SPINDRIFT_PERSISTED_PRODUCTION_PROFILE_PASS")
	return true


func _run_source_contracts() -> bool:
	_stage("source_contracts")
	var event_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_event_particles.gdshader")
	var mask_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_source_mask.gdshader")
	var controller_source: String = FileAccess.get_file_as_string("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
	var profile_source: String = FileAccess.get_file_as_string("res://addons/ocean/core/ocean_spindrift_profile.gd")
	var render_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_render.gdshader")
	if event_source.is_empty() or mask_source.is_empty() or controller_source.is_empty() or profile_source.is_empty() or render_source.is_empty():
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
	if not controller_source.contains("_layer_emission_radius_m") or not controller_source.contains("emission_radius_m"):
		return _fail("Spindrift LOD-aware emission radius contract is missing")
	if not event_source.contains("camera_world_xz") or not event_source.contains("inside_emission_footprint") or not event_source.contains("inside_visual_coverage"):
		return _fail("Spindrift camera/LOD emission footprint gate is missing")
	if not event_source.contains("ocean_space_normal_to_world_scaled"):
		return _fail("Spindrift normal inverse-transpose contract is missing")
	if not profile_source.contains("@export_range(0.0, 2.0, 0.01) var emission_density"):
		return _fail("Spindrift emission_density export range changed")
	if not controller_source.contains("_layer_sensor_radius_m") or not controller_source.contains("_sensor_anchor_drift_margin_m"):
		return _fail("Layer sensor lattice radius contract is missing")
	if not event_source.contains("max(sensor_radius_m - sensor_grid_cell_m"):
		return _fail("Sensor lattice distribution is not sized by the layer sensor radius")
	if event_source.contains("sqrt(radial_u) * max(active_radius_m"):
		return _fail("Sensor lattice distribution still spreads over the whole source disk")
	if not event_source.contains("uniform bool validation_telemetry = false;") or not event_source.contains("if (validation_telemetry) {"):
		return _fail("Validation-only sensor telemetry channel is not gated off by default")
	# A particle's world position must reach the fragment stage as a varying:
	# MODEL_MATRIX is per-particle only in the vertex stage, so measuring the
	# camera-relative LOD with it in fragment() measured it from the particle
	# system node origin instead of from the particle.
	if not render_source.contains("varying vec2 particle_world_xz") or not render_source.contains("particle_world_xz = particle_position.xz"):
		return _fail("Spindrift render LOD lost the per-particle world position varying")
	if not render_source.contains("distance(particle_world_xz, camera_world_xz)"):
		return _fail("Spindrift render LOD does not measure from the particle world position")
	if detached_source_has_early_return():
		return _fail("Detached child lifetime release reintroduced an early return")
	print("OCEAN_SPINDRIFT_SOURCE_AUTHORITY_CREST_G_PASS")
	print("OCEAN_SPINDRIFT_DETACHED_AFTER_BIRTH_PASS")
	print("OCEAN_SPINDRIFT_LAYER_LATTICE_RADIUS_PASS")
	print("OCEAN_SPINDRIFT_VALIDATION_TELEMETRY_GATED_PASS")
	print("OCEAN_SPINDRIFT_RENDER_PARTICLE_WORLD_LOD_PASS")
	return true


func detached_source_has_early_return() -> bool:
	## Godot 4.7.1 breaks the particle pipeline when the detached child shader
	## returns early from process(); the working shape is an if/else.
	var detached_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_detached_particles.gdshader")
	if detached_source.is_empty():
		return true
	var lines: PackedStringArray = detached_source.split("\n")
	for index: int in lines.size():
		if not lines[index].contains("ACTIVE = false;"):
			continue
		for probe: int in range(index + 1, mini(index + 4, lines.size())):
			if lines[probe].strip_edges().begins_with("return"):
				return true
	return false


func _run_child_pool_source_contract() -> bool:
	_stage("child_pool_source_contract")
	var detached_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_detached_particles.gdshader")
	var event_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_event_particles.gdshader")
	if detached_source.is_empty() or event_source.is_empty():
		return _fail("Child pool shaders are missing")
	if not detached_source.contains("CUSTOM.z += age_step") or not detached_source.contains("ACTIVE = false") or not detached_source.contains("} else {") or not detached_source.contains("TRANSFORM[3].xyz += VELOCITY * DELTA"):
		return _fail("Detached child does not release its slot at lifetime")
	if not event_source.contains("bool emit_detached_event") or not event_source.contains("return emit_subparticle"):
		return _fail("Detached emission result is not propagated")
	if not event_source.contains("bool emitted_any") or not event_source.contains("bool emitted_second"):
		return _fail("Emission success aggregation is missing")
	if not event_source.contains("if (emitted_any) {"):
		return _fail("Failed child emissions can still latch the sensor")
	print("OCEAN_SPINDRIFT_CHILD_LIFETIME_RELEASE_PASS")
	print("OCEAN_SPINDRIFT_FAILED_EMISSION_DOES_NOT_LATCH_PASS")
	return true


func _art_life_fade(age: float, fade_in: float, fade_out_start: float) -> float:
	## Mirrors spindrift_render.gdshader::layer_life_fade() exactly.
	var birth_end: float = clampf(fade_in, 0.0001, 0.49)
	var birth_fade: float = smoothstep(0.0, birth_end, age)
	var death_start: float = clampf(fade_out_start, birth_end, 0.999)
	var death_fade: float = 1.0 - smoothstep(death_start, 1.0, age)
	return birth_fade * death_fade


func _art_water_fade(world_y: float, sea_level: float, fade_height: float) -> float:
	## Mirrors spindrift_render.gdshader::water_fade_at() exactly.
	return smoothstep(0.0, maxf(fade_height, 0.001), world_y - sea_level)


func _line_index_of(source: String, needle: String) -> int:
	var lines: PackedStringArray = source.split("\n")
	for index: int in lines.size():
		if lines[index].contains(needle):
			return index
	return -1


func _run_art_contract() -> bool:
	_stage("art_contract")
	var profile_source: String = FileAccess.get_file_as_string("res://addons/ocean/core/ocean_spindrift_profile.gd")
	var detached_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_detached_particles.gdshader")
	var render_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_render.gdshader")
	var controller_source: String = FileAccess.get_file_as_string("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
	if profile_source.is_empty() or detached_source.is_empty() or render_source.is_empty() or controller_source.is_empty():
		return _fail("Art contract sources are missing")
	for group: String in ["Art / Life Fade", "Art / Water Contact", "Art / Motion", "Art / Visual Scale"]:
		if not profile_source.contains('@export_group("%s")' % group):
			return _fail("Spindrift profile is missing the export group %s" % group)
	var art_exports: Array[String] = [
		"chunks_fade_in_fraction", "streaks_fade_in_fraction", "mist_fade_in_fraction",
		"chunks_fade_out_start_fraction", "streaks_fade_out_start_fraction", "mist_fade_out_start_fraction",
		"chunks_water_fade_height_m", "streaks_water_fade_height_m", "mist_water_fade_height_m", "water_kill_depth_m",
		"chunks_gravity_mps2", "streaks_gravity_mps2", "mist_gravity_mps2",
		"chunks_wind_drag", "streaks_wind_drag", "mist_wind_drag",
		"chunks_turbulence_multiplier", "streaks_turbulence_multiplier", "mist_turbulence_multiplier",
		"chunks_visual_scale", "streaks_visual_scale", "mist_visual_scale"]
	for key: String in art_exports:
		if not profile_source.contains("var %s" % key):
			return _fail("Art export %s is missing from the Spindrift profile" % key)
	var shape_exports: Array[String] = [
		"chunks_width_scale", "streaks_width_scale", "mist_width_scale",
		"chunks_length_scale", "streaks_length_scale", "mist_length_scale",
		"chunks_edge_softness", "streaks_edge_softness", "mist_edge_softness",
		"chunks_breakup_strength", "streaks_breakup_strength", "mist_breakup_strength",
		"chunks_mottle_strength", "streaks_mottle_strength", "mist_mottle_strength",
		"chunks_terminal_scale", "streaks_terminal_scale", "mist_terminal_scale",
		"chunks_core_strength", "streaks_core_strength", "mist_core_strength"]
	if not profile_source.contains('@export_group("Art / Shape")'):
		return _fail("Spindrift profile is missing the Art / Shape export group")
	for key: String in shape_exports:
		if not profile_source.contains("var %s" % key):
			return _fail("Shape export %s is missing from the Spindrift profile" % key)
	if not detached_source.contains("uniform float sea_level") or not detached_source.contains("uniform float water_kill_depth_m"):
		return _fail("Detached child shader does not expose the water contact controls")
	var integration_line: int = _line_index_of(detached_source, "TRANSFORM[3].xyz += VELOCITY * DELTA;")
	var kill_line: int = _line_index_of(detached_source, "if (TRANSFORM[3].y <= sea_level - water_kill_depth_m)")
	if integration_line < 0 or kill_line < 0 or kill_line <= integration_line:
		return _fail("Detached child water contact does not release the slot after integration")
	if detached_source_has_early_return():
		return _fail("Detached child lifetime release reintroduced an early return")
	for uniform_name: String in ["sea_level", "fade_in_fraction", "fade_out_start_fraction", "water_fade_height_m", "visual_scale"]:
		if not render_source.contains("uniform float %s" % uniform_name):
			return _fail("Render shader is missing the art uniform %s" % uniform_name)
	if not render_source.contains("varying float particle_world_y") or not render_source.contains("particle_world_y = particle_position.y"):
		return _fail("Render shader does not carry the particle world Y to the fragment stage")
	if not render_source.contains("water_fade_at(particle_world_y)"):
		return _fail("Render shader does not consume the water fade")
	for uniform_name: String in ["shape_width_scale", "shape_length_scale", "edge_softness", "breakup_strength", "mottle_strength", "terminal_scale", "core_strength"]:
		if not render_source.contains("uniform float %s" % uniform_name):
			return _fail("Render shader is missing the shape uniform %s" % uniform_name)
	for mask_name: String in ["shape_detail"]:
		if not render_source.contains("float %s(" % mask_name):
			return _fail("Render shader is missing the silhouette mask %s" % mask_name)
	# H4.31: the supplied artwork defines the silhouette, so no procedural
	# silhouette may remain next to it, and every sampler must be bound.
	if render_source.contains("chunks_base_shape") or render_source.contains("cloud_lobe") or render_source.contains("mist_base_shape"):
		return _fail("Render shader still carries a procedural silhouette next to the supplied artwork")
	for sampler_name: String in ["spray_chunks", "spray_streaks", "spray_mist"]:
		if not render_source.contains("uniform sampler2D %s" % sampler_name):
			return _fail("Render shader is missing the artwork sampler %s" % sampler_name)
	for artwork_path: String in ["textures/chunks.png", "textures/streaks.png", "textures/mist.png"]:
		if not controller_source.contains(artwork_path):
			return _fail("Controller does not bind the supplied artwork %s" % artwork_path)
	for parameter_name: String in ["spray_chunks", "spray_streaks", "spray_mist"]:
		if not controller_source.contains("&\"%s\"" % parameter_name):
			return _fail("Controller does not bind the artwork uniform %s" % parameter_name)
	if not render_source.contains("stable_cell_noise") or render_source.contains("TIME"):
		return _fail("Procedural shape detail is not stable over particle lifetime")
	if not render_source.contains("visual_width *= visual_scale * shape_width_scale"):
		return _fail("shape_width_scale is no longer applied to the billboard width")
	# Silhouette work must happen once, inside the layer mask.
	if render_source.contains("float breakup =") or render_source.contains("float cloud_mask ="):
		return _fail("Render shader still carries the old shared cloud mask or a second breakup term")
	if render_source.contains("terminal_shrink") or render_source.contains("float layer_shape ="):
		return _fail("Render shader still hard-codes per-layer terminal shrink or layer alpha")
	var fragment_index: int = render_source.find("void fragment()")
	if fragment_index < 0:
		return _fail("Render shader has no fragment stage")
	if render_source.substr(fragment_index).contains("MODEL_MATRIX"):
		return _fail("Render fragment stage reads MODEL_MATRIX for the particle position again")
	if not controller_source.contains("_apply_art_bindings") or not controller_source.contains("_art_arrays"):
		return _fail("Controller does not bind the per-layer art values")
	for key: String in ["water_kill_depth_m", "fade_in_fraction", "fade_out_start_fraction", "water_fade_height_m", "visual_scale", "gravity_mps2", "wind_drag",
			"shape_width_scale", "shape_length_scale", "edge_softness", "breakup_strength", "mottle_strength", "terminal_scale", "core_strength"]:
		if not controller_source.contains(key):
			return _fail("Controller does not forward %s to the layer materials" % key)
	var changed_index: int = controller_source.find("func _on_profile_changed(")
	if changed_index < 0:
		return _fail("Controller lost its profile change handler")
	var changed_body: String = controller_source.substr(changed_index)
	var next_func: int = changed_body.find("\nfunc ", 1)
	if next_func > 0:
		changed_body = changed_body.substr(0, next_func)
	if changed_body.contains("restart()"):
		return _fail("Art-only profile changes restart particles")
	var fade_cases: Array[Dictionary] = [
		{"name": "chunks", "fade_in": 0.07, "fade_out_start": 0.70},
		{"name": "streaks", "fade_in": 0.05, "fade_out_start": 0.72},
		{"name": "mist", "fade_in": 0.10, "fade_out_start": 0.58},
		{"name": "zero_fade_in", "fade_in": 0.0, "fade_out_start": 0.30},
		{"name": "reversed_request", "fade_in": 0.5, "fade_out_start": 0.30},
		{"name": "full_width", "fade_in": 0.5, "fade_out_start": 1.0},
	]
	for test_case: Dictionary in fade_cases:
		var case_name: String = str(test_case["name"])
		var fade_in: float = float(test_case["fade_in"])
		var fade_out_start: float = float(test_case["fade_out_start"])
		if absf(_art_life_fade(0.0, fade_in, fade_out_start)) > 0.0001:
			return _fail("Life fade is not zero at birth (%s)" % case_name)
		if absf(_art_life_fade(1.0, fade_in, fade_out_start)) > 0.0001:
			return _fail("Life fade is not zero at lifetime end (%s)" % case_name)
		var birth_end: float = clampf(fade_in, 0.0001, 0.49)
		if _art_life_fade(birth_end, fade_in, fade_out_start) <= 0.99:
			return _fail("Life fade never reaches full contribution (%s)" % case_name)
		if _art_life_fade(birth_end * 0.5, fade_in, fade_out_start) >= _art_life_fade(birth_end, fade_in, fade_out_start):
			return _fail("Life fade does not rise during fade-in (%s)" % case_name)
		if _art_life_fade(1.0, fade_in, fade_out_start) > _art_life_fade(0.99, fade_in, fade_out_start) + 0.0001:
			return _fail("Life fade does not fall at the end of life (%s)" % case_name)
		for step: int in 41:
			var age: float = float(step) / 40.0
			var value: float = _art_life_fade(age, fade_in, fade_out_start)
			if is_nan(value) or is_inf(value) or value < -0.0001 or value > 1.0001:
				return _fail("Life fade left [0,1] at age %.3f (%s)" % [age, case_name])
	for fade_height: float in [0.01, 0.35, 0.45, 0.65, 2.0]:
		if absf(_art_water_fade(0.0, 0.0, fade_height)) > 0.0001:
			return _fail("Water fade is not zero at sea level (height %.2f m)" % fade_height)
		if absf(_art_water_fade(-0.5, 0.0, fade_height)) > 0.0001:
			return _fail("Water fade is not zero below sea level (height %.2f m)" % fade_height)
		if _art_water_fade(fade_height, 0.0, fade_height) <= 0.99:
			return _fail("Water fade never reaches full contribution (height %.2f m)" % fade_height)
		var sea_level_probe: float = 3.25
		if absf(_art_water_fade(sea_level_probe, sea_level_probe, fade_height)) > 0.0001:
			return _fail("Water fade ignores sea_level (height %.2f m)" % fade_height)
	print("OCEAN_SPINDRIFT_ART_PROFILE_CONTRACT_PASS")
	print("OCEAN_SPINDRIFT_ART_FADE_FORMULA_CONTRACT_PASS")
	print("OCEAN_SPINDRIFT_ART_WATER_CONTACT_CONTRACT_PASS")
	print("OCEAN_SPINDRIFT_ART_SHAPE_CONTRACT_PASS")
	return true


func _report_particle_rates(spindrift: Node) -> void:
	## Diagnostic only: the runtime particle rate of all six GPUParticles3D nodes,
	## printed once (no per-frame logging).
	var sensor_rates: Array = []
	var child_rates: Array = []
	var interpolate: Array = []
	var fract_delta: Array = []
	for layer_name: String in ["CrestChunksSensors", "SpindriftStreaksSensors", "FineMistSensors"]:
		var sensor: GPUParticles3D = spindrift.get_node_or_null(layer_name) as GPUParticles3D
		sensor_rates.append(sensor.fixed_fps if sensor != null else -1)
	for layer_name: String in ["CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]:
		var children: GPUParticles3D = spindrift.get_node_or_null(layer_name) as GPUParticles3D
		child_rates.append(children.fixed_fps if children != null else -1)
		interpolate.append(children.interpolate if children != null else false)
		fract_delta.append(children.fract_delta if children != null else false)
	print("SPINDRIFT PARTICLE RATE | sensors=%s children=%s interpolate=%s fract_delta=%s" % [
		sensor_rates, child_rates, interpolate, fract_delta])


func _check_artwork_binding(spindrift: Node) -> bool:
	## The supplied artwork must be genuinely bound per layer material, not merely
	## referenced by the shader source.
	var expected: Dictionary = {
		"spray_chunks": "addons/ocean/spindrift/textures/chunks.png",
		"spray_streaks": "addons/ocean/spindrift/textures/streaks.png",
		"spray_mist": "addons/ocean/spindrift/textures/mist.png",
	}
	var render_materials: Array = spindrift.get("_render_materials") as Array
	if render_materials.size() != 3:
		return _fail("Artwork binding check could not read all three render materials")
	for index: int in 3:
		var material: ShaderMaterial = render_materials[index] as ShaderMaterial
		if material == null:
			return _fail("Render material %d is missing" % index)
		for parameter_name: String in expected.keys():
			var texture: Texture2D = material.get_shader_parameter(StringName(parameter_name)) as Texture2D
			if texture == null:
				return _fail("Layer %d has no %s texture bound" % [index, parameter_name])
			if not texture.resource_path.ends_with(str(expected[parameter_name])):
				return _fail("Layer %d %s resolved to %s" % [index, parameter_name, texture.resource_path])
	print("OCEAN_SPINDRIFT_ARTWORK_BINDING_PASS | layers=3 samplers=%s" % [expected.keys()])
	return true


func _run_density_contract() -> bool:
	_stage("density_0_2_contract")
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
	_stage("ocean_space_position_parity")
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


func _run_ocean_space_recenter_source_contract() -> bool:
	_stage("ocean_space_recenter_source")
	var controller_source: String = FileAccess.get_file_as_string("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
	var event_source: String = FileAccess.get_file_as_string("res://addons/ocean/shaders/spindrift_event_particles.gdshader")
	var lod_is_world_space: bool = controller_source.contains("max_layer_lod = maxf(_profile.chunks_lod_end_m, maxf(_profile.streaks_lod_end_m, _profile.mist_lod_end_m))") and not controller_source.contains("max_layer_lod = maxf(_profile.chunks_lod_end_m, maxf(_profile.streaks_lod_end_m, _profile.mist_lod_end_m)) * horizontal_scale")
	var h_requantizes: bool = controller_source.contains("_requantize_sensor_lattice") and controller_source.contains("_sensor_ocean_space_requantize_count")
	var preserves_cell_identity: bool = event_source.contains("CUSTOM.xy = cell") and event_source.contains("round(CUSTOM.xy)")
	if not lod_is_world_space or not h_requantizes or not preserves_cell_identity:
		return _fail("Ocean Space recenter source contract is incomplete")
	print("OCEAN_SPINDRIFT_OCEAN_SPACE_RECENTER_FORMULA_PASS")
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
	_stage("runtime_layer_contract")
	var capacities: Array = state.get("visible_layer_capacities", [])
	var sensor_amounts: Array = state.get("sensor_layer_amounts", [])
	if capacities.size() != 3 or sensor_amounts.size() != 3:
		return _fail("Spindrift layer capacity diagnostics are incomplete")
	for index: int in 3:
		if int(capacities[index]) < int(sensor_amounts[index]) * 2:
			return _fail("Visible capacity is below the 2x density contract")
	if int(state.get("max_event_multiplicity", 0)) != 2:
		return _fail("Spindrift max event multiplicity is not 2")
	var emission_radii: Array = state.get("layer_emission_radius_m", [])
	if emission_radii.size() != 3 or not is_equal_approx(float(emission_radii[0]), 22.0) or not is_equal_approx(float(emission_radii[1]), 55.0) or not is_equal_approx(float(emission_radii[2]), 46.0):
		return _fail("LOD-aware emission footprint is not [22, 55, 46] at P0")
	print("SPINDRIFT EMISSION FOOTPRINT | source=%.1f layers=%s" % [float(state.get("effective_source_radius_m", 0.0)), emission_radii])
	print("OCEAN_SPINDRIFT_LOD_AWARE_EMISSION_FOOTPRINT_PASS")
	var margin: float = float(state.get("sensor_anchor_drift_margin_m", 0.0))
	var lattice_radii: Array = state.get("layer_sensor_radius_m", [])
	var footprint_estimates: Array = state.get("layer_footprint_sensor_estimate", [])
	var source_radius: float = float(state.get("effective_source_radius_m", 0.0))
	if lattice_radii.size() != 3 or footprint_estimates.size() != 3 or margin <= 0.0:
		return _fail("Layer lattice diagnostics are incomplete")
	for index: int in 3:
		var expected: float = minf(source_radius, float(emission_radii[index]) + margin)
		if absf(float(lattice_radii[index]) - expected) > 0.01:
			return _fail("Layer %d lattice radius is %.2f, expected %.2f (footprint + anchor drift)" % [index, float(lattice_radii[index]), expected])
	print("SPINDRIFT LATTICE FOOTPRINT | anchor_margin=%.1f lattice_radius=%s footprint_sensors=%s of %s" % [
		margin, lattice_radii, footprint_estimates, state.get("sensor_layer_amounts", [])])
	print("OCEAN_SPINDRIFT_LAYER_FOOTPRINT_LATTICE_PASS")
	if state.get("breaking_activity_authority", "") != "crest_g_long":
		return _fail("Runtime authority is not Crest G LONG")
	return true


func _run_sensor_coverage_contract(state: Dictionary) -> bool:
	_stage("sensor_lattice_coverage")
	var source_radius: float = float(state.get("effective_source_radius_m", 0.0))
	var spacing: float = float(state.get("sensor_grid_cell_m", 0.0))
	var amounts: Array = state.get("sensor_layer_amounts", []) as Array
	var lattice_radii: Array = state.get("layer_sensor_radius_m", []) as Array
	var emission_radii: Array = state.get("layer_emission_radius_m", []) as Array
	var margin: float = float(state.get("sensor_anchor_drift_margin_m", 0.0))
	if source_radius <= 0.0 or spacing <= 0.0 or amounts.size() != 3 or lattice_radii.size() != 3 or emission_radii.size() != 3 or margin <= 0.0:
		return _fail("Sensor coverage diagnostics are incomplete")
	for layer_index: int in 3:
		var count: int = int(amounts[layer_index])
		var layer_radius: float = float(lattice_radii[layer_index])
		var emission_radius: float = float(emission_radii[layer_index])
		# Coverage invariant: the lattice must still reach the whole visual
		# footprint at the worst camera drift from the anchor.
		if layer_radius + 0.001 < emission_radius + margin:
			return _fail("Layer %d lattice radius %.2f cannot cover its %.2f m footprint plus the %.2f m anchor drift"
				% [layer_index, layer_radius, emission_radius, margin])
		if layer_radius > source_radius + 0.001:
			return _fail("Layer %d lattice radius %.2f leaves the %.2f m source region" % [layer_index, layer_radius, source_radius])
		var area: float = PI * layer_radius * layer_radius
		var unique_cells: Dictionary = {}
		var footprint_cells: Dictionary = {}
		for particle_index: int in count:
			var cell: Vector2i = _sampled_sensor_cell(particle_index, count, layer_index, layer_radius, spacing)
			unique_cells[cell] = true
			if Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5).length() * spacing <= emission_radius:
				footprint_cells[cell] = true
		var unique_count: int = unique_cells.size()
		var duplicate_percentage: float = 100.0 * float(count - unique_count) / maxf(float(count), 1.0)
		var footprint_count: int = footprint_cells.size()
		var spacing_m: float = emission_radius / sqrt(maxf(float(footprint_count), 1.0))
		print("SPINDRIFT SENSOR LATTICE layer=%d sensors=%d lattice_radius_m=%.2f emission_radius_m=%.2f footprint_sensors=%d footprint_spacing_m=%.2f unique_cells=%d duplicate_percent=%.3f lattice_area_m2=%.2f area_per_sensor_m2=%.2f" % [
			layer_index, count, layer_radius, emission_radius, footprint_count, spacing_m, unique_count, duplicate_percentage, area, area / maxf(float(count), 1.0)])
		if footprint_count < MIN_FOOTPRINT_SENSORS:
			return _fail("Layer %d has only %d sensors inside its %.1f m visual footprint" % [layer_index, footprint_count, emission_radius])
		if duplicate_percentage > MAX_LATTICE_DUPLICATE_PERCENT:
			return _fail("Layer %d lattice wastes %.1f%% of its budget on repeated cells" % [layer_index, duplicate_percentage])
	print("OCEAN_SPINDRIFT_SENSOR_COVERAGE_PASS")
	return true


func _sampled_sensor_cell(particle_index: int, count: int, layer_index: int, radius: float, spacing: float) -> Vector2i:
	var radial_u: float = clampf((float(particle_index) + 0.5) / maxf(float(count), 1.0), 0.0, 1.0)
	var radial_distance: float = sqrt(radial_u) * maxf(radius - spacing, spacing)
	var angular_u: float = fposmod(float(particle_index) * 0.61803398875 + float(layer_index) * 0.3333333333, 1.0)
	var angle: float = angular_u * TAU
	var world: Vector2 = Vector2(cos(angle), sin(angle)) * radial_distance
	return Vector2i(floori(world.x / maxf(spacing, 0.001)), floori(world.y / maxf(spacing, 0.001)))


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


func _run_sensor_observation(ocean: Node, spindrift: Node, seconds: float, label: String) -> Dictionary:
	_stage("sensor_observation:%s" % label)
	## Observes the REAL parent sensors and the REAL detached children in the same
	## window. A Crest probe over arbitrary texels proves nothing about Production:
	## Production only samples Crest G at its own sensor cells, and a sensor may be
	## latched, rearming, or outside its emission footprint. Every verdict below is
	## drawn from what a real sensor consumed and what it actually emitted.
	var open_ocean: Node = ocean.get("_open_ocean") as Node
	if open_ocean == null or not open_ocean.has_method(&"get_spindrift_sources"):
		_fail("OpenOceanFFT source packet is missing for %s" % label)
		return {"healthy": false, "label": label}
	var free_camera: Camera3D = ocean.get_parent().find_child(^"FreeCamera", true, false) as Camera3D
	if free_camera == null:
		_fail("FreeCamera is missing for %s" % label)
		return {"healthy": false, "label": label}
	var state: Dictionary = _spindrift_state(ocean)
	var anchor_value: Variant = state.get("sensor_anchor_world", Vector3.ZERO)
	var anchor_world: Vector3 = anchor_value if anchor_value is Vector3 else Vector3.ZERO
	var source_radius: float = float(state.get("effective_source_radius_m", 0.0))
	var trigger: float = float(state.get("trigger_threshold", PROVEN_TRIGGER_THRESHOLD))
	var lattice_radii: Array = state.get("layer_sensor_radius_m", []) as Array
	var emission_radii: Array = state.get("layer_emission_radius_m", []) as Array
	var process_materials: Array = spindrift.get("_process_materials") as Array
	var sensor_names: Array[String] = ["CrestChunksSensors", "SpindriftStreaksSensors", "FineMistSensors"]
	var visible_names: Array[String] = ["CrestChunksVisible", "SpindriftStreaksVisible", "FineMistVisible"]
	if source_radius <= 0.0 or lattice_radii.size() != 3 or emission_radii.size() != 3 or process_materials.size() != 3:
		_fail("%s could not read the Spindrift layer contract" % label)
		return {"healthy": false, "label": label}

	var world_3d: World3D = get_viewport().world_3d
	var probe_viewport: SubViewport = _create_crest_probe_viewport()
	var probe_rect: ColorRect = probe_viewport.get_node_or_null(^"ProbeRect") as ColorRect
	var probe_material: ShaderMaterial = probe_rect.material as ShaderMaterial if probe_rect != null else null
	if probe_material == null:
		probe_viewport.queue_free()
		_fail("%s could not create the Crest source probe" % label)
		return {"healthy": false, "label": label}

	var sensor_viewports: Array = []
	var sensor_cameras: Array[Camera3D] = []
	var saved_layers: Array[Dictionary] = []
	var saved_draw_passes: Array[Dictionary] = []
	for index: int in 3:
		var sensor: GPUParticles3D = spindrift.get_node_or_null(sensor_names[index]) as GPUParticles3D
		var visible_layer: GPUParticles3D = spindrift.get_node_or_null(visible_names[index]) as GPUParticles3D
		var process_material: ShaderMaterial = process_materials[index] as ShaderMaterial
		if sensor == null or visible_layer == null or process_material == null:
			_cleanup_sensor_observation(sensor_viewports, null, probe_viewport, saved_layers, saved_draw_passes, process_materials)
			_fail("%s scene contract is incomplete at layer %d" % [label, index])
			return {"healthy": false, "label": label}
		saved_layers.append({"sensor": sensor, "visible": visible_layer, "sensor_layers": sensor.layers, "visible_layers": visible_layer.layers})
		saved_draw_passes.append({"sensor": sensor, "draw_passes": sensor.draw_passes, "draw_pass_1": sensor.draw_pass_1})
		var sensor_bit: int = SENSOR_TELEMETRY_LAYER_BIT + index
		sensor.layers = 1 << sensor_bit
		visible_layer.layers = 1 << CHILD_VIEWPORT_LAYER_BIT
		var telemetry_mesh: PlaneMesh = PlaneMesh.new()
		telemetry_mesh.size = Vector2(TELEMETRY_QUAD_M, TELEMETRY_QUAD_M)
		var telemetry_material: ShaderMaterial = ShaderMaterial.new()
		telemetry_material.shader = SENSOR_TELEMETRY_SHADER
		telemetry_mesh.material = telemetry_material
		sensor.draw_pass_1 = telemetry_mesh
		sensor.draw_passes = 1
		process_material.set_shader_parameter(&"validation_telemetry", true)
		var sensor_viewport: SubViewport = _create_observation_viewport(world_3d, 1 << sensor_bit, anchor_world, float(lattice_radii[index]))
		sensor_viewports.append(sensor_viewport)
		sensor_cameras.append(sensor_viewport.get_child(0) as Camera3D)
	var child_viewport: SubViewport = _create_observation_viewport(world_3d, 1 << CHILD_VIEWPORT_LAYER_BIT, anchor_world, CHILD_VIEWPORT_RADIUS_M)
	var child_camera: Camera3D = child_viewport.get_child(0) as Camera3D

	# One restart opens the observation window. The window itself never restarts
	# the sensors again: continuity is the point.
	await _restart_sensors(spindrift)
	var initial_camera_position: Vector3 = free_camera.global_position
	var initial_recenter_count: int = int(_spindrift_state(ocean).get("sensor_recenter_count", 0))
	var per_layer: Array[Dictionary] = []
	for _index: int in 3:
		per_layer.append({
			"sensor_pixels": 0,
			"eligible_samples": 0,
			"mid_samples": 0,
			"eligible_in_footprint_samples": 0,
			"eligible_outside_footprint_samples": 0,
			"latched_samples": 0,
			"emit_samples": 0,
			"emit_in_footprint_samples": 0,
			"rearm_samples": 0,
			"first_emit_s": -1.0,
			"last_emit_s": -1.0,
			"peak_eligible_pixels": 0,
			"peak_latched_pixels": 0,
		})
	var samples: int = 0
	var child_output_samples: int = 0
	var child_max_pixels: int = 0
	var child_first_s: float = -1.0
	var child_last_s: float = -1.0
	var child_windows: Array[int] = []
	var window_count: int = maxi(int(ceil(seconds / SOAK_WINDOW_SECONDS)), 1)
	for _window: int in window_count:
		child_windows.append(0)
	var source_samples: int = 0
	var camera_moved_m: float = 0.0
	var recenter_delta: int = 0
	var start_usec: int = Time.get_ticks_usec()
	var last_sample_usec: int = start_usec
	while float(Time.get_ticks_usec() - start_usec) / 1000000.0 < seconds:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var now_usec: int = Time.get_ticks_usec()
		if now_usec - last_sample_usec < int(TELEMETRY_SAMPLE_SECONDS * 1000000.0):
			continue
		last_sample_usec = now_usec
		var elapsed_s: float = float(now_usec - start_usec) / 1000000.0
		var live_state: Dictionary = _spindrift_state(ocean)
		if not bool(live_state.get("source_ready", false)) or int(live_state.get("debug_mode", -1)) != FULL_MODE or int(live_state.get("active_layers", 0)) != 3:
			_cleanup_sensor_observation(sensor_viewports, child_viewport, probe_viewport, saved_layers, saved_draw_passes, process_materials)
			_fail("%s lost FULL/source-ready state" % label)
			return {"healthy": false, "label": label}
		var current_sources: Dictionary = open_ocean.call("get_spindrift_sources") as Dictionary
		var identity: Dictionary = _refresh_spindrift_source_identity(current_sources, spindrift, probe_material, anchor_world, source_radius)
		if not bool(identity.get("valid", false)):
			_cleanup_sensor_observation(sensor_viewports, child_viewport, probe_viewport, saved_layers, saved_draw_passes, process_materials)
			print("SPINDRIFT_PROBE_STALE_OR_WRONG_SOURCE")
			_fail("%s sensors are not bound to the live Crest source packet" % label)
			return {"healthy": false, "label": label}
		source_samples += 1
		var live_anchor_value: Variant = live_state.get("sensor_anchor_world", Vector3.ZERO)
		var live_anchor: Vector3 = live_anchor_value if live_anchor_value is Vector3 else Vector3.ZERO
		# The observation cameras always track the live anchor, so the window keeps
		# looking at the real sensors even if the anchor recenters.
		child_camera.global_position = Vector3(live_anchor.x, live_anchor.y + 200.0, live_anchor.z)
		for camera: Camera3D in sensor_cameras:
			if camera != null:
				camera.global_position = Vector3(live_anchor.x, live_anchor.y + 200.0, live_anchor.z)
		# Every observation window is a stationary window: the harness performs the
		# travel between windows, so the window itself owns the camera. Keyboard or
		# mouse input must not be able to invalidate the measurement, and a drifted
		# anchor would walk the sensors out of the observation cameras.
		camera_moved_m = maxf(camera_moved_m, free_camera.global_position.distance_to(initial_camera_position))
		recenter_delta = maxi(recenter_delta, absi(int(live_state.get("sensor_recenter_count", 0)) - initial_recenter_count))
		free_camera.global_position = initial_camera_position
		samples += 1
		var window_index: int = clampi(int(elapsed_s / SOAK_WINDOW_SECONDS), 0, window_count - 1)
		for index: int in 3:
			var sample: Dictionary = _sample_sensor_pixels(sensor_viewports[index] as SubViewport, float(lattice_radii[index]), float(emission_radii[index]))
			var stats: Dictionary = per_layer[index]
			stats["sensor_pixels"] = int(stats["sensor_pixels"]) + int(sample.get("sensor_pixels", 0))
			stats["peak_eligible_pixels"] = maxi(int(stats["peak_eligible_pixels"]), int(sample.get("eligible_pixels", 0)))
			stats["peak_latched_pixels"] = maxi(int(stats["peak_latched_pixels"]), int(sample.get("latched_pixels", 0)))
			if int(sample.get("eligible_pixels", 0)) > 0:
				stats["eligible_samples"] = int(stats["eligible_samples"]) + 1
			if int(sample.get("mid_pixels", 0)) > 0:
				stats["mid_samples"] = int(stats["mid_samples"]) + 1
			if int(sample.get("eligible_in_footprint_pixels", 0)) > 0:
				stats["eligible_in_footprint_samples"] = int(stats["eligible_in_footprint_samples"]) + 1
			if int(sample.get("eligible_outside_footprint_pixels", 0)) > 0:
				stats["eligible_outside_footprint_samples"] = int(stats["eligible_outside_footprint_samples"]) + 1
			if int(sample.get("latched_pixels", 0)) > 0:
				stats["latched_samples"] = int(stats["latched_samples"]) + 1
			if int(sample.get("emit_pixels", 0)) > 0:
				stats["emit_samples"] = int(stats["emit_samples"]) + 1
				if float(stats["first_emit_s"]) < 0.0:
					stats["first_emit_s"] = elapsed_s
				stats["last_emit_s"] = elapsed_s
			if int(sample.get("emit_in_footprint_pixels", 0)) > 0:
				stats["emit_in_footprint_samples"] = int(stats["emit_in_footprint_samples"]) + 1
			if int(sample.get("rearm_pixels", 0)) > 0:
				stats["rearm_samples"] = int(stats["rearm_samples"]) + 1
		var child_pixels: int = _sample_child_pixels(child_viewport)
		if child_pixels > 0:
			child_output_samples += 1
			child_max_pixels = maxi(child_max_pixels, child_pixels)
			if child_first_s < 0.0:
				child_first_s = elapsed_s
			child_last_s = elapsed_s
			child_windows[window_index] = int(child_windows[window_index]) + 1
	_cleanup_sensor_observation(sensor_viewports, child_viewport, probe_viewport, saved_layers, saved_draw_passes, process_materials)
	if samples <= 0 or source_samples <= 0:
		_fail("%s observation window produced no samples" % label)
		return {"healthy": false, "label": label}
	var emit_total: int = 0
	var eligible_total: int = 0
	var rearm_total: int = 0
	for index: int in 3:
		var stats: Dictionary = per_layer[index]
		emit_total += int(stats["emit_samples"])
		eligible_total += int(stats["eligible_samples"])
		rearm_total += int(stats["rearm_samples"])
		print("SPINDRIFT SENSOR OBSERVATION %s LAYER %d | samples=%d sensor_pixels=%d eligible_samples=%d mid_samples=%d eligible_in_footprint=%d eligible_outside_footprint=%d latched_samples=%d emit_samples=%d emit_in_footprint=%d rearm_samples=%d peak_eligible_pixels=%d peak_latched_pixels=%d first_emit_s=%.1f last_emit_s=%.1f" % [
			label, index, samples, int(stats["sensor_pixels"]), int(stats["eligible_samples"]), int(stats["mid_samples"]),
			int(stats["eligible_in_footprint_samples"]), int(stats["eligible_outside_footprint_samples"]),
			int(stats["latched_samples"]), int(stats["emit_samples"]), int(stats["emit_in_footprint_samples"]),
			int(stats["rearm_samples"]), int(stats["peak_eligible_pixels"]), int(stats["peak_latched_pixels"]),
			float(stats["first_emit_s"]), float(stats["last_emit_s"])])
	print("SPINDRIFT CHILD OBSERVATION %s | seconds=%.1f samples=%d output_samples=%d max_pixels=%d windows=%s first_s=%.1f last_s=%.1f emit_samples_total=%d rearm_samples_total=%d" % [
		label, seconds, samples, child_output_samples, child_max_pixels, child_windows, child_first_s, child_last_s, emit_total, rearm_total])
	print("SPINDRIFT OBSERVATION WINDOW %s | pre_hold_camera_excursion_m=%.3f recenter_delta=%d anchor=%s" % [
		label, camera_moved_m, recenter_delta, anchor_world])
	return {
		"healthy": true,
		"label": label,
		"seconds": seconds,
		"samples": samples,
		"child_output_samples": child_output_samples,
		"child_max_pixels": child_max_pixels,
		"child_windows": child_windows,
		"child_first_s": child_first_s,
		"child_last_s": child_last_s,
		"emit_samples_total": emit_total,
		"eligible_samples_total": eligible_total,
		"rearm_samples_total": rearm_total,
		"camera_moved_m": camera_moved_m,
		"recenter_delta": recenter_delta,
		"layers": per_layer,
	}


func _judge_sensor_observation(observed: Dictionary, require_child_output: bool) -> bool:
	if not bool(observed.get("healthy", false)):
		return false
	var label: String = str(observed.get("label", "OBSERVATION"))
	var emit_total: int = int(observed.get("emit_samples_total", 0))
	var eligible_total: int = int(observed.get("eligible_samples_total", 0))
	var rearm_total: int = int(observed.get("rearm_samples_total", 0))
	var child_output: int = int(observed.get("child_output_samples", 0))
	if child_output > 0 and eligible_total <= 0 and emit_total <= 0:
		print("SPINDRIFT_CHILD_OUTPUT_PROVENANCE_MISMATCH")
		return _fail("%s drew detached children while no real sensor ever became eligible" % label)
	if emit_total > 0 and child_output <= 0:
		print("SPINDRIFT_CHILD_POOL_FAILURE")
		return _fail("%s: a real sensor emitted but no detached child was ever drawn" % label)
	if require_child_output and child_output <= 0:
		print("SPINDRIFT_NO_SENSOR_EVENT_IN_WINDOW")
		return _fail("%s: only %d eligible sensor samples and %d emissions, but no detached child was drawn" % [label, eligible_total, emit_total])
	if require_child_output and rearm_total <= 0:
		print("SPINDRIFT_STATE_REARM_FAILURE")
		return _fail("%s: no sensor released its hysteresis latch, so no second event could ever fire" % label)
	return true

func _create_crest_probe_viewport() -> SubViewport:
	var viewport: SubViewport = SubViewport.new()
	viewport.name = "CrestProbeViewport"
	viewport.size = Vector2i(CREST_PROBE_SIZE, CREST_PROBE_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.transparent_bg = false
	add_child(viewport)
	var rect: ColorRect = ColorRect.new()
	rect.name = "ProbeRect"
	rect.size = Vector2(CREST_PROBE_SIZE, CREST_PROBE_SIZE)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = CREST_PROBE_SHADER
	rect.material = material
	viewport.add_child(rect)
	return viewport


func _refresh_spindrift_source_identity(sources: Dictionary, spindrift: Node, probe_material: ShaderMaterial, anchor_world: Vector3, radius: float) -> Dictionary:
	var source_texture: Texture2D = sources.get("breaking_activity_long") as Texture2D
	var source_identity: Dictionary = _texture_identity(source_texture)
	if not bool(sources.get("ready", false)) or not bool(source_identity.get("valid", false)):
		return {"valid": false}
	var process_materials: Array = spindrift.get("_process_materials") as Array
	if process_materials.size() != 3:
		return {"valid": false}
	for value: Variant in process_materials:
		var process_material: ShaderMaterial = value as ShaderMaterial
		if process_material == null:
			return {"valid": false}
		var bound_texture: Texture2D = process_material.get_shader_parameter(&"breaking_activity_long") as Texture2D
		if not _same_texture_identity(source_identity, _texture_identity(bound_texture)):
			return {"valid": false}
	probe_material.set_shader_parameter(&"breaking_activity_long", source_texture)
	var probe_bound_texture: Texture2D = probe_material.get_shader_parameter(&"breaking_activity_long") as Texture2D
	if not _same_texture_identity(source_identity, _texture_identity(probe_bound_texture)):
		return {"valid": false}
	probe_material.set_shader_parameter(&"sensor_anchor_xz", Vector2(anchor_world.x, anchor_world.z))
	probe_material.set_shader_parameter(&"sample_radius_m", radius)
	var domains_value: Variant = sources.get("domains", Vector3(512.0, 137.0, 37.0))
	var domains: Vector3 = domains_value if domains_value is Vector3 else Vector3(512.0, 137.0, 37.0)
	probe_material.set_shader_parameter(&"domain_long_m", domains.x)
	return {"valid": true, "generation": int(sources.get("breaking_activity_generation", -1)), "rid_text": source_identity.get("rid_text", ""), "instance_id": int(source_identity.get("instance_id", 0))}


func _texture_identity(texture: Texture2D) -> Dictionary:
	var rd_texture: Texture2DRD = texture as Texture2DRD
	if rd_texture == null:
		return {"valid": false}
	var rid: RID = rd_texture.texture_rd_rid
	return {"valid": rid.is_valid(), "instance_id": texture.get_instance_id(), "rid": rid, "rid_text": str(rid)}


func _same_texture_identity(expected: Dictionary, actual: Dictionary) -> bool:
	if not bool(expected.get("valid", false)) or not bool(actual.get("valid", false)):
		return false
	return int(expected.get("instance_id", 0)) == int(actual.get("instance_id", 0)) and RID(expected.get("rid", RID())) == RID(actual.get("rid", RID()))


func _run_scale_runtime_sweep(ocean: Node, _spindrift: Node) -> bool:
	_stage("ocean_space_scale_sweep")
	var open_ocean: Node = ocean.get("_open_ocean") as Node
	if open_ocean == null:
		return _fail("OpenOceanFFT missing for Ocean Space runtime sweep")
	var original_h: float = float(open_ocean.get("_clipmap_geometry_scale"))
	var original_v: float = float(open_ocean.get("_surface_scale"))
	var last_h: float = original_h
	for h: float in [0.5, 1.0, 2.0, 4.0]:
		var state_before: Dictionary = _spindrift_state(ocean)
		var count_before: int = int(state_before.get("sensor_ocean_space_requantize_count", 0))
		open_ocean.call("set_clipmap_geometry_scale", h)
		open_ocean.call("set_surface_scale", 1.0)
		await _wait_runtime_frames(3)
		var state: Dictionary = _spindrift_state(ocean)
		if not _validate_ocean_space_scale(state, h, 1.0, count_before + (1 if absf(h - last_h) > 0.0001 else 0)):
			open_ocean.call("set_clipmap_geometry_scale", original_h)
			open_ocean.call("set_surface_scale", original_v)
			return false
		print("SPINDRIFT SCALE SWEEP H=%.2f V=1.00 READY radius=%.3f cell=%.3f recenter=%.3f requantize=%d" % [h, float(state.get("effective_source_radius_m", 0.0)), float(state.get("sensor_grid_cell_m", 0.0)), float(state.get("sensor_recenter_distance_m", 0.0)), int(state.get("sensor_ocean_space_requantize_count", 0))])
		last_h = h
	open_ocean.call("set_clipmap_geometry_scale", 1.0)
	open_ocean.call("set_surface_scale", 1.0)
	await _wait_runtime_frames(3)
	var v_baseline: Dictionary = _spindrift_state(ocean)
	var v_count: int = int(v_baseline.get("sensor_ocean_space_requantize_count", 0))
	for v: float in [0.5, 2.0, 1.0]:
		open_ocean.call("set_surface_scale", v)
		await _wait_runtime_frames(3)
		var state: Dictionary = _spindrift_state(ocean)
		if not _validate_ocean_space_scale(state, 1.0, v, v_count):
			open_ocean.call("set_clipmap_geometry_scale", original_h)
			open_ocean.call("set_surface_scale", original_v)
			return false
		print("SPINDRIFT SCALE SWEEP V-ONLY H=1.00 V=%.2f requantize=%d" % [v, int(state.get("sensor_ocean_space_requantize_count", 0))])
	open_ocean.call("set_clipmap_geometry_scale", original_h)
	open_ocean.call("set_surface_scale", original_v)
	await _wait_runtime_frames(3)
	print("OCEAN_SPINDRIFT_OCEAN_SPACE_SENSOR_REQUANTIZATION_PASS")
	print("OCEAN_SPINDRIFT_VERTICAL_SCALE_NO_SENSOR_REQUANTIZE_PASS")
	return true


func _wait_runtime_frames(frame_count: int) -> void:
	for _frame: int in frame_count:
		await get_tree().process_frame


func _validate_ocean_space_scale(state: Dictionary, expected_h: float, expected_v: float, expected_requantize_count: int) -> bool:
	if not bool(state.get("source_ready", false)) or int(state.get("active_layers", 0)) != 3:
		return _fail("Spindrift lost source/layer residency at Ocean Space scale H=%.2f V=%.2f" % [expected_h, expected_v])
	var expected_radius: float = 120.0 * expected_h
	var expected_cell: float = 2.5 * expected_h
	var expected_recenter: float = maxf(expected_cell * 4.0, minf(expected_radius * 0.25, 55.0 * 0.5))
	if absf(float(state.get("effective_source_radius_m", 0.0)) - expected_radius) > 0.01:
		return _fail("Spindrift source radius did not follow H: expected %.3f" % expected_radius)
	if absf(float(state.get("sensor_grid_cell_m", 0.0)) - expected_cell) > 0.001:
		return _fail("Spindrift sensor grid cell did not follow H: expected %.3f" % expected_cell)
	var lod: Array = state.get("layer_lod_end_m", []) as Array
	if lod.size() != 3 or absf(float(lod[0]) - 22.0) > 0.001 or absf(float(lod[1]) - 55.0) > 0.001 or absf(float(lod[2]) - 46.0) > 0.001:
		return _fail("Spindrift LOD became Ocean Space scaled: %s" % [lod])
	if absf(float(state.get("sensor_recenter_distance_m", 0.0)) - expected_recenter) > 0.01:
		return _fail("Spindrift recenter distance formula mismatch: expected %.3f got %.3f" % [expected_recenter, float(state.get("sensor_recenter_distance_m", 0.0))])
	if int(state.get("sensor_ocean_space_requantize_count", -1)) != expected_requantize_count:
		return _fail("Spindrift sensor requantization counter mismatch: expected %d got %d" % [expected_requantize_count, int(state.get("sensor_ocean_space_requantize_count", -1))])
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


func _create_observation_viewport(world_3d: World3D, cull_mask: int, anchor_world: Vector3, radius: float) -> SubViewport:
	var viewport: SubViewport = SubViewport.new()
	viewport.size = Vector2i(TELEMETRY_VIEWPORT_SIZE, TELEMETRY_VIEWPORT_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.transparent_bg = false
	viewport.world_3d = world_3d
	add_child(viewport)
	var camera: Camera3D = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = radius * 2.2
	camera.cull_mask = cull_mask
	camera.position = Vector3(anchor_world.x, anchor_world.y + 200.0, anchor_world.z)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	var environment: Environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	camera.environment = environment
	viewport.add_child(camera)
	camera.current = true
	return viewport


func _sample_sensor_pixels(viewport: SubViewport, lattice_radius: float, emission_radius: float) -> Dictionary:
	## Reads the telemetry encoding published by the real sensor shader:
	##   r = activity band (>= trigger / > rearm / <= rearm), g = latch,
	##   b = emit(1.0) / rearm(0.5) this frame. A pixel with r=g=b=0 is the
	##   cleared background, not a sensor.
	var image: Image = viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return {}
	var result: Dictionary = {
		"sensor_pixels": 0,
		"eligible_pixels": 0,
		"mid_pixels": 0,
		"latched_pixels": 0,
		"emit_pixels": 0,
		"rearm_pixels": 0,
		"eligible_in_footprint_pixels": 0,
		"eligible_outside_footprint_pixels": 0,
		"emit_in_footprint_pixels": 0,
	}
	var width: int = image.get_width()
	var height: int = image.get_height()
	var world_half_span: float = lattice_radius * 1.1
	for y: int in height:
		for x: int in width:
			var pixel: Color = image.get_pixel(x, y)
			if pixel.r <= 0.001 and pixel.g <= 0.001 and pixel.b <= 0.001:
				continue
			result["sensor_pixels"] = int(result["sensor_pixels"]) + 1
			var centered: Vector2 = Vector2((float(x) + 0.5) / float(width), (float(y) + 0.5) / float(height)) * 2.0 - Vector2.ONE
			var in_footprint: bool = centered.length() * world_half_span <= emission_radius
			var eligible: bool = pixel.r >= 0.9
			if eligible:
				result["eligible_pixels"] = int(result["eligible_pixels"]) + 1
				if in_footprint:
					result["eligible_in_footprint_pixels"] = int(result["eligible_in_footprint_pixels"]) + 1
				else:
					result["eligible_outside_footprint_pixels"] = int(result["eligible_outside_footprint_pixels"]) + 1
			elif pixel.r > 0.4:
				result["mid_pixels"] = int(result["mid_pixels"]) + 1
			if pixel.g >= 0.5:
				result["latched_pixels"] = int(result["latched_pixels"]) + 1
			if pixel.b >= 0.9:
				result["emit_pixels"] = int(result["emit_pixels"]) + 1
				if in_footprint:
					result["emit_in_footprint_pixels"] = int(result["emit_in_footprint_pixels"]) + 1
			elif pixel.b > 0.4:
				result["rearm_pixels"] = int(result["rearm_pixels"]) + 1
	return result


func _sample_child_pixels(viewport: SubViewport) -> int:
	if viewport == null:
		return 0
	var image: Image = viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return 0
	var count: int = 0
	for y: int in image.get_height():
		for x: int in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.a > 0.05 and pixel.r + pixel.g + pixel.b > 0.03:
				count += 1
	return count


func _cleanup_sensor_observation(sensor_viewports: Array, child_viewport: SubViewport, probe_viewport: SubViewport, saved_layers: Array[Dictionary], saved_draw_passes: Array[Dictionary], process_materials: Array) -> void:
	for entry: Dictionary in saved_layers:
		var sensor: GPUParticles3D = entry.get("sensor") as GPUParticles3D
		var visible_layer: GPUParticles3D = entry.get("visible") as GPUParticles3D
		if sensor != null:
			sensor.layers = int(entry.get("sensor_layers", sensor.layers))
		if visible_layer != null:
			visible_layer.layers = int(entry.get("visible_layers", visible_layer.layers))
	for entry: Dictionary in saved_draw_passes:
		var sensor: GPUParticles3D = entry.get("sensor") as GPUParticles3D
		if sensor != null:
			sensor.draw_passes = int(entry.get("draw_passes", sensor.draw_passes))
			sensor.draw_pass_1 = entry.get("draw_pass_1") as Mesh
	for value: Variant in process_materials:
		var process_material: ShaderMaterial = value as ShaderMaterial
		if process_material != null:
			process_material.set_shader_parameter(&"validation_telemetry", false)
	for viewport: SubViewport in sensor_viewports:
		if viewport != null:
			viewport.queue_free()
	if child_viewport != null:
		child_viewport.queue_free()
	if probe_viewport != null:
		probe_viewport.queue_free()


func _run_final_continuity_validation(p0: Node, ocean: Node, spindrift: Node) -> bool:
	_stage("final_continuity")
	var camera: Camera3D = p0.find_child(^"FreeCamera", true, false) as Camera3D
	if camera == null:
		return _fail("P0 FreeCamera is missing for final continuity validation")
	var state: Dictionary = _spindrift_state(ocean)
	if not _validate_dynamic_visibility(spindrift, state):
		return false
	# The distribution and the lattices changed, so the soak is measured again
	# instead of reusing an older graphical result.
	var soak: Dictionary = await _run_sensor_observation(ocean, spindrift, SOAK_SECONDS, "120S_SOAK")
	if not _judge_sensor_observation(soak, true):
		return false
	if not _judge_sustained_soak(soak):
		return false
	return await _run_final_camera_route(p0, ocean, spindrift)


func _judge_sustained_soak(soak: Dictionary) -> bool:
	if not (soak.get("child_windows", []) is Array):
		return _fail("Sustained soak did not report per-window child output")
	var windows: Array = soak.get("child_windows", []) as Array
	if windows.size() < 6:
		return _fail("Sustained soak produced only %d windows" % windows.size())
	var early_output: int = 0
	var late_output: int = 0
	var early_emit: int = 0
	var late_emit: int = 0
	for index: int in 3:
		early_output += int(windows[index])
		late_output += int(windows[windows.size() - 1 - index])
	var layers: Array = soak.get("layers", []) as Array
	for index: int in 3:
		var stats: Dictionary = layers[index] as Dictionary
		if float(stats.get("last_emit_s", -1.0)) >= SOAK_SECONDS - 3.0 * SOAK_WINDOW_SECONDS:
			late_emit += 1
		if float(stats.get("first_emit_s", -1.0)) >= 0.0 and float(stats.get("first_emit_s", 0.0)) <= 3.0 * SOAK_WINDOW_SECONDS:
			early_emit += 1
	print("SPINDRIFT 120S SOAK | windows=%s early_output_samples=%d late_output_samples=%d early_emit_layers=%d late_emit_layers=%d rearm_samples=%d" % [
		windows, early_output, late_output, early_emit, late_emit, int(soak.get("rearm_samples_total", 0))])
	if int(soak.get("child_output_samples", 0)) <= 0:
		print("SPINDRIFT_CHILD_POOL_EXHAUSTED")
		return _fail("120 s stationary soak never drew a detached child")
	if early_output <= 0 or late_output <= 0:
		print("SPINDRIFT_CHILD_POOL_EXHAUSTED")
		return _fail("120 s soak lost child output: early=%d late=%d windows=%s" % [early_output, late_output, windows])
	if late_emit <= 0:
		print("SPINDRIFT_NO_NEW_SENSOR_EVENT_AFTER_LIFETIMES")
		return _fail("No sensor emitted in the last %d s of the soak, so recycling was not observed" % int(3.0 * SOAK_WINDOW_SECONDS))
	print("SPINDRIFT_120S_SOAK_MEASURED")
	print("OCEAN_SPINDRIFT_CHILD_POOL_RECYCLE_PASS")
	print("OCEAN_SPINDRIFT_SUSTAINED_OUTPUT_120S_PASS")
	return true


func _run_final_camera_route(p0: Node, ocean: Node, spindrift: Node) -> bool:
	_stage("camera_route")
	var camera: Camera3D = p0.find_child(^"FreeCamera", true, false) as Camera3D
	if camera == null:
		return _fail("P0 FreeCamera is missing for the camera route")
	var initial_position: Vector3 = camera.global_position
	var initial_xz: Vector2 = Vector2(initial_position.x, initial_position.z)
	var initial_state: Dictionary = _spindrift_state(ocean)
	var initial_recenter_count: int = int(initial_state.get("sensor_recenter_count", 0))
	var route: Array[float] = [0.0, 100.0, 250.0, 500.0, 700.0, 500.0, 250.0, 0.0]
	for distance_m: float in route:
		if not await _move_camera_to(camera, initial_position, initial_xz + Vector2(distance_m, 0.0), ocean, spindrift):
			return false
	var returned_state: Dictionary = _spindrift_state(ocean)
	if int(returned_state.get("sensor_recenter_count", 0)) <= initial_recenter_count:
		return _fail("Sensor anchor did not recenter during the camera route")
	if not is_zero_approx(Vector2(camera.global_position.x, camera.global_position.z).distance_to(initial_xz)):
		return _fail("Camera route did not return to its world origin")
	var returned_anchor_value: Variant = returned_state.get("source_region_center_world", Vector2.INF)
	if not returned_anchor_value is Vector2:
		return _fail("Sensor anchor diagnostic is missing after the camera route")
	var returned_anchor: Vector2 = returned_anchor_value
	if returned_anchor.distance_to(initial_xz) > float(returned_state.get("sensor_recenter_distance_m", 1.0)) + 1.0:
		return _fail("Sensor anchor did not return with the camera")
	print("OCEAN_SPINDRIFT_DYNAMIC_VISIBILITY_AABB_PASS")
	print("OCEAN_SPINDRIFT_SENSOR_ANCHOR_PASS")
	print("OCEAN_SPINDRIFT_CAMERA_FOLLOW_PASS")
	print("OCEAN_SPINDRIFT_WORLD_ORIGIN_INDEPENDENCE_PASS")

	# Distant hold: moved 700 m away, then stay there. A Crest probe over
	# arbitrary texels cannot promise an event here, so the window only fails if
	# a real sensor emitted without a child, or a child appeared with no sensor
	# event at all. The pass line is printed only when the window measured it.
	if not await _move_camera_to(camera, initial_position, initial_xz + Vector2(700.0, 0.0), ocean, spindrift):
		return false
	var distant: Dictionary = await _run_sensor_observation(ocean, spindrift, 20.0, "DISTANT_700M_HOLD")
	if not _judge_sensor_observation(distant, false):
		return false
	_report_measured_observation(distant, "OCEAN_SPINDRIFT_DISTANT_REGION_EMISSION_PASS", "SPINDRIFT_DISTANT_HOLD_NO_SENSOR_EVENT")
	# Return to the world origin and keep observing.
	if not await _move_camera_to(camera, initial_position, initial_xz, ocean, spindrift):
		return false
	var returned: Dictionary = await _run_sensor_observation(ocean, spindrift, 10.0, "RETURN_ORIGIN_HOLD")
	if not _judge_sensor_observation(returned, false):
		return false
	_report_measured_observation(returned, "OCEAN_SPINDRIFT_RETURN_ORIGIN_CONTINUITY_PASS", "SPINDRIFT_RETURN_ORIGIN_NO_SENSOR_EVENT")
	if not await _run_periodic_distant_equivalence(ocean, spindrift, camera, initial_position, initial_xz):
		return false
	print("OCEAN_SPINDRIFT_FINAL_CAMERA_CONTINUITY_PASS")
	return true


func _report_measured_observation(observed: Dictionary, pass_line: String, no_event_line: String) -> void:
	var emitted: bool = int(observed.get("emit_samples_total", 0)) > 0
	var eligible: bool = int(observed.get("eligible_samples_total", 0)) > 0
	var child: bool = int(observed.get("child_output_samples", 0)) > 0
	if emitted and child:
		print(pass_line)
		return
	print("%s | eligible_samples=%d emit_samples=%d child_output_samples=%d" % [
		no_event_line, int(observed.get("eligible_samples_total", 0)), int(observed.get("emit_samples_total", 0)), int(observed.get("child_output_samples", 0))])
	if eligible and not emitted:
		print("SPINDRIFT_ELIGIBLE_SENSOR_WITHOUT_EMISSION")


func _move_camera_to(camera: Camera3D, initial_position: Vector3, destination: Vector2, ocean: Node, spindrift: Node) -> bool:
	while Vector2(camera.global_position.x, camera.global_position.z).distance_to(destination) > 0.25:
		var current: Vector2 = Vector2(camera.global_position.x, camera.global_position.z)
		var next: Vector2 = current.move_toward(destination, CAMERA_FOLLOW_STEP_M)
		camera.global_position = Vector3(next.x, initial_position.y, next.y)
		await get_tree().process_frame
		if not _validate_dynamic_visibility(spindrift, _spindrift_state(ocean)):
			return false
	camera.global_position = Vector3(destination.x, initial_position.y, destination.y)
	await get_tree().process_frame
	return _validate_dynamic_visibility(spindrift, _spindrift_state(ocean))


func _run_periodic_distant_equivalence(ocean: Node, spindrift: Node, camera: Camera3D, initial_position: Vector3, initial_xz: Vector2) -> bool:
	_stage("periodic_distant_equivalence")
	var open_ocean: Node = ocean.get("_open_ocean") as Node
	if open_ocean == null or not open_ocean.has_method(&"get_spindrift_sources"):
		return _fail("OpenOceanFFT source packet is missing for periodic distant equivalence")
	var sources: Dictionary = open_ocean.call("get_spindrift_sources") as Dictionary
	var domains_value: Variant = sources.get("domains", Vector3(LONG_DOMAIN_M, 137.0, 37.0))
	var domains: Vector3 = domains_value if domains_value is Vector3 else Vector3(LONG_DOMAIN_M, 137.0, 37.0)
	if absf(float(domains.x) - LONG_DOMAIN_M) > 0.001:
		return _fail("Periodic distant equivalence requires a 512 m LONG domain")
	if absf(LONG_PERIOD_M / LONG_DOMAIN_M - 5.0) > 0.0001 or absf(LONG_PERIOD_M / SENSOR_GRID_PERIOD_M - 1024.0) > 0.0001:
		return _fail("Periodic distant equivalence constants are not exact")
	# Same-frame spatial invariant: the LONG band is exactly periodic over
	# 2560 m (5 x 512 m). Both probes are read from the live texture in the same
	# frame, so FFT evolution between snapshots cannot confound the test.
	if not await _run_long_band_periodicity(ocean, initial_xz):
		return false
	var origin_state: Dictionary = _spindrift_state(ocean)
	camera.global_position = Vector3(initial_xz.x + LONG_PERIOD_M, initial_position.y, initial_xz.y)
	await _wait_runtime_frames(4)
	var distant_state: Dictionary = _spindrift_state(ocean)
	for key: String in ["source_ready", "active_layers", "sensor_distribution", "sensor_distribution_rule", "world_cell_identity", "sensor_grid_cell_m", "sensor_layer_amounts", "visible_layer_capacities", "visible_layer_lifetimes", "layer_emission_radius_m", "layer_sensor_radius_m", "sensor_anchor_drift_margin_m"]:
		if origin_state.get(key) != distant_state.get(key):
			camera.global_position = Vector3(initial_xz.x, initial_position.y, initial_xz.y)
			return _fail("Periodic sensor structure mismatch for %s: origin=%s distant=%s" % [key, origin_state.get(key), distant_state.get(key)])
	var origin_anchor_value: Variant = origin_state.get("sensor_anchor_world", Vector3.INF)
	var distant_anchor_value: Variant = distant_state.get("sensor_anchor_world", Vector3.INF)
	if not origin_anchor_value is Vector3 or not distant_anchor_value is Vector3:
		camera.global_position = Vector3(initial_xz.x, initial_position.y, initial_xz.y)
		return _fail("Periodic sensor anchor diagnostics are missing")
	var origin_anchor := Vector2((origin_anchor_value as Vector3).x, (origin_anchor_value as Vector3).z)
	var distant_anchor := Vector2((distant_anchor_value as Vector3).x, (distant_anchor_value as Vector3).z)
	var grid: float = float(distant_state.get("sensor_grid_cell_m", SENSOR_GRID_PERIOD_M))
	var margin: float = float(distant_state.get("sensor_recenter_distance_m", 0.0)) + 2.0 * grid
	# The anchor is a lattice cell snapped from the camera position at the last
	# recenter, so it is not a rigid translation of the camera. The invariants
	# that must hold at every world origin are: the anchor sits on the sensor
	# lattice, and the camera stays inside the recenter contract of its anchor.
	for anchor: Vector2 in [origin_anchor, distant_anchor]:
		if absf(fposmod(anchor.x, grid)) > 0.001 or absf(fposmod(anchor.y, grid)) > 0.001:
			camera.global_position = Vector3(initial_xz.x, initial_position.y, initial_xz.y)
			return _fail("Periodic sensor anchor is not aligned to the %.3f m sensor lattice: %s" % [grid, anchor])
	var anchor_follow: float = distant_anchor.distance_to(origin_anchor + Vector2(LONG_PERIOD_M, 0.0))
	if anchor_follow > margin:
		camera.global_position = Vector3(initial_xz.x, initial_position.y, initial_xz.y)
		return _fail("Periodic sensor anchor did not follow the 2560 m translation within the recenter contract: delta=%.3f limit=%.3f" % [anchor_follow, margin])
	var distant_camera: Vector2 = Vector2(camera.global_position.x, camera.global_position.z)
	var origin_relative: Vector2 = initial_xz - origin_anchor
	var distant_relative: Vector2 = distant_camera - distant_anchor
	if origin_relative.length() > margin or distant_relative.length() > margin:
		camera.global_position = Vector3(initial_xz.x, initial_position.y, initial_xz.y)
		return _fail("Periodic sensor lattice left the recenter contract: origin=%.3f distant=%.3f limit=%.3f" % [origin_relative.length(), distant_relative.length(), margin])
	# The far origin is not a candidate for a promise about Crest G, because the
	# MID/SHORT bands are not periodic over 2560 m. Structure is asserted; child
	# output is only required when a real sensor actually emitted.
	var distant_window: Dictionary = await _run_sensor_observation(ocean, spindrift, 10.0, "PERIODIC_DISTANT_2560M")
	if not _judge_sensor_observation(distant_window, false):
		camera.global_position = Vector3(initial_xz.x, initial_position.y, initial_xz.y)
		return false
	camera.global_position = Vector3(initial_xz.x, initial_position.y, initial_xz.y)
	await _wait_runtime_frames(3)
	print("SPINDRIFT PERIODIC STRUCTURE | origin_anchor=%s distant_anchor=%s distant_child_output_samples=%d distant_emit_samples=%d" % [
		origin_anchor, distant_anchor, int(distant_window.get("child_output_samples", 0)), int(distant_window.get("emit_samples_total", 0))])
	if int(distant_window.get("emit_samples_total", 0)) <= 0:
		print("SPINDRIFT_PERIODIC_DISTANT_NO_SENSOR_EVENT")
	print("OCEAN_SPINDRIFT_PERIODIC_DISTANT_EQUIVALENCE_PASS")
	return true


func _run_long_band_periodicity(ocean: Node, origin_xz: Vector2) -> bool:
	_stage("long_band_periodicity")
	var open_ocean: Node = ocean.get("_open_ocean") as Node
	if open_ocean == null or not open_ocean.has_method(&"get_spindrift_sources"):
		return _fail("OpenOceanFFT source packet is missing for the LONG band periodicity probe")
	var sources: Dictionary = open_ocean.call("get_spindrift_sources") as Dictionary
	var source_texture: Texture2D = sources.get("displacement_long") as Texture2D
	if not bool(sources.get("ready", false)) or source_texture == null:
		return _fail("LONG displacement texture is not available for the periodicity probe")
	var domains_value: Variant = sources.get("domains", Vector3(LONG_DOMAIN_M, 137.0, 37.0))
	var domains: Vector3 = domains_value if domains_value is Vector3 else Vector3(LONG_DOMAIN_M, 137.0, 37.0)
	var viewport: SubViewport = SubViewport.new()
	viewport.size = Vector2i(CREST_PROBE_SIZE, CREST_PROBE_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.transparent_bg = false
	add_child(viewport)
	var rect: ColorRect = ColorRect.new()
	rect.size = Vector2(CREST_PROBE_SIZE, CREST_PROBE_SIZE)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = PERIODICITY_PROBE_SHADER
	material.set_shader_parameter(&"displacement_long", source_texture)
	material.set_shader_parameter(&"origin_xz", origin_xz)
	material.set_shader_parameter(&"period_m", LONG_PERIOD_M)
	material.set_shader_parameter(&"domain_long_m", domains.x)
	material.set_shader_parameter(&"sample_span_m", float(FINAL_PRODUCTION_LOD[1]))
	rect.material = material
	viewport.add_child(rect)
	await _wait_runtime_frames(3)
	var image: Image = viewport.get_texture().get_image()
	if image == null or image.is_empty():
		viewport.queue_free()
		return _fail("LONG band periodicity probe produced no image")
	var maximum_delta: float = 0.0
	var minimum_sample: float = 1.0e9
	var maximum_sample: float = -1.0e9
	for y: int in image.get_height():
		for x: int in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			maximum_delta = maxf(maximum_delta, pixel.r)
			minimum_sample = minf(minimum_sample, pixel.g)
			maximum_sample = maxf(maximum_sample, pixel.g)
	viewport.queue_free()
	print("SPINDRIFT LONG BAND PERIODICITY | period_m=%.1f domain_m=%.1f max_absolute_delta=%.6f sample_range=%.4f" % [
		LONG_PERIOD_M, domains.x, maximum_delta, maximum_sample - minimum_sample])
	if maximum_sample - minimum_sample <= 0.001:
		return _fail("LONG band periodicity probe saw a degenerate (flat) wave field")
	if maximum_delta > 0.05:
		return _fail("LONG band is not periodic over %.1f m in the same frame: max delta %.6f" % [LONG_PERIOD_M, maximum_delta])
	print("OCEAN_SPINDRIFT_LONG_BAND_PERIODICITY_PASS")
	return true


func _fail(reason: String) -> bool:
	_failed = true
	push_error("OCEAN_SPINDRIFT_VALIDATION_FAIL: %s" % reason)
	return false


func _approximately_equal(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= SCALE_TOLERANCE


func _run_p7_smoke() -> bool:
	_stage("p7_smoke")
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
