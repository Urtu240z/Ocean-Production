extends "res://validation/physics/native_performance_2_replay.gd"
const ParityProvider = preload("res://validation/fixtures/contact_pipeline_3_parity_provider.gd")
var raw_query_modes := PackedInt32Array([1,1,1])

func _initialize() -> void:
	Engine.max_fps = 0
	super()

func create_profile_scene(scene_path: String) -> Node:
	var instance := super(scene_path)
	var host: Ocean = instance.get_node("JetSkiOcean/Production/Ocean")
	var old: Node = host.get("_cpu_water_provider")
	host.remove_child(old); old.free()
	var provider := ParityProvider.new()
	provider.name = "PhysicalWater"
	host.add_child(provider)
	host.set("_cpu_water_provider",provider)
	return instance

func raw_field(native_field: Object) -> PackedFloat64Array:
	if native_field == null: return PackedFloat64Array()
	var values: PackedFloat64Array = native_field.sample_dynamic_lite_contacts(PackedVector3Array([Vector3(17.3,0,-6.7)]),0.0,raw_query_modes)
	return values.slice(1) if not values.is_empty() else values

func end_tick() -> void:
	var before := replay_rows.size()
	super()
	if replay_rows.size() == before: return
	var provider: ParityProvider = world.water
	var fields := [raw_field(provider.native)]
	for state in runtime.states: fields.append(raw_field(state.native) if state != null else PackedFloat64Array())
	replay_rows[-1]["cp3"] = {"contact_calls_hits_misses_invalid":provider.contact_counts.duplicate(),
		"native_query_positions":provider.native_query_positions_this_physics_tick,
		"native_batches":provider.native_query_batches_this_physics_tick,"raw_fields":fields}
	provider.contact_counts.fill(0)
	var physical: Dictionary = replay_rows[-1].duplicate(true)
	physical.erase("hull_backend_diagnostics"); physical.erase("physical_binary_sha256")
	physical_hasher.start(HashingContext.HASH_SHA256)
	physical_hasher.update(var_to_bytes(physical))
	replay_rows[-1]["physical_binary_sha256"] = physical_hasher.finish().hex_encode()
