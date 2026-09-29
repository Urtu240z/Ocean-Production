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
const SYSTEM_SUBGROUPS := ["Core", "Surface", "Underwater", "Atmospherics"]
const SYSTEM_RESOURCES := [
	"wave_profile", "quality_profile", "coastal_bake", "crest_foam_profile",
	"surface_foam_profile", "optics_profile", "reflection_profile",
	"surface_detail_profile",
	"underwater_medium_profile", "underwater_bubble_profile",
	"underwater_sunray_profile", "caustics_profile", "underwater_sun_light",
	"breaker_profile", "spindrift_profile",
]
const RESOURCE_SUBGROUPS := ["Core", "Coastal", "Surface", "Underwater", "Breakers", "Spindrift"]
const ADVANCED_SUBGROUPS := ["Breaker Refinement"]
const DIAGNOSTIC_SUBGROUPS := ["General", "Breakers", "Spindrift"]
const DIAGNOSTICS := [
	"performance_overlay", "debug_view", "breaker_detector_debug_mode",
	"breaker_detector_probe_enabled", "breaker_detector_probe_xz",
	"breaker_detector_probe_reset_serial", "breaker_detector_capture_arm_serial",
	"breaker_detector_capture_release_serial", "local_breaker_refinement_debug",
	"spindrift_debug_mode", "freeze_spindrift_visuals",
]
# These lip controls remain active OceanBreakerProfile exports.
const DEAD_BREAKER_EXPORTS: Array[String] = []
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
	var checks := {
		"group order": _check_group_order(),
		"system order": _check_system_order(),
		"subgroup order": _check_subgroup_order(),
		"resource order": _check_resource_order(),
		"diagnostics order": _check_diagnostics_order(),
		"export boundaries": _check_export_boundaries(),
		"dead exports hidden": _check_dead_exports_hidden(),
		"serialization compatibility": _check_serialization_compatibility(),
	}
	for check_name in checks:
		if not checks[check_name]:
			_fail("Ocean Inspector contract failed: " + check_name)
			return
	print("OCEAN_INSPECTOR_GROUP_ORDER_PASS")
	print("OCEAN_INSPECTOR_SYSTEM_ORDER_PASS")
	print("OCEAN_INSPECTOR_SUBGROUP_ORDER_PASS")
	print("OCEAN_INSPECTOR_RESOURCE_ORDER_PASS")
	print("OCEAN_INSPECTOR_DIAGNOSTICS_ORDER_PASS")
	print("OCEAN_INSPECTOR_EXPORT_BOUNDARIES_PASS")
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


func _check_subgroup_order() -> bool:
	var source := _read(OCEAN_PATH)
	return _subgroups(_section(source, "Systems", "System Resources")) == SYSTEM_SUBGROUPS \
		and _subgroups(_section(source, "System Resources", "Advanced")) == RESOURCE_SUBGROUPS \
		and _subgroups(_section(source, "Advanced", "Diagnostics")) == ADVANCED_SUBGROUPS \
		and _subgroups(_section(source, "Diagnostics", "var _open_ocean")) == DIAGNOSTIC_SUBGROUPS


func _check_resource_order() -> bool:
	return _ordered_names(_section(_read(OCEAN_PATH), "System Resources", "Advanced"), SYSTEM_RESOURCES)


func _check_diagnostics_order() -> bool:
	var source := _section(_read(OCEAN_PATH), "Diagnostics", "var _open_ocean")
	return _ordered_names(source, DIAGNOSTICS)


func _check_export_boundaries() -> bool:
	var source := _read(OCEAN_PATH)
	var systems := _section(source, "Systems", "System Resources")
	var resources := _section(source, "System Resources", "Advanced")
	var diagnostics := _section(source, "Diagnostics", "var _open_ocean")
	for name in DIAGNOSTICS:
		if _declares_var(systems, name):
			return false
	for name in SYSTEM_RESOURCES:
		if _declares_var(systems, name):
			return false
	for name in SYSTEMS:
		if _declares_var(resources, name) or _declares_var(diagnostics, name):
			return false
	return true


func _declares_var(source: String, name: String) -> bool:
	var declaration := RegEx.new()
	declaration.compile("var " + name + "($|[ :])")
	return declaration.search(source) != null


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


func _subgroups(source: String) -> Array[String]:
	var subgroups: Array[String] = []
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("@export_subgroup("):
			subgroups.append(trimmed.get_slice("\"", 1))
	return subgroups


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
