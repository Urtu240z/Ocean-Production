extends "res://validation/physics/async_fft_real_scene_profile.gd"
const ReferenceProvider = preload("res://validation/physics/perf_contact_reference_provider.gd")
const InstrumentedProvider = preload("res://validation/physics/perf_contact_instrumented_provider.gd")
const SourceValidationReference = preload("res://validation/fixtures/source_validation_reference_provider.gd")

func create_profile_scene(scene_path: String) -> Node:
	var instance := super(scene_path)
	var host: Ocean = instance.get_node("JetSkiOcean/Production/Ocean")
	var provider: CpuFftWaterProvider
	if option("--contact-diagnostic","false") == "true":
		provider = InstrumentedProvider.new()
		provider.set("reference_comparison",option("--contact-variant","A") == "A")
	elif option("--source-variant","B") == "A": provider = SourceValidationReference.new()
	elif option("--contact-variant","A") == "A": provider = ReferenceProvider.new()
	else: provider = CpuFftWaterProvider.new()
	provider.name = "PhysicalWater"
	host.add_child(provider)
	host.set("_cpu_water_provider",provider)
	return instance

func measure(label: String, position: Vector3, velocity: Vector3, rotate: bool, seconds: float) -> void:
	var provider: CpuFftWaterProvider = world.water
	var first_tick := Engine.get_physics_frames()
	var before: Dictionary = provider.call("snapshot") if provider.has_method("snapshot") else {}
	await super(label,position,velocity,rotate,seconds)
	var after: Dictionary = provider.call("snapshot") if provider.has_method("snapshot") else {}
	var delta := {}
	for key in before: delta[key] = int(after[key])-int(before[key])
	cases[-1]["contact_diagnostic_including_settle"] = delta
	cases[-1]["contact_diagnostic_ticks_including_settle"] = Engine.get_physics_frames()-first_tick
	cases[-1]["contact_variant"] = option("--contact-variant","A")
