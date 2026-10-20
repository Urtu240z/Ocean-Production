extends "res://validation/physics/async_fft_deterministic_scene.gd"
const ReferenceProvider = preload("res://validation/physics/perf_contact_reference_provider.gd")
var pending_scale := 1.0
var pending_horizontal := 1.0

func create_profile_scene(scene_path: String) -> Node:
	var instance := super(scene_path)
	var host: Ocean = instance.get_node("JetSkiOcean/Production/Ocean")
	var provider: CpuFftWaterProvider = ReferenceProvider.new() if option("--contact-variant","A") == "A" else CpuFftWaterProvider.new()
	provider.name = "PhysicalWater"
	host.add_child(provider)
	host.set("_cpu_water_provider",provider)
	# The current saved scene has no active first footprint. Guarantee overlap
	# in this parity fixture alone, without changing the timed A/B scene.
	var area := OceanWaveArea3D.new()
	area.name = "ContactParityArea0"
	area.ocean = host
	area.sea_state = 0
	area.blend_distance_m = 40.0
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(180,60,400)
	shape_node.shape = box
	area.add_child(shape_node)
	area.position = Vector3(-5,0,-180)
	instance.add_child(area)
	return instance

func begin_tick() -> void:
	if not recording: return
	var tick := Engine.get_physics_frames()-replay_start_tick
	if tick == 120: ocean.wave_speed_multiplier = 0.0
	if tick == 132: ocean.wave_speed_multiplier = 1.5
	if tick in [180,420]:
		# Hot spatial configuration, applied only to these private replay nodes.
		ocean.ocean_scale = 1.15 if tick == 180 else 1.0
		ocean.clipmap_geometry_scale = 1.1 if tick == 180 else 1.0
	if tick == 240:
		for body in replay_bodies:
			body.reset_vehicle(&"perf_contact_respawn")
		world.water.invalidate_contacts()
	if tick == 480:
		world.water.set_query_mode(CpuFftWaterProvider.QueryMode.LOCAL_SURFACE)
	if tick == 540:
		world.water.set_query_mode(CpuFftWaterProvider.QueryMode.DIRECT)
	if tick == 600:
		world.water.invalidate_contacts()
	super()

func end_tick() -> void:
	var before := replay_rows.size()
	super()
	if replay_rows.size() == before: return
	var weights := []
	for entry in runtime.entries: weights.append(runtime.weight(entry,replay_bodies[0].global_position))
	replay_rows[-1]["area_weights"] = weights
	for i in replay_bodies.size():
		var body: RigidBody3D = replay_bodies[i]
		var physics: Node = body.get("water_physics_system")
		var row: Dictionary = replay_rows[-1].bodies[i]
		row["surface_positions"] = vectors(physics.get("_point_water_surface_positions"))
		row["contact_positions"] = vectors(physics.get("_point_world_positions"))
		row["point_water_velocities"] = vectors(physics.get("_point_water_velocities"))
		row["forward_drag_vectors"] = vectors(physics.get_point_forward_drag_forces())
		row["lateral_drag_vectors"] = vectors(physics.get_point_lateral_drag_forces())
		for property in ["hull_arcade_yaw_torque","landing_preserved_torque","heavy_wave_torque_correction","heavy_upright_torque","total_buoyancy_torque","_last_applied_buoyancy_torque","_last_wet_angular_damping_torque"]:
			row[property] = vector(physics.get(property))
		var moments := PackedVector3Array()
		for j in physics.point_buoyancy_force_vectors.size():
			var lever: Vector3 = physics.get_point_world_position(j)-body.global_position
			moments.append(lever.cross(physics.point_buoyancy_force_vectors[j]))
		row["buoyancy_force_moments"] = vectors(moments)
