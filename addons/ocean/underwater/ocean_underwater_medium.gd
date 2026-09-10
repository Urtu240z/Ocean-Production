class_name OceanUnderwaterMedium
extends Node
## Main-thread P6 owner. It only publishes authoritative clipmap arrays and
## valid FFT source RIDs; the effect owns every P6 RenderingDevice resource.

const EFFECT := preload("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")

var _effect: OceanUnderwaterMediumEffect
var _compositor: Compositor
var _attached := false
var _sea_level := 0.0
var _profile: OceanUnderwaterMediumProfile
var _bubble_enabled := false
var _bubble_profile: OceanUnderwaterBubbleProfile
var _bubble_wind_direction_degrees := 0.0
var _bubble_crest_profile: OceanCrestFoamProfile
var _bubble_profiling_gates: Dictionary = {}
var _sunray_enabled := false
var _sunray_profile: OceanUnderwaterSunrayProfile
var _sun_light: DirectionalLight3D
var _sunray_wave_phase := 0.0
var _last_surface_wave_time := 0.0
var _sunray_clock_valid := false
var _surface_source: Object
var _geometry_published := false
var _sources_published := false
var _raster_prepared := false


func configure(sea_level: float, profile: OceanUnderwaterMediumProfile) -> void:
	_sea_level = sea_level
	_profile = profile
	_effect = EFFECT.new()
	_push_state()
	_effect.set_bubble_profiling_gates(_bubble_profiling_gates)
	call_deferred(&"_attach")


func set_surface_source(source: Object) -> void:
	if _surface_source == source: return
	_surface_source = source
	_geometry_published = false
	_sources_published = false
	_raster_prepared = false


func set_bubbles(enabled: bool, profile: OceanUnderwaterBubbleProfile, wind_direction_degrees: float, crest_profile: OceanCrestFoamProfile) -> void:
	_bubble_enabled = enabled
	_bubble_profile = profile
	_bubble_wind_direction_degrees = wind_direction_degrees
	_bubble_crest_profile = crest_profile
	_push_bubble_state()


func set_bubble_profiling_gates(gates: Dictionary) -> void:
	_bubble_profiling_gates = gates.duplicate(true)
	if _effect != null:
		_effect.set_bubble_profiling_gates(_bubble_profiling_gates)


func set_sunrays(enabled: bool, profile: OceanUnderwaterSunrayProfile) -> void:
	_sunray_enabled = enabled
	_sunray_profile = profile
	_push_sunray_state()


func _try_publish_raster_inputs() -> void:
	if _effect == null or _surface_source == null or not is_instance_valid(_surface_source): return
	if not _surface_source.has_method(&"get_underwater_medium_raster_surface") or not _surface_source.has_method(&"get_underwater_medium_raster_sources"): return
	if not _geometry_published:
		var surface := _surface_source.get_underwater_medium_raster_surface() as OceanClipmapSurface
		if surface != null and is_instance_valid(surface):
			var geometry := surface.get_underwater_medium_raster_geometry()
			if not geometry.is_empty():
				_effect.set_raster_geometry(geometry)
				_geometry_published = true
	if not _sources_published:
		var sources: Dictionary = _surface_source.get_underwater_medium_raster_sources()
		var long_rid: RID = sources.get("long", RID())
		var mid_rid: RID = sources.get("mid", RID())
		var short_rid: RID = sources.get("short", RID())
		if long_rid.is_valid() and mid_rid.is_valid() and short_rid.is_valid():
			_effect.set_raster_sources(sources)
			_sources_published = true
	if _attached and _geometry_published and _sources_published and not _raster_prepared:
		# RD allocation remains render-thread only.
		RenderingServer.call_on_render_thread(_effect.prepare_resources)
		_raster_prepared = true


func update(sea_level: float, profile: OceanUnderwaterMediumProfile) -> void:
	_sea_level = sea_level
	_profile = profile
	_push_state()


func _process(_delta: float) -> void:
	_try_publish_raster_inputs()
	var surface_wave_time := 0.0
	if _effect != null and _surface_source != null and is_instance_valid(_surface_source) and _surface_source.has_method(&"get_wave_time"):
		surface_wave_time = float(_surface_source.get_wave_time())
		_effect.set_wave_time(surface_wave_time)
	_advance_sunray_wave_clock(surface_wave_time)
	_push_sunray_state()
	_push_state()


