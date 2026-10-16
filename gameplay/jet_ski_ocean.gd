extends Node3D
## Launchable development gameplay scene. The production ocean scene is reused.
const Vehicle = preload("res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn")
const CpuProvider = preload("res://gameplay/water/cpu_fft_water_provider.gd")
const OceanInteractionSink = preload("res://gameplay/integration/ocean_jet_ski_interaction_sink.gd")
const WaterContactFx = preload("res://gameplay/vehicles/common/visual/jet_ski_water_contact_fx.gd")
const Feel4Validation = preload("res://validation/physics/jetski_feel_4_validation.gd")
const Feel4BValidation = preload("res://validation/physics/jetski_feel_4b_validation.gd")
enum PhysicsMode { CURRENT, WATER_RACE }
@export var contact_debug := false
@export_enum("Current Production", "Normal", "Storm") var validation_sea_state := 0
@export var development_window_size := Vector2i(960, 540)
@export_group("Gameplay Wave Drift")
@export var wave_drift_enabled := true
@export_range(0.0, 3.0, 0.05) var wave_drift_strength := 0.75
## Maximum added water flow; actual hull drift builds gradually through drag.
@export_range(0.0, 3.0, 0.05, "suffix:m/s") var wave_drift_max_speed_mps := 0.5
var ski: JetSkiController
var water: WaterSurfaceProvider3D
var camera: Camera3D
var camera_rig: Node3D
## Non-exported compatibility adapter for existing development validation runners.
## The vehicle rig is the only owner of the actual setting.
var follow_camera: bool:
	get:
		if is_instance_valid(camera_rig): return bool(camera_rig.get("follow_camera"))
		return bool(get_meta(&"requested_camera_follow", true))
	set(value):
		if is_instance_valid(camera_rig): camera_rig.set("follow_camera", value)
		else: set_meta(&"requested_camera_follow", value)
var debug_mesh := ImmediateMesh.new()
var debug_node: MeshInstance3D
var label: Label
var ready_to_drive := false
var physics_mode := PhysicsMode.CURRENT
var closing := false
var camera_feedback := ""
var camera_feedback_timer := 0.0
var alignment_validation_running := false
var advanced_diagnostics_enabled := false
var softer_water_profile_enabled := true
var _last_physics_profile_tick := -1
var _last_waterline_debug_tick := -1
var _timeline_capture_enabled := false
var _timeline_capture_remaining_s := 0.0
var _timeline_capture_rows: Array[Dictionary] = []
var _timeline_capture_report: Dictionary = {}
var _timeline_capture_deferred_pending := false
var _timeline_contact_sample_accumulator := 0.0
var _timeline_contact_surface_errors := PackedFloat32Array()
var _waterline_debug_rows: Array[Dictionary] = []
var _waterline_trace_absolute_errors := PackedFloat32Array()
var _gameplay_audit_rows: Array[Dictionary] = []
var _gameplay_audit_rendered_hull_rows: Array[Dictionary] = []
var _gameplay_audit_hull_local_samples: Array[Dictionary] = []
var _gameplay_audit_pre_support_rows: Array[Dictionary] = []
var _gameplay_audit_air_events: Array[Dictionary] = []
var _gameplay_audit_previous_airborne := false
var _gameplay_audit_previous_velocity := Vector3.ZERO
var _gameplay_audit_last_tick := -1
var _requested_visual_water_profile: StringName = &"PHYSICS_ALIGNED"
var _requested_visual_water_multipliers := Vector3(0.0, 0.0, 1.0)
var _physics_time_samples := PackedFloat32Array()
var _physics_time_summary := {"mean": 0.0, "p95": 0.0}


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
	cpu_provider.wave_drift_enabled = wave_drift_enabled
	cpu_provider.wave_drift_strength = wave_drift_strength
	cpu_provider.wave_drift_max_speed_mps = wave_drift_max_speed_mps
	water = cpu_provider
	add_child(water)
	ski = Vehicle.instantiate()
	ski.process_mode = Node.PROCESS_MODE_PAUSABLE
	ski.name = "JetSki"
	ski.water_provider_path = NodePath("../PhysicalWater")
	# Respect the vehicle's submarine setting; this gameplay scene must not
	# silently disable the manual dive that its controller exposes.
	ski.trick_preload_enabled = false
	ski.freeze = true
	ski.position = Vector3(0, 1, 0)
	add_child(ski)
	camera_rig = ski.get_node("CameraRig")
	camera = camera_rig.get_node("Camera3D") as Camera3D
	camera_rig.connect("settings_changed", _on_camera_settings_changed)
	if has_meta(&"requested_camera_follow"):
		camera_rig.set("follow_camera", get_meta(&"requested_camera_follow"))
		remove_meta(&"requested_camera_follow")
	var water_contact_fx: Node3D = WaterContactFx.new()
	var interaction_sink := OceanInteractionSink.new()
	interaction_sink.name = "OceanVehicleInteractions"
	interaction_sink.configure(ocean)
	add_child(interaction_sink)
	water_contact_fx.set_water_interaction_sink(interaction_sink)
	ski.add_child(water_contact_fx)
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
	_apply_requested_visual_water_profile()
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

func _physics_process(_delta: float) -> void:
	if water != null:
		water.set("wave_drift_enabled", wave_drift_enabled)
		water.set("wave_drift_strength", wave_drift_strength)
		water.set("wave_drift_max_speed_mps", wave_drift_max_speed_mps)
