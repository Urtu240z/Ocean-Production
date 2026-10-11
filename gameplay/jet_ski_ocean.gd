extends Node3D
## Launchable development gameplay scene. The production ocean scene is reused.
const Vehicle = preload("res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn")
const CpuProvider = preload("res://gameplay/water/cpu_fft_water_provider.gd")
const WaterContactFx = preload("res://gameplay/vehicles/common/visual/jet_ski_water_contact_fx.gd")
enum PhysicsMode { CURRENT, WATER_RACE }
@export var contact_debug := false
@export_enum("Current Production", "Normal", "Storm") var validation_sea_state := 0
@export var follow_camera := true
@export var development_window_size := Vector2i(960, 540)
@export_group("Gameplay Follow Camera")
@export_range(2.0, 12.0, 0.1, "suffix:m") var camera_distance_m := 4.5
@export_range(0.8, 5.0, 0.1, "suffix:m") var camera_height_m := 2.2
@export_range(0.1, 1.5, 0.05, "suffix:m") var camera_look_height_m := 0.65
@export_range(0.0, 5.0, 0.1, "suffix:m") var camera_look_ahead_m := 1.5
@export_range(50.0, 90.0, 1.0, "suffix:°") var camera_fov_degrees := 70.0
@export_range(1.0, 20.0, 0.5) var camera_follow_rate := 7.0
var ski: JetSkiController
var water: WaterSurfaceProvider3D
var camera: Camera3D
var debug_mesh := ImmediateMesh.new()
var debug_node: MeshInstance3D
var label: Label
var ready_to_drive := false
var physics_mode := PhysicsMode.CURRENT
var closing := false
var camera_feedback := ""
var camera_feedback_timer := 0.0
var camera_preset_index := 0
var alignment_validation_running := false
var advanced_diagnostics_enabled := false
var _last_physics_profile_tick := -1
var _physics_time_samples := PackedFloat32Array()
var _physics_time_summary := {"mean": 0.0, "p95": 0.0}

const CAMERA_PRESETS := [
	{"name": "CLOSE", "distance": 4.5, "height": 2.2, "look_height": 0.65, "look_ahead": 1.5, "fov": 70.0},
	{"name": "MEDIUM", "distance": 6.5, "height": 2.8, "look_height": 0.65, "look_ahead": 2.0, "fov": 72.0},
	{"name": "FAR", "distance": 9.0, "height": 3.4, "look_height": 0.7, "look_ahead": 2.5, "fov": 75.0},
]

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
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_window().size = development_window_size
	_register_inputs()
	$Production/FreeCamera.queue_free()
	$Production/OceanDevPanel.queue_free()
	var ocean: Node = $Production/Ocean
	# This phase evaluates the single-valued open-ocean physics surface only.
	ocean.set("coastal", false)
	ocean.set("breakers", false)
	var cpu_provider := CpuProvider.new()
	cpu_provider.name = "PhysicalWater"
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
	var water_contact_fx: Node3D = WaterContactFx.new()
	ski.add_child(water_contact_fx)
	camera = Camera3D.new(); add_child(camera); camera.current = true
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.far = 4000
	camera.fov = camera_fov_degrees
	debug_node = MeshInstance3D.new(); add_child(debug_node); debug_node.mesh = debug_mesh
	debug_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	debug_node.material_override = material
	var canvas := CanvasLayer.new(); add_child(canvas)
	label = Label.new(); canvas.add_child(label); label.position = Vector2(20,20)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	label.add_theme_constant_override("outline_size", 2)
	for i in 30: await get_tree().process_frame
	water.set("lite_resolutions", PackedInt32Array([128, 128, 128]))
	water.set("lite_interpolation_modes", PackedInt32Array([1, 1, 1]))
	water.set("compare_other_cpu_backend", false)
	water.set("capture_contact_trace", false)
	if not bool(water.call("configure", ocean, CpuProvider.Backend.CPU_LITE_B, false)):
		push_error("CPU Lite 128/128/128 cubic water field failed to initialize")
		return
	cpu_provider.set_query_mode(CpuProvider.QueryMode.DIRECT)
	cpu_provider.set_water_race_mode(true)
	ski.water_physics_system.diagnostics_enabled = false
	ski.water_physics_system.buoyancy_torque_scale = 1.0
	ski.set_ballast_mode(JetSkiController.BallastMode.STOCK)
	ski.set_draft_mode(JetSkiController.DraftMode.STANDARD)
	ski.set_drive_mode(JetSkiController.DriveMode.RACE)
	_set_physics_mode(PhysicsMode.WATER_RACE)
	_set_angular_mode(true)
	ski.set_combined_rider_inertia(true)
	ski.reset_physics_interpolation()
	ski.freeze = false
	ready_to_drive = true

