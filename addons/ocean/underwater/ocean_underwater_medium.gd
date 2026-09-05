class_name OceanUnderwaterMedium
extends Node
## Main-thread owner for the P6 compositor. OFF owns neither an effect nor RD RIDs.

const EFFECT := preload("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")
const WATERLINE_CAMERA_ASSIST := preload("res://addons/ocean/underwater/ocean_waterline_camera_assist.gd")

var _effect: OceanUnderwaterMediumEffect
var _compositor: Compositor
var _attached := false
var _sea_level := 0.0
var _profile: OceanUnderwaterMediumProfile
var _camera_underwater := false
var _surface_source: Object
var _surface_sources_ready := false
var _waterline_camera_assist: OceanWaterlineCameraAssist
var _committed_waterline_state := false

func configure(sea_level: float, profile: OceanUnderwaterMediumProfile) -> void:
	_sea_level = sea_level
	_profile = profile
	_effect = EFFECT.new()
	_push_state()
	call_deferred(&"_attach")

func set_surface_source(source: Object) -> void:
	if _surface_source == source and _surface_sources_ready:
		return
	_surface_source = source
	_surface_sources_ready = false
	_try_bind_surface_sources()


func _try_bind_surface_sources() -> bool:
	if _surface_sources_ready or _effect == null or _surface_source == null or not is_instance_valid(_surface_source):
		return _surface_sources_ready
	if not _surface_source.has_method(&"get_underwater_medium_sources"):
		return false
	var sources: Dictionary = _surface_source.get_underwater_medium_sources()
	var long_rid: RID = sources.get("long", RID())
	var mid_rid: RID = sources.get("mid", RID())
	var domains: Vector2 = sources.get("domains", Vector2.ZERO)
	if not long_rid.is_valid() or not mid_rid.is_valid() or domains.x <= 0.0 or domains.y <= 0.0:
		return false
	_effect.set_surface_sources(long_rid, mid_rid, domains)
	_surface_sources_ready = true
	return true

func update(sea_level: float, profile: OceanUnderwaterMediumProfile) -> void:
	_sea_level = sea_level
	_profile = profile
	_push_state()

func _process(_delta: float) -> void:
	if _effect == null: return
	if not _surface_sources_ready:
		_try_bind_surface_sources()
	_update_camera_waterline_state()
	_push_state()


func _update_camera_waterline_state() -> void:
	_committed_waterline_state = false
	if _surface_source == null or not is_instance_valid(_surface_source) or not _surface_source.has_method(&"get_camera_macro_surface_height"):
		return
	if _waterline_camera_assist == null or not _waterline_camera_assist.is_active():
		_resolve_camera_assist()
	if _waterline_camera_assist == null or not _waterline_camera_assist.is_active():
		return
	var simulation_time: float = float(_surface_source.get_current_simulation_time()) if _surface_source.has_method(&"get_current_simulation_time") else Time.get_ticks_msec() * 0.001
	var query: Dictionary = _surface_source.get_camera_macro_surface_height(_waterline_camera_assist_anchor_xz(), simulation_time)
	var surface_y: float = query.get("height", NAN)
	if not is_finite(surface_y):
		return
	var profile := _profile
	var bias := profile.camera_waterline_bias_m if profile != null else 0.06
	var enter := profile.enter_under_threshold_m if profile != null else 0.02
	var exit := profile.exit_under_threshold_m if profile != null else 0.04
	var release := profile.camera_bias_release_distance_m if profile != null else 0.30
	_camera_underwater = _waterline_camera_assist.update(surface_y, bias, enter, exit, release)
	_committed_waterline_state = true


func _resolve_camera_assist() -> void:
	var render_camera := get_viewport().get_camera_3d()
	if render_camera == null:
		return
	var anchor := render_camera.get_parent() as Node3D
	if anchor == null or not anchor.is_in_group(&"ocean_camera_anchor"):
		return
	var assist := WATERLINE_CAMERA_ASSIST.new()
	if assist.configure(anchor, render_camera):
		_waterline_camera_assist = assist


func _waterline_camera_assist_anchor_xz() -> Vector2:
	# The assist only accepts an explicitly marked controller parent.
	var render_camera := get_viewport().get_camera_3d()
	var anchor := render_camera.get_parent() as Node3D if render_camera != null else null
	return Vector2(anchor.global_position.x, anchor.global_position.z) if anchor != null else Vector2.ZERO

func _push_state() -> void:
	if _effect == null: return
	var profile := _profile
	_effect.configure(
		_sea_level, _camera_underwater, _committed_waterline_state,
		profile.absorption_coeff_rgb if profile != null else Vector3(0.35, 0.14, 0.10),
		profile.absorption_scale if profile != null else 0.43,
		profile.scattering_color if profile != null else Color(0.0024315654, 0.09275196, 0.13127226),
		profile.scattering_strength if profile != null else 1.0,
		profile.scattering_density if profile != null else 0.15,
		profile.maximum_optical_distance_m if profile != null else 120.0)

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
	# Compile/create durable RD resources now, while still above water if that is
	# the current state. This is deliberately not a compute dispatch.
	RenderingServer.call_on_render_thread(_effect.prepare_resources)

func shutdown() -> void:
	set_process(false)
	if _waterline_camera_assist != null:
		_waterline_camera_assist.restore()
		_waterline_camera_assist = null
	_committed_waterline_state = false
	if _effect == null: return
	_effect.enabled = false
	_effect.begin_shutdown()
	_effect.configure(_sea_level, false, false, Vector3.ZERO, 0.0, Color.BLACK, 0.0, 0.0, 1.0)
	if _attached and _compositor != null:
		var effects := _compositor.compositor_effects.duplicate()
		effects.erase(_effect)
		_compositor.compositor_effects = effects
	RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false

func _exit_tree() -> void:
	shutdown()
