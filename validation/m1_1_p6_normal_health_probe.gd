extends SceneTree


func _init() -> void:
	call_deferred("_run_probe")


func _run_probe() -> void:
	var report := P7BreakerShapeVDMGenerator.get_p6_validation_report()
	print("M1_1_P6_NORMAL_HEALTH " + JSON.stringify({
		"p6_a": report.get("p6_a", {}),
		"p6_a_normal_health": report.get("p6_a_normal_health", {}),
		"p5_to_p6_normal_temporal": report.get("p5_to_p6_normal_temporal", {}),
	}))
	var scene: Node = load("res://validation/p7_breaker_carrier_h5.tscn").instantiate()
	var carrier: Node = scene.get_node("BreakerCarrier")
	carrier.set("carrier_validation_phase_override", 6.0)
	carrier.set("carrier_material_mode", 2)
	carrier.set("validation_lateral_progress", 1.0)
	carrier.set("validation_event_reacquire_serial", 1)
	get_root().add_child(scene)
	for _frame in 12:
		await process_frame
	var static_info: Dictionary = carrier.call("get_static_carrier_info")
	print("M1_1_P6_GEOMETRIC_RUNTIME " + JSON.stringify({
		"phase": static_info.get("validation_phase", -1.0),
		"exact_phase": static_info.get("validation_exact_phase", -1.0),
		"material_mode": static_info.get("carrier_material_mode", -1),
		"event_acquired": static_info.get("event_acquired", false),
		"full_width": static_info.get("lateral_envelope", {}).get("manual_progress", -1.0),
	}))
	carrier.set("carrier_material_mode", 3)
	await process_frame
	print("M1_1_P6_OCEAN_PARITY_RUNTIME " + JSON.stringify({
		"material_mode": carrier.get("carrier_material_mode"),
	}))
	quit()