func _process(delta: float) -> void:
	if ski == null: return
	if camera_feedback_timer > 0.0:
		camera_feedback_timer = maxf(camera_feedback_timer - delta, 0.0)
	var interpolated_transform := ski.get_global_transform_interpolated()
	var target := interpolated_transform.origin
	var backward := interpolated_transform.basis.z
	backward.y = 0
	if backward.length_squared() < 0.001: backward = Vector3.BACK
	backward = backward.normalized()
	var desired := target + Vector3.UP * camera_height_m + backward * camera_distance_m
	if follow_camera:
		camera.global_position = camera.global_position.lerp(desired, 1.0-exp(-delta*camera_follow_rate))
		camera.fov = camera_fov_degrees
		var forward := -backward
		camera.look_at(target + forward * camera_look_ahead_m + Vector3.UP * camera_look_height_m)
	if not advanced_diagnostics_enabled:
		label.text = "WATER: GAMEPLAY SURFACE\nHULL: WATER RACE\nMASS: %.0f kg\nDRAFT: %s (%.2f m)\nDRIVE: %s\nFPS: %d" % [
			ski.mass, ski.get_draft_mode_name(), ski.get_draft_offset_m(),
			ski.get_drive_mode_name(), Engine.get_frames_per_second()]
		return
	var provider: CpuProvider = water as CpuProvider
	var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	var physics_tick := Engine.get_physics_frames()
	if physics_tick != _last_physics_profile_tick:
		_last_physics_profile_tick = physics_tick
		_physics_time_samples.append(physics_ms)
		if _physics_time_samples.size() > 512: _physics_time_samples.remove_at(0)
		if physics_tick % 30 == 0: _physics_time_summary = _physics_time_stats()
	var hud := "FPS: %d | PHYSICS: %.1f ms\n" % [Engine.get_frames_per_second(), physics_ms]
	hud += "PHYSICS ROLLING: mean %.2f ms p95 %.2f ms\n" % [
		_physics_time_summary.mean, _physics_time_summary.p95]
	hud += "HULL: WATER RACE\nINERTIA: %s\nANGULAR: FULL TORQUE + WET DAMPING\nPHYS WATER: GAMEPLAY SURFACE (>= %.2f m)\nVISUAL FFT: FULL\n" % [
		"COMBINED RIDER" if ski.inertia_mode_combined_rider else "AUTO",
		provider.physics_min_wavelength_m]
	var gameplay_inertia: Vector3 = ski.inertia
	var modeled_com: Vector3 = ski.inertia_measurement.get(
		"modeled_combined_com_local_m", ski.center_of_mass
	)
	hud += "BALLAST: %s | MASS: %.0f kg\nMASS: %.0f kg | COM: WATER RACE %s\nMODELED COM: %s | INERTIA: %.1f / %.1f / %.1f\n" % [
		ski.get_ballast_mode_name(), ski.mass, ski.mass, str(ski.center_of_mass), str(modeled_com),
		gameplay_inertia.x, gameplay_inertia.y, gameplay_inertia.z]
	hud += "DRAFT: %s +%.2f m | SUPPORT DEPTH AVG %.3f m\nDRIVE: %s | PROPULSION %.0f N | CONTACT %.2f | THROTTLE τ %.2f s\n" % [
		ski.get_draft_mode_name(), ski.get_draft_offset_m(),
		ski.water_physics_system.state.average_effective_support_depth,
		ski.get_drive_mode_name(), ski.drive_system.state.propulsion_force,
		ski.drive_system.state.propulsion_contact_factor, ski.drive_system.throttle_response_seconds]
	var contact_physics := ski.water_physics_system
	hud += "CONTACTS: wet %d/4 | supported %d/4 | airborne %s | landing %s\n" % [
		contact_physics.wet_contact_count, contact_physics.supported_contact_count,
		str(contact_physics.contact_is_airborne), str(contact_physics.contact_is_landing)]
	var takeoff_diagnostic: Dictionary = contact_physics.takeoff_last_diagnostic
	hud += "TAKEOFF CLEANER: %s | LAST: %s\n" % [
		"ON" if contact_physics.takeoff_assist_enabled else "OFF",
		str(takeoff_diagnostic.get("classification", "—"))]
	hud += "TAKEOFF RATE PITCH %.2f→%.2f | ROLL %.2f→%.2f rad/s | YAW %.2f→%.2f\n" % [
		float(takeoff_diagnostic.get("pitch_rate_before_rad_s", 0.0)),
		float(takeoff_diagnostic.get("pitch_rate_after_rad_s", 0.0)),
		float(takeoff_diagnostic.get("roll_rate_before_rad_s", 0.0)),
		float(takeoff_diagnostic.get("roll_rate_after_rad_s", 0.0)),
		float(takeoff_diagnostic.get("yaw_rate_before_rad_s", 0.0)),
		float(takeoff_diagnostic.get("yaw_rate_after_rad_s", 0.0))]
	hud += "TAKEOFF IMPULSE %s N·m·s | RIDER INTENT %s\n" % [
		str(takeoff_diagnostic.get("correction_angular_impulse_world_nms", Vector3.ZERO)),
		str(takeoff_diagnostic.get("rider_intent", Vector2.ZERO))]
	hud += "FIELD BUILD: %.2f ms | NATIVE BATCHES: %d (%d points) | QUERY: %d us\n" % [
		float(provider.get("field_update_us")) / 1000.0,
		int(provider.get("native_query_batches_this_physics_tick")),
		int(provider.get("native_query_positions_this_physics_tick")),
		int(provider.get("water_query_batch_us_this_physics_tick"))]
	hud += "BUILDS/TICK: %d | contacts %d/4 | speed %.1f m/s" % [
		int(provider.get("field_builds_this_physics_tick")),
		ski.water_physics_system.state.submerged_point_count, ski.linear_velocity.length()]
	hud += "\nCAMERA: %s  %.1f m / %.1f m  FOV %.0f°" % [
		_camera_preset_name(), camera_distance_m, camera_height_m, camera_fov_degrees]
	hud += "\nW/S throttle  A/D steer  rider weight shift  B ballast"
	hud += "\nR reset  F6 AUTO inertia  F7 COMBINED RIDER inertia  F8 takeoff cleaner  C camera  F4 diagnostics  F3 contact overlay"
	hud += "\nNumpad +/- or wheel distance  PgUp/PgDn height  ESC cursor  F10 quit"
	if camera_feedback_timer > 0.0:
		hud += "\n" + camera_feedback
	if contact_debug and ski.water_physics_system.force_debug_enabled:
		var physics := ski.water_physics_system
		for index in physics.point_spring_forces.size():
			var clamp_text := "MAX" if physics.point_force_clamp_reached[index] else "OK"
			hud += "\nP%d d%.2f n%+.2f spring%.0f damp%+.0f final%.0f %s" % [
				index + 1, physics._point_diagnostic_depth[index],
				physics._point_diagnostic_normal_speed[index], physics.point_spring_forces[index],
				physics.point_damping_forces[index], physics.point_normal_forces[index], clamp_text]
		hud += "\nOLD LAW CLAMP: %d/%d | damping-caused %d/%d" % [
			physics.baseline_force_clamp_count, physics.baseline_contact_count,
			physics.baseline_damping_caused_clamp_count, physics.baseline_contact_count]
		var force_diagnostics: Dictionary = physics.get_gameplay_force_diagnostics()
		hud += "\nTOTAL BUOYANCY TORQUE N·m mean %.0f p95 %.0f max %.0f | pitch %.2f roll %.2f rad/s p95" % [
			force_diagnostics.get("total_buoyancy_torque_stats_nm", {}).get("mean", 0.0),
			force_diagnostics.get("total_buoyancy_torque_stats_nm", {}).get("p95", 0.0),
			force_diagnostics.get("total_buoyancy_torque_stats_nm", {}).get("max", 0.0),
			force_diagnostics.get("angular_velocity_pitch_rad_s", {}).get("p95", 0.0),
			force_diagnostics.get("angular_velocity_roll_rad_s", {}).get("p95", 0.0)]
		for point in force_diagnostics.get("points", []):
			hud += "\n%s d %.2f m F %.0f N r %s τ %.0f N·m" % [
				point.contact, point.depth_m, point.force_n, str(point.lever_arm_m), point.torque_magnitude_nm]
	label.text = hud
	debug_mesh.clear_surfaces()
	if not contact_debug or not ready_to_drive: return
	debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	if contact_debug:
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