func _process(delta: float) -> void:
	if ski == null: return
	_apply_requested_visual_water_profile()
	if camera_feedback_timer > 0.0:
		camera_feedback_timer = maxf(camera_feedback_timer - delta, 0.0)
	var interpolated_transform := ski.get_global_transform_interpolated()
	_capture_physics_timeline_frame(delta, interpolated_transform)
	if not advanced_diagnostics_enabled:
		label.text = "WATER: GAMEPLAY SURFACE\nHULL: WATER RACE\nVISUAL WATER: %s\nMASS: %.0f kg\nDRAFT: %s (%.2f m)\nDRIVE: %s\nFPS: %d" % [
			_visual_fft_mode_name(),
			ski.mass, ski.get_draft_mode_name(), ski.get_draft_offset_m(),
			ski.get_drive_mode_name(), Engine.get_frames_per_second()]
		return
	var provider: CpuProvider = water as CpuProvider
	var physics_tick := Engine.get_physics_frames()
	if advanced_diagnostics_enabled and contact_debug and physics_tick != _last_waterline_debug_tick:
		_last_waterline_debug_tick = physics_tick
		_update_waterline_debug(provider)
	var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	if physics_tick != _last_physics_profile_tick:
		_last_physics_profile_tick = physics_tick
		_physics_time_samples.append(physics_ms)
		if _physics_time_samples.size() > 512: _physics_time_samples.remove_at(0)
		if physics_tick % 30 == 0: _physics_time_summary = _physics_time_stats()
	var hud := "FPS: %d | PHYSICS: %.1f ms\n" % [Engine.get_frames_per_second(), physics_ms]
	hud += "PHYSICS ROLLING: mean %.2f ms p95 %.2f ms\n" % [
		_physics_time_summary.mean, _physics_time_summary.p95]
	hud += "HULL: WATER RACE\nINERTIA: %s\nANGULAR: FULL TORQUE + WET DAMPING\nPHYS WATER: GAMEPLAY SURFACE (>= %.2f m)\nVISUAL WATER: %s\n" % [
		"COMBINED RIDER" if ski.inertia_mode_combined_rider else "AUTO",
		provider.physics_min_wavelength_m, _visual_fft_mode_name()]
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
	var contact_clearance := 0.0
	for point_depth in contact_physics.get_buoyancy_point_depths():
		contact_clearance = maxf(contact_clearance, -point_depth)
	hud += "AIRBORNE: %.2f s | CLEARANCE: %.2f m | ANTI-HOP: %s | REDUCTION: %.1f m/s² | GRACE: %.2f | SHORT HOPS: %d\n" % [
		contact_physics._airborne_dry_time_s, maxf(contact_clearance, 0.0),
		"ON" if contact_physics.anti_hop_enabled else "OFF",
		contact_physics.anti_hop_last_acceleration_reduction_mps2,
		contact_physics.propulsion_grace_current_multiplier, contact_physics.short_hop_count]
	if contact_debug:
		hud += "WATERLINE ERROR cm: "
		for index in _waterline_debug_rows.size():
			var row: Dictionary = _waterline_debug_rows[index]
			if bool(row.get("valid", false)):
				hud += "%s Δ%+.1fcm hull G/V %+.1f/%+.1fcm Vy %+.2f  " % [
					str(row.get("contact", "P%d" % (index + 1))),
					float(row.get("delta_height_m", 0.0)) * 100.0,
					float(row.get("hull_vs_gameplay_m", 0.0)) * 100.0,
					float(row.get("hull_vs_visual_equivalent_m", 0.0)) * 100.0,
					float(row.get("gameplay_vy_mps", 0.0))]
			else:
				hud += "%s INVALID  " % str(row.get("contact", "P%d" % (index + 1)))
		hud += "\n"
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
		camera_rig.call("get_preset_name"), camera_rig.get("camera_distance_m"), camera_rig.get("camera_height_m"), camera_rig.get("camera_fov_degrees")]
	hud += "\nW/S throttle  A/D steer  rider weight shift  B ballast"
	hud += "\nR reset  F6 AUTO inertia  F7 COMBINED RIDER inertia  F8 takeoff cleaner  F11 anti-hop  C camera  F4 diagnostics  F3 waterline overlay"
	hud += "\nF2 FULL_CHOPPY_DEBUG / PHYSICS_ALIGNED visual A/B  F5 RAW/SOFTER water  F9 FEEL-4B  F12 FEEL-5 A/B"
	hud += "\nNumpad +/- or wheel distance  PgUp/PgDn height  ESC cursor  F10 quit"
	if camera_feedback_timer > 0.0:
		hud += "\n" + camera_feedback
	hud += "\nWATER RESPONSE: %s | NORMAL INFLUENCE %.2f | K %.0f N/m C %.0f N·s/m | EQ %.2f m ζ %.2f | WET DAMP %.0f / %.0f / %.0f" % [
		"SOFTER" if softer_water_profile_enabled else "RAW",
		ski.water_physics_system.buoyancy_normal_influence,
		ski.water_physics_system.buoyancy_strength_per_point,
		ski.water_physics_system.buoyancy_damping_per_point,
		ski.water_physics_system.equilibrium_depth,
		ski.water_physics_system.damping_ratio,
		ski.water_physics_system.wet_pitch_damping,
		ski.water_physics_system.wet_yaw_damping,
		ski.water_physics_system.wet_roll_damping]
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
		for row in _waterline_debug_rows:
			if not bool(row.get("valid", false)): continue
			var hull_point: Vector3 = row.point
			var direct_surface := Vector3(hull_point.x, float(row.gameplay_height_m), hull_point.z)
			var oracle_surface := Vector3(hull_point.x, float(row.visual_equivalent_height_m), hull_point.z)
			debug_mesh.surface_set_color(Color.LIME_GREEN)
			debug_mesh.surface_add_vertex(oracle_surface)
			debug_mesh.surface_add_vertex(oracle_surface + Vector3.UP * 0.001)
			debug_mesh.surface_set_color(Color.RED)
			debug_mesh.surface_add_vertex(direct_surface)
			debug_mesh.surface_add_vertex(direct_surface + Vector3.UP * 0.001)
			_debug_cross(oracle_surface, 0.07, Color.LIME_GREEN)
			_debug_cross(direct_surface, 0.07, Color.RED)
			_debug_cross(hull_point, 0.055, Color.WHITE)
			debug_mesh.surface_set_color(Color.CYAN)
			debug_mesh.surface_add_vertex(direct_surface)
			debug_mesh.surface_add_vertex(oracle_surface)
	debug_mesh.surface_end()

