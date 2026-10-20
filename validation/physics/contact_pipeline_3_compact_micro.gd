extends SceneTree
const Candidate = preload("res://validation/fixtures/contact_pipeline_3_compact_water.gd")
const BodyState = preload("res://validation/fixtures/contact_pipeline_3_micro_state.gd")
const Provider = preload("res://validation/fixtures/contact_pipeline_3_micro_provider.gd")
const Host = preload("res://validation/fixtures/contact_pipeline_3_micro_ocean.gd")
const LocalState = preload("res://addons/ocean/areas/ocean_local_fft_state.gd")
var scene: Node
var host: Host
var field: Object
var checks := 0
var mismatches: Array = []

func _initialize() -> void: call_deferred("run")
func option(name: String, fallback: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(name+"="): return arg.trim_prefix(name+"=")
	return fallback

func make_fields() -> void:
	host = Host.new()
	host.wave_profile = load("res://addons/ocean/presets/ocean_production/wave_profile.tres")
	var main_state := LocalState.new()
	main_state.configure_physics_only(host.local_sea_state_1,host)
	field = main_state.native
	if field == null or not field.build_dynamic_physics_lite(0.5,PackedInt32Array([128,128,128])):
		push_error("Invalid fixed micro field"); host.free(); scene.free(); quit(1); return
	var runtime: RefCounted = host.fixed_runtime
	runtime.time_s = 0.5
	for slot in 2:
		var local := LocalState.new()
		var settings: Resource = host.local_sea_state_1 if slot == 0 else host.local_sea_state_2
		local.configure_physics_only(settings,host)
		local._native_batch_supported = true
		local.time_s = 0.5
		local._last_clock = 0.5
		local._field_time = 0.5
		assert(local.native.build_dynamic_physics_lite(0.5,PackedInt32Array([128,128,128])))
		runtime.states[slot] = local
		runtime.entries.append({"inverse":Transform3D(Basis.IDENTITY,Vector3(slot*2,0,slot)).affine_inverse(),
			"shape":Vector4(4+slot,20,4+slot,0),"blend":Vector4(8,1,1,0),"meta":Vector4(slot,1,0.6,10)})
	assert(host.fixed_waves.advance(0,1.0/60.0,[],host.get_hull_foam_settings()))
	var packets := PackedFloat64Array([0,0,1,0,0.1,2,2,4,10,5,-0.1,0.75,4.5,0,0.28,-100,0.65,0,
		2,1,0,1,0.2,3,3,5,10,6,-0.2,0.75,4.5,0,0.28,-100,0.65,0])
	assert(host.fixed_waves._native.publish_hull_waves(packets,PackedInt64Array([100,101]),host.fixed_waves.clock))
	host.fixed_tsunami.center_radius = Vector4(0,0,10,1.5)
	host.fixed_tsunami.motion = Vector4(18,0,0.25,0)

func make_fleet(compact: bool) -> Dictionary:
	var provider := Provider.new()
	provider.ocean_root = host
	provider.native = field
	provider.backend = CpuFftWaterProvider.Backend.CPU_LITE_B
	provider.query_mode = CpuFftWaterProvider.QueryMode.DIRECT
	provider.water_race_normal_enabled = true
	provider.wave_drift_enabled = true
	provider.field_ready = true
	provider.current_field_time = 0.5
	provider.last_build_tick = Engine.get_physics_frames()
	var bodies := []
	for i in 6:
		var body := RigidBody3D.new()
		var physics: JetSkiWaterPhysicsSystem = Candidate.new() if compact else JetSkiWaterPhysicsSystem.new()
		body.add_child(physics)
		physics.configure(scene.get_node("JetSki/BuoyancyPoints"))
		physics.configure_hull_buoyancy(scene.get_node("JetSki/CollisionShape3D"))
		physics.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
		physics.hull_arcade_enabled = true
		physics.water_race_mode = true
		var points: PackedVector3Array = physics.hull_buoyancy.local_points.duplicate()
		points.append(Vector3(0,-0.2,1))
		bodies.append({"body":body,"physics":physics,"state":BodyState.new(),
			"context":provider.create_consumer_context(),"points":points,"propulsion":WaterSample3D.new()})
	return {"provider":provider,"bodies":bodies}

func tick(fleet: Dictionary, iteration: int, record: bool) -> Array:
	var provider: Provider = fleet.provider
	var result := []
	for i in 6:
		var member: Dictionary = fleet.bodies[i]
		var state: BodyState = member.state
		var mode := posmod(iteration,4)
		state.body_transform = Transform3D(Basis.from_euler(Vector3(mode*0.15,0,mode*0.08)),Vector3(i*2,[-0.3,0.1,0.8,2.0][mode],i*0.3))
		state.recording = record
		state.reset_forces()
		provider.select_consumer(member.context)
		provider.publish_contacts(state.body_transform,member.points)
		member.physics.step(state,provider,1.0)
		provider.sample_propulsion_water(state.body_transform*member.points[12],member.propulsion)
		if record:
			var physics: JetSkiWaterPhysicsSystem = member.physics
			result.append([state.sum_force,state.sum_torque,state.force_order.duplicate(true),
				physics.total_buoyancy_force_vector,physics.total_buoyancy_torque,
				physics.get_point_forward_drag_forces(),physics.get_point_lateral_drag_forces(),
				physics.get_buoyancy_point_normal_force_vectors(),physics.get_buoyancy_point_water_normals(),
				physics.hull_buoyancy._native_values,physics.get_buoyancy_point_depths(),
				provider._local_contacts.history,provider._contact_cache_cursor,
				member.propulsion.normal,member.propulsion.velocity,member.propulsion.signed_depth])
	return result

func summarize(values: PackedInt64Array) -> Dictionary:
	var ordered := values.duplicate(); ordered.sort()
	var total := 0
	for value in ordered: total += value
	return {"n":ordered.size(),"mean_ms":float(total)/ordered.size()/1000,
		"p50_ms":ordered[int(ordered.size()*0.5)]/1000.0,"p95_ms":ordered[int(ordered.size()*0.95)]/1000.0,
		"p99_ms":ordered[int(ordered.size()*0.99)]/1000.0}

func run() -> void:
	scene = load("res://validation/hull_wave_physics_playground.tscn").instantiate()
	make_fields()
	if field == null or not field.get_dynamic_lite_profile().get("valid",false): return
	var a := make_fleet(false)
	var b := make_fleet(true)
	var nonzero_force_steps := 0
	for iteration in 32:
		checks += 1
		var original := tick(a,iteration,true)
		var compact := tick(b,iteration,true)
		if original.any(func(row): return row[0].length_squared() > 0.0): nonzero_force_steps += 1
		if var_to_bytes(original) != var_to_bytes(compact):
			mismatches.append(iteration)
	assert(nonzero_force_steps > 0,"Do not accept a vacuous all-dry force comparison")
	for fleet in [a,b]:
		for member in fleet.bodies:
			assert(member.physics.hull_buoyancy.native_batch_count == 32,"Every consumer must run the real native geometry")
	var blocks := []
	for profiling in [false,true]:
		for label in ["A","B","B","A"]:
			var fleet: Dictionary = a if label == "A" else b
			fleet.provider._perf2_supported = profiling
			var times := PackedInt64Array()
			for iteration in range(-32,int(option("--iterations","1000"))):
				var started := Time.get_ticks_usec()
				tick(fleet,iteration,false)
				if iteration >= 0: times.append(Time.get_ticks_usec()-started)
			blocks.append({"variant":label,"profiling":profiling,"metrics":summarize(times)})
	var report := {"checks":checks,"nonzero_force_steps":nonzero_force_steps,"binary_mismatch_iterations":mismatches,"blocks":blocks,
		"scope":"six consumers: real FFT queries, 2 local areas, hull waves, tsunami, drift, history/publication, cached reads, native geometry, decode, full HULL force/drag calculations and deterministic force consumption; fields fixed; metadata freshness, worker builds and real Jolt integration excluded",
		"removed_per_tick":{"dictionaries":72,"dictionary_property_reads":216,"gdscript_adapter_calls":72},
		"candidate_production_active":false}
	DirAccess.make_dir_recursive_absolute("res://temp/contact_pipeline_3")
	var file := FileAccess.open(option("--output","res://temp/contact_pipeline_3/compact_micro.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report)); file.close()
	for fleet in [a,b]:
		for member in fleet.bodies:
			member.body.free()
			member.state.free()
		fleet.provider.free()
	host.free(); scene.free()
	print("CP3_COMPACT_MICRO checks=",checks," mismatch=",mismatches.size())
	quit(0 if mismatches.is_empty() else 1)
