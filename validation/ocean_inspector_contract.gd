extends SceneTree
## H4.13 production Inspector/API contract validation.
## This validator audits authoring structure and serialization visibility only;
## it does not alter runtime resources or visual behavior.

const OCEAN_PATH := "res://addons/ocean/ocean.gd"
const BREAKER_PATH := "res://addons/ocean/core/ocean_breaker_profile.gd"
const WAVE_BAND_PATH := "res://addons/ocean/core/ocean_wave_band_profile.gd"

const ROOT_GROUPS := [
	"General",
	"Ocean Space",
	"Sea State",
	"Wave Structure",
	"FFT Cascades",
	"Systems",
	"System Resources",
	"Advanced",
	"Diagnostics",
]
const SYSTEMS := [
	"open_ocean_fft", "coastal", "crest_foam", "surface_foam", "breakers",
	"optics", "reflections", "surface_detail", "underwater_medium",
	"underwater_bubbles", "underwater_sunrays", "enable_spindrift",
]
const SYSTEM_RESOURCES := [
	"coastal_bake", "crest_foam_profile", "surface_foam_profile", "breaker_profile",
	"optics_profile", "reflection_profile", "surface_detail_profile",
	"underwater_medium_profile", "underwater_bubble_profile",
	"underwater_sunray_profile", "spindrift_profile",
]
const DEAD_BREAKER_EXPORTS := ["lip_strength", "lip_forward_fraction", "lip_drop_scale"]
const DEAD_WAVE_EXPORTS := ["directional_spread", "short_wave_damping_m"]
const FUNCTIONAL_OCEAN_EXPORTS := [
	"enabled", "sea_level", "simulation_seed", "quality_profile", "ocean_scale",
	"clipmap_geometry_scale", "wave_profile", "sea_state_mode",
	"significant_wave_height_m", "wave_height_scale", "wave_speed_multiplier",
	"wind_speed_mps", "wind_direction_degrees", "swell", "long_wave_spacing",
	"mid_fill_amount", "long_band_scale", "mid_band_scale", "short_band_scale",
	"long_enabled", "mid_enabled", "short_enabled",
]


func _initialize() -> void:
	var checks := [
		_check_group_order(),
		_check_system_order(),
		_check_resource_order(),
		_check_diagnostics_order(),
		_check_dead_exports_hidden(),
		_check_serialization_compatibility(),
	]
	for check in checks:
		if not check:
			_fail("Ocean Inspector contract failed")
			return
	print("OCEAN_INSPECTOR_GROUP_ORDER_PASS")
	print("OCEAN_INSPECTOR_SYSTEM_ORDER_PASS")
	print("OCEAN_INSPECTOR_RESOURCE_ORDER_PASS")
	print("OCEAN_INSPECTOR_DIAGNOSTICS_ORDER_PASS")
	print("OCEAN_DEAD_EXPORTS_HIDDEN_PASS")
	print("OCEAN_EXPORT_SERIALIZATION_COMPAT_PASS")
	quit(0)


func _check_group_order() -> bool:
	var source := _read(OCEAN_PATH)
	if source.is_empty() or source.contains("Ocean V4 / Spindrift"):
		return false
	var groups: Array[String] = []
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("@export_group("):
			var group_name := trimmed.get_slice("\"", 1)
			groups.append(group_name)
	return groups == ROOT_GROUPS and groups.count("Sea State") == 1


func _check_system_order() -> bool:
	return _ordered_names(_section(_read(OCEAN_PATH), "Systems", "System Resources"), SYSTEMS)


func _check_resource_order() -> bool:
	return _ordered_names(_section(_read(OCEAN_PATH), "System Resources", "Advanced"), SYSTEM_RESOURCES)


func _check_diagnostics_order() -> bool:
	var source := _section(_read(OCEAN_PATH), "Diagnostics", "var _open_ocean")
	return _ordered_tokens(source, ["@export_subgroup(\"Breaker Refinement\")", "@export_subgroup(\"Spindrift\")"])


func _check_dead_exports_hidden() -> bool:
	var breaker := _read(BREAKER_PATH)
	var wave_band := _read(WAVE_BAND_PATH)
	for name in DEAD_BREAKER_EXPORTS:
		if not _hidden_storage_export(breaker, name):
			return false
	for name in DEAD_WAVE_EXPORTS:
		if not _hidden_storage_export(wave_band, name):
			return false
	var ocean := _read(OCEAN_PATH)
	for name in FUNCTIONAL_OCEAN_EXPORTS:
		if ocean.find("var " + name) < 0:
			return false
	return true


func _check_serialization_compatibility() -> bool:
	var files: Array[String] = []
	_collect_files("res://addons/ocean", files)
	_collect_files("res://validation", files)
	var storage_sources := _read(BREAKER_PATH) + _read(WAVE_BAND_PATH)
	for path in files:
		if not path.ends_with(".tres") and not path.ends_with(".tscn"):
			continue
		var resource_source := _read(path)
		for name in DEAD_BREAKER_EXPORTS + DEAD_WAVE_EXPORTS:
			if resource_source.contains(name + " =") and not storage_sources.contains("@export_storage var " + name):
				return false
	return true


func _hidden_storage_export(source: String, name: String) -> bool:
	return source.contains("@export_storage var " + name) and not source.contains("@export var " + name)


func _ordered_names(source: String, names: Array) -> bool:
	var cursor := 0
	for name in names:
		var position := source.find("var " + name, cursor)
		if position < 0:
			return false
		cursor = position + 4
	return true


func _ordered_tokens(source: String, tokens: Array) -> bool:
	var cursor := 0
	for token in tokens:
		var position := source.find(token, cursor)
		if position < 0:
			return false
		cursor = position + token.length()
	return true


func _section(source: String, start_name: String, end_name: String) -> String:
	var start := source.find("@export_group(\"" + start_name + "\")")
	var end := source.find("@export_group(\"" + end_name + "\")", start + 1)
	if start < 0:
		return ""
	if end < 0:
		end = source.length()
	return source.substr(start, end - start)


func _collect_files(path: String, output: Array[String]) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	while true:
		var entry := directory.get_next()
		if entry.is_empty():
			break
		if entry == "." or entry == "..":
			continue
		var child := path.path_join(entry)
		if directory.current_is_dir():
			_collect_files(child, output)
		else:
			output.append(child)
	directory.list_dir_end()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
