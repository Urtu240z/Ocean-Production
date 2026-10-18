@tool
class_name Ocean
extends Node3D
## Ocean authoring API. Simulation is owned by OpenOceanFFT.

const CpuWater = preload("res://addons/ocean/physics/water/cpu_fft_water_provider.gd")
var _cpu_water_provider: CpuFftWaterProvider

const OpenOcean := preload("res://addons/ocean/fft/open_ocean_fft.gd")
const UnderwaterMedium := preload("res://addons/ocean/underwater/ocean_underwater_medium.gd")
const CausticsManager := preload("res://addons/ocean/underwater/caustics/ocean_caustics_manager.gd")
const SpindriftController := preload("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
const EditorPreview := preload("res://addons/ocean/editor/ocean_editor_preview.gd")
const SceneLighting := preload("res://addons/ocean/core/ocean_scene_lighting.gd")
var _scene_lighting := SceneLighting.new()
const HULL_FOAM_STYLE_PATH := "res://addons/ocean/surface/foam2d/default_style.tres"
# One source of settings. Inspector properties below forward to this Ocean's
# resource, rather than duplicating values on a separate presentation node.
@export_storage var hull_foam_settings: Resource:
	set(value):
		if hull_foam_settings != null and hull_foam_settings.changed.is_connected(_hull_effect_settings_changed):
			hull_foam_settings.changed.disconnect(_hull_effect_settings_changed)
		hull_foam_settings = value
		if value != null and not value.changed.is_connected(_hull_effect_settings_changed):
			value.changed.connect(_hull_effect_settings_changed)
		_hull_effect_settings_changed()
var _physical_hull_waves: RefCounted
var _hull_foam_enabled := false
var _hull_foam_mode := "combined"
var _hull_foam_runtime: Node
var _hull_foam_vehicles: Array[WeakRef] = []
var _hull_foam_starting := false
var _hull_foam_defaults: Resource

func get_hull_foam_settings() -> Resource:
	if hull_foam_settings == null:
		# Separate Oceans start independently, with the user's saved appearance.
		hull_foam_settings = load(HULL_FOAM_STYLE_PATH).duplicate(true)
	return hull_foam_settings

func get_hull_foam_runtime() -> Node:
	return _hull_foam_runtime

## Immutable borrowed atlas state; no readback and no additional wave field.
func publish_hull_wave_render_state(state: Dictionary) -> void:
	if is_instance_valid(_underwater_medium):
		_underwater_medium.set_hull_wave_render_state(state)

func _hull_effect_settings_changed() -> void:
	if not is_inside_tree() or Engine.is_editor_hint(): return
	_refresh_hull_foam.call_deferred()
	if not _hull_waves_requested(): _physical_hull_waves = null

func _hull_waves_requested() -> bool:
	return _hull_foam_mode in ["contact","wake","combined"] and hull_foam_settings != null and hull_foam_settings.deformation_enabled and hull_foam_settings.wave_physics_enabled

func _physics_process(delta: float) -> void:
	if not Engine.is_editor_hint() and _hull_waves_requested():
		get_physical_hull_wave_state(delta)

## The same snapshot is used by every consumer and by the visible hull waves.
## Lazy advance also covers force integration before this node's callback.
func get_physical_hull_wave_state(delta := -1.0) -> RefCounted:
	if Engine.is_editor_hint() or not _hull_waves_requested(): return null
	if _physical_hull_waves == null:
		_physical_hull_waves = load("res://addons/ocean/physics/water/hull_wave_state.gd").new()
	if _physical_hull_waves.tick == Engine.get_physics_frames():
		return _physical_hull_waves if _physical_hull_waves.status == "OK" else null
	var live: Array[RigidBody3D] = []
	for reference in _hull_foam_vehicles:
		var vehicle: RigidBody3D = reference.get_ref()
		if is_instance_valid(vehicle) and vehicle.is_inside_tree() and vehicle.is_node_ready() and live.size() < 12:
			live.append(vehicle)
	var step := delta if delta >= 0.0 else get_physics_process_delta_time()
	return _physical_hull_waves if _physical_hull_waves.advance(Engine.get_physics_frames(),step,live,hull_foam_settings) else null

func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = [
		{"name":"Hull Foam","type":TYPE_NIL,"usage":PROPERTY_USAGE_GROUP,"hint_string":"foam_"},
		{"name":"foam_enabled","type":TYPE_BOOL,"usage":PROPERTY_USAGE_DEFAULT},
		{"name":"foam_mode","type":TYPE_STRING,"hint":PROPERTY_HINT_ENUM,"hint_string":"combined,contact,wake","usage":PROPERTY_USAGE_DEFAULT}]
	for entry in get_hull_foam_settings().get_property_list():
		if entry.usage & PROPERTY_USAGE_GROUP and entry.name in ["Hull Foam","Resource"]: continue
		if entry.usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			properties.append({"name":entry.name,"type":TYPE_NIL,"usage":entry.usage,"hint_string":"foam_"+str(entry.hint_string)})
		elif entry.usage & PROPERTY_USAGE_EDITOR and entry.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var property: Dictionary = entry.duplicate()
			property.name = "foam_"+entry.name
			property.usage = PROPERTY_USAGE_DEFAULT
			if entry.name == "wake_spread":
				property.name = "foam_wake_opening_degrees"
				property.hint_string = "0,24.4,0.1,suffix:°"
			properties.append(property)
	return properties

func _set(property: StringName, value: Variant) -> bool:
	if property == &"foam_enabled":
		_hull_foam_enabled = value
		if not Engine.is_editor_hint() and is_inside_tree():
			if is_instance_valid(_hull_foam_runtime): _hull_foam_runtime.set_enabled(value)
			if value: _refresh_hull_foam.call_deferred()
		return true
	if property == &"foam_mode":
		_hull_foam_mode = str(value)
		if not Engine.is_editor_hint() and is_inside_tree(): _refresh_hull_foam.call_deferred()
		return true
	if property == &"foam_wake_opening_degrees":
		# Nominal full angle; coherent irregular flow and speed still vary it.
		get_hull_foam_settings().set_wake_opening_degrees(float(value))
		return true
	if str(property).begins_with("foam_"):
		var key := str(property).trim_prefix("foam_")
		for entry in get_hull_foam_settings().get_property_list():
			if entry.name == key and entry.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				get_hull_foam_settings().set(key,value)
				return true
	return false

func _get(property: StringName) -> Variant:
	if property == &"foam_enabled": return _hull_foam_enabled
	if property == &"foam_mode": return _hull_foam_mode
	if property == &"foam_wake_opening_degrees": return get_hull_foam_settings().get_wake_opening_degrees()
	if str(property).begins_with("foam_"): return get_hull_foam_settings().get(str(property).trim_prefix("foam_"))
	return null

func _property_can_revert(property: StringName) -> bool:
	if property in [&"foam_enabled",&"foam_mode",&"foam_wake_opening_degrees"]: return true
	if not str(property).begins_with("foam_"): return false
	var key := str(property).trim_prefix("foam_")
	for entry in get_hull_foam_settings().get_property_list():
		if entry.name == key and entry.usage & PROPERTY_USAGE_SCRIPT_VARIABLE: return true
	return false

func _property_get_revert(property: StringName) -> Variant:
	if property == &"foam_enabled": return false
	if property == &"foam_mode": return "combined"
	if _hull_foam_defaults == null: _hull_foam_defaults = get_hull_foam_settings().get_script().new()
	var defaults := _hull_foam_defaults
	if property == &"foam_wake_opening_degrees": return defaults.get_wake_opening_degrees()
	return defaults.get(str(property).trim_prefix("foam_"))

func register_hull_foam_vehicle(vehicle: Node3D) -> void:
	for reference in _hull_foam_vehicles:
		if reference.get_ref() == vehicle: return
	_hull_foam_vehicles.append(weakref(vehicle))
	if vehicle.is_node_ready():
		_refresh_hull_foam.call_deferred()
	else:
		vehicle.ready.connect(_refresh_hull_foam,CONNECT_ONE_SHOT)
	vehicle.tree_exited.connect(_refresh_hull_foam,CONNECT_ONE_SHOT)

func _refresh_hull_foam() -> void:
	if Engine.is_editor_hint() or not (_hull_foam_enabled or _hull_waves_requested()) or _hull_foam_starting or not is_inside_tree(): return
	_hull_foam_starting = true
	# GPU publication builds surface materials a few frames after Ocean exists.
	for frame in 600:
		if not is_inside_tree() or not (_hull_foam_enabled or _hull_waves_requested()):
			_hull_foam_starting = false
			return
		if is_instance_valid(_open_ocean) and _open_ocean.get("_surface_initialized"): break
		await get_tree().process_frame
	_hull_foam_starting = false
	if not is_instance_valid(_open_ocean) or not _open_ocean.get("_surface_initialized"): return
	var live: Array[RigidBody3D] = []
	for i in range(_hull_foam_vehicles.size()-1,-1,-1):
		var vehicle: RigidBody3D = _hull_foam_vehicles[i].get_ref()
		if not is_instance_valid(vehicle) or not vehicle.is_inside_tree():
			_hull_foam_vehicles.remove_at(i)
		elif vehicle.is_node_ready() and live.size() < 12: live.push_front(vehicle)
	if live.is_empty():
		if is_instance_valid(_hull_foam_runtime): _hull_foam_runtime.set_enabled(false)
		return
	if not is_instance_valid(_hull_foam_runtime):
		# Load on demand to avoid Ocean <-> vehicle script preload cycles.
		_hull_foam_runtime = load("res://addons/ocean/surface/foam2d/foam2d_review_director.gd").new()
		_hull_foam_runtime.name = &"HullFoam"
		add_child(_hull_foam_runtime)
	if _hull_foam_runtime.fft != _open_ocean or _hull_foam_runtime.mode != _hull_foam_mode or _hull_foam_runtime.style != get_hull_foam_settings():
		_hull_foam_runtime.configure(_open_ocean,live,_hull_foam_mode,get_hull_foam_settings())
	else:
		_hull_foam_runtime.set_vehicles(live)
	_hull_foam_runtime.set_enabled(_hull_foam_enabled)
const AUTHORING_REBUILD_DEBOUNCE_S := 0.15
signal physics_source_invalidated
var _physics_source_revision := 0
var _physics_source_status := "UPDATING"
const CascadeState := preload("res://addons/ocean/core/ocean_cascade_state.gd")
const BREAKER_DETECTOR_MARKER_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D displacement_long : filter_linear, repeat_enable;
uniform sampler2D displacement_mid : filter_linear, repeat_enable;
uniform sampler2D displacement_short : filter_linear, repeat_enable;
uniform vec2 probe_uv_long = vec2(0.5);
uniform vec2 probe_uv_mid = vec2(0.5);
uniform vec2 probe_uv_short = vec2(0.5);

void vertex() {
	vec3 displacement = textureLod(displacement_long, probe_uv_long, 0.0).xyz;
	displacement += textureLod(displacement_mid, probe_uv_mid, 0.0).xyz;
	displacement += textureLod(displacement_short, probe_uv_short, 0.0).xyz;
	VERTEX += displacement;
}

void fragment() {
	ALBEDO = vec3(1.0, 0.12, 0.015);
	EMISSION = vec3(1.0, 0.045, 0.005);
}
"""

enum DebugView { OFF, NORMALS }
enum VisualWaterProfile { FULL_CHOPPY_DEBUG, PHYSICS_ALIGNED }

@export_group("Editor Preview")
## Frozen surface preview. No CPU water field, vehicles or underwater simulation.
@export var editor_preview := true:
	set(value):
		editor_preview = value
		if Engine.is_editor_hint() and is_inside_tree():
			_sync_editor_preview()
@export_range(0.0, 3600.0, 0.1, "or_greater", "suffix:s") var preview_time := 0.0
@export_tool_button("Refresh Preview") var refresh_preview: Callable = _refresh_editor_preview
var _editor_preview_node: Node3D

# Inspector contract: Systems contains feature gates only; System Resources contains
# profiles/resources/references; Advanced contains production advanced/experimental
# controls; Diagnostics contains debug/probe/capture/validation controls only.
@export_group("General")
@export var enabled := true:
	set(value):
		enabled = value
		if _initializing:
			_rebuild_requested = true
			return
		if is_inside_tree():
			if not enabled:
				_rebuild_debounce_remaining = -1.0
				set_process(false)
				shutdown()
			elif open_ocean_fft and _open_ocean == null:
				initialize()
@export var sea_level := 0.0:
	set(value):
		sea_level = value
		_sync_underwater_medium()
		_sync_caustics_runtime()
		_request_rebuild()
@export var simulation_seed := 1:
	set(value):
		simulation_seed = value
		_request_rebuild()
@export_group("Ocean Space")
## Exposes the existing runtime presentation choice for portable presets.
## Default preserves the standalone addon; production gameplay uses aligned.
@export_enum("Full choppy", "Physics aligned") var visual_water_profile: int = VisualWaterProfile.FULL_CHOPPY_DEBUG:
	set(value):
		visual_water_profile = value
		_apply_visual_water_profile()
## Vertical amplitude scale for wave height and reconstructed vertical displacement.
@export_range(0.25, 4.0, 0.01) var ocean_scale := 1.0:
	set(value):
		ocean_scale = clampf(value, 0.25, 4.0)
		if _open_ocean != null:
			_open_ocean.set_surface_scale(ocean_scale)
## Horizontal wavelength scale for XZ geometry, displacement and published FFT domains.
@export_range(0.25, 4.0, 0.01) var clipmap_geometry_scale := 1.0:
	set(value):
		clipmap_geometry_scale = clampf(value, 0.25, 4.0)
		if _open_ocean != null:
			_open_ocean.set_clipmap_geometry_scale(clipmap_geometry_scale)

@export_group("Sea State")
@export var significant_wave_height_m := 2.574:
	set(value):
		significant_wave_height_m = maxf(value, 0.0)
		_request_rebuild()
@export_enum("WIND_DRIVEN", "MANUAL_HS") var sea_state_mode := 0:
	set(value):
		sea_state_mode = clampi(value, 0, 1)
		_request_rebuild()
@export_range(0.0, 3.0, 0.01) var wave_height_scale := 1.0:
	set(value):
		wave_height_scale = clampf(value, 0.0, 3.0)
		_request_rebuild()
@export_range(0.0, 3.0, 0.01) var wave_speed_multiplier := 1.0:
	set(value):
		wave_speed_multiplier = clampf(value, 0.0, 3.0)
		if _open_ocean != null: _open_ocean.set_wave_speed_multiplier(wave_speed_multiplier)
@export var wind_speed_mps := 18.0:
	set(value):
		wind_speed_mps = maxf(value, 0.0)
		_request_rebuild()
@export var wind_direction_degrees := 5.71:
	set(value):
		wind_direction_degrees = value
		_request_rebuild()
@export_range(0.0, 1.0, 0.01) var swell := 0.80:
	set(value):
		swell = clampf(value, 0.0, 1.0)
		_request_rebuild()

@export_group("Wave Structure")
## Controls dominant spacing between the large LONG swells. 1.0 preserves the original spectrum.
@export_range(0.5, 2.5, 0.01) var long_wave_spacing := 1.0:
	set(value):
		long_wave_spacing = clampf(value, 0.5, 2.5)
		_request_rebuild()
## Controls how strongly MID waves fill the geometry between large LONG swells.
@export_range(0.0, 1.5, 0.01) var mid_fill_amount := 1.0:
	set(value):
		mid_fill_amount = clampf(value, 0.0, 1.5)
		_request_rebuild()
@export_range(0.0, 3.0, 0.01) var long_band_scale := 1.0:
	set(value):
		long_band_scale = clampf(value, 0.0, 3.0)
		_request_rebuild()

@export_range(0.0, 3.0, 0.01) var mid_band_scale := 1.0:
	set(value):
		mid_band_scale = clampf(value, 0.0, 3.0)
		_request_rebuild()

@export_range(0.0, 3.0, 0.01) var short_band_scale := 1.0:
	set(value):
		short_band_scale = clampf(value, 0.0, 3.0)
		_request_rebuild()

@export_group("FFT Cascades")
@export var long_enabled := true:
	set(value):
		long_enabled = value
		_update_fft_cascade_mask()
@export var mid_enabled := true:
	set(value):
		mid_enabled = value
		_update_fft_cascade_mask()
@export var short_enabled := true:
	set(value):
		short_enabled = value
		_update_fft_cascade_mask()

@export_group("Systems")
@export_subgroup("Core")
@export var open_ocean_fft := true:
	set(value):
		open_ocean_fft = value
		if _initializing:
			_rebuild_requested = true
			return
		if is_inside_tree():
			if not value:
				_rebuild_debounce_remaining = -1.0
				set_process(false)
				shutdown()
			elif enabled and _open_ocean == null:
				initialize()
@export var coastal := false:
	set(value):
		coastal = value
		_sync_coastal_runtime()
@export_subgroup("Surface")
@export var crest_foam := true:
	set(value):
		crest_foam = value
		if _open_ocean != null: _open_ocean.set_crest_foam(crest_foam)
@export var surface_foam := true:
	set(value):
		surface_foam = value
		if _open_ocean != null: _open_ocean.set_surface_foam(surface_foam)
@export var breakers := false:
	set(value):
		breakers = value
		if _open_ocean != null: _open_ocean.set_breakers(breakers, breaker_profile)
@export var optics := false:
	set(value):
		optics = value
		if _open_ocean != null:
			_open_ocean.set_optics(optics, optics_profile)
			_sync_coastal_runtime()
@export var reflections := false:
	set(value):
		reflections = value
		if _open_ocean != null:
			_open_ocean.set_reflections(reflections, reflection_profile)
@export var surface_detail := false:
	set(value):
		surface_detail = value
		if _open_ocean != null:
			_open_ocean.set_surface_detail(surface_detail, surface_detail_profile)
@export_subgroup("Underwater")
@export var underwater_medium := false:
	set(value):
		underwater_medium = value
		_sync_underwater_medium()
@export var underwater_bubbles := false:
	set(value):
		underwater_bubbles = value
		_sync_underwater_medium()
@export var underwater_sunrays := true:
	set(value):
		underwater_sunrays = value
		_sync_underwater_medium()

@export var caustics := false:
	set(value):
		caustics = value
		_sync_caustics_runtime()

@export_subgroup("Atmospherics")
## Master gate. When OFF the controller and all GPUParticles3D instances are absent.
@export var enable_spindrift := false:
	set(value):
		enable_spindrift = value
		if _open_ocean != null:
			_open_ocean.set_spindrift_enabled(enable_spindrift, spindrift_profile, spindrift_debug_mode)
			_apply_spindrift_visual_freeze()

@export_group("System Resources")
@export_subgroup("Core")
@export var wave_profile: Resource:
	set(value):
		if wave_profile == value:
			_connect_profile_changed(wave_profile, _on_wave_profile_changed)
			return
		_disconnect_profile_changed(wave_profile, _on_wave_profile_changed)
		wave_profile = value
		_connect_profile_changed(wave_profile, _on_wave_profile_changed)
		_request_rebuild()
@export var quality_profile: Resource:
	set(value):
		if quality_profile == value:
			_connect_profile_changed(quality_profile, _on_quality_profile_changed)
			return
		_disconnect_profile_changed(quality_profile, _on_quality_profile_changed)
		quality_profile = value
		_connect_profile_changed(quality_profile, _on_quality_profile_changed)
		_request_rebuild()
@export_subgroup("Coastal")
@export var coastal_bake: Resource:
	set(value):
		coastal_bake = value
		_sync_coastal_runtime()
@export_subgroup("Surface")
@export var crest_foam_profile: OceanCrestFoamProfile:
	set(value):
		if crest_foam_profile == value:
			_connect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
			return
		_disconnect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
		crest_foam_profile = value
		_connect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
		if _open_ocean != null: _open_ocean.set_crest_foam_profile(crest_foam_profile)
@export var surface_foam_profile: OceanSurfaceFoamProfile:
	set(value):
		if surface_foam_profile == value:
			_connect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
			return
		_disconnect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
		surface_foam_profile = value
		_connect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
		if _open_ocean != null: _open_ocean.set_surface_foam_profile(surface_foam_profile)
@export var optics_profile: OceanOpticsProfile:
	set(value):
		if optics_profile == value:
			_connect_profile_changed(optics_profile, _on_optics_profile_changed)
			return
		_disconnect_profile_changed(optics_profile, _on_optics_profile_changed)
		optics_profile = value
		_connect_profile_changed(optics_profile, _on_optics_profile_changed)
		if _open_ocean != null:
			_open_ocean.set_optics_profile(optics_profile)
			_sync_coastal_runtime()
@export var reflection_profile: OceanReflectionProfile:
	set(value):
		if reflection_profile == value:
			_connect_profile_changed(reflection_profile, _on_reflection_profile_changed)
			return
		_disconnect_profile_changed(reflection_profile, _on_reflection_profile_changed)
		reflection_profile = value
		_connect_profile_changed(reflection_profile, _on_reflection_profile_changed)
		if _open_ocean != null:
			_open_ocean.set_reflection_profile(reflection_profile)
@export var surface_detail_profile: OceanSurfaceDetailProfile:
	set(value):
		if surface_detail_profile == value:
			_connect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
			return
		_disconnect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
		surface_detail_profile = value
		_connect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
		if _open_ocean != null:
			_open_ocean.set_surface_detail_profile(surface_detail_profile)
@export_subgroup("Underwater")
@export var underwater_medium_profile: OceanUnderwaterMediumProfile:
	set(value):
		if underwater_medium_profile == value:
			_connect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
			return
		_disconnect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
		underwater_medium_profile = value
		_connect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
		_sync_underwater_medium()
@export var underwater_bubble_profile: OceanUnderwaterBubbleProfile:
	set(value):
		if underwater_bubble_profile == value:
			_connect_profile_changed(underwater_bubble_profile, _on_underwater_bubble_profile_changed)
			return
		_disconnect_profile_changed(underwater_bubble_profile, _on_underwater_bubble_profile_changed)
		underwater_bubble_profile = value
		_connect_profile_changed(underwater_bubble_profile, _on_underwater_bubble_profile_changed)
		_sync_underwater_medium()
@export var underwater_sunray_profile: OceanUnderwaterSunrayProfile:
	set(value):
		if underwater_sunray_profile == value:
			_connect_profile_changed(underwater_sunray_profile, _on_underwater_sunray_profile_changed)
			return
		_disconnect_profile_changed(underwater_sunray_profile, _on_underwater_sunray_profile_changed)
		underwater_sunray_profile = value
		_connect_profile_changed(underwater_sunray_profile, _on_underwater_sunray_profile_changed)
		_sync_underwater_medium()

@export var caustics_profile: OceanCausticsProfile:
	set(value):
		if caustics_profile == value:
			_connect_profile_changed(caustics_profile, _on_caustics_profile_changed)
			return
		_disconnect_profile_changed(caustics_profile, _on_caustics_profile_changed)
		caustics_profile = value
		_connect_profile_changed(caustics_profile, _on_caustics_profile_changed)
		_sync_caustics_runtime()
## Optional explicit DirectionalLight3D used by Underwater Sunrays. Leave empty to use AUTO scene fallback.
@export var underwater_sun_light: DirectionalLight3D:
	set(value):
		underwater_sun_light = value
		_underwater_sun_explicit = value != null
		_scene_lighting.invalidate()
		_sync_underwater_medium()
		_sync_caustics_runtime()

## Optional moon. AUTO uses the other light only when the scene has exactly two
## directional lights. No time-of-day plugin or node name is required.
@export var underwater_moon_light: DirectionalLight3D:
	set(value):
		underwater_moon_light = value
		_scene_lighting.invalidate()
## Optional environment override; otherwise use this Ocean's World3D environment.
@export var underwater_environment: WorldEnvironment:
	set(value):
		underwater_environment = value
		_scene_lighting.invalidate()


func get_scene_lighting_state() -> Dictionary:
	return _scene_lighting.sample(self, underwater_sun_light, underwater_moon_light, underwater_environment)


func get_underwater_lighting_influence() -> float:
	return underwater_medium_profile.scene_lighting_influence if underwater_medium_profile != null else 1.0

@export_subgroup("Breakers")
@export var breaker_profile: OceanBreakerProfile:
	set(value):
		if breaker_profile == value:
			_connect_profile_changed(breaker_profile, _on_breaker_profile_changed)
			return
		_disconnect_profile_changed(breaker_profile, _on_breaker_profile_changed)
		breaker_profile = value
		_connect_profile_changed(breaker_profile, _on_breaker_profile_changed)
		if _open_ocean != null:
			_open_ocean.set_breaker_profile(breaker_profile)

@export_subgroup("Spindrift")
@export var spindrift_profile: OceanSpindriftProfile:
	set(value):
		_disconnect_profile_changed(spindrift_profile, _on_spindrift_profile_changed)
		spindrift_profile = value
		_connect_profile_changed(spindrift_profile, _on_spindrift_profile_changed)
		if _open_ocean != null:
			_open_ocean.set_spindrift_enabled(enable_spindrift, spindrift_profile, spindrift_debug_mode)
			_apply_spindrift_visual_freeze()

@export_group("Advanced")
@export_subgroup("Breaker Refinement")
## Production prototype gate. It is deliberately OFF for normal scenes.
@export var local_breaker_refinement_enabled := false:
	set(value):
		local_breaker_refinement_enabled = value
		if _open_ocean != null:
			_open_ocean.set_local_breaker_refinement_enabled(value)

@export_group("Diagnostics")
@export_subgroup("General")
@export var performance_overlay := false:
	set(value):
		performance_overlay = value
		_update_overlay()
@export_enum("Off", "Normals") var debug_view: int = DebugView.OFF:
	set(value):
		debug_view = clampi(value, DebugView.OFF, DebugView.NORMALS)
		if _open_ocean != null: _open_ocean.set_debug_view(debug_view)
@export_subgroup("Breakers")
## Validation-only overlay for inspecting the real LONG fresh-foam signal and
## the detector's edge/rejection conditions. OFF is the production default.
@export_enum("OFF:0", "FRESH_FOAM:1", "THRESHOLD_MARGIN:2", "REJECTION_REASON:3", "THRESHOLD_EDGE:4") var breaker_detector_debug_mode := 0:
	set(value):
		breaker_detector_debug_mode = clampi(value, 0, 4)
		if _open_ocean != null:
			_open_ocean.set_breaker_detector_debug_mode(breaker_detector_debug_mode, breaker_profile)
		_sync_breaker_detector_debug_ui()
@export var breaker_detector_probe_enabled := false:
	set(value):
		breaker_detector_probe_enabled = value
		_apply_breaker_detector_probe()
		_sync_breaker_detector_debug_ui()
@export var breaker_detector_probe_xz := Vector2.ZERO:
	set(value):
		breaker_detector_probe_xz = value
		_apply_breaker_detector_probe()
@export_range(0, 2147483647, 1) var breaker_detector_probe_reset_serial := 0:
	set(value):
		breaker_detector_probe_reset_serial = value
		_apply_breaker_detector_probe()
@export_range(0, 2147483647, 1) var breaker_detector_capture_arm_serial := 0:
	set(value):
		breaker_detector_capture_arm_serial = value
		_apply_breaker_detector_capture_control()
@export_range(0, 2147483647, 1) var breaker_detector_capture_release_serial := 0:
	set(value):
		breaker_detector_capture_release_serial = value
		_apply_breaker_detector_capture_control()
@export var local_breaker_refinement_debug := false:
	set(value):
		local_breaker_refinement_debug = value
		if _open_ocean != null and _open_ocean.has_method(&"set_local_breaker_refinement_debug_visible"):
			_open_ocean.set_local_breaker_refinement_debug_visible(value)
@export_subgroup("Spindrift")
@export_enum("OFF", "SOURCE_MASK_REAL", "CHUNKS_ONLY", "SPINDRIFT_ONLY", "MIST_ONLY", "FULL", "FORCE_EMISSION", "HEIGHT_ONLY", "STEEPNESS_ONLY", "CREST_ONLY", "POSITION_DEBUG", "SOURCE_MASK_FORCE_0", "SOURCE_MASK_FORCE_1", "POSITION_DEBUG_FORCE", "DEBUG_HEIGHT_RAW", "DEBUG_HEIGHT_GATE", "DEBUG_STEEPNESS_RAW", "DEBUG_STEEPNESS_GATE", "DEBUG_CREST_RAW", "DEBUG_CREST_GATE", "DEBUG_BREAKUP_RAW", "DEBUG_DOMAIN_FADE", "DEBUG_CLIPMAP_FADE", "DEBUG_SOURCE_PRE_THRESHOLD", "DEBUG_SOURCE_FINAL", "DEBUG_SHORT_FADE", "DEBUG_MID_FADE", "DEBUG_LONG_FADE", "DEBUG_ACTIVE_RADIUS_FADE", "DEBUG_CREST_GT_001", "DEBUG_CREST_GT_002", "DEBUG_CREST_GT_005", "DEBUG_CREST_GT_010", "DEBUG_CREST_GT_020", "DEBUG_CREST_GT_040", "DEBUG_CREST_GT_060", "DEBUG_CREST_GAIN_1", "DEBUG_CREST_GAIN_4", "DEBUG_CREST_GAIN_8", "DEBUG_CREST_GAIN_16") var spindrift_debug_mode: int = SpindriftController.DebugMode.FULL:
	set(value):
		spindrift_debug_mode = clampi(value, SpindriftController.DebugMode.OFF, SpindriftController.DebugMode.DEBUG_CREST_GAIN_16)
		if _open_ocean != null:
			_open_ocean.set_spindrift_debug_mode(spindrift_debug_mode)

## Temporary validation-only control for the H4.31 art gate, exposed here so the
## Ocean node is the only node that has to be selected. It freezes the
## already-emitted detached children in place, which makes silhouette,
## directionality and texture edges inspectable from any camera angle without
## touching the GPUParticles3D children in the Remote Inspector. Sensors,
## emission, pooling and every shader stay untouched.
@export var freeze_spindrift_visuals := false:
	set(value):
		freeze_spindrift_visuals = value
		_apply_spindrift_visual_freeze()

var _open_ocean: Node3D
var _underwater_medium: OceanUnderwaterMedium
var _caustics_manager: OceanCausticsManager
var _underwater_sun_explicit := false
var _overlay: Label
var _initializing := false
var _rebuild_requested := false
var _rebuild_debounce_remaining := -1.0
var _wave_time := 0.0
var _fft_cascade_mask := CascadeState.FULL
var _updating_fft_cascade_state := false
var _waterline_state_readback_enabled := true
var _local_breaker_refinement_authority: Dictionary = {}
var _breaker_detector_capture_panel: Label
var _breaker_detector_probe_marker: MeshInstance3D


func _ready() -> void:
	_connect_profile_changed(wave_profile, _on_wave_profile_changed)
	_connect_profile_changed(quality_profile, _on_quality_profile_changed)
	_connect_profile_changed(optics_profile, _on_optics_profile_changed)
	_connect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
	_connect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
	_connect_profile_changed(reflection_profile, _on_reflection_profile_changed)
	_connect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
	_connect_profile_changed(breaker_profile, _on_breaker_profile_changed)
	_connect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
	_connect_profile_changed(underwater_bubble_profile, _on_underwater_bubble_profile_changed)
	_connect_profile_changed(underwater_sunray_profile, _on_underwater_sunray_profile_changed)
	_connect_profile_changed(spindrift_profile, _on_spindrift_profile_changed)
	_connect_profile_changed(caustics_profile, _on_caustics_profile_changed)
	set_process(false)
	if Engine.is_editor_hint():
		_sync_editor_preview.call_deferred()
		return
	_sync_breaker_detector_debug_ui()
	_sync_underwater_medium()
	if enabled and open_ocean_fft: initialize()
	# In inherited validation scenes an exported P6 override can be applied after
	# this first ready pass. Re-sync once the scene's final property state exists.
	call_deferred(&"_sync_underwater_medium")


func initialize() -> bool:
	if _initializing:
		_rebuild_requested = true
		return false
	if _open_ocean != null: return true
	if wave_profile == null or quality_profile == null:
		_physics_source_status = "ERROR"
		push_error("Ocean necesita Wave Profile y Quality Profile.")
		return false
	_initializing = true
	var candidate := OpenOcean.new()
	candidate.name = &"OpenOceanFFT"
	add_child(candidate)
	var manual_hs := significant_wave_height_m if sea_state_mode == 1 else -1.0
	var initialized := candidate.initialize(wave_profile, quality_profile, simulation_seed, sea_level, manual_hs, wind_speed_mps, wind_direction_degrees, swell, crest_foam, surface_foam, crest_foam_profile, surface_foam_profile, wave_height_scale, long_band_scale, mid_band_scale, short_band_scale, _wave_time, _fft_cascade_mask, long_wave_spacing, mid_fill_amount)
	if initialized:
		# Publicar sólo un runtime completamente construido. Los setters pueden
		# solicitar un rebuild durante la construcción, pero nunca desmontarlo.
		_open_ocean = candidate
		_open_ocean.set_enabled(enabled and open_ocean_fft)
		_open_ocean.set_surface_scale(ocean_scale)
		_open_ocean.set_clipmap_geometry_scale(clipmap_geometry_scale)
		_open_ocean.set_wave_speed_multiplier(wave_speed_multiplier)
		_apply_visual_water_profile()
		_open_ocean.set_debug_view(debug_view)
		_open_ocean.set_crest_foam(crest_foam)
		_open_ocean.set_surface_foam(surface_foam)
		_open_ocean.set_crest_foam_profile(crest_foam_profile)
		_open_ocean.set_surface_foam_profile(surface_foam_profile)
		_open_ocean.set_optics(optics, optics_profile)
		_sync_coastal_runtime()
		_open_ocean.set_reflections(reflections, reflection_profile)
		_open_ocean.set_surface_detail(surface_detail, surface_detail_profile)
		_open_ocean.set_breakers(breakers, breaker_profile)
		_open_ocean.set_breaker_profile(breaker_profile)
		_open_ocean.set_breaker_detector_debug_mode(breaker_detector_debug_mode, breaker_profile)
		_open_ocean.set_breaker_detector_probe(breaker_detector_probe_enabled, breaker_detector_probe_xz, breaker_detector_probe_reset_serial)
		_open_ocean.set_breaker_detector_capture_control(breaker_detector_capture_arm_serial, breaker_detector_capture_release_serial)
		_open_ocean.set_local_breaker_refinement_enabled(local_breaker_refinement_enabled)
		_open_ocean.set_local_breaker_refinement_authority(_local_breaker_refinement_authority)
		_open_ocean.set_spindrift_enabled(enable_spindrift, spindrift_profile, spindrift_debug_mode)
		_apply_spindrift_visual_freeze()
		_sync_underwater_medium()
		_sync_caustics_runtime()
		_update_overlay()
		_physics_source_revision += 1
		_physics_source_status = "OK"
	else:
		_physics_source_status = "ERROR"
		candidate.shutdown()
		candidate.queue_free()
	_initializing = false
	if _rebuild_requested:
		_rebuild_requested = false
		_request_rebuild()
	return initialized


func set_fft_cascade_mask(mask: int) -> void:
	_fft_cascade_mask = clampi(mask, 0, CascadeState.FULL) & CascadeState.FULL
	if not _updating_fft_cascade_state:
		_updating_fft_cascade_state = true
		long_enabled = bool(_fft_cascade_mask & CascadeState.LONG)
		mid_enabled = bool(_fft_cascade_mask & CascadeState.MID)
		short_enabled = bool(_fft_cascade_mask & CascadeState.SHORT)
		_updating_fft_cascade_state = false
	_request_rebuild()


func _update_fft_cascade_mask() -> void:
	if _updating_fft_cascade_state:
		return
	var mask := 0
	if long_enabled:
		mask |= CascadeState.LONG
	if mid_enabled:
		mask |= CascadeState.MID
	if short_enabled:
		mask |= CascadeState.SHORT
	set_fft_cascade_mask(mask)


func get_fft_cascade_mask() -> int:
	return _fft_cascade_mask


## Current simulation clock. Consumers should not read OpenOceanFFT internals.
func get_wave_time() -> float:
	if is_instance_valid(_open_ocean) and _open_ocean.has_method(&"get_wave_time"):
		return _open_ocean.get_wave_time()
	return _wave_time


## Returns the authoring values that define the active sea state.
func get_sea_state() -> Dictionary:
	return {
		"sea_state_mode": sea_state_mode,
		"significant_wave_height_m": significant_wave_height_m,
		"wave_height_scale": wave_height_scale,
		"wave_speed_multiplier": wave_speed_multiplier,
		"wind_speed_mps": wind_speed_mps,
		"wind_direction_degrees": wind_direction_degrees,
		"swell": swell,
	}


## Applies a partial sea-state update. Unknown keys reject the update.
func set_sea_state(state: Dictionary) -> bool:
	const ALLOWED_KEYS: Array[StringName] = [
		&"sea_state_mode", &"significant_wave_height_m", &"wave_height_scale",
		&"wave_speed_multiplier", &"wind_speed_mps", &"wind_direction_degrees", &"swell",
	]
	for key in state:
		if StringName(key) not in ALLOWED_KEYS or typeof(state[key]) not in [TYPE_FLOAT, TYPE_INT]:
			return false
	for key in state:
		set(StringName(key), state[key])
	return true


## Returns the externally authorable feature gates, including optional breakers.
func get_feature_flags() -> Dictionary:
	return {
		"open_ocean_fft": open_ocean_fft,
		"coastal": coastal,
		"crest_foam": crest_foam,
		"surface_foam": surface_foam,
		"breakers": breakers,
		"optics": optics,
		"reflections": reflections,
		"surface_detail": surface_detail,
		"underwater_medium": underwater_medium,
		"underwater_bubbles": underwater_bubbles,
		"underwater_sunrays": underwater_sunrays,
		"caustics": caustics,
		"enable_spindrift": enable_spindrift,
	}


## Applies a partial feature-flag update. Unknown keys or non-boolean values reject it.
func set_feature_flags(flags: Dictionary) -> bool:
	const ALLOWED_KEYS: Array[StringName] = [
		&"open_ocean_fft", &"coastal", &"crest_foam", &"surface_foam", &"breakers",
		&"optics", &"reflections", &"surface_detail", &"underwater_medium",
		&"underwater_bubbles", &"underwater_sunrays", &"caustics", &"enable_spindrift",
	]
	for key in flags:
		if StringName(key) not in ALLOWED_KEYS or typeof(flags[key]) != TYPE_BOOL:
			return false
	for key in flags:
		set(StringName(key), flags[key])
	return true


func shutdown() -> void:
	if _initializing:
		_rebuild_requested = true
		return
	_physics_source_status = "UPDATING"
	physics_source_invalidated.emit()
	# Detach P6 before retiring its published FFT source RIDs.
	_shutdown_caustics_manager()
	_shutdown_underwater_medium()
	if _open_ocean != null:
		_open_ocean.shutdown()
		# queue_free() is deferred. Release the public name before creating the
		# replacement during the same-frame runtime rebuild.
		_open_ocean.name = &"RetiringOpenOceanFFT"
		_open_ocean.queue_free()
		_open_ocean = null
	if _overlay != null:
		_overlay.queue_free()
		_overlay = null


func _exit_tree() -> void:
	if is_instance_valid(_editor_preview_node):
		_editor_preview_node.shutdown()
		_editor_preview_node.queue_free()
		_editor_preview_node = null
	_rebuild_debounce_remaining = -1.0
	set_process(false)
	_disconnect_profile_changed(wave_profile, _on_wave_profile_changed)
	_disconnect_profile_changed(quality_profile, _on_quality_profile_changed)
	_disconnect_profile_changed(optics_profile, _on_optics_profile_changed)
	_disconnect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
	_disconnect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
	_disconnect_profile_changed(reflection_profile, _on_reflection_profile_changed)
	_disconnect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
	_disconnect_profile_changed(breaker_profile, _on_breaker_profile_changed)
	_disconnect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
	_disconnect_profile_changed(underwater_bubble_profile, _on_underwater_bubble_profile_changed)
	_disconnect_profile_changed(underwater_sunray_profile, _on_underwater_sunray_profile_changed)
	_disconnect_profile_changed(spindrift_profile, _on_spindrift_profile_changed)
	_disconnect_profile_changed(caustics_profile, _on_caustics_profile_changed)
	shutdown()


func _sync_editor_preview() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if not editor_preview:
		if is_instance_valid(_editor_preview_node):
			_editor_preview_node.shutdown()
			_editor_preview_node.queue_free()
			_editor_preview_node = null
		return
	if not is_instance_valid(_editor_preview_node):
		_editor_preview_node = EditorPreview.new()
		_editor_preview_node.name = &"OceanEditorPreview"
		add_child(_editor_preview_node, false, Node.INTERNAL_MODE_BACK)
		_editor_preview_node.configure(self)


func _refresh_editor_preview() -> void:
	_sync_editor_preview()
	if Engine.is_editor_hint() and is_instance_valid(_editor_preview_node):
		_editor_preview_node.request_refresh()


func _apply_visual_water_profile() -> void:
	if not is_instance_valid(_open_ocean):
		return
	var profile: StringName = &"PHYSICS_ALIGNED" if visual_water_profile == VisualWaterProfile.PHYSICS_ALIGNED else &"FULL_CHOPPY_DEBUG"
	if StringName(str(_open_ocean.get("_visual_horizontal_displacement_profile"))) != profile:
		_open_ocean.call(&"set_visual_horizontal_displacement_profile", profile)


func _on_wave_profile_changed() -> void:
	_request_rebuild()


func _on_quality_profile_changed() -> void:
	_request_rebuild()


func _on_optics_profile_changed() -> void:
	if _open_ocean != null:
		_open_ocean.set_optics_profile(optics_profile)
		_sync_coastal_runtime()


func _on_crest_foam_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_crest_foam_profile(crest_foam_profile)
	_sync_underwater_medium()


func _on_surface_foam_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_surface_foam_profile(surface_foam_profile)


func _on_reflection_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_reflection_profile(reflection_profile)


func _on_surface_detail_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_surface_detail_profile(surface_detail_profile)


func _on_breaker_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_breaker_profile(breaker_profile)


func _on_underwater_medium_profile_changed() -> void:
	# Resource edits update only CPU packet state. RenderingDevice work stays render-thread owned.
	_sync_underwater_medium()


func _on_underwater_bubble_profile_changed() -> void:
	_sync_underwater_medium()


func _on_underwater_sunray_profile_changed() -> void:
	_sync_underwater_medium()


func _on_caustics_profile_changed() -> void:
	_sync_caustics_runtime()


func _on_spindrift_profile_changed() -> void:
	if _open_ocean != null:
		_open_ocean.set_spindrift_enabled(enable_spindrift, spindrift_profile, spindrift_debug_mode)
		_apply_spindrift_visual_freeze()


func _apply_spindrift_visual_freeze() -> void:
	## The controller is recreated whenever Spindrift is rebuilt, so the authoring
	## value lives on the Ocean node and is pushed to the controller here.
	if _open_ocean == null:
		return
	var spindrift: SpindriftController = _open_ocean.get(&"_spindrift") as SpindriftController
	if spindrift != null:
		spindrift.freeze_spindrift_visuals = freeze_spindrift_visuals


func _sync_underwater_medium() -> void:
	if Engine.is_editor_hint() or not is_inside_tree(): return
	if not enabled or not underwater_medium:
		_shutdown_underwater_medium()
		return
	if _open_ocean == null:
		return
	if _underwater_medium == null:
		_underwater_medium = UnderwaterMedium.new()
		_underwater_medium.name = &"OceanUnderwaterMedium"
		add_child(_underwater_medium)
		_underwater_medium.configure(sea_level, underwater_medium_profile)
		_underwater_medium.set_surface_source(_open_ocean)
	else:
		_underwater_medium.update(sea_level, underwater_medium_profile)
		_underwater_medium.set_surface_source(_open_ocean)
	_underwater_medium.set_waterline_state_readback_enabled(_waterline_state_readback_enabled)
	if is_instance_valid(_hull_foam_runtime):
		publish_hull_wave_render_state(_hull_foam_runtime.get_wave_render_state())
	_underwater_medium.set_bubbles(underwater_bubbles, underwater_bubble_profile, wind_direction_degrees)
	_underwater_medium.set_sun_light_authority(underwater_sun_light, _underwater_sun_explicit)
	_underwater_medium.set_sunrays(underwater_sunrays, underwater_sunray_profile)


func _sync_caustics_runtime() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	if not enabled or not caustics:
		_shutdown_caustics_manager()
		return
	if _open_ocean == null:
		return
	if _caustics_manager == null or not is_instance_valid(_caustics_manager):
		_caustics_manager = CausticsManager.new()
		_caustics_manager.name = &"OceanCausticsManager"
		add_child(_caustics_manager)
		_caustics_manager.configure(self, sea_level, caustics_profile, underwater_sun_light)
	else:
		_caustics_manager.set_settings(sea_level, caustics_profile, underwater_sun_light)


func _shutdown_caustics_manager() -> void:
	if _caustics_manager == null:
		return
	_caustics_manager.shutdown()
	_caustics_manager.name = &"RetiringOceanCausticsManager"
	_caustics_manager.queue_free()
	_caustics_manager = null


func set_waterline_state_readback_enabled(enabled: bool) -> void:
	_waterline_state_readback_enabled = enabled
	if _underwater_medium != null:
		_underwater_medium.set_waterline_state_readback_enabled(enabled)


func get_waterline_state() -> Dictionary:
	if _underwater_medium == null:
		return {"valid": false, "frame": 0}
	return _underwater_medium.get_waterline_state()


func get_runtime_feature_state() -> Dictionary:
	var open_state: Dictionary = _open_ocean.get_runtime_feature_state() if _open_ocean != null and _open_ocean.has_method(&"get_runtime_feature_state") else {}
	var medium_state: Dictionary = _underwater_medium.get_runtime_feature_state() if _underwater_medium != null and _underwater_medium.has_method(&"get_runtime_feature_state") else {}
	return {
		"surface_present": open_state.get("surface_present", false),
		"shader_variant_key": open_state.get("shader_variant_key", ""),
		"crest_foam": open_state.get("crest_foam", false),
		"surface_foam": open_state.get("surface_foam", false),
		"optics": open_state.get("optics", false),
		"reflections": open_state.get("reflections", false),
		"sspr": open_state.get("sspr", false),
		"surface_detail": open_state.get("surface_detail", false),
		"breakers_requested": open_state.get("breakers_requested", false),
		"breakers": open_state.get("breakers", false),
		"breakers_runtime_active": open_state.get("breakers_runtime_active", false),
		"breaker_detector_probe": open_state.get("breaker_detector_probe", {"valid": false}),
		"local_breaker_refinement_enabled": open_state.get("local_breaker_refinement_enabled", false),
		"local_breaker_refinement": open_state.get("local_breaker_refinement", {}),
		"underwater": medium_state.get("medium", false),
		"bubbles": medium_state.get("bubbles", false),
		"sunrays": medium_state.get("sunrays", false),
		"runtime_water_state": medium_state.get("runtime_water_state", "TRANSITION"),
		"readback_mode": medium_state.get("readback_mode", "ASYNC"),
		"readback_pending": medium_state.get("readback_pending", false),
		"readback_age_frames": medium_state.get("readback_age_frames", -1),
		"medium_fullscreen_active": medium_state.get("medium_fullscreen_active", true),
		"waterline_raster_active": medium_state.get("waterline_raster_active", true),
		"bubbles_runtime_active": medium_state.get("bubbles_runtime_active", false),
		"sunrays_runtime_active": medium_state.get("sunrays_runtime_active", false),
		"sun_authority_mode": medium_state.get("sun_authority_mode", "AUTO"),
		"sun_light_valid": medium_state.get("sun_light_valid", false),
		"sun_light_instance_id": medium_state.get("sun_light_instance_id", 0),
		"sun_candidate_count": medium_state.get("sun_candidate_count", 0),
		"sun_light_into_water": medium_state.get("sun_light_into_water", Vector3.ZERO),
		"sun_light_color": medium_state.get("sun_light_color", Color.BLACK),
		"sun_light_energy": medium_state.get("sun_light_energy", 0.0),
		"sun_resolution": medium_state.get("sun_resolution", "UNAVAILABLE"),
		"transition_resources_warmed": medium_state.get("transition_resources_warmed", false),
		"bubble_simulation_resources_warmed": medium_state.get("bubble_simulation_resources_warmed", false),
		"sspr_runtime_active": open_state.get("sspr_runtime_active", false),
		"optics_runtime_active": open_state.get("optics_runtime_active", false),
		"surface_detail_runtime_active": open_state.get("surface_detail_runtime_active", false),
		"surface_foam_presentation_active": open_state.get("surface_foam_presentation_active", false),
		"surface_foam_update_hz": open_state.get("surface_foam_update_hz", 30.0),
		"spindrift": open_state.get("spindrift", false),
		"spindrift_runtime": open_state.get("spindrift_runtime", {}),
		"authoring": {
			"surface_foam": surface_foam,
			"optics": optics,
			"reflections": reflections,
			"surface_detail": surface_detail,
			"breakers": breakers,
			"underwater_medium": underwater_medium,
			"underwater_bubbles": underwater_bubbles,
			"underwater_sunrays": underwater_sunrays,
		},
}


func get_breaker_detector_probe_state() -> Dictionary:
	if _open_ocean != null and _open_ocean.has_method(&"get_breaker_detector_probe_state"):
		return _open_ocean.get_breaker_detector_probe_state()
	return {"valid": false}


func get_breaker_detector_capture_state() -> Dictionary:
	if _open_ocean != null and _open_ocean.has_method(&"get_breaker_detector_capture_state"):
		return _open_ocean.get_breaker_detector_capture_state()
	return {"capture_armed": false, "capture_frozen": false, "capture_complete_gpu": false}


func _apply_breaker_detector_probe() -> void:
	if _open_ocean != null:
		_open_ocean.set_breaker_detector_probe(breaker_detector_probe_enabled, breaker_detector_probe_xz, breaker_detector_probe_reset_serial)


func _apply_breaker_detector_capture_control() -> void:
	if _open_ocean != null:
		_open_ocean.set_breaker_detector_capture_control(breaker_detector_capture_arm_serial, breaker_detector_capture_release_serial)


func _sync_breaker_detector_debug_ui() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	var debug_visible := breaker_detector_debug_mode != 0 and breaker_detector_probe_enabled
	if not debug_visible:
		if is_instance_valid(_breaker_detector_capture_panel):
			_breaker_detector_capture_panel.get_parent().queue_free()
		_breaker_detector_capture_panel = null
		if is_instance_valid(_breaker_detector_probe_marker):
			_breaker_detector_probe_marker.queue_free()
		_breaker_detector_probe_marker = null
		if _rebuild_debounce_remaining < 0.0:
			set_process(false)
		return
	if not is_instance_valid(_breaker_detector_capture_panel):
		var canvas := CanvasLayer.new()
		canvas.name = &"BreakerDetectorCaptureHUD"
		canvas.layer = 120
		_breaker_detector_capture_panel = Label.new()
		_breaker_detector_capture_panel.name = &"CaptureState"
		_breaker_detector_capture_panel.position = Vector2(18.0, 18.0)
		_breaker_detector_capture_panel.size = Vector2(1100.0, 250.0)
		_breaker_detector_capture_panel.add_theme_font_size_override(&"font_size", 15)
		_breaker_detector_capture_panel.add_theme_color_override(&"font_color", Color(1.0, 0.95, 0.72))
		_breaker_detector_capture_panel.add_theme_color_override(&"font_shadow_color", Color(0.0, 0.0, 0.0, 0.98))
		_breaker_detector_capture_panel.add_theme_constant_override(&"shadow_offset_x", 2)
		_breaker_detector_capture_panel.add_theme_constant_override(&"shadow_offset_y", 2)
		canvas.add_child(_breaker_detector_capture_panel)
		add_child(canvas)
	if not is_instance_valid(_breaker_detector_probe_marker):
		var marker_mesh := SphereMesh.new()
		marker_mesh.radius = 0.45
		marker_mesh.height = 0.90
		marker_mesh.radial_segments = 16
		marker_mesh.rings = 8
		var marker_material := ShaderMaterial.new()
		var marker_shader := Shader.new()
		marker_shader.code = BREAKER_DETECTOR_MARKER_SHADER
		marker_material.shader = marker_shader
		_breaker_detector_probe_marker = MeshInstance3D.new()
		_breaker_detector_probe_marker.name = &"BreakerDetectorResolvedCellMarker"
		_breaker_detector_probe_marker.mesh = marker_mesh
		_breaker_detector_probe_marker.material_override = marker_material
		_breaker_detector_probe_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_breaker_detector_probe_marker)
	set_process(true)
	_update_breaker_detector_debug_ui()


func _update_breaker_detector_debug_ui() -> void:
	if not is_instance_valid(_breaker_detector_capture_panel) or not is_instance_valid(_breaker_detector_probe_marker) or _open_ocean == null:
		return
	var probe_state: Dictionary = get_breaker_detector_probe_state()
	var capture_state: Dictionary = get_breaker_detector_capture_state()
	var capture_id := int(capture_state.get("capture_id", 0))
	var cell: Vector2i = probe_state.get("cell", Vector2i(-1, -1))
	var resolved: Vector2 = probe_state.get("resolved_cell_world_xz", Vector2.ZERO)
	var valid := bool(probe_state.get("valid", false))
	var status := "ARMED" if bool(capture_state.get("capture_armed", false)) else "FROZEN" if bool(capture_state.get("capture_frozen", false)) else "LIVE"
	var wave_error := float(capture_state.get("wave_time_error", -1.0))
	var lifecycle_error := float(capture_state.get("lifecycle_time_error", -1.0))
	var resume_text := "not resumed"
	if bool(capture_state.get("capture_released", false)) and capture_state.has("resume_first_wave_delta"):
		resume_text = "delta %.6f s (dt %.6f s, residual %.9f s)" % [float(capture_state.get("resume_first_wave_delta", 0.0)), float(capture_state.get("resume_first_simulation_dt", 0.0)), float(capture_state.get("resume_first_wave_delta_error", 0.0))]
	_breaker_detector_capture_panel.text = """
	BREAKER PROBE  |  %s  |  CAPTURE ID %d  |  GPU READBACK %s
	WAVE %.6f  frozen %.6f  error %.9f   |   LIFECYCLE %.6f  frozen %.6f  error %.9f
	CELL %d,%d  |  XZ (%.3f, %.3f)  |  FRESH G %.4f  THRESHOLD %.4f  LONG SLOPE %.4f
	ABOVE %s  EDGE %s  DUPLICATE %s  REFRACTORY %s  PREVIOUS ACTIVE %s
	SEED %.4f  EVENT SCORE %.4f
	RELEASE FIRST FRAME: %s
	""" % [status, capture_id, "MATCH" if bool(capture_state.get("capture_complete_gpu", false)) else "INVALID" if bool(capture_state.get("capture_invalid", false)) else "WAIT", float(capture_state.get("current_wave_time", 0.0)), float(capture_state.get("captured_wave_time", 0.0)), wave_error, float(capture_state.get("current_lifecycle_time", 0.0)), float(capture_state.get("captured_lifecycle_time", 0.0)), lifecycle_error, cell.x, cell.y, resolved.x, resolved.y, float(probe_state.get("fresh_foam", 0.0)), float(probe_state.get("threshold", 0.0)), float(probe_state.get("long_surface_slope", 0.0)), str(probe_state.get("above_threshold", false)), str(probe_state.get("threshold_edge", false)), str(probe_state.get("duplicate_event", false)), str(probe_state.get("refractory_active", false)), str(probe_state.get("previous_active", false)), float(probe_state.get("seed", 0.0)), float(probe_state.get("event_score", 0.0)), resume_text]
	_breaker_detector_probe_marker.visible = valid
	if not valid:
		return
	_breaker_detector_probe_marker.global_position = Vector3(resolved.x, sea_level, resolved.y)
	var marker_material := _breaker_detector_probe_marker.material_override as ShaderMaterial
	var marker_sources: Dictionary = _open_ocean.get_breaker_detector_probe_marker_sources(resolved) if _open_ocean.has_method(&"get_breaker_detector_probe_marker_sources") else {}
	var textures: Array = marker_sources.get("textures", [])
	var uvs: Array = marker_sources.get("uvs", [])
	if textures.size() == 3 and uvs.size() == 3:
		marker_material.set_shader_parameter(&"displacement_long", textures[0])
		marker_material.set_shader_parameter(&"displacement_mid", textures[1])
		marker_material.set_shader_parameter(&"displacement_short", textures[2])
		marker_material.set_shader_parameter(&"probe_uv_long", uvs[0])
		marker_material.set_shader_parameter(&"probe_uv_mid", uvs[1])
		marker_material.set_shader_parameter(&"probe_uv_short", uvs[2])


func get_spindrift_runtime_state() -> Dictionary:
	if _open_ocean != null and _open_ocean.has_method(&"get_spindrift_runtime_state"):
		return _open_ocean.get_spindrift_runtime_state()
	return {"enabled": false, "configured_max_live_particles": 0}


func _shutdown_underwater_medium() -> void:
	if _underwater_medium == null: return
	_underwater_medium.shutdown()
	_underwater_medium.name = &"RetiringOceanUnderwaterMedium"
	_underwater_medium.queue_free()
	_underwater_medium = null


func _sync_coastal_runtime() -> void:
	if _open_ocean == null:
		return
	# Coastal waves and P4 optical seabed authority are the only consumers of a
	# bake. When both are OFF, passing null removes publication/consumption from
	# the active surface while OpenOceanFFT may keep its resident cache.
	var required_bake: Resource = coastal_bake if coastal or optics else null
	_open_ocean.set_coastal(coastal, required_bake)


func set_local_breaker_refinement_authority(authority: Dictionary) -> void:
	_local_breaker_refinement_authority = authority.duplicate(true)
	if _open_ocean != null:
		_open_ocean.set_local_breaker_refinement_authority(_local_breaker_refinement_authority)


func set_local_breaker_refinement_enabled(enabled: bool) -> void:
	local_breaker_refinement_enabled = enabled


func set_local_breaker_refinement_debug_visible(visible: bool) -> void:
	local_breaker_refinement_debug = visible


func get_local_breaker_refinement_info() -> Dictionary:
	if _open_ocean != null and _open_ocean.has_method(&"get_local_breaker_refinement_info"):
		return _open_ocean.get_local_breaker_refinement_info()
	return {}


func _connect_profile_changed(profile: Resource, callback: Callable) -> void:
	if profile == null: return
	if profile.has_method("ensure_change_propagation"):
		profile.ensure_change_propagation()
	if not profile.changed.is_connected(callback):
		profile.changed.connect(callback)


func _disconnect_profile_changed(profile: Resource, callback: Callable) -> void:
	if profile != null and profile.changed.is_connected(callback):
		profile.changed.disconnect(callback)


func get_physics_source_state() -> Dictionary:
	# Metadata only: no H0 copy, FFT work or texture readback on this hot path.
	var status := _physics_source_status
	var source_valid := is_instance_valid(_open_ocean) and not _open_ocean.is_queued_for_deletion()
	if _initializing or _rebuild_requested or _rebuild_debounce_remaining >= 0.0:
		status = "UPDATING"
	elif not enabled or not open_ocean_fft:
		status = "ERROR"
	elif source_valid and not _open_ocean.is_surface_initialized():
		status = "UPDATING"
	elif not source_valid and status == "OK":
		status = "ERROR"
	return {
		"status": status,
		"revision": _physics_source_revision,
		"fft_instance_id": _open_ocean.get_instance_id() if source_valid else -1,
		"spectrum_version": int(_open_ocean.call("get_phys2_spectrum_generation")) \
			if source_valid and _open_ocean.has_method("get_phys2_spectrum_generation") else 0,
		"wave_time": float(_open_ocean.get_wave_time()) if source_valid else _wave_time,
		"sea_level": sea_level,
		"ocean_space": _open_ocean.get_ocean_space_contract() if source_valid else {
			"ocean_scale": ocean_scale, "clipmap_geometry_scale": clipmap_geometry_scale,
			"revision": -1},
	}


func _request_rebuild() -> void:
	if _initializing:
		_rebuild_requested = true
		return
	if Engine.is_editor_hint() or not is_inside_tree() or _open_ocean == null: return
	_physics_source_status = "UPDATING"
	physics_source_invalidated.emit()
	_rebuild_debounce_remaining = AUTHORING_REBUILD_DEBOUNCE_S
	set_process(true)


func _process(delta: float) -> void:
	if is_instance_valid(_breaker_detector_capture_panel):
		_update_breaker_detector_debug_ui()
	if _rebuild_debounce_remaining < 0.0:
		if not is_instance_valid(_breaker_detector_capture_panel):
			set_process(false)
		return
	_rebuild_debounce_remaining -= delta
	if _rebuild_debounce_remaining > 0.0: return
	_rebuild_debounce_remaining = -1.0
	_rebuild_if_ready()
	if not is_instance_valid(_breaker_detector_capture_panel):
		set_process(false)


func _rebuild_if_ready() -> void:
	if _initializing:
		_rebuild_requested = true
		return
	if not is_inside_tree() or _open_ocean == null: return
	_wave_time = _open_ocean.get_wave_time()
	shutdown()
	if enabled and open_ocean_fft: initialize()


func _update_overlay() -> void:
	if not is_inside_tree(): return
	if not performance_overlay:
		if _overlay != null:
			_overlay.queue_free()
			_overlay = null
		return
	if _overlay == null:
		_overlay = Label.new()
		_overlay.position = Vector2(16.0, 16.0)
		_overlay.add_theme_font_size_override("font_size", 16)
		get_tree().root.add_child.call_deferred(_overlay)
	_overlay.text = "Ocean P3\nLONG · MID · SHORT\nJONSWAP + Hasselmann"

## One provider and native field per Ocean. Configure once after the physical
## source is ready; hand this same reference to every vehicle/consumer.
func get_water_provider() -> CpuFftWaterProvider:
	if not is_instance_valid(_cpu_water_provider):
		_cpu_water_provider = CpuWater.new()
		_cpu_water_provider.name = "PhysicalWater"
		add_child(_cpu_water_provider)
	return _cpu_water_provider

func _claim_water_provider(provider: CpuFftWaterProvider) -> bool:
	if is_instance_valid(_cpu_water_provider) and _cpu_water_provider != provider:
		push_error("This Ocean already owns a CPU water provider; use get_water_provider()")
		return false
	_cpu_water_provider = provider
	return true

func is_persistent_foam_enabled() -> bool:
	return is_instance_valid(_open_ocean) and _open_ocean.persistent_foam_enabled

func is_landing_ripple_enabled() -> bool:
	return is_instance_valid(_open_ocean) and _open_ocean.landing_ripples_enabled

func submit_foam_stamp(position: Vector3, velocity: Vector3, strength: float, landing: bool) -> void:
	if is_instance_valid(_open_ocean):
		_open_ocean.submit_interaction_foam_stamp(position, velocity, strength, landing)
