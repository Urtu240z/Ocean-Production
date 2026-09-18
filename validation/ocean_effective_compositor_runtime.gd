extends Node

## H4.20 runtime validation.  This deliberately exercises the real P0 scene;
## the assertions are about compositor ownership and callback residency, not
## a reimplementation of any underwater or reflection shader.

const SCENE := preload("res://validation/p0_open_ocean.tscn")
const STARTUP_TIMEOUT_FRAMES := 360
const SETTLE_FRAMES := 8
const STRESS_CYCLES := 10

var _scene: Node
var _ocean: Ocean
var _open_ocean: Node
var _medium: Node
var _sspr: Node
var _camera: Camera3D
var _world: WorldEnvironment
var _phase := 0
var _wait_frames := 0
var _stress_cycle := 0
var _stress_subphase := 0
var _failed := false
var _foreign_world_effect: CompositorEffect
var _source_signature_before := ""
var _active_framebuffer_signature := 0.0
var _inactive_framebuffer_signature := 0.0

func _ready() -> void:
	if not _run_source_contract():
		_fail("source contract")
		return
	if RenderingServer.get_rendering_device() == null:
		print("GODOT_RUNTIME_NOT_AVAILABLE")
		get_tree().quit(2)
		return
	_scene = SCENE.instantiate()
	get_tree().root.call_deferred("add_child", _scene)
	_phase = 0

func _resolve_runtime_nodes() -> bool:
	if _scene == null or not _scene.is_inside_tree():
		return false
	_ocean = _scene.get_node_or_null(^"Ocean") as Ocean
	_camera = _scene.get_node_or_null(^"FreeCamera") as Camera3D
	_world = _scene.get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	if _ocean == null or _camera == null or _world == null:
		return false
	_open_ocean = _ocean.get("_open_ocean") as Node
	_medium = _ocean.get("_underwater_medium") as Node
	return true

func _process(_delta: float) -> void:
	if _failed:
		return
	if _phase == 0:
		if not _resolve_runtime_nodes():
			return
		if _open_ocean == null:
			_open_ocean = _ocean.get("_open_ocean") as Node
		if _medium == null:
			_medium = _ocean.get("_underwater_medium") as Node
		if _open_ocean == null or _medium == null:
			return
		_sspr = _open_ocean.get("_sspr") as Node
		if _sspr == null:
			return
		_camera.global_position = Vector3(0.0, -5.0, 16.0)
		_open_ocean.set_runtime_water_state(&"UNDERWATER_SAFE")
		_wait_frames = 0
		_phase = 1
		return
	if _open_ocean != null and _sspr == null:
		_sspr = _open_ocean.get("_sspr") as Node
	if _open_ocean == null or not bool(_open_ocean.get("_surface_initialized")) or _sspr == null:
		_wait_frames += 1
		if _wait_frames > STARTUP_TIMEOUT_FRAMES:
			_fail("P0 runtime startup timed out")
		return
	match _phase:
		1:
			if not _wait_for_settle(): return
			_phase = 2
		2:
			_run_camera_precedence_setup()
		3:
			_run_camera_precedence_verify()
		4:
			_run_world_fallback_verify()
		5:
			_run_pending_verify()
		6:
			_run_camera_replacement_verify()
		7:
			_run_world_restore_verify()
		8:
			_run_framebuffer_setup()
		9:
			_run_framebuffer_disabled()
		10:
			_run_framebuffer_enabled()
		11:
			_run_sspr_off_migration()
		12:
			_run_stress()
		13:
			_run_toggle_stress()
		14:
			_run_final_checks()
		15:
			print("OCEAN_EFFECTIVE_COMPOSITOR_STRESS_PASS")
			print("OCEAN_EFFECTIVE_COMPOSITOR_TOGGLE_STRESS_PASS")
			print("OCEAN_UNDERWATER_COMPOSITOR_SOURCE_CONTINUITY_PASS")
			print("OCEAN_P0_UNDERWATER_REAL_RENDER_PASS")
			get_tree().quit(0)

