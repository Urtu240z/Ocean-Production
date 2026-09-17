extends Node
## H4.17 runtime validation for the real Coastal runtime cache.
## It exercises OceanCoastalRuntime with the repository's production bake and
## real build_gpu_textures() implementations; it does not simulate dictionaries.

const RUNTIME := preload("res://addons/ocean/coastal/ocean_coastal_runtime.gd")
const BAKE_PATH := "res://validation/p4_paradise/coastal_bake.tres"
const OPTICS_PROFILE_PATH := "res://validation/profiles/p0_optics_profile.tres"
const RUNTIME_PATH := "res://addons/ocean/coastal/ocean_coastal_runtime.gd"
const OPEN_OCEAN_PATH := "res://addons/ocean/fft/open_ocean_fft.gd"
const EPSILON := 0.000001

var _runtime: OceanCoastalRuntime
var _bake_a: Resource
var _bake_b: Resource


func _ready() -> void:
	call_deferred(&"_initialize")


func _initialize() -> void:
	if not _check_source_contract():
		_fail("Coastal cache source contract is not hardened")
		return
	_bake_a = load(BAKE_PATH) as Resource
	if _bake_a == null or not _bake_a.has_method(&"is_valid") or not _bake_a.is_valid():
		_fail("The repository Coastal bake is not valid")
		return
	_runtime = RUNTIME.new()
	var first_data: Dictionary = _runtime.activate(_bake_a)
	var first_state: Dictionary = _runtime.get_runtime_state()
	if first_data.is_empty() or not _is_resident_with_textures(first_state) or int(first_state.get("build_count", 0)) != 1 or int(first_state.get("generation", 0)) != 1:
		_fail("Initial Coastal cache build did not produce a resident generation")
		return
	print("OCEAN_COASTAL_CACHE_INITIAL_BUILD_PASS")

	if not _check_same_bake():
		_fail("Same-bake activation rebuilt Coastal textures")
		return
	print("OCEAN_COASTAL_CACHE_SAME_BAKE_PASS")
	if not _check_coastal_toggle():
		_fail("Coastal toggle evicted or rebuilt the resident cache")
		return
	print("OCEAN_COASTAL_CACHE_COASTAL_TOGGLE_PASS")
	if not _check_optics_toggle():
		_fail("Optics toggle evicted or rebuilt the resident cache")
		return
	print("OCEAN_COASTAL_CACHE_OPTICS_TOGGLE_PASS")
	if not _check_mixed_toggle():
		_fail("Mixed Coastal/Optics toggles rebuilt the resident cache")
		return
	print("OCEAN_COASTAL_CACHE_MIXED_TOGGLE_PASS")
	if not _check_optics_profile():
		_fail("Optics profile sync changed the Coastal build count")
		return
	print("OCEAN_COASTAL_CACHE_OPTICS_PROFILE_PASS")
	if not _check_bake_change():
		_fail("Changing bake identity did not create exactly one new generation")
		return
	print("OCEAN_COASTAL_CACHE_BAKE_CHANGE_PASS")
	if not _check_invalidation():
		_fail("In-place Coastal resource invalidation was not deferred and rebuilt once")
		return
	print("OCEAN_COASTAL_CACHE_INVALIDATION_PASS")
	if not _check_deactivate_residency():
		_fail("Deactivate did not preserve resident data or active publication state")
		return
	print("OCEAN_COASTAL_CACHE_RESIDENCY_PASS")
	if not _check_shutdown():
		_fail("Coastal cache clear left resident data or signal connections")
		return
	print("OCEAN_COASTAL_CACHE_SHUTDOWN_PASS")
	print("OCEAN_COASTAL_CACHE_SOURCE_CONTRACT_PASS")
	get_tree().quit(0)


func _check_same_bake() -> bool:
	for _index in 20:
		if _runtime.activate(_bake_a).is_empty():
			return false
	var state: Dictionary = _runtime.get_runtime_state()
	return int(state.get("build_count", 0)) == 1 \
		and int(state.get("generation", 0)) == 1 \
		and int(state.get("cache_hit_count", 0)) >= 20


func _check_coastal_toggle() -> bool:
	var build_count_before: int = int(_runtime.get_runtime_state().get("build_count", 0))
	for _index in 10:
		_runtime.deactivate()
		if _runtime.activate(_bake_a).is_empty():
			return false
	var state: Dictionary = _runtime.get_runtime_state()
	return int(state.get("build_count", 0)) == build_count_before \
		and bool(state.get("resident", false)) \
		and bool(state.get("active", false))


func _check_optics_toggle() -> bool:
	var build_count_before: int = int(_runtime.get_runtime_state().get("build_count", 0))
	for _index in 10:
		_runtime.deactivate()
		if _runtime.activate(_bake_a).is_empty():
			return false
	var state: Dictionary = _runtime.get_runtime_state()
	return int(state.get("build_count", 0)) == build_count_before \
		and bool(state.get("resident", false))


func _check_mixed_toggle() -> bool:
	var build_count_before: int = int(_runtime.get_runtime_state().get("build_count", 0))
	var modes := [[false, false], [true, false], [false, true], [true, true]]
	for index in 20:
		var mode: Array = modes[index % modes.size()]
		if bool(mode[0]) or bool(mode[1]):
			if _runtime.activate(_bake_a).is_empty():
				return false
		else:
			_runtime.deactivate()
	var state: Dictionary = _runtime.get_runtime_state()
	return int(state.get("build_count", 0)) == build_count_before \
		and int(state.get("generation", 0)) == 1