func _update_waterline_debug(provider: CpuProvider) -> void:
	_waterline_debug_rows.clear()
	if provider == null or not provider.field_ready:
		return
	var physics := ski.water_physics_system
	var tick := Engine.get_physics_frames()
	var now_s := Time.get_ticks_msec() * 0.001
	var velocity := ski.linear_velocity
	var dt := 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
	var vertical_acceleration := (velocity.y - _gameplay_audit_previous_velocity.y) / dt
	var raw_airborne := physics.state.submerged_point_count == 0
	var positions := PackedVector3Array()
	for point_name in physics.POINT_NAMES:
		positions.append(ski.get_node("BuoyancyPoints/" + point_name).global_position)
	var report: Dictionary = provider.validate_direct_vs_rendered_surface(positions)
	var rows: Array = report.get("rows", [])
	var audit_contacts: Array[Dictionary] = []
	var spring_sum := 0.0
	var damping_sum := 0.0
	var final_sum := 0.0
	var shallow_spring_sum := 0.0
	var deep_support_sum := 0.0
	var damping_post_clamp_sum := 0.0
	var support_cap_correction_sum := 0.0
	var maximum_clearance := -INF
	for index in mini(positions.size(), rows.size()):
		var comparison: Dictionary = rows[index]
		var point: Vector3 = positions[index]
		if not bool(comparison.get("valid", false)):
			_waterline_debug_rows.append({"contact": physics.POINT_NAMES[index], "valid": false})
			continue
		var gameplay_height := float(comparison.get("direct_height_m", point.y))
		var oracle_height := float(comparison.get("rendered_height_m", point.y))
		var spring_force := float(physics.point_spring_forces[index]) if index < physics.point_spring_forces.size() else 0.0
		var damping_force := float(physics.point_damping_forces[index]) if index < physics.point_damping_forces.size() else 0.0
		var final_force := float(physics.point_normal_forces[index]) if index < physics.point_normal_forces.size() else 0.0
		var support_depth := float(physics.effective_point_depths[index]) if index < physics.effective_point_depths.size() else 0.0
		var deep_depth := maxf(support_depth - physics.deep_buoyancy_start_depth, 0.0)
		var deep_force := minf(physics.deep_buoyancy_strength_per_point * deep_depth,
			physics.deep_buoyancy_force_limit_per_meter * deep_depth)
		var shallow_spring_force := maxf(spring_force - deep_force, 0.0)
		var uncapped_support := spring_force + damping_force
		var clamped_support := clampf(uncapped_support, 0.0, physics.max_buoyancy_force_per_point)
		var force_scale_after_clamps := final_force / uncapped_support if uncapped_support > 0.0001 else 0.0
		var post_clamp_shallow := shallow_spring_force * force_scale_after_clamps
		var post_clamp_deep := deep_force * force_scale_after_clamps
		var post_clamp_damping := damping_force * force_scale_after_clamps
		var clearance := point.y - gameplay_height
		spring_sum += spring_force
		damping_sum += damping_force
		final_sum += final_force
		shallow_spring_sum += post_clamp_shallow
		deep_support_sum += post_clamp_deep
		damping_post_clamp_sum += post_clamp_damping
		support_cap_correction_sum += final_force - (shallow_spring_force + deep_force + damping_force)
		maximum_clearance = maxf(maximum_clearance, clearance)
		_waterline_trace_absolute_errors.append(absf(gameplay_height - oracle_height))
		if _waterline_trace_absolute_errors.size() > 8192:
			_waterline_trace_absolute_errors.remove_at(0)
		audit_contacts.append({
			"contact": physics.POINT_NAMES[index],
			"hull_y_m": point.y,
			"direct_water_y_m": gameplay_height,
			"visual_equivalent_y_m": oracle_height,
			"visual_minus_direct_m": oracle_height - gameplay_height,
			"hull_minus_direct_m": clearance,
			"hull_minus_visual_m": point.y - oracle_height,
			"water_vy_mps": physics.point_water_velocities[index].y if index < physics.point_water_velocities.size() else 0.0,
			"relative_contact_vy_mps": physics.point_relative_velocities[index].y if index < physics.point_relative_velocities.size() else 0.0,
			"spring_n": spring_force,
			"shallow_spring_n_pre_clamp": shallow_spring_force,
			"deep_support_n_pre_clamp": deep_force,
			"water_relative_damping_n": damping_force,
			"uncapped_support_n": uncapped_support,
			"support_after_force_cap_n": clamped_support,
			"support_final_after_submarine_and_limiter_n": final_force,
			"post_clamp_shallow_spring_n": post_clamp_shallow,
			"post_clamp_deep_support_n": post_clamp_deep,
			"post_clamp_damping_n": post_clamp_damping,
			"final_support_n": final_force,
			"force_capped": physics.point_force_clamp_reached[index] if index < physics.point_force_clamp_reached.size() else false,
			"wet": physics.point_sample_valid[index] and physics.point_depths[index] > 0.0,
		})
		_waterline_debug_rows.append({
			"contact": physics.POINT_NAMES[index],
			"valid": true,
			"point": point,
			"gameplay_height_m": gameplay_height,
			"visual_equivalent_height_m": oracle_height,
			"delta_height_m": gameplay_height - oracle_height,
			"gameplay_vy_mps": 0.0,
			"gameplay_normal": [0.0, 1.0, 0.0],
			"hull_vs_gameplay_m": point.y - gameplay_height,
			"hull_vs_visual_equivalent_m": point.y - oracle_height,
			"oracle_normal": [0.0, 1.0, 0.0],
		})
	if tick % 6 == 0 and not _gameplay_audit_hull_local_samples.is_empty():
		var hull_mesh := ski.get_node_or_null("VisualRoot/JetSkiVisual/HullModel/NewJetSki_Hull/hull") as MeshInstance3D
		if hull_mesh != null:
			var hull_positions := PackedVector3Array()
			for sample in _gameplay_audit_hull_local_samples:
				hull_positions.append(hull_mesh.global_transform * sample.point)
			var hull_report: Dictionary = provider.validate_direct_vs_rendered_surface(hull_positions)
			var hull_rows: Array = hull_report.get("rows", [])
			for index in mini(hull_positions.size(), hull_rows.size()):
				var hull_sample: Dictionary = hull_rows[index]
				if not bool(hull_sample.get("valid", false)):
					continue
				var hull_point: Vector3 = hull_positions[index]
				var direct_y := float(hull_sample.get("direct_height_m", hull_point.y))
				var visual_y := float(hull_sample.get("rendered_height_m", hull_point.y))
				_gameplay_audit_rendered_hull_rows.append({
					"tick": tick,
					"time_s": now_s,
					"wave_time_s": provider.current_field_time,
					"sample_name": _gameplay_audit_hull_local_samples[index].label,
					"world_x_m": hull_point.x,
					"world_z_m": hull_point.z,
					"rendered_hull_y_m": hull_point.y,
					"direct_water_y_m": direct_y,
					"visual_equivalent_water_y_m": visual_y,
					"hull_minus_direct_m": hull_point.y - direct_y,
					"hull_minus_visual_equivalent_m": hull_point.y - visual_y,
				})
			if _gameplay_audit_rendered_hull_rows.size() > 8192:
				_gameplay_audit_rendered_hull_rows.pop_front()
	var audit_row := {
		"tick": tick,
		"time_s": now_s,
		"wave_time_s": provider.current_field_time,
		"vehicle_y_m": ski.global_position.y,
		"vertical_velocity_mps": velocity.y,
		"vertical_acceleration_mps2": vertical_acceleration,
		"pitch_deg": ski.global_rotation_degrees.x,
		"roll_deg": ski.global_rotation_degrees.z,
		"angular_velocity_rad_s": ski.angular_velocity,
		"wet_contacts": physics.wet_contact_count,
		"supported_contacts": physics.supported_contact_count,
		"raw_airborne": raw_airborne,
		"confirmed_airborne": physics.contact_is_airborne,
		"total_buoyancy_n": physics.state.total_buoyancy_force,
		"spring_total_n": spring_sum,
		"shallow_spring_post_clamp_n": shallow_spring_sum,
		"deep_support_post_clamp_n": deep_support_sum,
		"water_relative_damping_total_n": damping_sum,
		"water_relative_damping_post_clamp_n": damping_post_clamp_sum,
		"final_contact_support_total_n": final_sum,
		"support_cap_and_submarine_correction_n": support_cap_correction_sum,
		"actual_buoyancy_force_vector_n": physics.total_buoyancy_force_vector,
		"actual_buoyancy_force_y_n": physics.total_buoyancy_force_vector.y,
		"hydrodynamic_drag_force_y_n": _sum_drag_force_y(physics),
		"propulsion_force_vector_n": ski.drive_system.state.propulsion_force_vector,
		"propulsion_force_y_n": ski.drive_system.state.propulsion_force_vector.y,
		"coasting_steering_force_y_n": ski.drive_system.state.coasting_steering_force_vector.y,
		"gravity_force_y_n": physics.audit_last_total_gravity.y * ski.mass,
		"physical_contact_impulse_n_s": ski.navigation_system.state.physical_contact_impulse,
		"physical_contact_impulse_y_n_s": ski.navigation_system.state.physical_contact_impulse.y,
		"physical_contact_count": ski.physical_contact_count,
		"physical_contact_delta_velocity_mps": ski.physical_contact_delta_velocity,
		"required_net_force_y_n": ski.mass * vertical_acceleration,
		"force_balance_residual_y_n": _force_balance_residual_y(physics, ski, vertical_acceleration, dt),
		"average_depth_m": physics.state.average_depth,
		"maximum_depth_m": physics.state.maximum_depth,
		"maximum_contact_clearance_m": maximum_clearance if is_finite(maximum_clearance) else 0.0,
		"contacts": audit_contacts,
	}
	_gameplay_audit_rows.append(audit_row)
	if _gameplay_audit_rows.size() > 8192:
		_gameplay_audit_rows.pop_front()
	if raw_airborne and not _gameplay_audit_previous_airborne:
		_gameplay_audit_air_events.append({
			"takeoff_time_s": now_s,
			"pre_250ms": _gameplay_audit_pre_support_rows.duplicate(true),
			"air_rows": [],
			"maximum_clearance_m": 0.0,
			"reentry_time_s": -1.0,
		})
	if raw_airborne and not _gameplay_audit_air_events.is_empty():
		var event: Dictionary = _gameplay_audit_air_events[-1]
		var air_rows: Array = event.air_rows
		air_rows.append(audit_row.duplicate(true))
		event.air_rows = air_rows
		event.maximum_clearance_m = maxf(float(event.maximum_clearance_m), maxf(maximum_clearance, 0.0))
		_gameplay_audit_air_events[-1] = event
	if not raw_airborne:
		if _gameplay_audit_previous_airborne and not _gameplay_audit_air_events.is_empty():
			var event: Dictionary = _gameplay_audit_air_events[-1]
			event.reentry_time_s = now_s
			_gameplay_audit_air_events[-1] = event
		_gameplay_audit_pre_support_rows.append(audit_row.duplicate(true))
		if _gameplay_audit_pre_support_rows.size() > 15:
			_gameplay_audit_pre_support_rows.pop_front()
	_gameplay_audit_previous_airborne = raw_airborne
	_gameplay_audit_previous_velocity = velocity
	_gameplay_audit_last_tick = tick


