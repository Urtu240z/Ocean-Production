extends Node
## H4.24 validates the production cache for borrowed Coastal RenderingDevice RIDs.
## It exercises the real P7 OpenOceanFFT source packet and never frees borrowed RIDs.

const P7_SCENE := preload("res://validation/p7_breakers.tscn")
const BAKE_SCENE_RESOURCE := preload("res://validation/p4_paradise/coastal_bake.tres")
const STARTUP_TIMEOUT_FRAMES: int = 600
const STEADY_STATE_FRAMES: int = 300

var _p7: Node
var _ocean: Node
var _open_ocean: Object
var _failed: bool = false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("OCEAN_BORROWED_RD_CACHE_START")
	_p7 = P7_SCENE.instantiate() as Node
	add_child(_p7)
	_ocean = _p7.get_node_or_null(^"P0/Ocean") as Node
	if _ocean == null:
		_fail("P7 production Ocean not found")
		return
	if not await _wait_for_coastal_sources(STARTUP_TIMEOUT_FRAMES):
		_fail("P7 Coastal/Breaker source packet did not become ready")
		return

	var initial_state: Dictionary = _lifecycle_state()
	var initial_packet: Dictionary = _query_sources()
	if not _packet_is_ready(initial_packet, true):
		_fail("initial source packet is incomplete")
		return
	if int(initial_state.get("borrowed_rd_cache_entries", 0)) != 4:
		_fail("initial cache does not contain field/warp/phase/metrics")
		return
	if int(initial_state.get("borrowed_rd_conversions", 0)) != 4:
		_fail("initial Coastal conversion count is not four")
		return
	print("OCEAN_BORROWED_RD_INITIAL_RESOLVE_PASS")

	var steady_conversion_count: int = int(initial_state.get("borrowed_rd_conversions", 0))
	var steady_hits_start: int = int(initial_state.get("borrowed_rd_cache_hits", 0))
	for _frame in STEADY_STATE_FRAMES:
		var packet: Dictionary = _query_sources()
		if not _packet_is_ready(packet, true):
			_fail("source packet became invalid during steady state")
			return
		await get_tree().process_frame
	var steady_state: Dictionary = _lifecycle_state()
	if int(steady_state.get("borrowed_rd_conversions", 0)) != steady_conversion_count:
		_fail("borrowed RID conversions increased during steady state")
		return
	if int(steady_state.get("borrowed_rd_cache_hits", 0)) <= steady_hits_start:
		_fail("borrowed RID cache did not record steady-state hits")
		return
	print("OCEAN_BORROWED_RD_STEADY_STATE_PASS")

	var same_bake_conversion_count: int = int(steady_state.get("borrowed_rd_conversions", 0))
	_ocean.set("coastal", false)
	await _wait_frames(4)
	_ocean.set("coastal", true)
	if not await _wait_for_coastal_sources(STARTUP_TIMEOUT_FRAMES):
		_fail("same-bake Coastal reactivation did not become ready")
		return
	var same_bake_state: Dictionary = _lifecycle_state()
	if int(same_bake_state.get("borrowed_rd_conversions", 0)) != same_bake_conversion_count:
		_fail("same-bake Coastal toggle reconverted stable textures")
		return
	print("OCEAN_BORROWED_RD_SAME_BAKE_REUSE_PASS")

	var breaker_conversion_count: int = int(same_bake_state.get("borrowed_rd_conversions", 0))
	_ocean.set("breakers", false)
	await _wait_frames(4)
	_ocean.set("breakers", true)
	if not await _wait_for_coastal_sources(STARTUP_TIMEOUT_FRAMES):
		_fail("Breaker reactivation did not restore the source packet")
		return
	var breaker_state: Dictionary = _lifecycle_state()
	if int(breaker_state.get("borrowed_rd_conversions", 0)) != breaker_conversion_count:
		_fail("Breaker toggle reconverted stable phase/metrics textures")
		return
	print("OCEAN_BORROWED_RD_BREAKER_TOGGLE_PASS")

	var original_bake: Resource = _ocean.get("coastal_bake") as Resource
	var replacement_bake: Resource = BAKE_SCENE_RESOURCE.duplicate(true) as Resource
	if replacement_bake == null:
		_fail("could not create controlled replacement Coastal bake")
		return
	_ocean.set("coastal_bake", replacement_bake)
	_ocean.set("coastal", true)
	if not await _wait_for_coastal_sources(STARTUP_TIMEOUT_FRAMES):
		_fail("replacement Coastal bake did not become ready")
		return
	var replacement_state: Dictionary = _lifecycle_state()
	if int(replacement_state.get("borrowed_rd_conversions", 0)) <= breaker_conversion_count:
		_fail("source identity change did not invalidate borrowed RID cache")
		return
	if not _packet_is_ready(_query_sources(), true):
		_fail("replacement source packet is invalid")
		return
	print("OCEAN_BORROWED_RD_INVALIDATION_PASS")

	_ocean.set("coastal_bake", original_bake)
	_ocean.set("coastal", true)
	if not await _wait_for_coastal_sources(STARTUP_TIMEOUT_FRAMES):
		_fail("original Coastal bake did not restore")
		return
	var open_before_shutdown: Object = _open_ocean
	open_before_shutdown.call("shutdown")
	var shutdown_state: Dictionary = open_before_shutdown.call("get_fft_resource_lifecycle_state")
	if int(shutdown_state.get("borrowed_rd_cache_entries", -1)) != 0:
		_fail("shutdown did not empty borrowed RID cache")
		return
	_ocean.call("shutdown")
	await _wait_frames(2)
	_ocean.call("initialize")
	if not await _wait_for_coastal_sources(STARTUP_TIMEOUT_FRAMES):
		_fail("reinitialize did not restore Coastal sources")
		return
	var lifecycle_state: Dictionary = _lifecycle_state()
	if int(lifecycle_state.get("borrowed_rd_cache_entries", 0)) != 4:
		_fail("reinitialize did not resolve all four borrowed sources")
		return
	if not _packet_is_ready(_query_sources(), true):
		_fail("reinitialized source packet is invalid")
		return
	print("OCEAN_BORROWED_RD_LIFECYCLE_PASS")

	var source: String = _read("res://addons/ocean/fft/open_ocean_fft.gd")
	if not source.contains("get_publication_snapshot()") or source.contains("_texture2d_rd_rid"):
		_fail("H4.23 publication contract was changed or raw RID helper remains")
		return
	print("OCEAN_BORROWED_RD_GPU_HANDSHAKE_COMPAT_PASS")
	print("OCEAN_BORROWED_RD_SOURCE_COMPAT_PASS")
	var final_state: Dictionary = _lifecycle_state()
	print("OCEAN_BORROWED_RD_CONVERSIONS=%d" % int(final_state.get("borrowed_rd_conversions", 0)))
	print("OCEAN_BORROWED_RD_CACHE_HITS=%d" % int(final_state.get("borrowed_rd_cache_hits", 0)))
	print("OCEAN_BORROWED_RD_CACHE_MISSES=%d" % int(final_state.get("borrowed_rd_cache_misses", 0)))
	get_tree().quit(0)