func _wait_for_settle() -> bool:
	_wait_frames += 1
	return _wait_frames >= SETTLE_FRAMES

func _run_camera_precedence_setup() -> bool:
	_source_signature_before = _source_signature()
	_foreign_world_effect = CompositorEffect.new()
	var world_compositor: Compositor = _world.compositor
	if world_compositor == null:
		world_compositor = Compositor.new()
		_world.compositor = world_compositor
	_append_effect(world_compositor, _foreign_world_effect)
	_camera.compositor = Compositor.new()
	_phase = 3
	return false

func _run_camera_precedence_verify() -> bool:
	var medium_state: Dictionary = _medium.get_compositor_attachment_state()
	var sspr_state: Dictionary = _sspr.get_compositor_attachment_state()
	if not _assert_target(medium_state, &"CAMERA") or not _assert_target(sspr_state, &"CAMERA"):
		return false
	if not _assert_single_effect(medium_state) or not _assert_single_effect(sspr_state):
		return false
	if _count_effect(_world.compositor, _foreign_world_effect) != 1:
		_fail("foreign WorldEnvironment compositor effect was not preserved")
		return false
	print("OCEAN_EFFECTIVE_COMPOSITOR_CAMERA_PRECEDENCE_PASS")
	print("OCEAN_EFFECTIVE_COMPOSITOR_FOREIGN_EFFECT_PASS")
	_camera.compositor = null
	_wait_frames = 0
	_phase = 4
	return false

func _run_world_fallback_verify() -> bool:
	var medium_state: Dictionary = _medium.get_compositor_attachment_state()
	var sspr_state: Dictionary = _sspr.get_compositor_attachment_state()
	if StringName(medium_state.get("target_type", &"")) == &"CAMERA" and _wait_frames < 2:
		_wait_frames += 1
		return false
	if not _assert_target(medium_state, &"WORLD_ENVIRONMENT") or not _assert_target(sspr_state, &"WORLD_ENVIRONMENT"):
		return false
	print("OCEAN_EFFECTIVE_COMPOSITOR_WORLD_FALLBACK_PASS")
	print("OCEAN_EFFECTIVE_COMPOSITOR_CAMERA_RESTORE_PASS")
	var parent: Node = _world.get_parent()
	if parent != null:
		parent.remove_child(_world)
	_camera.current = false
	_phase = 5
	return false

func _run_pending_verify() -> bool:
	var medium_state: Dictionary = _medium.get_compositor_attachment_state()
	var sspr_state: Dictionary = _sspr.get_compositor_attachment_state()
	if StringName(medium_state.get("target_type", &"")) != &"PENDING" or StringName(sspr_state.get("target_type", &"")) != &"PENDING":
		_fail("effects did not enter PENDING when no effective compositor target existed")
		return false
	if bool(medium_state.get("attached", true)) or bool(sspr_state.get("attached", true)):
		_fail("PENDING compositor state still reported attached")
		return false
	print("OCEAN_EFFECTIVE_COMPOSITOR_LATE_TARGET_PASS")
	_scene.add_child(_world)
	_camera.current = true
	_camera.compositor = Compositor.new()
	_phase = 6
	return false

func _run_camera_replacement_verify() -> bool:
	var medium_state: Dictionary = _medium.get_compositor_attachment_state()
	var sspr_state: Dictionary = _sspr.get_compositor_attachment_state()
	if not _assert_target(medium_state, &"CAMERA") or not _assert_target(sspr_state, &"CAMERA"):
		return false
	if not _assert_single_effect(medium_state) or not _assert_single_effect(sspr_state):
		return false
	print("OCEAN_EFFECTIVE_COMPOSITOR_REPLACEMENT_PASS")
	_camera.compositor = null
	_phase = 7
	return false

func _run_world_restore_verify() -> bool:
	var medium_state: Dictionary = _medium.get_compositor_attachment_state()
	var sspr_state: Dictionary = _sspr.get_compositor_attachment_state()
	if not _assert_target(medium_state, &"WORLD_ENVIRONMENT") or not _assert_target(sspr_state, &"WORLD_ENVIRONMENT"):
		return false
	_phase = 8
	return false

