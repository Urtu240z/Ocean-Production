extends RefCounted

## Main-thread-only compositor attachment contract shared by runtime effects.
## The active camera compositor is authoritative whenever it exists. A world
## compositor is used only when the active camera has no compositor.

const HOST_PENDING: StringName = &"PENDING"
const HOST_CAMERA: StringName = &"CAMERA"
const HOST_WORLD_ENVIRONMENT: StringName = &"WORLD_ENVIRONMENT"

var _owner: Node
var _effect: CompositorEffect
var _host_object: Node
var _compositor: Compositor
var _host_type: StringName = HOST_PENDING
var _attached := false
var _generation := 0

func _init(owner: Node, effect: CompositorEffect) -> void:
	_owner = owner
	_effect = effect

func ensure_attached() -> bool:
	if _owner == null or not is_instance_valid(_owner) or _effect == null:
		_detach()
		return false
	var target: Dictionary = _resolve_target()
	var target_compositor: Compositor = target.get("compositor", null) as Compositor
	var target_host: Node = target.get("host", null) as Node
	var target_type: StringName = target.get("type", HOST_PENDING) as StringName
	if target_compositor == null or target_host == null:
		_detach()
		return false
	var changed := _compositor != target_compositor or _host_object != target_host or _host_type != target_type
	if changed:
		_remove_from_compositor(_compositor)
		_compositor = target_compositor
		_host_object = target_host
		_host_type = target_type
		_generation += 1
	var occurrences := _effect_occurrences(_compositor)
	if occurrences != 1:
		_remove_from_compositor(_compositor)
		var effects: Array[CompositorEffect] = _compositor.compositor_effects.duplicate()
		effects.append(_effect)
		_compositor.compositor_effects = effects
		_generation += 1 if not changed else 0
	_attached = _effect_occurrences(_compositor) == 1
	return _attached

func detach() -> void:
	_detach()

func get_compositor() -> Compositor:
	return _compositor

func get_host_type() -> StringName:
	return _host_type

func get_generation() -> int:
	return _generation

func is_attached() -> bool:
	return _attached

func get_effect_occurrences() -> int:
	return _effect_occurrences(_compositor)

func _resolve_target() -> Dictionary:
	var camera: Camera3D = _owner.get_viewport().get_camera_3d()
	var world: WorldEnvironment = _find_world_environment()
	if camera != null and camera.compositor != null:
		return {"type": HOST_CAMERA, "host": camera, "compositor": camera.compositor}
	if world != null and world.compositor != null:
		return {"type": HOST_WORLD_ENVIRONMENT, "host": world, "compositor": world.compositor}
	if world != null:
		var world_compositor := Compositor.new()
		world.compositor = world_compositor
		return {"type": HOST_WORLD_ENVIRONMENT, "host": world, "compositor": world_compositor}
	if camera != null:
		var camera_compositor := Compositor.new()
		camera.compositor = camera_compositor
		return {"type": HOST_CAMERA, "host": camera, "compositor": camera_compositor}
	return {}

func _find_world_environment() -> WorldEnvironment:
	var scene: Node = _owner.get_tree().current_scene
	var world: WorldEnvironment = _find_world_in_root(scene)
	if world != null:
		return world
	var root: Node = _owner.get_tree().root
	return _find_world_in_root(root)

func _find_world_in_root(root: Node) -> WorldEnvironment:
	if root == null:
		return null
	if root is WorldEnvironment:
		return root as WorldEnvironment
	var candidates: Array = root.find_children("*", "WorldEnvironment", true, false)
	for candidate in candidates:
		if candidate is WorldEnvironment:
			return candidate as WorldEnvironment
	return null

func _detach() -> void:
	var had_state := _compositor != null or _host_object != null or _attached
	_remove_from_compositor(_compositor)
	_compositor = null
	_host_object = null
	_host_type = HOST_PENDING
	_attached = false
	if had_state:
		_generation += 1

func _remove_from_compositor(compositor: Compositor) -> void:
	if compositor == null or _effect == null:
		return
	var effects: Array[CompositorEffect] = compositor.compositor_effects.duplicate()
	var changed := false
	while effects.has(_effect):
		effects.erase(_effect)
		changed = true
	if changed:
		compositor.compositor_effects = effects

func _effect_occurrences(compositor: Compositor) -> int:
	if compositor == null or _effect == null:
		return 0
	var count := 0
	for effect in compositor.compositor_effects:
		if effect == _effect:
			count += 1
	return count