func _sum_drag_force_y(physics: JetSkiWaterPhysicsSystem) -> float:
	var total := 0.0
	for force in physics.point_forward_drag_forces:
		total += force.y
	for force in physics.point_lateral_drag_forces:
		total += force.y
	return total


func _force_balance_residual_y(physics: JetSkiWaterPhysicsSystem,
		rigid_body: JetSkiController, vertical_acceleration: float, delta: float) -> float:
	var known_force_y := physics.audit_last_total_gravity.y * rigid_body.mass
	known_force_y += physics.total_buoyancy_force_vector.y
	known_force_y += _sum_drag_force_y(physics)
	known_force_y += rigid_body.drive_system.state.propulsion_force_vector.y
	known_force_y += rigid_body.drive_system.state.coasting_steering_force_vector.y
	known_force_y += rigid_body.constant_force.y
	if delta > 0.0:
		known_force_y += rigid_body.navigation_system.state.physical_contact_impulse.y / delta
	return rigid_body.mass * vertical_acceleration - known_force_y


func begin_gameplay_audit_capture() -> void:
	reset_gameplay_audit_capture()
	_prepare_gameplay_audit_hull_samples()
	advanced_diagnostics_enabled = true
	contact_debug = true
	if ski != null:
		ski.water_physics_system.force_debug_enabled = true
		# This audit deliberately leaves diagnostics that affect takeoff classification off.
		ski.water_physics_system.diagnostics_enabled = false
	print("GAMEPLAY AUDIT CAPTURE: ON | physics behavior unchanged")


func end_gameplay_audit_capture() -> void:
	advanced_diagnostics_enabled = false
	contact_debug = false
	if ski != null:
		ski.water_physics_system.force_debug_enabled = false
	debug_mesh.clear_surfaces()
	print("GAMEPLAY AUDIT CAPTURE: OFF")


func reset_gameplay_audit_capture() -> void:
	_gameplay_audit_rows.clear()
	_gameplay_audit_rendered_hull_rows.clear()
	_gameplay_audit_pre_support_rows.clear()
	_gameplay_audit_air_events.clear()
	_waterline_trace_absolute_errors.clear()
	_gameplay_audit_previous_airborne = false
	_gameplay_audit_previous_velocity = ski.linear_velocity if ski != null else Vector3.ZERO
	_gameplay_audit_last_tick = -1
	_last_waterline_debug_tick = -1