func _advance_sunray_wave_clock(surface_wave_time: float) -> void:
	var sunray_wave_speed := _sunray_profile.wave_animation_speed if _sunray_profile != null else 1.50
	if not _sunray_clock_valid:
		_last_surface_wave_time = surface_wave_time
		_sunray_wave_phase = surface_wave_time * sunray_wave_speed
		_sunray_clock_valid = true
		return
	var wave_delta := surface_wave_time - _last_surface_wave_time
	_last_surface_wave_time = surface_wave_time
	# A source reset/rebuild is a clock discontinuity, not physical wave motion.
	if wave_delta < 0.0 or wave_delta > 1.0:
		return
	if _sunray_profile == null or not _sunray_profile.wave_freeze:
		_sunray_wave_phase += wave_delta * sunray_wave_speed


func _push_state() -> void:
	if _effect == null: return
	var profile := _profile
	_effect.configure(_sea_level, profile.waterline_mask_debug if profile != null else false, profile.meniscus_enabled if profile != null else false, profile.meniscus_width_px if profile != null else 30.0, profile.meniscus_softness if profile != null else 0.5, profile.meniscus_strength if profile != null else 0.04, profile.meniscus_debug if profile != null else false, profile.visibility_distance_m if profile != null else 25.0, profile.depth_light_falloff if profile != null else 0.028, profile.surface_light_strength if profile != null else 1.35, profile.ambient_debug_mode if profile != null else 0, profile.absorption_coeff_rgb if profile != null else Vector3(0.35, 0.14, 0.10), profile.absorption_scale if profile != null else 0.36, profile.scattering_color if profile != null else Color(0.0024315654, 0.09275196, 0.13127226), profile.scattering_strength if profile != null else 1.0, profile.scattering_density if profile != null else 0.15, profile.maximum_optical_distance_m if profile != null else 120.0, profile.enter_margin_m if profile != null else 0.05, profile.exit_margin_m if profile != null else 0.05)


func _push_bubble_state() -> void:
	if _effect == null: return
	var profile := _bubble_profile
	var crest := _bubble_crest_profile
	_effect.configure_bubbles({
		"enabled": _bubble_enabled,
		"volume_extent_xz_m": profile.volume_extent_xz_m if profile != null else 64.0,
		"volume_top_above_sea_m": profile.volume_top_above_sea_m if profile != null else 6.0,
		"volume_depth_below_sea_m": profile.volume_depth_below_sea_m if profile != null else 12.0,
		"resolution_x": profile.resolution_x if profile != null else 96,
		"resolution_y": profile.resolution_y if profile != null else 32,
		"resolution_z": profile.resolution_z if profile != null else 96,
		"simulation_hz": profile.simulation_hz if profile != null else 30.0,
		"injection_strength": profile.injection_strength if profile != null else 1.0,
		"injection_depth_m": profile.injection_depth_m if profile != null else 2.5,
		"downward_entrainment_mps": profile.downward_entrainment_mps if profile != null else 1.0,
		"buoyancy_mps": profile.buoyancy_mps if profile != null else 0.35,
		"horizontal_drift_mps": profile.horizontal_drift_mps if profile != null else 0.20,
		"curl_strength_mps": profile.curl_strength_mps if profile != null else 0.80,
		"curl_scale_m": profile.curl_scale_m if profile != null else 3.0,
		"curl_time_scale": profile.curl_time_scale if profile != null else 0.20,
		"diffusion": profile.diffusion if profile != null else 0.04,
		"decay_half_life_s": profile.decay_half_life_s if profile != null else 5.0,
		"max_density": profile.max_density if profile != null else 1.0,
		"scatter_strength": profile.scatter_strength if profile != null else 0.24,
		"extinction_strength": profile.extinction_strength if profile != null else 1.60,
		"bubble_tint": profile.bubble_tint if profile != null else Color(0.88, 0.94, 0.97),
		"density_gamma": profile.density_gamma if profile != null else 1.10,
		"march_steps": profile.march_steps if profile != null else 12,
		"macro_noise_scale_m": profile.macro_noise_scale_m if profile != null else 6.0,
		"macro_erosion_strength": profile.macro_erosion_strength if profile != null else 0.80,
		"micro_noise_scale_m": profile.micro_noise_scale_m if profile != null else 0.12,
		"micro_detail_strength": profile.micro_detail_strength if profile != null else 0.58,
		"noise_warp_strength_m": profile.noise_warp_strength_m if profile != null else 0.75,
		"wave_noise_warp_strength_m": profile.wave_noise_warp_strength_m if profile != null else 0.20,
		"shadow_strength": profile.shadow_strength if profile != null else 1.0,
		"shadow_tint": profile.shadow_tint if profile != null else Color(0.20, 0.32, 0.36),
		"shadow_steps": profile.shadow_steps if profile != null else 3,
		"debug_mode": profile.debug_mode if profile != null else 0,
		"freeze_simulation": profile.freeze_simulation if profile != null else false,
		"wind_direction_degrees": _bubble_wind_direction_degrees,
		"source_thresholds": Vector3(crest.long_whitecap_threshold, crest.mid_whitecap_threshold, crest.short_whitecap_threshold) if crest != null else Vector3(0.62, 0.66, 0.68),
		"source_weights": Vector3(crest.long_weight, crest.mid_weight, crest.short_weight) if crest != null else Vector3(1.0, 0.65, 0.10),
	})


