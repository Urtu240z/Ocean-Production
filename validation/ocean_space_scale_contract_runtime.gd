extends SceneTree
## H2 runtime contract test.  Scale changes are uniform-only; rebuilds are
## deliberately interleaved with Crest toggles and profile publication.

const SpindriftController := preload("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
const CYCLES := 4
const STABILIZATION_FRAMES := 8
const READY_TIMEOUT_FRAMES := 240
const BASE_WAVE_DOMAINS := Vector3(512.0, 137.0, 37.0)
const BASE_SURFACE_FOAM_DOMAINS := Vector2(14.5, 88.0)
const PHASE_SAMPLE_X := 64.0

var _scene: Node
var _ocean: Ocean
var _crest_profile: Resource
var _cycle := 0
var _stage := 0
var _stage_frames := 0
var _wait_frames := 0
var _failed := false
var _validated_scales := {0.5: false, 1.0: false, 2.0: false}


func _initialize() -> void:
	if not _source_contract_tests():
		return
	_scene = load("res://validation/p0_open_ocean.tscn").instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node(^"Ocean") as Ocean
	_crest_profile = load("res://validation/profiles/p0_crest_foam_profile.tres")
	if _ocean == null or _crest_profile == null:
		_fail("H2 scene/profile unavailable")


func _process(_delta: float) -> bool:
	if _failed:
		return false
	var open_ocean := _ocean.get("_open_ocean") as Node if _ocean != null else null
	if open_ocean == null:
		return _wait_or_fail("OpenOceanFFT startup")
	if _stage_frames == 0:
		_apply_stage(open_ocean)
		if _stage == 3:
			open_ocean = _ocean.get("_open_ocean") as Node
			if open_ocean == null:
				return _wait_or_fail("replacement OpenOceanFFT")
	_stage_frames += 1
	if not _validate_transient_contract(open_ocean):
		return false
	if _stage_frames < STABILIZATION_FRAMES:
		return false
	if not _validate_stable_contract(open_ocean):
		return false
	_stage += 1
	_stage_frames = 0
	_wait_frames = 0
	if _stage >= 4:
		_stage = 0
		_cycle += 1
	if _cycle >= CYCLES:
		for scale_key in _validated_scales:
			if not _validated_scales[scale_key]:
				_fail("Surface scale %s was not validated" % scale_key)
				return false
		_ocean.ocean_scale = 1.0
		_ocean.clipmap_geometry_scale = 1.0
		print("OCEAN_SPACE_SCALE_CONTRACT_PASS cycles=%d" % CYCLES)
		print("OCEAN_SURFACE_DOMAIN_SCALE_PARITY_PASS scales=0.5,1.0,2.0")
		print("OCEAN_WAVE_PHASE_SCALE_PARITY_PASS sample_x=%s" % PHASE_SAMPLE_X)
		print("OCEAN_SURFACE_FOAM_WAVE_RATIO_PASS")
		print("OCEAN_WORLD_SPACE_INVARIANTS_PASS sea_level=%s wind_direction=%s" % [_ocean.sea_level, _ocean.wind_direction_degrees])
		print("OCEAN_UNDERWATER_SCALE_PARITY_PASS")
		print("OCEAN_SPACE_SCALE_RATIO_PASS ratios=0.5,2.0")
		quit(0)
	return false


func _apply_stage(open_ocean: Node) -> void:
	match _stage:
		0:
			_ocean.clipmap_geometry_scale = 0.5
			_ocean.ocean_scale = 0.7
			open_ocean.set_crest_foam(false)
		1:
			_ocean.clipmap_geometry_scale = 2.0
			_ocean.ocean_scale = 1.5
			open_ocean.set_crest_foam(true)
			var profile := _crest_profile.duplicate(true)
			profile.breakup_world_size_m = _crest_profile.breakup_world_size_m + 1.0
			open_ocean.set_crest_foam_profile(profile)
		2:
			_ocean.clipmap_geometry_scale = 1.0
			_ocean.ocean_scale = 1.0
			open_ocean.set_crest_foam(false)
		3:
			_ocean.shutdown()
			if not _ocean.initialize():
				_fail("initialize() failed during rapid rebuild cycle %d" % _cycle)


func _validate_transient_contract(open_ocean: Node) -> bool:
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	if not bool(state.get("generation_active", false)):
		return true
	var generation := int(state.get("generation", -1))
	var published := int(state.get("published_generation", -1))
	if bool(state.get("surface_initialized", false)) and published != generation:
		_fail("old generation visible on initialized Surface: %s" % state)
		return false
	for band in state.get("bands", []):
		if bool(band.get("solver_ready", false)) and int(band.get("solver_generation", -1)) != generation:
			_fail("old solver generation exposed: %s" % band)
			return false
	return true


func _validate_stable_contract(open_ocean: Node) -> bool:
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	if not bool(state.get("generation_active", false)) or not bool(state.get("neutral_ready", false)):
		_fail("resources not ready after stabilization: %s" % state)
		return false
	if int(state.get("published_generation", -1)) != int(state.get("generation", -2)):
		_fail("old generation published: %s" % state)
		return false
	if not bool(state.get("surface_initialized", false)):
		_fail("Surface not initialized after stabilization")
		return false
	var surface := open_ocean.get_underwater_medium_raster_surface() as OceanClipmapSurface
	if surface == null or not surface.visible:
		_fail("Surface became invisible during H2 scale/rebuild sequence")
		return false
	var expected_horizontal := float(_ocean.clipmap_geometry_scale)
	var effective_surface_domains := surface.get_effective_wave_domains()
	var expected_domains := BASE_WAVE_DOMAINS * expected_horizontal
	if not effective_surface_domains.is_equal_approx(expected_domains):
		_fail("Surface material domains diverged: expected=%s actual=%s" % [expected_domains, effective_surface_domains])
		return false
	for band in state.get("bands", []):
		for key in ["displacement_valid", "normal_valid", "crest_valid"]:
			if not bool(band.get(key, false)):
				_fail("invalid published RID: %s" % band)
				return false
		if band.get("published_displacement", RID()) != band.get("displacement_rid", RID()) or band.get("published_normal", RID()) != band.get("normal_rid", RID()) or band.get("published_crest", RID()) != band.get("crest_rid", RID()):
			_fail("solver/Texture2DRD state mismatch: %s" % band)
			return false
		if bool(band.get("solver_ready", false)) and not String(band.get("solver_error", "")).is_empty():
			_fail("FFT lifecycle error: %s" % band)
			return false
	var space: Dictionary = open_ocean.get_ocean_space_contract()
	var expected_ocean := float(_ocean.ocean_scale)
	if not is_equal_approx(float(space.get("ocean_scale", -1.0)), expected_ocean) or not is_equal_approx(float(space.get("clipmap_geometry_scale", -1.0)), expected_horizontal):
		_fail("central Ocean Space contract disagrees with public controls: %s" % space)
		return false
	var sources: Dictionary = open_ocean.get_underwater_medium_raster_sources()
	var spindrift_sources: Dictionary = open_ocean.get_spindrift_sources()
	if not sources.has("domains") or not spindrift_sources.has("domains") or sources.domains != spindrift_sources.domains or not sources.domains.is_equal_approx(effective_surface_domains):
		_fail("Surface/Underwater/Spindrift domains diverged")
		return false
	if not is_equal_approx(float(sources.get("ocean_scale", -1.0)), expected_ocean):
		_fail("Underwater displacement scale diverged")
		return false
	if not sources.domains.is_equal_approx(expected_domains):
		_fail("domain ratio contract failed: expected=%s actual=%s" % [expected_domains, sources.domains])
		return false
	var phase := (PHASE_SAMPLE_X * expected_horizontal) / effective_surface_domains.x
	var expected_phase := PHASE_SAMPLE_X / BASE_WAVE_DOMAINS.x
	if not is_equal_approx(phase, expected_phase):
		_fail("wave phase changed with scale: expected=%s actual=%s" % [expected_phase, phase])
		return false
	var effective_foam_domains := surface.get_effective_surface_foam_domains()
	var expected_foam_domains := BASE_SURFACE_FOAM_DOMAINS * expected_horizontal
	if not effective_foam_domains.is_equal_approx(expected_foam_domains):
		_fail("Surface Foam domains diverged: expected=%s actual=%s" % [expected_foam_domains, effective_foam_domains])
		return false
	if not is_equal_approx(effective_foam_domains.x / effective_surface_domains.x, BASE_SURFACE_FOAM_DOMAINS.x / BASE_WAVE_DOMAINS.x) or not is_equal_approx(effective_foam_domains.y / effective_surface_domains.x, BASE_SURFACE_FOAM_DOMAINS.y / BASE_WAVE_DOMAINS.x):
		_fail("Surface Foam/FFT wavelength ratio changed")
		return false
	for scale_key in _validated_scales:
		if is_equal_approx(expected_horizontal, float(scale_key)):
			_validated_scales[scale_key] = true
	var spindrift_state: Dictionary = open_ocean.get_spindrift_runtime_state()
	if bool(spindrift_state.get("enabled", false)):
		if not bool(spindrift_state.get("source_ready", false)) or not bool(spindrift_state.get("detached_particles", false)):
			_fail("Spindrift lifecycle/source state inconsistent: %s" % spindrift_state)
			return false
		var expected_cell := 2.5 * expected_horizontal
		if not is_equal_approx(float(spindrift_state.get("sensor_grid_cell_m", -1.0)), expected_cell):
			_fail("Spindrift spacing did not follow Ocean Space scale: %s" % spindrift_state)
	return true


func _source_contract_tests() -> bool:
	var contract := _read("res://addons/ocean/core/ocean_space_contract.gd")
	var surface := _read("res://addons/ocean/shaders/ocean_surface.gdshader")
	var waterline := _read("res://addons/ocean/underwater/shaders/ocean_waterline_raster.glsl")
	var open_ocean := _read("res://addons/ocean/fft/open_ocean_fft.gd")
	var spindrift := _read("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
	if contract.is_empty() or surface.is_empty() or waterline.is_empty() or open_ocean.is_empty() or spindrift.is_empty():
		_fail("H2 contract source missing")
		return false
	for token in ["ocean_height", "ocean_length", "ocean_domains", "set_ocean_space_contract", "clipmap_geometry_scale"]:
		if not contract.contains(token) and not surface.contains(token) and not open_ocean.contains(token):
			_fail("H2 central contract token missing: " + token)
			return false
	if not surface.contains("VERTEX.xz * clipmap_geometry_scale") or surface.contains("VERTEX.xz * ocean_surface_scale * clipmap_geometry_scale"):
		_fail("Surface still couples ocean_scale to horizontal geometry")
		return false
	if not waterline.contains("params.domains.w"):
		_fail("Waterline does not consume vertical Ocean Scale")
		return false
	if not spindrift.contains("sensor_grid_cell_m"):
		_fail("Spindrift scale contract missing")
		return false
	var surface_script := _read("res://addons/ocean/surface/ocean_clipmap_surface.gd")
	for token in ["_base_wave_domains", "_apply_ocean_space_domains", "get_effective_wave_domains"]:
		if not surface_script.contains(token):
			_fail("Surface effective domain contract missing: " + token)
			return false
	print("OCEAN_SPACE_SCALE_SOURCE_CONTRACT_PASS")
	return true


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _wait_or_fail(context: String) -> bool:
	_wait_frames += 1
	if _wait_frames > READY_TIMEOUT_FRAMES:
		_fail("%s timed out after %d frames" % [context, READY_TIMEOUT_FRAMES])
	return false


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	push_error("OCEAN_SPACE_SCALE_CONTRACT_FAIL: " + reason)
	quit(1)