func _prepare_gameplay_audit_hull_samples() -> void:
	_gameplay_audit_hull_local_samples.clear()
	if ski == null:
		return
	var hull_mesh := ski.get_node_or_null("VisualRoot/JetSkiVisual/HullModel/NewJetSki_Hull/hull") as MeshInstance3D
	if hull_mesh == null or hull_mesh.mesh == null:
		return
	var vertices := hull_mesh.mesh.get_faces()
	if vertices.is_empty():
		return
	var minimum_y := INF
	var maximum_y := -INF
	for vertex in vertices:
		minimum_y = minf(minimum_y, vertex.y)
		maximum_y = maxf(maximum_y, vertex.y)
	var bottom_band := maxf(0.04, (maximum_y - minimum_y) * 0.12)
	var left_point := Vector3.ZERO
	var right_point := Vector3.ZERO
	var bow_point := Vector3.ZERO
	var stern_point := Vector3.ZERO
	var lowest_point := Vector3.ZERO
	var left_x := INF
	var right_x := -INF
	var bow_z := INF
	var stern_z := -INF
	var lowest_y := INF
	for vertex in vertices:
		if vertex.y > minimum_y + bottom_band:
			continue
		if vertex.x < left_x:
			left_x = vertex.x
			left_point = vertex
		if vertex.x > right_x:
			right_x = vertex.x
			right_point = vertex
		if vertex.z < bow_z:
			bow_z = vertex.z
			bow_point = vertex
		if vertex.z > stern_z:
			stern_z = vertex.z
			stern_point = vertex
		if vertex.y < lowest_y:
			lowest_y = vertex.y
			lowest_point = vertex
	for sample in [
		{"label": "bottom_left", "point": left_point},
		{"label": "bottom_right", "point": right_point},
		{"label": "bottom_bow", "point": bow_point},
		{"label": "bottom_stern", "point": stern_point},
		{"label": "lowest_vertex", "point": lowest_point},
	]:
		var point: Vector3 = sample.point
		if not point.is_equal_approx(Vector3.ZERO) and not _gameplay_audit_hull_local_samples.any(func(existing: Dictionary) -> bool: return (existing.point as Vector3).is_equal_approx(point)):
			_gameplay_audit_hull_local_samples.append(sample)
func get_gameplay_audit_capture_summary() -> Dictionary:
	var visual_errors := PackedFloat32Array()
	var hull_clearances := PackedFloat32Array()
	var airborne_clearances := PackedFloat32Array()
	var vertical_accelerations := PackedFloat32Array()
	var airtimes := PackedFloat32Array()
	var spring_values := PackedFloat32Array()
	var damping_values := PackedFloat32Array()
	var final_values := PackedFloat32Array()
	var rendered_hull_direct := PackedFloat32Array()
	var rendered_hull_visual := PackedFloat32Array()
	var airborne_samples := 0
	var force_cap_samples := 0
	var wet_force_contacts := 0
	for row in _gameplay_audit_rows:
		vertical_accelerations.append(float(row.vertical_acceleration_mps2))
		spring_values.append(float(row.spring_total_n))
		damping_values.append(float(row.water_relative_damping_total_n))
		final_values.append(float(row.final_contact_support_total_n))
		if bool(row.raw_airborne): airborne_samples += 1
		for contact in row.contacts:
			visual_errors.append(absf(float(contact.visual_minus_direct_m)))
			hull_clearances.append(float(contact.hull_minus_direct_m))
			if bool(row.raw_airborne): airborne_clearances.append(maxf(float(contact.hull_minus_direct_m), 0.0))
			if bool(contact.force_capped): force_cap_samples += 1
			if bool(contact.wet): wet_force_contacts += 1
	for event in _gameplay_audit_air_events:
		if float(event.reentry_time_s) >= float(event.takeoff_time_s):
			airtimes.append(float(event.reentry_time_s) - float(event.takeoff_time_s))
	for hull_row in _gameplay_audit_rendered_hull_rows:
		rendered_hull_direct.append(float(hull_row.hull_minus_direct_m))
		rendered_hull_visual.append(float(hull_row.hull_minus_visual_equivalent_m))
	var fps := Engine.get_frames_per_second()
	var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	var events := _gameplay_audit_air_events.duplicate(true)
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.maximum_clearance_m) > float(b.maximum_clearance_m))
	if events.size() > 3: events.resize(3)
	return {
		"rows": _gameplay_audit_rows.size(),
		"capture_seconds": float(_gameplay_audit_rows[-1].time_s - _gameplay_audit_rows[0].time_s) if _gameplay_audit_rows.size() > 1 else 0.0,
		"phase": {"wind_speed_mps": get_node("Production/Ocean").get("wind_speed_mps"), "wave_speed_multiplier": get_node("Production/Ocean").get("wave_speed_multiplier")},
		"visual_minus_direct_abs_cm": _waterline_error_metrics_from_values(visual_errors),
		"hull_minus_direct_signed_m": _float_metrics(hull_clearances),
		"positive_hull_clearance_m": _float_metrics(_positive_values(hull_clearances)),
		"rendered_hull_sample_count": _gameplay_audit_rendered_hull_rows.size(),
		"rendered_hull_minus_direct_m": _float_metrics(rendered_hull_direct),
		"rendered_hull_minus_visual_equivalent_m": _float_metrics(rendered_hull_visual),
		"airborne_clearance_m": _float_metrics(airborne_clearances),
		"airborne_transitions": _gameplay_audit_air_events.size(),
		"airborne_percent": 100.0 * float(airborne_samples) / maxf(float(_gameplay_audit_rows.size()), 1.0),
		"airtime_s": _float_metrics(airtimes),
		"vertical_acceleration_mps2": _float_metrics(vertical_accelerations),
		"spring_force_total_n": _float_metrics(spring_values),
		"water_relative_damping_total_n": _float_metrics(damping_values),
		"final_contact_support_total_n": _float_metrics(final_values),
		"force_cap_contact_samples": force_cap_samples,
		"wet_force_contact_samples": wet_force_contacts,
		"latest_fps": fps,
		"latest_physics_ms": physics_ms,
		"representative_events": events,
	}


