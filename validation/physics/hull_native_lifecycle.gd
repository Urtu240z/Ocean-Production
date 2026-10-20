extends SceneTree
const Hull = preload("res://addons/jet_ski/common/systems/jet_ski_hull_buoyancy_v1.gd")
var failures: Array[String] = []
var checks := 0
class RejectedResult extends RefCounted:
	func set_profiling_enabled(_enabled: bool) -> void: pass
	func integrate_cells(_t: Transform3D,_p: PackedVector3Array,_n: PackedVector3Array,_v: PackedByteArray,_d: float) -> PackedFloat64Array: return PackedFloat64Array()

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func check_geometry(hull: RefCounted) -> void:
	var samples: Array[WaterSample3D] = []
	for i in 12:
		var sample := WaterSample3D.new()
		sample.valid = true; sample.surface_position = Vector3(i*.1,.15,0)
		sample.normal = Vector3(-.2,1,.1).normalized(); samples.append(sample)
	check(hull.prepare_native_geometry(),"geometry available")
	check(hull.integrate_native_batch(Transform3D.IDENTITY,samples,.05),"valid batch")
	for i in 12:
		var a: Dictionary = hull.integrate_cell(i,Transform3D.IDENTITY,samples[i],.05)
		var b: Dictionary = hull.native_cell_result(i)
		check(var_to_bytes(a) == var_to_bytes(b),"exact lifecycle cell %d"%i)

func run() -> void:
	var scene: Node = load("res://validation/hull_wave_physics_playground.tscn").instantiate()
	var collision: CollisionShape3D = scene.get_node("JetSki/CollisionShape3D")
	var hull := Hull.new()
	check(hull.geometry_backend == 0,"GDScript remains default")
	check(hull.configure(collision),"original hull")
	for _iteration in 8: check_geometry(hull)
	check(hull.native_geometry_uploads == 1,"one upload for repeated ticks and transforms")
	var changed: ConvexPolygonShape3D = collision.shape.duplicate(true)
	var points := changed.points
	for i in points.size(): points[i] *= 1.03
	changed.points = points
	var private_collision := CollisionShape3D.new()
	private_collision.shape = changed
	check(hull.configure(private_collision),"changed collision geometry")
	check_geometry(hull)
	check(hull.native_geometry_uploads == 2,"new geometry uploaded exactly once")
	private_collision.shape = BoxShape3D.new()
	check(not hull.configure(private_collision),"invalid hull rejected")
	check(not hull.prepare_native_geometry(),"old native geometry cannot survive invalid reconstruction")
	check(hull.configure(collision),"geometry restored")
	check_geometry(hull)
	check(hull.native_geometry_uploads == 3,"restored geometry has fresh upload")
	# Fail closed to the GDScript path; never decode an old native result.
	hull.set("_native_geometry",RejectedResult.new())
	var samples: Array[WaterSample3D] = []
	for i in 12:
		var sample := WaterSample3D.new(); sample.valid = true
		samples.append(sample)
	var before := hull.native_fallback_count
	check(not hull.integrate_native_batch(Transform3D.IDENTITY,samples,.05),"rejected batch triggers fallback")
	check(hull.native_fallback_count == before+1,"fallback visible in telemetry")
	private_collision.free(); scene.free()
	print("HULL_NATIVE_LIFECYCLE ",JSON.stringify({"checks":checks,"failures":failures}))
	quit(0 if failures.is_empty() else 1)
