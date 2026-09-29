@tool
class_name Ocean
extends Node3D
## API pública P0. El nodo expone authoring; la simulación vive en OpenOceanFFT.

const OpenOcean := preload("res://addons/ocean/fft/open_ocean_fft.gd")
const UnderwaterMedium := preload("res://addons/ocean/underwater/ocean_underwater_medium.gd")
const CausticsManager := preload("res://addons/ocean/underwater/caustics/ocean_caustics_manager.gd")
const SpindriftController := preload("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
const AUTHORING_REBUILD_DEBOUNCE_S := 0.15
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
@export var quality_profile: Resource:
	set(value):
		if quality_profile == value:
			_connect_profile_changed(quality_profile, _on_quality_profile_changed)
			return
		_disconnect_profile_changed(quality_profile, _on_quality_profile_changed)
		quality_profile = value
		_connect_profile_changed(quality_profile, _on_quality_profile_changed)
		_request_rebuild()
@export_group("Ocean Space")
## Escala vertical/amplitud del Ocean Space. Se aplica a la altura de las
## olas y a los desplazamientos verticales reconstruidos por los sistemas.
@export_range(0.25, 4.0, 0.01) var ocean_scale := 1.0:
	set(value):
		ocean_scale = clampf(value, 0.25, 4.0)
		if _open_ocean != null:
			_open_ocean.set_surface_scale(ocean_scale)
## Escala horizontal/wavelength del Ocean Space. Se aplica a la geometría XZ,
## a los desplazamientos horizontales y a los dominios FFT publicados.
@export_range(0.25, 4.0, 0.01) var clipmap_geometry_scale := 1.0:
	set(value):
		clipmap_geometry_scale = clampf(value, 0.25, 4.0)
		if _open_ocean != null:
			_open_ocean.set_clipmap_geometry_scale(clipmap_geometry_scale)

@export_group("Sea State")
@export var wave_profile: Resource:
	set(value):
		if wave_profile == value:
			_connect_profile_changed(wave_profile, _on_wave_profile_changed)
			return
		_disconnect_profile_changed(wave_profile, _on_wave_profile_changed)
		wave_profile = value
		_connect_profile_changed(wave_profile, _on_wave_profile_changed)
		_request_rebuild()
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

@export_group("Breaker Detector Capture (Validation Only)")
@export_range(0, 2147483647, 1) var breaker_detector_capture_arm_serial := 0:
	set(value):
		breaker_detector_capture_arm_serial = value
		_apply_breaker_detector_capture_control()
@export_range(0, 2147483647, 1) var breaker_detector_capture_release_serial := 0:
	set(value):
		breaker_detector_capture_release_serial = value
		_apply_breaker_detector_capture_control()
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

## Master gate. When OFF the controller and all GPUParticles3D instances are absent.
@export var enable_spindrift := false:
	set(value):
		enable_spindrift = value
		if _open_ocean != null:
			_open_ocean.set_spindrift_enabled(enable_spindrift, spindrift_profile, spindrift_debug_mode)
			_apply_spindrift_visual_freeze()

@export_group("System Resources")
@export var coastal_bake: Resource:
	set(value):
		coastal_bake = value
		_sync_coastal_runtime()
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
		_sync_underwater_medium()
		_sync_caustics_runtime()
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
@export var performance_overlay := false:
	set(value):
		performance_overlay = value
		_update_overlay()
@export_enum("Off", "Normals") var debug_view: int = DebugView.OFF:
	set(value):
		debug_view = clampi(value, DebugView.OFF, DebugView.NORMALS)
		if _open_ocean != null: _open_ocean.set_debug_view(debug_view)
@export_subgroup("Breaker Refinement")
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
	if Engine.is_editor_hint(): return
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
	else:
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


func _request_rebuild() -> void:
	if _initializing:
		_rebuild_requested = true
		return
	if Engine.is_editor_hint() or not is_inside_tree() or _open_ocean == null: return
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