func get_gameplay_audit_takeoff_windows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event_index in _gameplay_audit_air_events.size():
		var event: Dictionary = _gameplay_audit_air_events[event_index]
		var rows: Array[Dictionary] = []
		for row in event.pre_250ms:
			var contacts: Array[Dictionary] = []
			for contact in row.contacts:
				contacts.append({
					"contact": contact.contact,
					"wet": contact.wet,
					"relative_contact_vy_mps": contact.relative_contact_vy_mps,
					"spring_n": contact.spring_n,
					"water_relative_damping_n": contact.water_relative_damping_n,
					"final_support_n": contact.final_support_n,
					"force_capped": contact.force_capped,
				})
			rows.append({
				"time_to_takeoff_s": float(row.time_s) - float(event.takeoff_time_s),
				"vertical_velocity_mps": row.vertical_velocity_mps,
				"vertical_acceleration_mps2": row.vertical_acceleration_mps2,
				"pitch_deg": row.pitch_deg,
				"roll_deg": row.roll_deg,
				"raw_airborne": row.raw_airborne,
				"wet_contacts": row.wet_contacts,
				"supported_contacts": row.supported_contacts,
				"spring_total_n": row.spring_total_n,
				"water_relative_damping_total_n": row.water_relative_damping_total_n,
				"final_contact_support_total_n": row.final_contact_support_total_n,
				"contacts": contacts,
			})
		result.append({
			"event_index": event_index,
			"takeoff_time_s": event.takeoff_time_s,
			"reentry_time_s": event.reentry_time_s,
			"airtime_s": float(event.reentry_time_s) - float(event.takeoff_time_s) if float(event.reentry_time_s) >= float(event.takeoff_time_s) else -1.0,
			"maximum_clearance_m": event.maximum_clearance_m,
			"pre_250ms": rows,
		})
	return result