func _debug_cross(center: Vector3, radius: float, color: Color) -> void:
	debug_mesh.surface_set_color(color)
	debug_mesh.surface_add_vertex(center - Vector3(radius, 0, 0))
	debug_mesh.surface_add_vertex(center + Vector3(radius, 0, 0))
	debug_mesh.surface_add_vertex(center - Vector3(0, 0, radius))
	debug_mesh.surface_add_vertex(center + Vector3(0, 0, radius))
	debug_mesh.surface_add_vertex(center - Vector3(0, radius, 0))
	debug_mesh.surface_add_vertex(center + Vector3(0, radius, 0))

func _physics_time_stats() -> Dictionary:
	if _physics_time_samples.is_empty(): return {"mean": 0.0, "p95": 0.0}
	var ordered := _physics_time_samples.duplicate()
	ordered.sort()
	var total := 0.0
	for value in _physics_time_samples: total += value
	var p95_index := mini(ordered.size() - 1, int(ceil((ordered.size() - 1) * 0.95)))
	return {"mean": total / ordered.size(), "p95": ordered[p95_index]}

func _camera_preset_name() -> String:
	for preset in CAMERA_PRESETS:
		if is_equal_approx(camera_distance_m, preset.distance) and is_equal_approx(camera_height_m, preset.height) \
			and is_equal_approx(camera_look_height_m, preset.look_height) and is_equal_approx(camera_look_ahead_m, preset.look_ahead) \
			and is_equal_approx(camera_fov_degrees, preset.fov):
			return preset.name
	return "CUSTOM"

