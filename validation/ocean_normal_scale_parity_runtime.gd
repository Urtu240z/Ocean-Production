extends SceneTree
## H2.2 runtime contract test. Scale presentation only; FFT generations and
## GPU resources must remain unchanged while the exact V/H sequence is applied.

const SCALE_SEQUENCE := [
	Vector2(1.0, 1.0),
	Vector2(1.0, 0.5),
	Vector2(1.0, 2.0),
	Vector2(0.5, 1.0),
	Vector2(2.0, 1.0),
	Vector2(0.5, 0.5),
	Vector2(2.0, 2.0),
	Vector2(1.0, 1.0),
]
const SEQUENCES := 3
const STABILIZATION_FRAMES := 8
const READY_TIMEOUT_FRAMES := 240
const BASE_WAVE_DOMAINS := Vector3(512.0, 137.0, 37.0)
const NORMAL_EPSILON := 0.00001
const NORMAL_DOT_TOLERANCE := 0.99999

var _scene: Node
var _ocean: Ocean
var _stage := 0
var _sequence := 0
var _stage_frames := 0
var _wait_frames := 0
var _initial_generation := -1
var _failed := false


func _initialize() -> void:
	if not _normal_math_tests():
		return
	if not _source_contract_tests():
		return
	_scene = load("res://validation/p0_open_ocean.tscn").instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node(^"Ocean") as Ocean
	if _ocean == null:
		_fail("H2.2 scene/Ocean unavailable")


func _process(_delta: float) -> bool:
	if _failed:
		return false
	var open_ocean := _ocean.get("_open_ocean") as Node if _ocean != null else null
	if open_ocean == null:
		return _wait_or_fail("OpenOceanFFT startup")
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	if not bool(state.get("generation_active", false)) or not bool(state.get("neutral_ready", false)) or not bool(state.get("surface_initialized", false)):
		return _wait_or_fail("H2.2 initial GPU readiness")
	if _initial_generation < 0:
		_initial_generation = int(state.get("generation", -1))
		if _initial_generation < 0:
			_fail("H2.2 initial generation unavailable")
			return false
	if _stage_frames == 0:
		var scale_v_h: Vector2 = SCALE_SEQUENCE[_stage]
		_ocean.ocean_scale = scale_v_h.x
		_ocean.clipmap_geometry_scale = scale_v_h.y
	if not _validate_frame_contract(open_ocean):
		return false
	_stage_frames += 1
	if _stage_frames < STABILIZATION_FRAMES:
		return false
	_stage_frames = 0
	_stage += 1
	if _stage >= SCALE_SEQUENCE.size():
		_stage = 0
		_sequence += 1
	if _sequence >= SEQUENCES:
		_ocean.ocean_scale = 1.0
		_ocean.clipmap_geometry_scale = 1.0
		print("OCEAN_NORMAL_RUNTIME_SCALE_SEQUENCE_PASS stages=%d sequences=%d generation=%d" % [SCALE_SEQUENCE.size(), SEQUENCES, _initial_generation])
		quit(0)
	return false


func _validate_frame_contract(open_ocean: Node) -> bool:
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	var generation := int(state.get("generation", -1))
	if generation != _initial_generation:
		_fail("FFT generation changed during scale-only sequence: expected=%d actual=%d" % [_initial_generation, generation])
		return false
	if int(state.get("published_generation", -1)) != generation:
		_fail("published generation diverged during scale-only sequence: %s" % state)
		return false
	if not bool(state.get("neutral_ready", false)) or not bool(state.get("surface_initialized", false)):
		_fail("GPU readiness regressed during scale-only sequence: %s" % state)
		return false
	for band in state.get("bands", []):
		for key in ["displacement_valid", "normal_valid", "crest_valid"]:
			if not bool(band.get(key, false)):
				_fail("invalid FFT RID during scale-only sequence: %s" % band)
				return false
		if int(band.get("solver_generation", -1)) != generation or int(band.get("published_generation", -1)) != generation:
			_fail("old FFT generation visible during scale-only sequence: %s" % band)
			return false
		if not String(band.get("solver_error", "")).is_empty():
			_fail("FFT lifecycle error during scale-only sequence: %s" % band)
			return false
	var surface := open_ocean.get_underwater_medium_raster_surface() as OceanClipmapSurface
	if surface == null or not surface.visible:
		_fail("Surface became invisible during normal scale sequence")
		return false
	var scale_v_h: Vector2 = SCALE_SEQUENCE[_stage]
	var actual_scales := surface.get_effective_ocean_space_scales()
	var expected_scales := Vector2(scale_v_h.y, scale_v_h.x)
	if not actual_scales.is_equal_approx(expected_scales):
		_fail("Surface normal scale contract diverged: expected H/V=%s actual=%s" % [expected_scales, actual_scales])
		return false
	var actual_domains := surface.get_effective_wave_domains()
	var expected_domains := BASE_WAVE_DOMAINS * scale_v_h.y
	if not actual_domains.is_equal_approx(expected_domains):
		_fail("Surface domains changed independently of H: expected=%s actual=%s" % [expected_domains, actual_domains])
		return false
	return true


