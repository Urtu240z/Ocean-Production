extends Node3D
## Launchable development gameplay scene. The production ocean scene is reused.
const Vehicle = preload("res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn")
const Provider = preload("res://gameplay/water/gpu_heightfield_water.gd")
const CpuProvider = preload("res://gameplay/water/cpu_fft_water_provider.gd")
@export_enum("GPU PHYSICAL_HEIGHTFIELD", "FULL CPU reference", "CPU LITE B") var physics_water_backend := 1
@export var compare_cpu_backends := false
@export var contact_debug := true
@export var capture_metrics := false
@export_enum("Current Production", "Normal", "Storm") var validation_sea_state := 0
@export_range(3, 8, 1) var query_ring_size := 3
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
var _telemetry_file: FileAccess
var _telemetry_elapsed := 0.0

func _enter_tree() -> void:
	# Startup selection happens before Production/Ocean enters the tree and builds its spectrum.
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--phys1-state="): continue
		match argument.trim_prefix("--phys1-state=").to_lower():
			"current", "production": validation_sea_state = 0
			"normal": validation_sea_state = 1
			"storm": validation_sea_state = 2
	var ocean := get_node_or_null("Production/Ocean")
	if ocean == null: return
	if validation_sea_state == 1:
		_apply_validation_sea_state(ocean, 1.8, 8.0, 35.0, 1.0, 1.0)
	elif validation_sea_state == 2:
		_apply_validation_sea_state(ocean, 3.0, 18.0, 75.0, 1.16, 0.8)

func _apply_validation_sea_state(ocean: Node, wave_height: float, wind_speed: float,
		wind_direction: float, height_scale: float, swell_scale: float) -> void:
	ocean.set("coastal", false)
	ocean.set("breakers", false)
	ocean.set("sea_state_mode", 1)
	ocean.set("significant_wave_height_m", wave_height)
	ocean.set("wind_speed_mps", wind_speed)
	ocean.set("wind_direction_degrees", wind_direction)
	ocean.set("wave_height_scale", height_scale)
	ocean.set("swell", swell_scale)

func _ready() -> void:
	get_tree().auto_accept_quit = false
	get_window().size = development_window_size
	var cpu_water: Node
	var selected_cpu_backend := CpuProvider.Backend.CPU_LITE_B
	_register_inputs()
	$Production/FreeCamera.queue_free()
	$Production/OceanDevPanel.queue_free()
	var ocean: Node = $Production/Ocean
	# This phase evaluates the single-valued open-ocean physics surface only.
	ocean.set("coastal", false)
	ocean.set("breakers", false)
	if physics_water_backend == 0:
		var gpu_provider := Provider.new()
		gpu_provider.name = "PhysicalWater"
		gpu_provider.record_metrics = capture_metrics
		gpu_provider.ring_size_override = query_ring_size
		water = gpu_provider
	else:
		var cpu_provider := CpuProvider.new()
		cpu_provider.name = "PhysicalWater"
		selected_cpu_backend = CpuProvider.Backend.FULL_CPU if physics_water_backend == 1 else CpuProvider.Backend.CPU_LITE_B
		cpu_water = cpu_provider
		water = cpu_provider
	add_child(water)
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
	if physics_water_backend == 0:
		water.configure(ocean)
		for i in 8: await get_tree().process_frame
	else:
		if not bool(cpu_water.call("configure", ocean, selected_cpu_backend, compare_cpu_backends)):
			push_error("Selected synchronous CPU water backend failed to initialize")
			return
	ski.freeze = false
	ready_to_drive = true
	_open_manual_telemetry()

func _process(delta: float) -> void:
	if ski == null: return
	_telemetry_elapsed += delta
	if _telemetry_elapsed >= 1.0:
		_telemetry_elapsed = fmod(_telemetry_elapsed, 1.0)
		_record_manual_telemetry()
	var target := ski.global_position
	var backward := ski.global_basis.z
	backward.y = 0
	var desired := target + Vector3.UP * 4 + backward.normalized() * 8
	if follow_camera:
		camera.global_position = camera.global_position.lerp(desired, 1.0-exp(-delta*4))
		if camera.global_position.distance_to(target) > 0.1: camera.look_at(target + Vector3(0,0.5,0))
	var backend_status := ""
	if physics_water_backend == 0:
		backend_status = "PHYSICAL_HEIGHTFIELD: horizontal factor 0 | age %d ticks | %s" % [water.result_age,
			"WATER SAMPLES READY" if water.samples.size() == 4 else "waiting for coherent samples"]
	else:
		var profile: Dictionary = water.call("get_provider_profile")
		var wet := 0
		for i in ski.water_physics_system.point_depths.size():
			if ski.water_physics_system.point_sample_valid[i] and ski.water_physics_system.point_depths[i] > 0.0: wet += 1
		backend_status = "%s | field p95 %.2f ms | last query %.1f us | wet %d/4" % [
			water.call("get_manual_candidate_name"), float(profile.get("selected_update_p95_us", 0)) / 1000.0,
			float(water.get("last_contact_query_wall_us")), wet]
	var state_label := _validation_sea_state_name()
	var fft := $Production/Ocean.get_node_or_null("OpenOceanFFT")
	var wave_time := float(fft.call("get_wave_time")) if fft != null else 0.0
	var euler := ski.global_basis.get_euler()
	var navigation := ski.navigation_system.state if ski.navigation_system != null else null
	var airborne := navigation != null and bool(navigation.has_confirmed_airborne)
	label.text = "W/S throttle/reverse • A/D steer • 1 Full • 2 B+LONG • 3 LONG+SHORT • 4 128 Cubic • F3 contacts • P pause • R reset\n%s | %s t=%.2fs | speed %.1f m/s | v=(%.1f, %.1f, %.1f) | pitch %.1f° roll %.1f° | airborne %s" % [
		backend_status, state_label, wave_time, ski.linear_velocity.length(), ski.linear_velocity.x,
		ski.linear_velocity.y, ski.linear_velocity.z, rad_to_deg(euler.x), rad_to_deg(euler.z),
		"yes" if airborne else "no"]
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