func _run_framebuffer_setup() -> bool:
	var medium_state: Dictionary = _medium.get_compositor_attachment_state()
	var target_size: Vector2i = medium_state.get("target_size", Vector2i.ZERO)
	if not bool(medium_state.get("effect_callback_seen", false)) or target_size.x <= 0 or target_size.y <= 0 or not bool(medium_state.get("waterline_valid", false)):
		_fail("Underwater callback did not produce a valid framebuffer target and waterline readback")
		return false
	_open_ocean.set_process(false)
	_active_framebuffer_signature = _framebuffer_signature()
	var effect: CompositorEffect = _medium.get("_effect") as CompositorEffect
	if effect == null:
		_fail("Underwater compositor effect missing")
		return false
	effect.enabled = false
	_wait_frames = 0
	_phase = 9
	return false

func _run_framebuffer_disabled() -> bool:
	if not _wait_for_settle(): return false
	_inactive_framebuffer_signature = _framebuffer_signature()
	var effect: CompositorEffect = _medium.get("_effect") as CompositorEffect
	if effect == null:
		_fail("Underwater effect disappeared while disabled")
		return false
	effect.enabled = true
	_wait_frames = 0
	_phase = 10
	return false

func _run_framebuffer_enabled() -> bool:
	if not _wait_for_settle(): return false
	var restored_signature := _framebuffer_signature()
	if is_equal_approx(_active_framebuffer_signature, _inactive_framebuffer_signature) or is_equal_approx(_inactive_framebuffer_signature, restored_signature):
		_fail("Underwater effect did not measurably contribute to the P0 framebuffer")
		return false
	print("OCEAN_UNDERWATER_EFFECT_CALLBACK_PASS")
	print("OCEAN_UNDERWATER_SAFE_STATE_PASS")
	print("OCEAN_UNDERWATER_FRAMEBUFFER_CONTRIBUTION_PASS")
	_open_ocean.set_process(true)
	_phase = 11
	return false

func _run_sspr_off_migration() -> bool:
	_sspr.set_runtime_active(false)
	_camera.compositor = Compositor.new()
	_phase = 12
	_stress_cycle = -1
	_stress_subphase = 0
	print("OCEAN_SSPR_OFF_EFFECTIVE_COMPOSITOR_MIGRATION_PASS")
	return false

func _run_stress() -> bool:
	if _stress_cycle < 0:
		var state: Dictionary = _sspr.get_compositor_attachment_state()
		if not _assert_target(state, &"CAMERA") or bool(state.get("active", true)):
			_fail("SSPR OFF did not remain resident and migrate to camera compositor")
			return false
		_sspr.set_runtime_active(true)
		_stress_cycle = 0
		_stress_subphase = 0
		return false
	if _stress_cycle >= STRESS_CYCLES:
		_phase = 13
		_stress_cycle = 0
		return false
	if _stress_subphase == 0:
		_camera.compositor = Compositor.new()
		_stress_subphase = 1
		return false
	if _stress_subphase == 1:
		var camera_state: Dictionary = _medium.get_compositor_attachment_state()
		if not _assert_target(camera_state, &"CAMERA"):
			return false
		_camera.compositor = null
		_stress_subphase = 2
		return false
	var world_state: Dictionary = _medium.get_compositor_attachment_state()
	if not _assert_target(world_state, &"WORLD_ENVIRONMENT"):
		return false
	_stress_cycle += 1
	_stress_subphase = 0
	return false

func _run_toggle_stress() -> bool:
	if _stress_cycle >= STRESS_CYCLES:
		_phase = 14
		return false
	var enabled := (_stress_cycle % 2) == 0
	_sspr.set_runtime_active(enabled)
	_open_ocean.set_runtime_water_state(&"UNDERWATER_SAFE" if enabled else &"AIR_SAFE")
	_camera.compositor = Compositor.new() if enabled else null
	_stress_cycle += 1
	return false

