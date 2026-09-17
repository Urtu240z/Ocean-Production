class_name OceanSSPR
extends Node
## Main-thread lifecycle owner. Runtime OFF keeps the compositor effect and GPU
## allocations resident, disables dispatch, and removes the material binding.
## Final shutdown detaches the effect and releases its RD resources.

const EFFECT := preload("res://addons/ocean/reflections/ocean_sspr_effect.gd")
const COMPOSITOR_ATTACHMENT := preload("res://addons/ocean/core/ocean_compositor_attachment.gd")
var _surface: OceanClipmapSurface
var _effect: OceanSSPREffect
var _compositor_attachment: RefCounted
var _compositor: Compositor
var _wrapper := Texture2DRD.new()
var _published := RID()
var _attached := false
var _attachment_generation := -1
var _runtime_active := true
var _fresh_output_pending := false

func configure(surface: OceanClipmapSurface, ocean_level: float, profile: OceanReflectionProfile) -> void:
	_surface = surface
	_effect = EFFECT.new()
	_effect.configure(ocean_level, profile.sspr_resolution_scale, profile.temporal_enabled, profile.temporal_weight, profile.temporal_depth_threshold)
	_fresh_output_pending = true
	_compositor_attachment = COMPOSITOR_ATTACHMENT.new(self, _effect)
	call_deferred(&"_attach")

func update(ocean_level: float, profile: OceanReflectionProfile) -> void:
	if _effect != null:
		_effect.configure(ocean_level, profile.sspr_resolution_scale, profile.temporal_enabled, profile.temporal_weight, profile.temporal_depth_threshold)
		_fresh_output_pending = true


func set_runtime_active(value: bool) -> void:
	if value == _runtime_active:
		return
	_runtime_active = value
	_fresh_output_pending = value
	if _effect != null:
		_effect.set_active(value)
	if not value and _surface != null and is_instance_valid(_surface):
		# Keep the compositor and its allocations alive; material falls back to IBL.
		_surface.set_reflection_texture(null, false)

func _attach() -> void:
	_ensure_attachment()


func _ensure_attachment() -> void:
	if _effect == null or _compositor_attachment == null:
		return
	var previous_generation: int = _attachment_generation
	_attached = _compositor_attachment.ensure_attached()
	_compositor = _compositor_attachment.get_compositor()
	var current_generation: int = _compositor_attachment.get_generation()
	if current_generation != previous_generation:
		_attachment_generation = current_generation


func get_compositor_attachment_state() -> Dictionary:
	var effect_state: Dictionary = _effect.get_temporal_runtime_state() if _effect != null else {}
	return {
		"attached": _attached,
		"target_type": _compositor_attachment.get_host_type() if _compositor_attachment != null else &"PENDING",
		"attachment_generation": _compositor_attachment.get_generation() if _compositor_attachment != null else 0,
		"effect_occurrences": _compositor_attachment.get_effect_occurrences() if _compositor_attachment != null else 0,
		"effective_compositor_instance_id": _compositor.get_instance_id() if _compositor != null else 0,
		"effect_callback_seen": int(effect_state.get("project_depth_dispatch_count", 0)) > 0,
		"target_size": _effect.get_target_size() if _effect != null else Vector2i.ZERO,
		"active": bool(effect_state.get("active", false)),
	}

func _process(_delta: float) -> void:
	if _effect == null: return
	_ensure_attachment()
	if not _runtime_active:
		return
	# This check also covers render-thread resource recreation caused by a
	# viewport resize. A valid RID is not publishable until its frame completed.
	var fresh_output := _effect.has_fresh_output()
	if _fresh_output_pending or not fresh_output:
		if not fresh_output:
			return
		_fresh_output_pending = false
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
	_runtime_active = false
	_fresh_output_pending = false
	if _surface != null and is_instance_valid(_surface): _surface.set_reflection_texture(null, false)
	_wrapper.texture_rd_rid = RID(); _published=RID()
	if _effect != null:
		_effect.begin_shutdown()
		_effect.enabled=false; _effect.set_active(false)
		if _compositor_attachment != null:
			_compositor_attachment.detach()
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect=null; _compositor_attachment=null; _attached=false; _compositor=null; _attachment_generation=-1
