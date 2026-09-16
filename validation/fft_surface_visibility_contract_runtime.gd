extends SceneTree
## Validates Surface presentation separately from the aggressive H0 race stress.
## Controlled rebuilds wait only on observable readiness, never on sleeps.

const SpindriftController := preload("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
const SPINDRIFT_PROFILE := preload("res://validation/profiles/p0_spindrift_profile.tres")
const CONTROLLED_REBUILDS := 8
const READY_TIMEOUT_FRAMES := 240


class MockProvider:
	extends Node3D

	var _clipmap_quality: Resource
	var _crest_foam_profile: Resource
	var _surface: Node3D

	func _init(initial_visible: bool) -> void:
		_surface = Node3D.new()
		_surface.name = &"OceanClipmapSurface"
		_surface.visible = initial_visible
		add_child(_surface)

	func get_spindrift_sources() -> Dictionary:
		return {"ready": false}

	func is_surface_initialized() -> bool:
		return true


var _scene: Node
var _ocean: Ocean
var _phase := 0
var _rebuild := 0
var _wait_frames := 0
var _mock_provider: MockProvider
var _mock_spindrift: OceanSpindriftV4
var _mock_surface: Node3D
var _failed := false


func _initialize() -> void:
	_scene = load("res://validation/p0_open_ocean.tscn").instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node(^"Ocean") as Ocean


func _process(_delta: float) -> bool:
	if _failed:
		return false
	match _phase:
		0:
			if not _production_ready():
				return _wait_for_ready("startup")
			if not _validate_production_surface("startup"):
				return false
			if not _validate_production_transitions():
				return false
			_begin_production_rebuild()
			_phase = 1
		1:
			if not _production_ready():
				return _wait_for_ready("controlled rebuild %d" % (_rebuild + 1))
			if not _validate_production_surface("controlled rebuild %d" % (_rebuild + 1)):
				return false
			_rebuild += 1
			if _rebuild < CONTROLLED_REBUILDS:
				_begin_production_rebuild()
			else:
				_setup_mock(true)
				_phase = 2
		2:
			if not _validate_mock_visible_provider():
				return false
			_mock_spindrift.set_debug_mode(SpindriftController.DebugMode.SOURCE_MASK)
			if not _expect_mock_visibility(false, "mock Source Mask"):
				return false
			_mock_spindrift.set_debug_mode(SpindriftController.DebugMode.FULL)
			if not _expect_mock_visibility(true, "mock FULL restore"):
				return false
			# In FULL, another legitimate owner may change visibility. Spindrift
			# must not claim it back from its normal process/control path.
			_mock_surface.visible = false
			_mock_spindrift.set_enabled(true)
			if not _expect_mock_visibility(false, "mock FULL non-ownership"):
				return false
			_mock_surface.visible = true
			_mock_spindrift.set_enabled(true)
			if not _expect_mock_visibility(true, "mock FULL non-ownership restore"):
				return false
			_mock_spindrift.set_debug_mode(SpindriftController.DebugMode.SOURCE_MASK)
			if not _expect_mock_visibility(false, "mock destruction entry"):
				return false
			_mock_spindrift.queue_free()
			_phase = 3
		3:
			if is_instance_valid(_mock_spindrift):
				return false
			if not _expect_mock_visibility(true, "mock destruction restore"):
				return false
			_mock_provider.queue_free()
			_mock_provider = null
			_mock_surface = null
			_mock_spindrift = null
			_setup_mock(false)
			_phase = 4
		4:
			if not _validate_mock_invisible_provider():
				return false
			_mock_spindrift.set_debug_mode(SpindriftController.DebugMode.SOURCE_MASK)
			if not _expect_mock_visibility(false, "mock false Source Mask"):
				return false
			_mock_spindrift.set_debug_mode(SpindriftController.DebugMode.FULL)
			if not _expect_mock_visibility(false, "mock false FULL fallback restore"):
				return false
			_mock_spindrift.set_debug_mode(SpindriftController.DebugMode.SOURCE_MASK)
			_mock_spindrift.queue_free()
			_phase = 5
		5:
			if is_instance_valid(_mock_spindrift):
				return false
			if not _expect_mock_visibility(false, "mock false destruction restore"):
				return false
			print("FFT_SURFACE_VISIBILITY_CONTRACT_PASS rebuilds=%d" % CONTROLLED_REBUILDS)
			quit(0)
	return false


func _production_ready() -> bool:
	if _ocean == null:
		_fail("Ocean no encontrado")
		return false
	var open_ocean := _ocean.get("_open_ocean") as Node
	if open_ocean == null:
		return false
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	return bool(state.get("generation_active", false)) \
		and bool(state.get("neutral_ready", false)) \
		and int(state.get("published_generation", -1)) == int(state.get("generation", -2)) \
		and bool(state.get("surface_initialized", false))


func _wait_for_ready(context: String) -> bool:
	_wait_frames += 1
	if _wait_frames > READY_TIMEOUT_FRAMES:
		var open_ocean := _ocean.get("_open_ocean") as Node if _ocean != null else null
		_fail("%s no alcanzó readiness en %d frames: %s" % [context, READY_TIMEOUT_FRAMES, open_ocean.get_fft_resource_lifecycle_state() if open_ocean != null else {}])
	return false


func _begin_production_rebuild() -> void:
	_wait_frames = 0
	_ocean.shutdown()
	if not _ocean.initialize():
		_fail("Ocean.initialize() falló en rebuild controlado %d" % (_rebuild + 1))


func _validate_production_surface(context: String) -> bool:
	var open_ocean := _ocean.get("_open_ocean") as Node
	if open_ocean == null or not open_ocean.has_method(&"is_surface_initialized") or not open_ocean.has_method(&"is_enabled"):
		_fail("%s no tiene OpenOceanFFT/API esperada" % context)
		return false
	if not open_ocean.is_surface_initialized() or not open_ocean.is_enabled():
		_fail("%s no dejó OpenOceanFFT habilitado y Surface inicializada" % context)
		return false
	var surface := open_ocean.get_underwater_medium_raster_surface() as OceanClipmapSurface
	if surface == null or not surface.visible:
		_fail("%s dejó OceanClipmapSurface invisible" % context)
		return false
	var spindrift_state: Dictionary = open_ocean.get_spindrift_runtime_state()
	if not spindrift_state.get("enabled", false) or int(spindrift_state.get("debug_mode", -1)) != SpindriftController.DebugMode.FULL:
		_fail("%s no dejó Spindrift ON/FULL: %s" % [context, spindrift_state])
		return false
	return true


func _validate_production_transitions() -> bool:
	var open_ocean := _ocean.get("_open_ocean") as Node
	var surface := open_ocean.get_underwater_medium_raster_surface() as OceanClipmapSurface
	open_ocean.set_spindrift_debug_mode(SpindriftController.DebugMode.SOURCE_MASK)
	if not _expect_production_visibility(surface, false, "Production Source Mask"):
		return false
	open_ocean.set_spindrift_debug_mode(SpindriftController.DebugMode.FULL)
	if not _expect_production_visibility(surface, true, "Production FULL restore"):
		return false
	open_ocean.set_spindrift_enabled(false, null, SpindriftController.DebugMode.OFF)
	if not _expect_production_visibility(surface, true, "Production Spindrift OFF"):
		return false
	open_ocean.set_spindrift_enabled(true, _ocean.spindrift_profile, SpindriftController.DebugMode.FULL)
	return _expect_production_visibility(surface, true, "Production Spindrift ON")


func _expect_production_visibility(surface: OceanClipmapSurface, expected: bool, context: String) -> bool:
	if surface == null or surface.visible != expected:
		_fail("%s: visible=%s esperado=%s" % [context, surface != null and surface.visible, expected])
		return false
	return true


func _setup_mock(initial_visible: bool) -> void:
	_mock_provider = MockProvider.new(initial_visible)
	root.add_child(_mock_provider)
	_mock_surface = _mock_provider.get_node(^"OceanClipmapSurface") as Node3D
	_mock_spindrift = SpindriftController.new()
	root.add_child(_mock_spindrift)
	_mock_spindrift.configure(_mock_provider, SPINDRIFT_PROFILE, 0.0, 18.0, 0.0, SpindriftController.DebugMode.FULL)


func _validate_mock_visible_provider() -> bool:
	return _expect_mock_visibility(true, "mock startup visible")


func _validate_mock_invisible_provider() -> bool:
	return _expect_mock_visibility(false, "mock startup invisible")


func _expect_mock_visibility(expected: bool, context: String) -> bool:
	if _mock_surface == null or _mock_surface.visible != expected:
		_fail("%s: visible=%s esperado=%s" % [context, _mock_surface != null and _mock_surface.visible, expected])
		return false
	return true


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	push_error("FFT_SURFACE_VISIBILITY_CONTRACT_FAIL: " + reason)
	quit(1)