func _wait_for_coastal_sources(max_frames: int) -> bool:
	for _frame in max_frames:
		_refresh_open_ocean()
		if _open_ocean != null:
			var packet: Dictionary = _query_sources()
			if _packet_is_ready(packet, true):
				return true
		await get_tree().process_frame
	return false


func _wait_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await get_tree().process_frame


func _refresh_open_ocean() -> void:
	var candidate: Object = _ocean.get("_open_ocean") as Object if _ocean != null else null
	if candidate != null and is_instance_valid(candidate):
		_open_ocean = candidate
	else:
		_open_ocean = null


func _query_sources() -> Dictionary:
	_refresh_open_ocean()
	if _open_ocean == null:
		return {}
	return _open_ocean.call("get_underwater_medium_raster_sources") as Dictionary


func _lifecycle_state() -> Dictionary:
	_refresh_open_ocean()
	if _open_ocean == null:
		return {}
	return _open_ocean.call("get_fft_resource_lifecycle_state") as Dictionary


func _packet_is_ready(packet: Dictionary, require_breakers: bool) -> bool:
	if packet.is_empty() or not bool(packet.get("coastal_enabled", false)):
		return false
	for key in [
		&"long", &"mid", &"short", &"breaking_activity_long",
		&"domains", &"ocean_scale", &"clipmap_geometry_scale",
		&"coastal_field", &"coastal_warp", &"coastal_origin", &"coastal_extent",
		&"coastal_warp_origin", &"coastal_warp_extent", &"coastal_warp_detj_safe",
		&"breaker_enabled", &"breaker_phase", &"breaker_metrics", &"breaker_normal_long",
		&"breaker_profile",
	]:
		if not packet.has(key):
			return false
	for key in [&"long", &"mid", &"short", &"breaking_activity_long", &"coastal_field", &"coastal_warp"]:
		var rid: RID = packet.get(key, RID())
		if not rid.is_valid():
			return false
	if require_breakers:
		if not bool(packet.get("breaker_enabled", false)):
			return false
		for key in [&"breaker_phase", &"breaker_metrics", &"breaker_normal_long"]:
			var rid: RID = packet.get(key, RID())
			if not rid.is_valid():
				return false
	return true


func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	push_error("OCEAN_BORROWED_RD_CACHE_FAIL: %s" % reason)
	get_tree().quit(1)