func _show_camera_feedback(action: String) -> void:
	camera_feedback = "CAMERA %s | %s | distance %.1f m | height %.1f m" % [action, _camera_preset_name(), camera_distance_m, camera_height_m]
	camera_feedback_timer = 2.5

func _adjust_camera_distance(amount: float) -> void:
	camera_distance_m = clampf(camera_distance_m + amount, 2.0, 12.0)
	_show_camera_feedback("DISTANCE")

func _adjust_camera_height(amount: float) -> void:
	camera_height_m = clampf(camera_height_m + amount, 0.8, 5.0)
	_show_camera_feedback("HEIGHT")

func _cycle_camera_preset() -> void:
	var current_name := _camera_preset_name()
	var next_index := 0
	for i in CAMERA_PRESETS.size():
		if CAMERA_PRESETS[i].name == current_name:
			next_index = (i + 1) % CAMERA_PRESETS.size()
			break
	var preset: Dictionary = CAMERA_PRESETS[next_index]
	camera_preset_index = next_index
	camera_distance_m = preset.distance
	camera_height_m = preset.height
	camera_look_height_m = preset.look_height
	camera_look_ahead_m = preset.look_ahead
	camera_fov_degrees = preset.fov
	_show_camera_feedback("PRESET")

func _physics_mode_name() -> String:
	return "WATER RACE" if physics_mode == PhysicsMode.WATER_RACE else "CURRENT"


func _visual_fft_mode_name() -> String:
	var gate := get_node_or_null("Production/FFTCascadeGate")
	if gate != null and gate.has_method("_mode_name"):
		return str(gate.call("_mode_name", gate.get("_mode")))
	return "FULL"


func _set_physics_mode(mode: int) -> void:
	physics_mode = mode
	if ski != null:
		ski.water_physics_system.water_race_mode = mode == PhysicsMode.WATER_RACE
	print("PHYSICS MODE: " + _physics_mode_name())


func _set_angular_mode(stabilized: bool) -> void:
	if ski == null: return
	ski.water_physics_system.stabilized_angular_mode = stabilized
	ski.water_physics_system.reset_diagnostics()
	print("ANGULAR MODE: " + ("STABILIZED" if stabilized else "RAW"))