func _check_optics_profile() -> bool:
	var profile_a: Resource = load(OPTICS_PROFILE_PATH) as Resource
	var profile_b: Resource = profile_a.duplicate(true) if profile_a != null else null
	var build_count_before: int = int(_runtime.get_runtime_state().get("build_count", 0))
	for profile in [profile_a, profile_b, profile_a, profile_b]:
		if profile == null or _runtime.activate(_bake_a).is_empty():
			return false
	var state: Dictionary = _runtime.get_runtime_state()
	return int(state.get("build_count", 0)) == build_count_before


func _check_bake_change() -> bool:
	_bake_b = _bake_a.duplicate(true)
	if _bake_b == null or not _bake_b.has_method(&"is_valid") or not _bake_b.is_valid():
		return false
	var before: Dictionary = _runtime.get_runtime_state()
	var expected_build: int = int(before.get("build_count", 0)) + 1
	var expected_generation: int = int(before.get("generation", 0)) + 1
	if _runtime.activate(_bake_b).is_empty():
		return false
	var changed: Dictionary = _runtime.get_runtime_state()
	if int(changed.get("build_count", 0)) != expected_build or int(changed.get("generation", 0)) != expected_generation:
		return false
	if _runtime.activate(_bake_b).is_empty():
		return false
	var repeated: Dictionary = _runtime.get_runtime_state()
	return int(repeated.get("build_count", 0)) == expected_build and int(repeated.get("generation", 0)) == expected_generation


func _check_invalidation() -> bool:
	var propagation: Resource = _bake_b.get("propagation") as Resource
	if propagation == null:
		return false
	propagation.emit_changed()
	var dirty: Dictionary = _runtime.get_runtime_state()
	if not bool(dirty.get("cache_dirty", false)):
		return false
	var before: Dictionary = dirty
	if _runtime.activate(_bake_b).is_empty():
		return false
	var rebuilt: Dictionary = _runtime.get_runtime_state()
	if int(rebuilt.get("build_count", 0)) != int(before.get("build_count", 0)) + 1 or int(rebuilt.get("generation", 0)) != int(before.get("generation", 0)) + 1:
		return false
	if _runtime.activate(_bake_b).is_empty():
		return false
	var stable: Dictionary = _runtime.get_runtime_state()
	return int(stable.get("build_count", 0)) == int(rebuilt.get("build_count", 0)) \
		and int(stable.get("generation", 0)) == int(rebuilt.get("generation", 0)) \
		and not bool(stable.get("cache_dirty", true))


func _check_deactivate_residency() -> bool:
	var before: Dictionary = _runtime.get_runtime_state()
	_runtime.deactivate()
	var off: Dictionary = _runtime.get_runtime_state()
	if not bool(off.get("resident", false)) or bool(off.get("active", true)) or int(off.get("build_count", 0)) != int(before.get("build_count", 0)):
		return false
	if _runtime.activate(_bake_b).is_empty():
		return false
	var on_again: Dictionary = _runtime.get_runtime_state()
	return int(on_again.get("build_count", 0)) == int(before.get("build_count", 0))


func _check_shutdown() -> bool:
	_runtime.clear()
	var state: Dictionary = _runtime.get_runtime_state()
	return not bool(state.get("resident", true)) \
		and not bool(state.get("active", true)) \
		and int(state.get("connected_resource_count", -1)) == 0 \
		and not bool(state.get("has_field", true)) \
		and not bool(state.get("has_warp", true))


func _is_resident_with_textures(state: Dictionary) -> bool:
	return bool(state.get("resident", false)) \
		and bool(state.get("has_field", false)) \
		and bool(state.get("has_metrics", false)) \
		and bool(state.get("has_phase", false)) \
		and bool(state.get("has_warp", false)) \
		and bool(state.get("has_jacobian", false))


func _check_source_contract() -> bool:
	var runtime_source := _read(RUNTIME_PATH)
	var open_source := _read(OPEN_OCEAN_PATH)
	var activate_start: int = runtime_source.find("func activate(bake: Resource)")
	var activate_end: int = runtime_source.find("func deactivate()", activate_start)
	var set_start: int = open_source.find("func set_coastal(enabled: bool, bake: Resource)")
	var set_end: int = open_source.find("func set_breakers", set_start)
	var shutdown_start: int = open_source.find("func shutdown()")
	var shutdown_end: int = open_source.find("func _process", shutdown_start)
	if activate_start < 0 or activate_end <= activate_start or set_start < 0 or set_end <= set_start or shutdown_start < 0 or shutdown_end <= shutdown_start:
		return false
	var activate_source: String = runtime_source.substr(activate_start, activate_end - activate_start)
	var set_source: String = open_source.substr(set_start, set_end - set_start)
	var shutdown_source: String = open_source.substr(shutdown_start, shutdown_end - shutdown_start)
	return not activate_source.contains("clear()") \
		and set_source.contains("deactivate()") \
		and not set_source.contains("_coastal_runtime.clear()") \
		and shutdown_source.contains("_coastal_runtime.clear()")


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