func _validation_sea_state_name() -> String:
	return ["CURRENT_PRODUCTION", "NORMAL", "STORM"][clampi(validation_sea_state, 0, 2)]

func _open_manual_telemetry() -> void:
	if physics_water_backend == 0: return
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	var path := "res://.godot/phys_cpu_lite_manual_%s_%s.csv" % [_validation_sea_state_name().to_lower(), stamp]
	_telemetry_file = FileAccess.open(path, FileAccess.WRITE)
	if _telemetry_file == null:
		push_warning("Manual CPU Lite telemetry could not be opened: " + path)
		return
	_telemetry_file.store_line("elapsed_ms,sea_state,wave_time,backend,field_update_us,contact_query_wall_us,velocity_x,velocity_y,velocity_z,pitch_deg,roll_deg,wet_contacts,airborne")
	_telemetry_file.flush()
	print("PHYS_CPU_LITE_MANUAL_TELEMETRY=" + path)

func _record_manual_telemetry() -> void:
	if _telemetry_file == null or not is_instance_valid(ski) or water == null: return
	var profile: Dictionary = water.call("get_provider_profile")
	var wet := 0
	for index in ski.water_physics_system.point_depths.size():
		if ski.water_physics_system.point_sample_valid[index] and ski.water_physics_system.point_depths[index] > 0.0: wet += 1
	var fft := $Production/Ocean.get_node_or_null("OpenOceanFFT")
	var wave_time := float(fft.call("get_wave_time")) if fft != null else 0.0
	var euler := ski.global_basis.get_euler()
	var navigation := ski.navigation_system.state if ski.navigation_system != null else null
	var airborne := navigation != null and bool(navigation.has_confirmed_airborne)
	_telemetry_file.store_line("%d,%s,%.6f,%s,%d,%.3f,%.6f,%.6f,%.6f,%.4f,%.4f,%d,%s" % [
		Time.get_ticks_msec(), _validation_sea_state_name(), wave_time,
		water.call("get_manual_candidate_name"), int(profile.get("field_update_us", 0)),
		float(water.get("last_contact_query_wall_us")), ski.linear_velocity.x, ski.linear_velocity.y,
		ski.linear_velocity.z, rad_to_deg(euler.x), rad_to_deg(euler.z), wet, str(airborne).to_lower()])
	_telemetry_file.flush()

func _exit_tree() -> void:
	if _telemetry_file != null:
		_telemetry_file.close()
		_telemetry_file = null

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo(): return
	if event.keycode == KEY_F3: contact_debug = not contact_debug
	if event.keycode == KEY_P: get_tree().paused = not get_tree().paused
	if event.keycode == KEY_ESCAPE: _close_gracefully()
	if ready_to_drive and physics_water_backend != 0 and event.keycode in [KEY_1, KEY_2, KEY_3, KEY_4]:
		var selected := 0 if event.keycode == KEY_1 else (1 if event.keycode == KEY_2 else (2 if event.keycode == KEY_3 else 3))
		if bool(water.call("set_manual_candidate", selected)):
			print("PHYS_CPU_LITE_MANUAL_CANDIDATE=" + str(water.call("get_manual_candidate_name")))

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _close_gracefully()

func _close_gracefully() -> void:
	if closing: return
	closing = true
	get_tree().paused = false
	if ski != null: ski.freeze = true
	if physics_water_backend == 0 and water != null and water.query != null:
		var token: RefCounted = water.query
		RenderingServer.call_on_render_thread(token.shutdown)
		# Continue presenting frames while native async callbacks drain; no rd.sync.
		for i in 180:
			await get_tree().process_frame
			if token.get_stats().retired and token.get_stats().owned_buffers == 0: break
		var stats: Dictionary = token.get_stats()
		print("GAMEPLAY_QUERY_SHUTDOWN="+JSON.stringify({"in_flight":stats.in_flight,"owned_buffers":stats.owned_buffers,"pending":stats.pending,"retired":stats.retired,"errors":stats.errors,"mismatches":stats.mismatches}))
	elif physics_water_backend != 0 and water != null:
		print("CPU_WATER_PROVIDER_PROFILE=" + JSON.stringify(water.call("get_provider_profile")))
		water.call("shutdown")
	$Production/Ocean.shutdown()
	for i in 8: await get_tree().process_frame
	get_tree().quit()

func _register_inputs() -> void:
	for action in {"throttle":KEY_W,"brake":KEY_S,"steer_left":KEY_A,"steer_right":KEY_D,"rider_shift_left":KEY_LEFT,"rider_shift_right":KEY_RIGHT,"rider_shift_forward":KEY_UP,"rider_shift_back":KEY_DOWN,"reset_vehicle":KEY_R,"recover_vehicle":KEY_T,"eject_rider":KEY_E}:
		if not InputMap.has_action(action): InputMap.add_action(action)
		var event := InputEventKey.new(); event.physical_keycode = {"throttle":KEY_W,"brake":KEY_S,"steer_left":KEY_A,"steer_right":KEY_D,"rider_shift_left":KEY_LEFT,"rider_shift_right":KEY_RIGHT,"rider_shift_forward":KEY_UP,"rider_shift_back":KEY_DOWN,"reset_vehicle":KEY_R,"recover_vehicle":KEY_T,"eject_rider":KEY_E}[action]
		InputMap.action_add_event(action,event)
