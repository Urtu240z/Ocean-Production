extends "res://validation/physics/hull_native_real_scene_profile.gd"
const ContactDiagnostic = preload("res://validation/physics/contact_pipeline_3_provider.gd")
var cp3_rows: Array = []
var cp3_configured := false

func _initialize() -> void:
	Engine.max_fps = 0
	super()

func create_profile_scene(scene_path: String) -> Node:
	var instance: Node = load(scene_path).instantiate()
	var host: Ocean = instance.get_node("JetSkiOcean/Production/Ocean")
	var provider: CpuFftWaterProvider = CpuFftWaterProvider.new() if option("--cp3-kind","cost") == "benchmark" else ContactDiagnostic.new()
	if provider is ContactDiagnostic: provider.cp3_trace = option("--cp3-kind","cost") == "trace"
	provider.name = "PhysicalWater"
	host.add_child(provider)
	host.set("_cpu_water_provider",provider)
	return instance

func begin_tick() -> void:
	if option("--cp3-free-motion","false") == "true":
		elapsed += 1.0/Engine.physics_ticks_per_second
		tick_us = Time.get_ticks_usec()
	else:
		super()
	if not cp3_configured:
		var bodies: Array = [boat]
		bodies.append_array(extra_boats)
		for body in bodies:
			if option("--cp3-arcade","saved") != "saved":
				body.arcade_handling_system.arcade_handling_enabled = option("--cp3-arcade","saved") == "true"
		cp3_configured = true
	if world.water is ContactDiagnostic: world.water.cp3_measured = measured

func end_tick() -> void:
	super()
	if world.water is ContactDiagnostic:
		var row: PackedInt64Array = world.water.cp3_flush()
		if measured: cp3_rows.append([Engine.get_physics_frames(),Array(row)])

func measure(label: String, point: Vector3, velocity: Vector3, rotate: bool, seconds: float) -> void:
	cp3_rows.clear()
	if world.water is ContactDiagnostic: world.water.cp3_traces.clear()
	await super(label,point,velocity,rotate,seconds)
	cases[-1]["cp3"] = cp3_rows.duplicate(true)
	if world.water is ContactDiagnostic:
		cases[-1]["cp3_labels"] = ContactDiagnostic.CP3_LABELS
		cases[-1]["cp3_trace"] = world.water.cp3_traces.duplicate(true)