func _push_sunray_state() -> void:
	if _effect == null: return
	var light := _resolve_sun_light()
	var profile := _sunray_profile
	var basis_z := light.global_transform.basis.z.normalized() if light != null else Vector3.UP
	# Ocean convention: basis.z points water -> sun; light_into_water is its inverse.
	var light_into_water := -basis_z
	var light_color := light.light_color if light != null else Color.BLACK
	var light_energy := light.light_energy if light != null else 0.0
	_effect.configure_sunrays({
		"enabled": _sunray_enabled and light != null,
		"light_into_water": light_into_water,
		"light_color": light_color,
		"light_energy": light_energy,
		"strength": profile.strength if profile != null else 0.35,
		"color": profile.color if profile != null else Color(0.78, 0.95, 1.0),
		"anisotropy": profile.anisotropy if profile != null else 0.72,
		"density": profile.density if profile != null else 0.08,
		"max_distance_m": profile.max_distance_m if profile != null else 30.0,
		"length_variation": profile.length_variation if profile != null else 0.70,
		"pattern_scale": profile.pattern_scale if profile != null else 1.0,
		"pattern_contrast": profile.pattern_contrast if profile != null else 1.4,
		"animation_speed": profile.animation_speed if profile != null else 0.12,
		"wave_modulation_enabled": profile.wave_modulation_enabled if profile != null else true,
		"wave_animation_speed": profile.wave_animation_speed if profile != null else 1.50,
		"wave_freeze": profile.wave_freeze if profile != null else false,
		"wave_phase": _sunray_wave_phase,
		"wave_intensity_strength": profile.wave_intensity_strength if profile != null else 0.35,
		"wave_width_strength": profile.wave_width_strength if profile != null else 0.10,
		"wave_depth_fade_m": profile.wave_depth_fade_m if profile != null else 15.0,
		"phase_debug_constant": profile.phase_debug_constant if profile != null else false,
		"segment_mode": profile.segment_mode if profile != null else 1,
		"debug_mode": profile.debug_mode if profile != null else 0,
	})


func _resolve_sun_light() -> DirectionalLight3D:
	if _sun_light != null and is_instance_valid(_sun_light) and _sun_light.is_inside_tree():
		return _sun_light
	_sun_light = null
	var scene := get_tree().current_scene
	if scene == null:
		return null
	for candidate in scene.find_children("*", "DirectionalLight3D", true, false):
		if candidate is DirectionalLight3D:
			_sun_light = candidate
			break
	return _sun_light


func _attach() -> void:
	if _attached or not is_inside_tree() or _effect == null: return
	var scene := get_tree().current_scene
	var world := scene.find_child("WorldEnvironment", true, false) if scene != null else null
	if world is WorldEnvironment:
		_compositor = world.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			world.compositor = _compositor
	else:
		var camera := get_viewport().get_camera_3d()
		if camera == null:
			push_warning("Ocean Underwater Medium needs a WorldEnvironment or active Camera3D.")
			return
		_compositor = camera.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			camera.compositor = _compositor
	var effects := _compositor.compositor_effects.duplicate()
	effects.append(_effect)
	_compositor.compositor_effects = effects
	_attached = true
	RenderingServer.call_on_render_thread(_effect.prepare_resources)


func shutdown() -> void:
	set_process(false)
	if _effect == null: return
	_effect.enabled = false
	_effect.configure_bubbles({"enabled": false})
	_effect.configure_sunrays({"enabled": false})
	_effect.begin_shutdown()
	_effect.configure(_sea_level, false, false, 30.0, 0.5, 0.0, false, 25.0, 0.028, 1.35, 0, Vector3.ZERO, 0.0, Color.BLACK, 0.0, 0.0, 1.0, 0.05, 0.05)
	if _attached and _compositor != null:
		var effects := _compositor.compositor_effects.duplicate()
		effects.erase(_effect)
		_compositor.compositor_effects = effects
	RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false
	_geometry_published = false
	_sources_published = false
	_raster_prepared = false
	_surface_source = null
	_sun_light = null
	_sunray_clock_valid = false


func _exit_tree() -> void:
	shutdown()
