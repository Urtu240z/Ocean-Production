class_name OceanSSPR
extends Node
## Main-thread lifecycle owner. OFF means no CompositorEffect, no RD targets
## and no Texture2DRD published to the material.

const EFFECT := preload("res://addons/ocean/reflections/ocean_sspr_effect.gd")
var _surface: OceanClipmapSurface
var _effect: OceanSSPREffect
var _compositor: Compositor
var _wrapper := Texture2DRD.new()
var _published := RID()
var _attached := false

func configure(surface: OceanClipmapSurface, ocean_level: float, profile: Resource) -> void:
	_surface = surface
	_effect = EFFECT.new()
	_effect.configure(ocean_level, profile.sspr_resolution_scale, profile.temporal_enabled, profile.temporal_weight, profile.temporal_depth_threshold)
	call_deferred(&"_attach")

func update(ocean_level: float, profile: Resource) -> void:
	if _effect != null: _effect.configure(ocean_level, profile.sspr_resolution_scale, profile.temporal_enabled, profile.temporal_weight, profile.temporal_depth_threshold)

func _attach() -> void:
	if _attached or not is_inside_tree() or _effect == null: return
	var world := get_tree().current_scene.find_child("WorldEnvironment", true, false) if get_tree().current_scene != null else null
	if world is WorldEnvironment:
		_compositor = world.compositor
		if _compositor == null:
			_compositor = Compositor.new(); world.compositor = _compositor
	else:
		var camera := get_viewport().get_camera_3d()
		if camera == null: push_warning("OceanSSPR needs a WorldEnvironment or active camera."); return
		_compositor = camera.compositor
		if _compositor == null: _compositor=Compositor.new(); camera.compositor=_compositor
	var effects := _compositor.compositor_effects.duplicate(); effects.append(_effect); _compositor.compositor_effects=effects; _attached=true

func _process(_delta: float) -> void:
	if _effect == null: return
	var current := _effect.get_output_rid()
	if not current.is_valid(): return
	if current != _published and _published.is_valid():
		_wrapper.texture_rd_rid = RID()
		RenderingServer.call_on_render_thread(_effect.release_retired.bind(_published))
	if current != _published:
		_published=current
		_wrapper.texture_rd_rid=current
	# Rebind on the main thread even when the RID is stable: switching material
	# variants invalidates their parameter table without recreating the SSPR target.
	if _surface != null and is_instance_valid(_surface): _surface.set_reflection_texture(_wrapper, true)

func shutdown() -> void:
	if _surface != null and is_instance_valid(_surface): _surface.set_reflection_texture(null, false)
	_wrapper.texture_rd_rid = RID(); _published=RID()
	if _effect != null:
		_effect.enabled=false; _effect.set_active(false)
		if _attached and _compositor != null:
			var effects:=_compositor.compositor_effects.duplicate(); effects.erase(_effect); _compositor.compositor_effects=effects
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect=null; _attached=false
