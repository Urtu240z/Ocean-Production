extends SceneTree
const GUARD := preload("res://addons/jet_ski/common/visual/jet_ski_render_size_guard.gd")
var failures: Array[String] = []
class Probe extends CompositorEffect:
	var sizes: Array[Vector2i] = []
	func _init(): effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE
	func _render_callback(_kind, data):
		var size: Vector2i = data.get_render_scene_buffers().get_internal_size()
		if not sizes.has(size): sizes.append(size)

func _initialize() -> void:
	call_deferred(&"run")
func frames(count: int) -> void:
	for index in count: await process_frame
	await RenderingServer.frame_post_draw
func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
		push_error("RENDER_SIZE_GUARD_FAIL: " + label)
func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128,128)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var guard := GUARD.new(viewport)
	var camera := Camera3D.new()
	camera.position.z = 3
	viewport.add_child(camera)
	camera.current = true
	var probe := Probe.new()
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [probe]
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded; uniform sampler2D screen_color : hint_screen_texture, filter_linear_mipmap; void fragment() { EMISSION=textureLod(screen_color,SCREEN_UV,0.0).rgb; }"
	var material := ShaderMaterial.new()
	material.shader = shader
	mesh.material_override = material
	viewport.add_child(mesh)
	await frames(30)
	viewport.size = Vector2i(2,2)
	viewport.scaling_3d_scale = 0.25
	await frames(5)
	check(viewport.disable_3d and guard.pauses == 1, "transient tiny viewport pauses only 3D")
	viewport.size = Vector2i(128,128)
	await frames(5)
	check(not viewport.disable_3d and guard.resumes == 1, "usable size automatically resumes 3D")
	# Logical size does not change in this case; the frame check must catch it.
	viewport.scaling_3d_scale = 0.01
	await frames(5)
	check(viewport.disable_3d and guard.pauses == 2, "render scaling alone cannot create a 1x1 render")
	viewport.scaling_3d_scale = 1.0
	await frames(5)
	check(not viewport.disable_3d and guard.resumes == 2, "restoring render scale resumes rendering")
	check(not probe.sizes.has(Vector2i.ONE), "GPU callback never receives unsafe 1x1 size")
	guard.release()
	viewport.disable_3d = true
	var disabled_guard := GUARD.new(viewport)
	viewport.size = Vector2i(2,2)
	await frames(2)
	viewport.size = Vector2i(128,128)
	await frames(2)
	check(viewport.disable_3d, "preexisting application 3D-disable setting is preserved")
	disabled_guard.release()
	print("RENDER_SIZE_GUARD_RESULT sizes=",probe.sizes," pauses=",guard.pauses," resumes=",guard.resumes," failures=",failures)
	viewport.queue_free()
	await frames(2)
	quit(0 if failures.is_empty() else 1)