func _run_final_checks() -> bool:
	var medium_state: Dictionary = _medium.get_compositor_attachment_state()
	var sspr_state: Dictionary = _sspr.get_compositor_attachment_state()
	if not _assert_single_effect(medium_state) or not _assert_single_effect(sspr_state):
		return false
	if _source_signature() != _source_signature_before:
		_fail("underwater source RIDs changed during compositor migration stress")
		return false
	if _count_effect(_world.compositor, _foreign_world_effect) != 1:
		_fail("foreign effect was lost during migration stress")
		return false
	print("OCEAN_OCEAN_EFFECT_SINGLE_AUTHORITY_PASS")
	_phase = 15
	return true

func _assert_target(state: Dictionary, expected: StringName) -> bool:
	if StringName(state.get("target_type", &"")) != expected or not bool(state.get("attached", false)):
		_fail("unexpected effective compositor target: expected %s, got %s" % [expected, state.get("target_type", &"")])
		return false
	return true

func _assert_single_effect(state: Dictionary) -> bool:
	if int(state.get("effect_occurrences", 0)) != 1:
		_fail("runtime effect was not attached exactly once")
		return false
	return true

func _append_effect(compositor: Compositor, effect: CompositorEffect) -> void:
	var effects: Array[CompositorEffect] = compositor.compositor_effects.duplicate()
	effects.append(effect)
	compositor.compositor_effects = effects

func _count_effect(compositor: Compositor, effect: CompositorEffect) -> int:
	if compositor == null or effect == null:
		return 0
	var count := 0
	for candidate in compositor.compositor_effects:
		if candidate == effect:
			count += 1
	return count

func _framebuffer_signature() -> float:
	var viewport: Viewport = _scene.get_viewport()
	var image: Image = viewport.get_texture().get_image()
	if image == null or image.is_empty():
		_fail("P0 framebuffer readback returned no image")
		return 0.0
	var total := 0.0
	var samples := 0
	var y_step: int = maxi(1, int(round(float(image.get_height()) / 12.0)))
	var x_step: int = maxi(1, int(round(float(image.get_width()) / 16.0)))
	for y in range(0, image.get_height(), y_step):
		for x in range(0, image.get_width(), x_step):
			var color: Color = image.get_pixel(x, y)
			total += color.r * 0.3 + color.g * 0.59 + color.b * 0.11
			samples += 1
	return total / float(max(1, samples))

func _source_signature() -> String:
	if _open_ocean == null:
		return ""
	var sources: Dictionary = _open_ocean.get_underwater_medium_raster_sources()
	return "%s|%s|%s|%s" % [str(sources.get("long", RID())), str(sources.get("mid", RID())), str(sources.get("short", RID())), str(sources.get("breaking_activity_long", RID()))]

func _run_source_contract() -> bool:
	var underwater_source := _read_source("res://addons/ocean/underwater/ocean_underwater_medium.gd")
	var sspr_source := _read_source("res://addons/ocean/reflections/ocean_sspr.gd")
	var helper_source := _read_source("res://addons/ocean/core/ocean_compositor_attachment.gd")
	var p0_source := _read_source("res://validation/p0_open_ocean.tscn")
	if underwater_source.is_empty() or sspr_source.is_empty() or helper_source.is_empty() or p0_source.is_empty():
		return false
	if not helper_source.contains("camera.compositor") or not helper_source.contains("world.compositor") or not helper_source.contains("HOST_PENDING"):
		return false
	if not underwater_source.contains("COMPOSITOR_ATTACHMENT") or not sspr_source.contains("COMPOSITOR_ATTACHMENT"):
		return false
	if p0_source.contains("ocean_sspr_effect.gd") or p0_source.contains("CompositorEffect_dy3si"):
		return false
	return true

func _read_source(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""

func _fail(reason: String) -> void:
	_failed = true
	push_error("H4.20 effective compositor validation failed: %s" % reason)
	get_tree().quit(1)