func _set_inertia_mode(combined_rider: bool) -> void:
	if ski == null: return
	ski.set_combined_rider_inertia(combined_rider)
	print("INERTIA MODE: " + ("COMBINED RIDER" if combined_rider else "AUTO"))

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo(): return
	if ready_to_drive and event.keycode == KEY_F4:
		advanced_diagnostics_enabled = not advanced_diagnostics_enabled
		if ski != null:
			ski.water_physics_system.diagnostics_enabled = advanced_diagnostics_enabled
			ski.water_physics_system.force_debug_enabled = advanced_diagnostics_enabled
			ski.water_physics_system.reset_diagnostics()
		if not advanced_diagnostics_enabled:
			contact_debug = false
			debug_mesh.clear_surfaces()
		print("ADVANCED DIAGNOSTICS: " + ("ON" if advanced_diagnostics_enabled else "OFF"))
	if event.keycode == KEY_F3 and advanced_diagnostics_enabled:
		contact_debug = not contact_debug
	if ready_to_drive and event.keycode == KEY_F6: _set_inertia_mode(false)
	if ready_to_drive and event.keycode == KEY_F7: _set_inertia_mode(true)
	if ready_to_drive and event.keycode == KEY_F8:
		ski.water_physics_system.set_takeoff_assist_enabled(
			not ski.water_physics_system.takeoff_assist_enabled
		)
		print("TAKEOFF CLEANER: " + ("ON" if ski.water_physics_system.takeoff_assist_enabled else "OFF"))
	if ready_to_drive and event.keycode == KEY_B:
		ski.cycle_ballast_mode()
		print("BALLAST: %s | MASS: %.0f kg" % [ski.get_ballast_mode_name(), ski.mass])
	if ready_to_drive and event.keycode == KEY_V:
		ski.cycle_draft_mode()
		print("DRAFT: %s | offset %.2f m" % [ski.get_draft_mode_name(), ski.get_draft_offset_m()])
	if ready_to_drive and event.keycode == KEY_N:
		ski.cycle_drive_mode()
		print("DRIVE: %s | %.0f N forward" % [ski.get_drive_mode_name(), ski.drive_system.forward_engine_force])
	if event.keycode == KEY_P: get_tree().paused = not get_tree().paused
	if event.keycode == KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event.keycode == KEY_F10: _close_gracefully()
	if event.keycode in [KEY_KP_ADD, KEY_EQUAL]: _adjust_camera_distance(-0.25)
	if event.keycode in [KEY_KP_SUBTRACT, KEY_MINUS]: _adjust_camera_distance(0.25)
	if event.keycode == KEY_PAGEUP: _adjust_camera_height(0.15)
	if event.keycode == KEY_PAGEDOWN: _adjust_camera_height(-0.15)
	if event.keycode == KEY_C: _cycle_camera_preset()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: _adjust_camera_distance(-0.25)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: _adjust_camera_distance(0.25)

func start_gameplay_baseline_validation() -> void:
	if not ready_to_drive or alignment_validation_running: return
	alignment_validation_running = true
	var validator := preload("res://validation/physics/phys_gameplay_baseline_validation.gd").new()
	add_child(validator)
	validator.run(self)


func start_feel_2b_validation() -> void:
	if not ready_to_drive:
		return
	var validator := preload("res://validation/physics/jetski_feel_2b_validation.gd").new()
	add_child(validator)
	validator.run_drive_profiles(self)


func start_feel_3_validation() -> void:
	if not ready_to_drive:
		return
	var validator := preload("res://validation/physics/jetski_feel_3_takeoff_validation.gd").new()
	add_child(validator)
	validator.run(self)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _close_gracefully()

func _close_gracefully() -> void:
	if closing: return
	closing = true
	get_tree().paused = false
	if ski != null: ski.freeze = true
	if water != null:
		water.call("shutdown")
	$Production/Ocean.shutdown()
	for i in 8: await get_tree().process_frame
	get_tree().quit()

func _register_inputs() -> void:
	for action in {"throttle":KEY_W,"brake":KEY_S,"steer_left":KEY_A,"steer_right":KEY_D,"rider_shift_left":KEY_LEFT,"rider_shift_right":KEY_RIGHT,"rider_shift_forward":KEY_UP,"rider_shift_back":KEY_DOWN,"reset_vehicle":KEY_R,"recover_vehicle":KEY_T,"eject_rider":KEY_E}:
		if not InputMap.has_action(action): InputMap.add_action(action)
		var event := InputEventKey.new(); event.physical_keycode = {"throttle":KEY_W,"brake":KEY_S,"steer_left":KEY_A,"steer_right":KEY_D,"rider_shift_left":KEY_LEFT,"rider_shift_right":KEY_RIGHT,"rider_shift_forward":KEY_UP,"rider_shift_back":KEY_DOWN,"reset_vehicle":KEY_R,"recover_vehicle":KEY_T,"eject_rider":KEY_E}[action]
		InputMap.action_add_event(action,event)
