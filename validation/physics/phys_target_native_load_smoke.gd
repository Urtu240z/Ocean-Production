extends SceneTree
## Direct runtime check for the built OceanQueryNative GDExtension.

const DESCRIPTOR := "res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension"


func _initialize() -> void:
	var extension := load(DESCRIPTOR)
	if extension == null:
		printerr("TARGET_NATIVE_LOAD_FAIL=descriptor could not load: " + DESCRIPTOR)
		quit(1)
		return
	if not ClassDB.class_exists("OceanQueryNative"):
		printerr("TARGET_NATIVE_LOAD_FAIL=ClassDB.class_exists returned false")
		quit(1)
		return
	var instance: Object = ClassDB.instantiate("OceanQueryNative")
	if instance == null:
		printerr("TARGET_NATIVE_LOAD_FAIL=class registered but instantiation failed")
		quit(1)
		return
	print("TARGET_NATIVE_LOAD_PASS " + JSON.stringify({
		"godot": Engine.get_version_info().get("string", "unknown"),
		"descriptor": DESCRIPTOR,
		"class_registered": ClassDB.class_exists("OceanQueryNative"),
		"instance_created": true,
	}))
	# OceanQueryNative derives from RefCounted; dropping the reference releases it.
	instance = null
	quit(0)
