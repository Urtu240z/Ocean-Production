extends SceneTree

func _initialize() -> void:
	var descriptor := load("res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension")
	if descriptor == null or not ClassDB.class_exists("OceanQueryNative"):
		push_error("PHYS-OPT-2D native extension failed to register")
		quit(1)
		return
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if native == null:
		push_error("PHYS-OPT-2D native class failed to instantiate")
		quit(1)
		return
	var build_id := String(native.call("get_dynamic_async_build_id"))
	print("PHYS_OPT_2D_LOAD_OK build_id=" + build_id)
	if build_id != "PHYS-OPT-2D-latest-wins-v1":
		push_error("Loaded stale or unexpected native build: " + build_id)
		quit(1)
		return
	quit(0)
