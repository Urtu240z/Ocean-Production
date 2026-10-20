extends SceneTree
const Reference = preload("res://validation/physics/perf_contact_reference_provider.gd")
var failures: Array[String] = []
var comparisons := 0
class Source extends Node3D:
	var reads := 0
	var state := {}
	func get_physics_source_state() -> Dictionary:
		reads += 1
		return state.duplicate(true)

func _initialize() -> void: call_deferred("run")

func fields(sample: WaterSample3D) -> Array:
	return [sample.valid,sample.surface_position,sample.normal,sample.velocity,
		sample.signed_depth,sample.sample_physics_tick,sample.sample_time_seconds]

func check(ok: bool, label: String) -> void:
	comparisons += 1
	if not ok: failures.append(label)

func prepare(provider: CpuFftWaterProvider, source: Source, fft_node: Node) -> void:
	provider.ocean_root = source
	provider.fft = fft_node
	provider.native = RefCounted.new()
	provider.field_ready = true
	provider.current_field_time = 3.0
	provider.set("_synced_fft_instance_id",fft_node.get_instance_id())
	provider.set("_synced_ocean_revision",2)
	provider.set("_last_fft_spectrum_generation",7)
	provider.set("_synced_ocean_space_revision",4)
	provider.water_sync_status = "OK"
	source.state = {"status":"OK","fft_instance_id":fft_node.get_instance_id(),"revision":2,
		"spectrum_version":7,"sea_level":0.0,"wave_time":3.0,
		"ocean_space":{"revision":4,"ocean_scale":1.0,"clipmap_geometry_scale":1.0}}
	var sample := WaterSample3D.new()
	sample.valid = true
	sample.surface_position = Vector3(1,2.125,3)
	sample.normal = Vector3(-0.125,0.875,0.25)
	sample.velocity = Vector3(0.25,-0.5,0.75)
	sample.signed_depth = 1.125
	sample.sample_physics_tick = Engine.get_physics_frames()
	sample.sample_time_seconds = 3.0
	provider.set("_contact_positions",PackedVector3Array([Vector3(1,1,3)]))
	var samples: Array[WaterSample3D] = [sample]
	provider.set("_selected_contact_cache",samples)
	provider.set("_comparison_contact_cache",samples.duplicate())
	provider.set("_contact_cache_cursor",0)
	provider.set("_contact_cache_waiting_for_comparison",true)

func run() -> void:
	var source := Source.new()
	var fft_node := Node.new()
	root.add_child(source)
	source.add_child(fft_node)
	var a: CpuFftWaterProvider = Reference.new()
	var b := CpuFftWaterProvider.new()
	root.add_child(a); root.add_child(b)
	var scenarios := ["unchanged","wind_rebuild","spectrum","source","revision","vertical",
		"horizontal","space_revision","sea_level","invalid_scale","unavailable","failed_field"]
	var tick := Engine.get_physics_frames()
	for scenario in scenarios:
		var outputs := []
		for provider in [a,b]:
			prepare(provider,source,fft_node)
			match scenario:
				"wind_rebuild": source.state.status = "UPDATING"
				"spectrum": source.state.spectrum_version = 8
				"source": source.state.fft_instance_id = -1
				"revision": source.state.revision = 3
				"vertical": source.state.ocean_space.ocean_scale = 1.25
				"horizontal": source.state.ocean_space.clipmap_geometry_scale = 1.25
				"space_revision": source.state.ocean_space.revision = 5
				"sea_level": source.state.sea_level = 0.5
				"invalid_scale": source.state.ocean_space.ocean_scale = NAN
				"unavailable": source.state.status = "ERROR"
				"failed_field": provider.field_ready = false
			var start := source.reads
			var result: WaterSample3D = provider.sample_water(Vector3(1,1,3),WaterSample3D.new())
			check(source.reads-start == 1,scenario+" actual read still validates once")
			check(result.valid == (scenario == "unchanged"),scenario+" invalidation")
			outputs.append(fields(result))
		check(var_to_bytes(outputs[0]) == var_to_bytes(outputs[1]),scenario+" exact cached output")
	for enabled in [false,true]:
		var outputs := []
		for provider in [a,b]:
			prepare(provider,source,fft_node)
			provider.compare_other_cpu_backend = enabled
			var start := source.reads
			var result: WaterSample3D = provider.sample_comparison_water(Vector3(1,1,3),WaterSample3D.new())
			check(source.reads-start == (1 if enabled or provider == a else 0),"comparison validation count")
			outputs.append(fields(result))
		check(var_to_bytes(outputs[0]) == var_to_bytes(outputs[1]),"comparison enabled=%s exact"%enabled)
	for available in [false,true]:
		var outputs := []
		for provider in [a,b]:
			prepare(provider,source,fft_node)
			provider.compare_other_cpu_backend = false
			source.state.status = "OK" if available else "UPDATING"
			var start := source.reads
			provider.sample_comparison_water(Vector3(1,1,3),WaterSample3D.new())
			var result: WaterSample3D = provider.sample_water(Vector3(1,1,3),WaterSample3D.new())
			check(source.reads-start == (2 if provider == a else 1),"real read after disabled comparison still validates")
			outputs.append(fields(result))
		check(var_to_bytes(outputs[0]) == var_to_bytes(outputs[1]),"deferred diagnostic invalidation preserves actual read")
	check(Engine.get_physics_frames() == tick,"all mutations happened in the same tick")
	print("PERF_CONTACT_SAME_TICK ",JSON.stringify({"checks":comparisons,"failures":failures}))
	quit(0 if failures.is_empty() else 1)
