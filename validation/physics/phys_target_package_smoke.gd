extends SceneTree
func _initialize() -> void:
	load("res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension")
	var ok := ClassDB.class_exists("OceanQueryNative")
	var native: Object = ClassDB.instantiate("OceanQueryNative") if ok else null
	var expected := preload("res://validation/physics/phys_native_build_contract.gd").ID
	ok = ok and native != null and native.call("get_dynamic_async_build_id") == expected
	var api := RenderingServer.get_video_adapter_api_version()
	var worker_probe := {}
	if native != null:
		var original: int = native.call("get_dynamic_worker_count")
		for count in [3,4,5,6,8]:
			native.call("set_dynamic_worker_count",count)
			worker_probe[str(count)]=int(native.call("get_dynamic_worker_count"))
		native.call("set_dynamic_worker_count",original)
	var report := {"passed": ok, "class_registered": ClassDB.class_exists("OceanQueryNative"),
		"instance_created": native != null, "build_id": native.call("get_dynamic_async_build_id") if native != null else "missing",
		"godot": Engine.get_version_info().string, "gpu": RenderingServer.get_video_adapter_name(),
		"api": api, "driver": RenderingServer.get_current_rendering_driver_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"worker_probe":worker_probe}
	var f := FileAccess.open("res://.godot/phys_target_package_smoke.json",FileAccess.WRITE)
	f.store_string(JSON.stringify(report)); f.close()
	print("TARGET_PACKAGE_LOAD=" + JSON.stringify(report))
	native = null
	quit(0 if ok else 1)
