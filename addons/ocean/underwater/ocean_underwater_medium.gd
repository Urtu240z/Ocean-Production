class_name OceanUnderwaterMedium
extends Node
## Main-thread owner for the P6 compositor. OFF owns neither an effect nor RD RIDs.

const EFFECT := preload("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")

var _effect: OceanUnderwaterMediumEffect
var _compositor: Compositor
var _attached := false
var _sea_level := 0.0
var _profile: OceanUnderwaterMediumProfile
var _camera_underwater := false
var _surface_sources := {}

func configure(sea_level: float, profile: OceanUnderwaterMediumProfile) -> void:
	_sea_level = sea_level
	_profile = profile
	_effect = EFFECT.new()
	_push_state()
	call_deferred(&"_attach")

func set_surface_sources(surface: Object) -> void:
	if surface == null or not surface.has_method(&"get_surface_material"):
		return
	var material := surface.get_surface_material() as ShaderMaterial
	if material == null:
		return
	_surface_sources = {
		"long": _rd_texture(material, &"displacement_long"),
		"mid": _rd_texture(material, &"displacement_mid"),
		"domains": Vector2(float(material.get_shader_parameter(&"domain_long_m")), float(material.get_shader_parameter(&"domain_mid_m")))
	}
	if _effect != null:
		_effect.set_surface_sources(_surface_sources["long"], _surface_sources["mid"], _surface_sources["domains"])

func _rd_texture(material: ShaderMaterial, parameter: StringName) -> RID:
	var texture := material.get_shader_parameter(parameter) as Texture2D
	if texture == null or not texture.get_rid().is_valid():
		return RID()
	return RenderingServer.texture_get_rd_texture(texture.get_rid(), true)

func update(sea_level: float, profile: OceanUnderwaterMediumProfile) -> void:
	_sea_level = sea_level
	_profile = profile
	_push_state()

func _process(_delta: float) -> void:
	if _effect == null: return
	# Dynamic waterline classification is performed in the compositor from the
	# published LONG+MID maps; this node only pushes profile/settings.
	_push_state()

func _push_state() -> void:
	if _effect == null: return
	var profile := _profile
	_effect.configure(
		_sea_level, _camera_underwater,
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
	if _effect == null: return
	_effect.enabled = false
	_effect.begin_shutdown()
	_effect.configure(_sea_level, false, Vector3.ZERO, 0.0, Color.BLACK, 0.0, 0.0, 1.0)
	if _attached and _compositor != null:
		var effects := _compositor.compositor_effects.duplicate()
		effects.erase(_effect)
		_compositor.compositor_effects = effects
	RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false

func _exit_tree() -> void:
	shutdown()
