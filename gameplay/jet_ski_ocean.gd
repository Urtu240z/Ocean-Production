extends Node3D
## Launchable development gameplay scene. The production ocean scene is reused.
const Vehicle = preload("res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn")
const Provider = preload("res://gameplay/water/gpu_heightfield_water.gd")
@export var contact_debug := true
@export var capture_metrics := false
@export var follow_camera := true
@export var development_window_size := Vector2i(960, 540)
var ski: JetSkiController
var water: WaterSurfaceProvider3D
var camera: Camera3D
var debug_mesh := ImmediateMesh.new()
var debug_node: MeshInstance3D
var label: Label
var ready_to_drive := false
var closing := false

func _ready() -> void:
	get_tree().auto_accept_quit = false
	get_window().size = development_window_size
	_register_inputs()
	$Production/FreeCamera.queue_free()
	$Production/OceanDevPanel.queue_free()
	water = Provider.new(); water.name = "PhysicalWater"; add_child(water)
	water.record_metrics = capture_metrics
	ski = Vehicle.instantiate()
	ski.process_mode = Node.PROCESS_MODE_PAUSABLE
	ski.name = "JetSki"
	ski.water_provider_path = NodePath("../PhysicalWater")
	ski.submarine_dive_enabled = false
	ski.trick_preload_enabled = false
	ski.freeze = true
	ski.position = Vector3(0, 1, 0)
	add_child(ski)
	camera = Camera3D.new(); add_child(camera); camera.current = true
	camera.far = 4000
	debug_node = MeshInstance3D.new(); add_child(debug_node); debug_node.mesh = debug_mesh
	debug_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	debug_node.material_override = material
	var canvas := CanvasLayer.new(); add_child(canvas)
	label = Label.new(); canvas.add_child(label); label.position = Vector2(20,20)
	for i in 30: await get_tree().process_frame
	water.configure($Production/Ocean)
	for i in 8: await get_tree().process_frame
	ski.freeze = false
	ready_to_drive = true

func _process(delta: float) -> void:
	if ski == null: return
	var target := ski.global_position
	var backward := ski.global_basis.z
	backward.y = 0
	var desired := target + Vector3.UP * 4 + backward.normalized() * 8
	if follow_camera:
		camera.global_position = camera.global_position.lerp(desired, 1.0-exp(-delta*4))
		if camera.global_position.distance_to(target) > 0.1: camera.look_at(target + Vector3(0,0.5,0))
	label.text = "W/S throttle/reverse • A/D steer • F3 contacts • P pause • R reset\nPHYSICAL_HEIGHTFIELD: horizontal factor 0 | age %d ticks | speed %.1f m/s\n%s" % [water.result_age, ski.linear_velocity.length(), "WATER SAMPLES READY" if water.samples.size()==4 else "waiting for coherent samples"]
	debug_mesh.clear_surfaces()
	if not contact_debug or not ready_to_drive: return
	debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in 4:
		var physics := ski.water_physics_system
		var p: Vector3 = ski.get_node("BuoyancyPoints/"+physics.POINT_NAMES[i]).global_position
		var valid := physics.point_sample_valid[i]
		var wet := physics.point_depths[i] > 0 and valid
		debug_mesh.surface_set_color(Color.LIME_GREEN if wet else Color.ORANGE)
		debug_mesh.surface_add_vertex(p-Vector3(0.06,0,0)); debug_mesh.surface_add_vertex(p+Vector3(0.06,0,0))
		debug_mesh.surface_add_vertex(p-Vector3(0,0,0.06)); debug_mesh.surface_add_vertex(p+Vector3(0,0,0.06))
		if valid:
			debug_mesh.surface_add_vertex(p); debug_mesh.surface_add_vertex(physics.point_water_surface_positions[i])
			debug_mesh.surface_set_color(Color.CYAN)
			debug_mesh.surface_add_vertex(p); debug_mesh.surface_add_vertex(p+physics.point_buoyancy_force_vectors[i]*0.0003)
	debug_mesh.surface_end()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo(): return
	if event.keycode == KEY_F3: contact_debug = not contact_debug
	if event.keycode == KEY_P: get_tree().paused = not get_tree().paused
	if event.keycode == KEY_ESCAPE: _close_gracefully()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _close_gracefully()

func _close_gracefully() -> void:
	if closing: return
	closing = true
	get_tree().paused = false
	if ski != null: ski.freeze = true
	if water != null and water.query != null:
		var token: RefCounted = water.query
		RenderingServer.call_on_render_thread(token.shutdown)
		# Continue presenting frames while native async callbacks drain; no rd.sync.
		for i in 180:
			await get_tree().process_frame
			if token.get_stats().retired and token.get_stats().owned_buffers == 0: break
		var stats: Dictionary = token.get_stats()
		print("GAMEPLAY_QUERY_SHUTDOWN="+JSON.stringify({"in_flight":stats.in_flight,"owned_buffers":stats.owned_buffers,"pending":stats.pending,"retired":stats.retired,"errors":stats.errors,"mismatches":stats.mismatches}))
	$Production/Ocean.shutdown()
	for i in 8: await get_tree().process_frame
	get_tree().quit()

func _register_inputs() -> void:
	for action in {"throttle":KEY_W,"brake":KEY_S,"steer_left":KEY_A,"steer_right":KEY_D,"rider_shift_left":KEY_LEFT,"rider_shift_right":KEY_RIGHT,"rider_shift_forward":KEY_UP,"rider_shift_back":KEY_DOWN,"reset_vehicle":KEY_R,"recover_vehicle":KEY_T,"eject_rider":KEY_E}:
		if not InputMap.has_action(action): InputMap.add_action(action)
		var event := InputEventKey.new(); event.physical_keycode = {"throttle":KEY_W,"brake":KEY_S,"steer_left":KEY_A,"steer_right":KEY_D,"rider_shift_left":KEY_LEFT,"rider_shift_right":KEY_RIGHT,"rider_shift_forward":KEY_UP,"rider_shift_back":KEY_DOWN,"reset_vehicle":KEY_R,"recover_vehicle":KEY_T,"eject_rider":KEY_E}[action]
		InputMap.action_add_event(action,event)