func _normal_math_tests() -> bool:
	var authored_normal := Vector3(0.42, 0.86, -0.21).normalized()
	for scale_v_h in SCALE_SEQUENCE:
		var vertical: float = scale_v_h.x
		var horizontal: float = scale_v_h.y
		var expected: Vector3 = Vector3(authored_normal.x / horizontal, authored_normal.y / vertical, authored_normal.z / horizontal).normalized()
		var transformed := _scale_normal(authored_normal, horizontal, vertical)
		if transformed.dot(expected) < NORMAL_DOT_TOLERANCE:
			_fail("inverse-transpose normal math mismatch at V/H=%s" % scale_v_h)
			return false
		var source_slope: float = Vector2(authored_normal.x, authored_normal.z).length() / maxf(abs(authored_normal.y), NORMAL_EPSILON)
		var transformed_slope: float = Vector2(transformed.x, transformed.z).length() / maxf(abs(transformed.y), NORMAL_EPSILON)
		if not is_equal_approx(transformed_slope / source_slope, vertical / horizontal):
			_fail("normal slope ratio mismatch at V/H=%s" % scale_v_h)
			return false
	print("OCEAN_NORMAL_SCALE_MATH_PASS")
	print("OCEAN_NORMAL_SLOPE_RATIO_PASS")
	var tangent_x := Vector3(1.12, 0.35, 0.08)
	var tangent_z := Vector3(0.05, -0.22, 1.18)
	var source_geometry_normal := tangent_z.cross(tangent_x).normalized()
	for scale_v_h in SCALE_SEQUENCE:
		var vertical: float = scale_v_h.x
		var horizontal: float = scale_v_h.y
		var scaled_tangent_x: Vector3 = Vector3(tangent_x.x * horizontal, tangent_x.y * vertical, tangent_x.z * horizontal)
		var scaled_tangent_z: Vector3 = Vector3(tangent_z.x * horizontal, tangent_z.y * vertical, tangent_z.z * horizontal)
		var geometry_normal: Vector3 = scaled_tangent_z.cross(scaled_tangent_x).normalized()
		if _scale_normal(source_geometry_normal, horizontal, vertical).dot(geometry_normal) < NORMAL_DOT_TOLERANCE:
			_fail("geometry/normal parity mismatch at V/H=%s" % scale_v_h)
			return false
	print("OCEAN_NORMAL_GEOMETRY_PARITY_PASS")
	return true


func _scale_normal(n: Vector3, horizontal: float, vertical: float) -> Vector3:
	var safe_horizontal: float = maxf(abs(horizontal), NORMAL_EPSILON)
	var safe_vertical: float = maxf(abs(vertical), NORMAL_EPSILON)
	var transformed: Vector3 = Vector3(n.x * safe_vertical / safe_horizontal, n.y, n.z * safe_vertical / safe_horizontal)
	return transformed.normalized() if transformed.length_squared() > NORMAL_EPSILON * NORMAL_EPSILON else Vector3.UP


func _source_contract_tests() -> bool:
	var surface := _read("res://addons/ocean/shaders/ocean_surface.gdshader")
	var surface_script := _read("res://addons/ocean/surface/ocean_clipmap_surface.gd")
	var spindrift_shader := _read("res://addons/ocean/shaders/spindrift_event_particles.gdshader")
	if surface.is_empty() or surface_script.is_empty() or spindrift_shader.is_empty():
		_fail("H2.2 source contract missing")
		return false
	for token in ["ocean_space_normal_to_world_scaled", "surface_displacement.xz *= clipmap_geometry_scale", "surface_displacement.y *= ocean_surface_scale"]:
		if not surface.contains(token):
			_fail("normal/geometry source token missing: " + token)
			return false
	for token in ["ocean_space_normal_to_world_scaled(texture(normal_long", "ocean_space_normal_to_world_scaled(texture(normal_mid", "ocean_space_normal_to_world_scaled(texture(normal_short"]:
		if not surface_script.contains(token) and not surface.contains(token):
			_fail("normal consumer source token missing: " + token)
			return false
	if not spindrift_shader.contains("clipmap_geometry_scale") or not spindrift_shader.contains("ocean_space_normal_to_world_scaled"):
		_fail("Spindrift normal scale contract missing")
		return false
	print("OCEAN_NORMAL_SOURCE_CONTRACT_PASS")
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
	push_error("OCEAN_NORMAL_SCALE_PARITY_FAIL: " + reason)
	quit(1)
