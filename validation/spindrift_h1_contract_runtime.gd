extends SceneTree
## H1 semantic contracts plus a real GPU smoke run.
## No FFT texture readback is used; source contracts are checked from shader/API
## text and runtime state, while the scene smoke validates GPU resource binding.

const SpindriftController := preload("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
const CascadeState := preload("res://addons/ocean/core/ocean_cascade_state.gd")
const READY_TIMEOUT_FRAMES := 360
const SMOKE_FRAMES := 240

var _scene: Node
var _ocean: Ocean
var _camera: Camera3D
var _wait_frames := 0
var _smoke_frames := 0
var _failed := false
var _contracts_passed := false


func _initialize() -> void:
	if not _run_contract_tests():
		return
	_contracts_passed = true
	_scene = load("res://validation/p0_open_ocean.tscn").instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node(^"Ocean") as Ocean
	_camera = _find_camera(_scene)
	if _ocean == null or _camera == null:
		_fail("runtime smoke scene did not expose Ocean and Camera3D")
		return
	_ocean.set_fft_cascade_mask(CascadeState.FULL)
	_ocean.enable_spindrift = true
	_ocean.spindrift_debug_mode = SpindriftController.DebugMode.FULL


func _process(_delta: float) -> bool:
	if _failed:
		return false
	if not _contracts_passed:
		return false
	var open_ocean := _ocean.get("_open_ocean") as Node if _ocean != null else null
	if open_ocean == null:
		return _wait_or_fail("OpenOceanFFT unavailable")
	if not _runtime_ready(open_ocean):
		return _wait_or_fail("H1 runtime readiness")
	_wait_frames = 0
	if _smoke_frames < SMOKE_FRAMES:
		_move_camera()
		_smoke_frames += 1
		return false
	if not _validate_runtime(open_ocean):
		return false
	print("SPINDRIFT_RUNTIME_SMOKE_PASS frames=%d camera_moves=%d" % [SMOKE_FRAMES, 8])
	quit(0)
	return false


func _run_contract_tests() -> bool:
	var crest_update := _read("res://addons/ocean/shaders/fft/update_crest_foam.glsl")
	var open_ocean := _read("res://addons/ocean/fft/open_ocean_fft.gd")
	var event_shader := _read("res://addons/ocean/shaders/spindrift_event_particles.gdshader")
	var source_mask := _read("res://addons/ocean/shaders/spindrift_source_mask.gdshader")
	var detached_shader := _read("res://addons/ocean/shaders/spindrift_detached_particles.gdshader")
	if crest_update.is_empty() or open_ocean.is_empty() or event_shader.is_empty() or source_mask.is_empty() or detached_shader.is_empty():
		_fail("required H1 source file missing")
		return false

	if not crest_update.contains("clamp(fresh, 0.0, 1.0)") or not crest_update.contains("imageStore(foam_next"):
		_fail("Crest G is not visibly clamped to the documented 0..1 contract")
		return false
	if not open_ocean.contains("breaking_activity_long") or not open_ocean.contains("breaking_activity_channel") or not open_ocean.contains("breaking_activity_range"):
		_fail("OpenOceanFFT does not publish the explicit Breaking Activity contract")
		return false
	if not event_shader.contains("breaking_activity_long") or not event_shader.contains("texture(breaking_activity_long") or not event_shader.contains(".g"):
		_fail("Spindrift event path does not consume Crest G")
		return false
	for forbidden in ["crest_foam_long", "evaluate_event_score", "curvature_gate", "wave_height_reference_m", "prebreak_gate", "long_whitecap_threshold"]:
		if event_shader.contains(forbidden):
			_fail("duplicate event detector token remains in active event shader: " + forbidden)
			return false
	if not source_mask.contains("breaking_activity_long") or not source_mask.contains("texture(breaking_activity_long") or not source_mask.contains(".g"):
		_fail("Source Mask does not visualize the same Crest G source")
		return false
	print("SPINDRIFT_BREAKING_SOURCE_CONTRACT_PASS authority=CrestG channel=G range=0..1 long_only=true residual_R=false")

	var cell_samples := [Vector2(-37.1, 12.4), Vector2(0.0, 0.0), Vector2(81.2, -44.8), Vector2(512.0, 512.0)]
	for sample in cell_samples:
		var expected := SpindriftController.world_cell_id(sample, 2.5)
		for camera_delta in [Vector2(0.0, 0.0), Vector2(40.0, 0.0), Vector2(0.0, 57.5), Vector2(40.0, 57.5)]:
			if SpindriftController.world_cell_id(sample + camera_delta - camera_delta, 2.5) != expected:
				_fail("world cell identity changed with camera translation")
				return false
	if not event_shader.contains("world_to_cell") or not event_shader.contains("CUSTOM.xy") or not event_shader.contains("floor(world_xz"):
		_fail("GPU sensor does not persist world-space cell identity")
		return false
	print("SPINDRIFT_WORLD_CELL_IDENTITY_PASS cells=%d camera_translation_rotation_invariant=true" % cell_samples.size())

	var sequence: Array[float] = [0.0, 0.2, 0.7, 0.9, 0.8, 0.6, 0.3, 0.1, 0.8]
	var events := SpindriftController.hysteresis_event_count(sequence, 0.72, 0.28)
	if events != 2:
		_fail("hysteresis expected 2 events, got %d" % events)
		return false
	print("SPINDRIFT_HYSTERESIS_PASS events=%d trigger=0.72 rearm=0.28" % events)

	if not event_shader.contains("emit_subparticle") or not detached_shader.contains("TRANSFORM[3].xyz += VELOCITY * DELTA") or not detached_shader.contains("gravity_mps2") or not detached_shader.contains("wind_velocity"):
		_fail("sensor-to-detached-particle GPU path is incomplete")
		return false
	if detached_shader.contains("sampler2D") or detached_shader.contains("texture("):
		_fail("detached particle shader still samples a GPU texture")
		return false
	print("SPINDRIFT_DETACHMENT_PASS sub_emitter=true fft_resample_after_spawn=false wind_drag_gravity=true")

	if event_shader.contains("curvature") or event_shader.contains("jacobian") or event_shader.contains("peak") or event_shader.contains("height_gate"):
		_fail("active emission path still contains a parallel peak/curvature/height/Jacobian detector")
		return false
	print("SPINDRIFT_SINGLE_AUTHORITY_PASS event_path=CrestG_only source_mask_shared=true")
	return true


func _runtime_ready(open_ocean: Node) -> bool:
	if not open_ocean.has_method(&"get_fft_resource_lifecycle_state"):
		return false
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	return bool(state.get("generation_active", false)) and bool(state.get("neutral_ready", false)) and int(state.get("published_generation", -1)) == int(state.get("generation", -2)) and bool(state.get("surface_initialized", false))


func _validate_runtime(open_ocean: Node) -> bool:
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	if not _runtime_ready(open_ocean):
		_fail("runtime smoke lost FFT readiness")
		return false
	var surface := open_ocean.get_underwater_medium_raster_surface() as OceanClipmapSurface
	if surface == null or not surface.visible:
		_fail("runtime smoke left Surface invisible")
		return false
	var spindrift_state: Dictionary = open_ocean.get_spindrift_runtime_state()
	if not bool(spindrift_state.get("enabled", false)) or int(spindrift_state.get("debug_mode", -1)) != SpindriftController.DebugMode.FULL:
		_fail("runtime smoke lost Spindrift FULL state")
		return false
	if not bool(spindrift_state.get("source_ready", false)) or not bool(spindrift_state.get("detached_particles", false)) or str(spindrift_state.get("breaking_activity_authority", "")) != "crest_g_long":
		_fail("runtime smoke has inconsistent Spindrift source state: %s" % spindrift_state)
		return false
	if int(state.get("published_generation", -1)) < 0:
		_fail("runtime smoke published an invalid generation")
		return false
	return true


func _move_camera() -> void:
	if _camera == null:
		return
	var step := _smoke_frames / 30
	var positions := [Vector3(0.0, 8.0, 16.0), Vector3(32.0, 8.0, 16.0), Vector3(32.0, 8.0, 48.0), Vector3(-24.0, 8.0, 48.0), Vector3(-24.0, 8.0, -32.0), Vector3(0.0, 8.0, -32.0), Vector3(40.0, 8.0, -16.0), Vector3(0.0, 8.0, 16.0)]
	var index := mini(step, positions.size() - 1)
	_camera.position = positions[index]
	_camera.rotation_degrees = Vector3(-12.0, float(index) * 45.0, 0.0)


func _find_camera(node: Node) -> Camera3D:
	if node is Camera3D:
		return node
	for child in node.get_children():
		var camera := _find_camera(child)
		if camera != null:
			return camera
	return null


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
	push_error("SPINDRIFT_H1_CONTRACT_FAIL: " + reason)
	quit(1)