func _positive_values(values: PackedFloat32Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	for value in values: result.append(maxf(value, 0.0))
	return result


func validate_waterline_grid() -> Dictionary:
	var provider := water as CpuProvider
	if not ready_to_drive or provider == null or not provider.field_ready:
		return {"error": "Gameplay water provider is not ready"}
	var positions := PackedVector3Array()
	var center := ski.global_position
	for z_index in 15:
		for x_index in 15:
			positions.append(Vector3(center.x + (float(x_index) - 7.0) * 1.4, 0.0,
				center.z + (float(z_index) - 7.0) * 1.4))
	var contact_start := positions.size()
	for point_name in ski.water_physics_system.POINT_NAMES:
		positions.append(ski.get_node("BuoyancyPoints/" + point_name).global_position)
	var report: Dictionary = (water as CpuProvider).validate_direct_vs_rendered_surface(positions)
	var rows: Array = report.get("rows", [])
	return {
		"visual_profile": _visual_fft_mode_name(),
		"wind_speed_mps": get_node("Production/Ocean").get("wind_speed_mps"),
		"wave_speed_multiplier": get_node("Production/Ocean").get("wave_speed_multiplier"),
		"wave_time_s": report.get("wave_time_s", -1.0),
		"horizontal_displacement_multipliers": report.get("horizontal_displacement_multipliers", Vector3.ONE),
		"dense_grid": _waterline_error_metrics(rows, 0, contact_start),
		"jetski_contacts": _waterline_error_metrics(rows, contact_start, positions.size() - contact_start),
		"invalid_samples": int((water as CpuProvider).get("invalid_sample_count")),
		"local_surface_build": report.get("local_patch", {}),
	}


func validate_interpolated_contact_waterline() -> Dictionary:
	var provider: CpuProvider = water as CpuProvider
	if not ready_to_drive or provider == null or not provider.field_ready:
		return {"error": "Gameplay water provider is not ready"}
	var interpolated_transform := ski.get_global_transform_interpolated()
	var positions := PackedVector3Array()
	var hull_y := PackedFloat32Array()
	for point_name in ski.water_physics_system.POINT_NAMES:
		var point: Node3D = ski.get_node("BuoyancyPoints/" + String(point_name))
		var local_point := ski.to_local(point.global_position)
		var rendered_point := interpolated_transform * local_point
		positions.append(rendered_point)
		hull_y.append(rendered_point.y)
	var report: Dictionary = provider.validate_direct_vs_rendered_surface(positions)
	var rows: Array = report.get("rows", [])
	var waterline_signed := PackedFloat32Array()
	for index in mini(rows.size(), hull_y.size()):
		var row: Dictionary = rows[index]
		if bool(row.get("valid", false)):
			waterline_signed.append(hull_y[index] - float(row.get("rendered_height_m", hull_y[index])))
	var errors := PackedFloat32Array()
	for row in rows:
		if bool(row.get("valid", false)):
			errors.append(float(row.get("absolute_error_m", 0.0)))
	var timing: Dictionary = get_node("Production/Ocean/OpenOceanFFT").call("get_physics_wave_time_state")
	return {
		"contact_spatial_direct_vs_local_surface_cm": _waterline_error_metrics_from_values(errors),
		"hull_to_local_surface_signed_m": _float_metrics(waterline_signed),
		"interpolated_contact_world_positions": positions,
		"contact_count": positions.size(),
		"query_mode": provider.query_mode,
		"field_time_s": provider.current_field_time,
		"expected_visual_time_s": lerpf(float(timing.get("previous_physics_wave_time", 0.0)),
			float(timing.get("current_physics_wave_time", 0.0)),
			float(timing.get("render_interpolation_fraction", 1.0))),
		"local_surface_build": report.get("local_patch", {}),
	}


func get_waterline_contact_trace_summary() -> Dictionary:
	return _waterline_error_metrics_from_values(_waterline_trace_absolute_errors)


func get_physics_timeline_audit() -> Dictionary:
	var fft: Node = get_node("Production/Ocean/OpenOceanFFT")
	var timing: Dictionary = fft.call("get_physics_wave_time_state")
	var previous_time := float(timing.get("previous_physics_wave_time", 0.0))
	var current_time := float(timing.get("current_physics_wave_time", 0.0))
	var alpha := float(timing.get("render_interpolation_fraction", 1.0))
	var interpolated_time := lerpf(previous_time, current_time, alpha)
	var provider: CpuProvider = water as CpuProvider
	var interpolated_transform: Transform3D = ski.get_global_transform_interpolated()
	return {
		"physics_frame": Engine.get_physics_frames(),
		"timing": timing,
		"expected_interpolated_time": interpolated_time,
		"visual_clock_residual_ms": absf(float(timing.get("visual_wave_time", interpolated_time)) - interpolated_time) * 1000.0,
		"cpu_field_time": provider.current_field_time if provider != null else -1.0,
		"cpu_field_tick": provider.last_build_tick if provider != null else -1,
		"cpu_minus_current_physics_ms": (provider.current_field_time - current_time) * 1000.0 if provider != null else 0.0,
		"cpu_field_builds_this_tick": provider.field_builds_this_physics_tick if provider != null else -1,
		"visual_profile": _visual_fft_mode_name(),
		"query_mode": provider.query_mode if provider != null else -1,
		"drive_mode": ski.get_drive_mode_name(),
		"normal_influence": ski.water_physics_system.buoyancy_normal_influence,
		"takeoff_cleaner": ski.water_physics_system.takeoff_assist_enabled,
		"interpolated_body_origin": interpolated_transform.origin,
		"physics_body_origin": ski.global_position,
	}


func start_physics_timeline_capture(duration_s := 2.0) -> bool:
	_timeline_capture_rows.clear()
	_timeline_contact_surface_errors.clear()
	_timeline_contact_sample_accumulator = 0.0
	_timeline_capture_report.clear()
	_timeline_capture_remaining_s = maxf(duration_s, 0.25)
	_timeline_capture_enabled = true
	return true


func get_physics_timeline_capture_report() -> Dictionary:
	return _timeline_capture_report.duplicate(true)


func _capture_physics_timeline_frame(delta: float, interpolated_transform: Transform3D) -> void:
	if not _timeline_capture_enabled:
		return
	if _timeline_capture_deferred_pending:
		return
	_timeline_capture_deferred_pending = true
	call_deferred("_capture_physics_timeline_frame_deferred", delta, interpolated_transform)


func _capture_physics_timeline_frame_deferred(delta: float, interpolated_transform: Transform3D) -> void:
	_timeline_capture_deferred_pending = false
	if not _timeline_capture_enabled:
		return
	_timeline_contact_sample_accumulator += maxf(delta, 0.0)
	if _timeline_contact_sample_accumulator >= 1.0 / 30.0:
		_timeline_contact_sample_accumulator = fposmod(_timeline_contact_sample_accumulator, 1.0 / 30.0)
		_capture_interpolated_contact_spatial_error(interpolated_transform)
	var audit := get_physics_timeline_audit()
	var timing: Dictionary = audit.get("timing", {})
	_timeline_capture_rows.append({
		"physics_frame": audit.get("physics_frame", -1),
		"previous_time": timing.get("previous_physics_wave_time", -1.0),
		"current_time": timing.get("current_physics_wave_time", -1.0),
		"alpha": timing.get("render_interpolation_fraction", 1.0),
		"expected_visual_time": audit.get("expected_interpolated_time", -1.0),
		"dispatched_visual_time": timing.get("visual_wave_time", -1.0),
		"visual_clock_residual_ms": audit.get("visual_clock_residual_ms", -1.0),
		"cpu_field_time": audit.get("cpu_field_time", -1.0),
		"cpu_minus_current_physics_ms": audit.get("cpu_minus_current_physics_ms", 0.0),
		"cpu_field_tick": audit.get("cpu_field_tick", -1),
		"fps": Engine.get_frames_per_second(),
		"physics_time_ms": float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0,
		"body_render_origin": interpolated_transform.origin,
	})
	_timeline_capture_remaining_s -= maxf(delta, 0.0)
	if _timeline_capture_remaining_s <= 0.0:
		_timeline_capture_enabled = false
		_timeline_capture_report = _summarize_timeline_capture(_timeline_capture_rows)


func _summarize_timeline_capture(rows: Array[Dictionary]) -> Dictionary:
	var residuals := PackedFloat32Array()
	var cpu_deltas := PackedFloat32Array()
	var fps_values := PackedFloat32Array()
	var physics_values := PackedFloat32Array()
	var alpha_values := PackedFloat32Array()
	var physics_steps := PackedFloat32Array()
	var field_tick_mismatches := 0
	for row in rows:
		residuals.append(float(row.get("visual_clock_residual_ms", -1.0)))
		cpu_deltas.append(absf(float(row.get("cpu_minus_current_physics_ms", 0.0))))
		fps_values.append(float(row.get("fps", 0.0)))
		physics_values.append(float(row.get("physics_time_ms", 0.0)))
		alpha_values.append(float(row.get("alpha", 1.0)))
		physics_steps.append(float(row.get("current_time", 0.0)) - float(row.get("previous_time", 0.0)))
		if int(row.get("cpu_field_tick", -1)) != int(row.get("physics_frame", -2)):
			field_tick_mismatches += 1
	return {
		"frame_count": rows.size(),
		"first": rows[0] if not rows.is_empty() else {},
		"last": rows[-1] if not rows.is_empty() else {},
		"visual_clock_residual_ms": _float_metrics(residuals),
		"moving_interpolated_contact_spatial_error_cm": _waterline_error_metrics_from_values(_timeline_contact_surface_errors),
		"cpu_field_minus_current_physics_ms_abs": _float_metrics(cpu_deltas),
		"fps": _float_metrics(fps_values),
		"physics_time_ms": _float_metrics(physics_values),
		"render_alpha": _float_metrics(alpha_values),
		"physics_wave_step_s": _float_metrics(physics_steps),
		"cpu_field_tick_mismatches": field_tick_mismatches,
		"visual_profile": _visual_fft_mode_name(),
		"wind_speed_mps": get_node("Production/Ocean").get("wind_speed_mps"),
		"wave_speed_multiplier": get_node("Production/Ocean").get("wave_speed_multiplier"),
		"query_mode": (water as CpuProvider).query_mode if water is CpuProvider else -1,
		"cpu_lite_provider": (water as CpuProvider).call("get_provider_profile") if water is CpuProvider else {},
	}


func _capture_interpolated_contact_spatial_error(interpolated_transform: Transform3D) -> void:
	var provider: CpuProvider = water as CpuProvider
	if provider == null or not provider.field_ready:
		return
	var positions := PackedVector3Array()
	for point_name in ski.water_physics_system.POINT_NAMES:
		var point: Node3D = ski.get_node("BuoyancyPoints/" + String(point_name))
		positions.append(interpolated_transform * ski.to_local(point.global_position))
	var report: Dictionary = provider.validate_direct_vs_rendered_surface(positions)
	var rows: Array = report.get("rows", [])
	for row in rows:
		if bool(row.get("valid", false)):
			_timeline_contact_surface_errors.append(float(row.get("absolute_error_m", 0.0)))


func _float_metrics(values: PackedFloat32Array) -> Dictionary:
	if values.is_empty(): return {"count": 0, "mean": -1.0, "p95": -1.0, "max": -1.0}
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	for value in values: total += value
	var index := clampi(int(ceil(float(ordered.size()) * 0.95)) - 1, 0, ordered.size() - 1)
	return {"count": values.size(), "mean": total / float(values.size()), "p95": ordered[index], "max": ordered[-1]}


func _waterline_error_metrics(rows: Array, start_index: int, count: int) -> Dictionary:
	var errors := PackedFloat32Array()
	var valid_count := 0
	for index in range(start_index, mini(start_index + count, rows.size())):
		var row: Dictionary = rows[index]
		if not bool(row.get("valid", false)):
			continue
		valid_count += 1
		errors.append(float(row.get("absolute_error_m", 0.0)))
	var result := _waterline_error_metrics_from_values(errors)
	result["valid_samples"] = valid_count
	result["requested_samples"] = count
	return result


func _waterline_error_metrics_from_values(values: PackedFloat32Array) -> Dictionary:
	if values.is_empty():
		return {"valid_samples": 0, "mean_cm": -1.0, "p95_cm": -1.0, "max_cm": -1.0}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in values:
		total += value
	var p95_index := clampi(int(ceil(float(sorted.size()) * 0.95)) - 1, 0, sorted.size() - 1)
	return {
		"valid_samples": values.size(),
		"mean_cm": total / float(values.size()) * 100.0,
		"p95_cm": float(sorted[p95_index]) * 100.0,
		"max_cm": float(sorted[-1]) * 100.0,
	}


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
	return {"mean": total / float(ordered.size()), "p95": ordered[p95_index]}

func _on_camera_settings_changed(action: String) -> void:
	# Development HUD only; the vehicle rig works without this listener.
	camera_feedback = "CAMERA %s | %s | distance %.1f m | height %.1f m" % [action, camera_rig.call("get_preset_name"), camera_rig.get("camera_distance_m"), camera_rig.get("camera_height_m")]
	camera_feedback_timer = 2.5

func _physics_mode_name() -> String:
	return "WATER RACE" if physics_mode == PhysicsMode.WATER_RACE else "CURRENT"


func _visual_fft_mode_name() -> String:
	var ocean := get_node_or_null("Production/Ocean/OpenOceanFFT")
	if ocean != null:
		return str(ocean.get("_visual_horizontal_displacement_profile"))
	return "PHYSICS_ALIGNED"


func _apply_requested_visual_water_profile() -> void:
	var open_ocean := get_node_or_null("Production/Ocean/OpenOceanFFT")
	if open_ocean == null:
		return
	var current_profile := StringName(str(open_ocean.get("_visual_horizontal_displacement_profile")))
	var current_multipliers: Vector3 = open_ocean.get("_visual_horizontal_displacement_multipliers")
	if current_profile == _requested_visual_water_profile and current_multipliers.is_equal_approx(_requested_visual_water_multipliers):
		return
	if _requested_visual_water_profile == &"PHYSICS_ALIGNED_CUSTOM":
		open_ocean.call(&"set_visual_horizontal_displacement_multipliers", _requested_visual_water_multipliers)
	else:
		open_ocean.call(&"set_visual_horizontal_displacement_profile", _requested_visual_water_profile)


func _set_visual_water_profile(profile: StringName) -> void:
	_requested_visual_water_profile = profile
	_requested_visual_water_multipliers = Vector3.ONE if profile == &"FULL_CHOPPY_DEBUG" else Vector3(0.0, 0.0, 1.0)
	_apply_requested_visual_water_profile()


func _set_visual_water_multipliers(multipliers: Vector3) -> void:
	_requested_visual_water_profile = &"PHYSICS_ALIGNED_CUSTOM"
	_requested_visual_water_multipliers = Vector3(
		clampf(multipliers.x, 0.0, 1.0),
		clampf(multipliers.y, 0.0, 1.0),
		clampf(multipliers.z, 0.0, 1.0)
	)
	_apply_requested_visual_water_profile()


func _set_physics_mode(mode: PhysicsMode) -> void:
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

func _set_water_response_profile(softer: bool) -> void:
	if ski == null: return
	softer_water_profile_enabled = softer
	var physics := ski.water_physics_system
	if softer:
		physics.buoyancy_normal_influence = 0.50
		physics.use_raw_buoyancy_direction = false
		physics.buoyancy_strength_per_point = ski.buoyancy_strength_per_point
		physics.buoyancy_damping_per_point = ski.buoyancy_damping_per_point
	else:
		physics.buoyancy_normal_influence = 1.0
		physics.use_raw_buoyancy_direction = true
		physics.buoyancy_strength_per_point = 5500.0
		physics.buoyancy_damping_per_point = 2500.0
	print("WATER RESPONSE: %s | normal=%.2f K=%.0f C=%.1f" % [
		"SOFTER" if softer else "RAW", physics.buoyancy_normal_influence,
		physics.buoyancy_strength_per_point, physics.buoyancy_damping_per_point])

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
	if ready_to_drive and advanced_diagnostics_enabled and event.keycode == KEY_F5:
		_set_water_response_profile(not softer_water_profile_enabled)
	if ready_to_drive and advanced_diagnostics_enabled and event.keycode == KEY_F9:
		start_feel_4b_validation()
	if ready_to_drive and advanced_diagnostics_enabled and event.keycode == KEY_F12:
		start_feel_5_validation()
	if ready_to_drive and event.keycode == KEY_F11:
		ski.water_physics_system.set_anti_hop_enabled(not ski.water_physics_system.anti_hop_enabled)
		print("ANTI-HOP: " + ("ON" if ski.water_physics_system.anti_hop_enabled else "OFF"))
	if event.keycode == KEY_F3 and advanced_diagnostics_enabled:
		contact_debug = not contact_debug
		if contact_debug:
			_waterline_trace_absolute_errors.clear()
	if ready_to_drive and event.keycode == KEY_F2:
		var next_profile: StringName = &"FULL_CHOPPY_DEBUG" if _visual_fft_mode_name() != "FULL_CHOPPY_DEBUG" else &"PHYSICS_ALIGNED"
		_set_visual_water_profile(next_profile)
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

func start_feel_5_validation(phase_1 := -1.0, phase_2 := -1.0) -> void:
	if not ready_to_drive or alignment_validation_running: return
	alignment_validation_running = true
	var validator := preload("res://validation/physics/jetski_feel_5_validation.gd").new()
	add_child(validator)
	validator.run(self, phase_1, phase_2)


func start_feel_6_validation(phase := -1.0) -> void:
	if not ready_to_drive or alignment_validation_running: return
	alignment_validation_running = true
	var validator := preload("res://validation/physics/jetski_feel_6_validation.gd").new()
	add_child(validator)
	validator.run(self, phase)


func start_gameplay_baseline_validation() -> void:
	if not ready_to_drive or alignment_validation_running: return
	alignment_validation_running = true
	var validator := preload("res://validation/physics/phys_gameplay_baseline_validation.gd").new()
	add_child(validator)
	validator.run(self)

func start_feel_4_validation() -> void:
	if not ready_to_drive: return
	var runner := Feel4Validation.new()
	add_child(runner)
	runner.run(self)

func start_feel_4b_validation(wave_speed := -1.0, verify_selected := false) -> void:
	if not ready_to_drive: return
	var runner := Feel4BValidation.new()
	add_child(runner)
	runner.run(self, wave_speed, verify_selected)


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
