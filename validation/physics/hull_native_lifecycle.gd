extends SceneTree
const Hull = preload("res://addons/jet_ski/common/systems/jet_ski_hull_buoyancy_v1.gd")
const Reference = preload("res://validation/fixtures/hull_geometry_gdscript_reference.gd")
var failures: Array[String] = []
var checks := 0
class MissingNative extends Hull:
	func _create_native_geometry() -> Object: return null
class RejectedResult extends RefCounted:
	func set_profiling_enabled(_enabled: bool) -> void: pass
	func integrate_cells(_t: Transform3D,_p: PackedVector3Array,_n: PackedVector3Array,_v: PackedByteArray,_d: float) -> PackedFloat64Array: return PackedFloat64Array()

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func samples() -> Array[WaterSample3D]:
	var output: Array[WaterSample3D] = []
	for i in 12:
		var sample := WaterSample3D.new()
		sample.valid = true; sample.surface_position = Vector3(i*.1,.15,0)
		sample.normal = Vector3(-.2,1,.1).normalized(); output.append(sample)
	return output
func check_geometry(hull: RefCounted, reference: RefCounted) -> void:
	var input := samples()
	check(hull.is_native_ready(),"geometry registered by configure")
	check(hull.integrate_native_batch(Transform3D.IDENTITY,input,.05),"valid batch")
	for i in 12:
		input[i].normal = hull._native_normals[i]
		var a: Dictionary = reference.integrate_cell(i,Transform3D.IDENTITY,input[i],.05)
		check(var_to_bytes(a) == var_to_bytes(hull.native_cell_result(i)),"exact lifecycle cell %d"%i)
func run() -> void:
	var scene: Node = load("res://validation/hull_wave_physics_playground.tscn").instantiate()
	var collision: CollisionShape3D = scene.get_node("JetSki/CollisionShape3D")
	var reference := Reference.new()
	check(reference.configure(collision),"reference shape")
	var hull := Hull.new()
	check(hull.configure(collision),"native registration at initialization")
	for _iteration in 8: check_geometry(hull,reference)
	check(hull.native_geometry_uploads == 1,"one upload across ticks")
	var changed: ConvexPolygonShape3D = collision.shape.duplicate(true)
	var points := changed.points
	for i in points.size(): points[i] *= 1.03
	changed.points = points
	var private_collision := CollisionShape3D.new()
	private_collision.shape = changed
	check(hull.configure(private_collision),"changed geometry")
	check(hull.native_geometry_uploads == 2,"one new generation upload")
	private_collision.shape = BoxShape3D.new()
	check(not hull.configure(private_collision),"invalid collision rejected")
	check(not hull.is_native_ready() and hull._native_values.is_empty() and hull._native_surfaces.is_empty(),"invalid reconstruction releases state")
	check(hull.configure(collision),"geometry restored")
	check_geometry(hull,reference)
	check(hull.native_geometry_uploads == 3,"restored generation upload")
	var missing := MissingNative.new()
	check(not missing.configure(collision) and not missing.is_native_ready(),"missing dependency fails closed")
	check(not missing.native_failure_reason.is_empty(),"explicit missing dependency error")
	hull.set("_native_geometry",RejectedResult.new())
	check(not hull.integrate_native_batch(Transform3D.IDENTITY,samples(),.05),"bad result rejected")
	check(not hull.is_native_ready() and hull._native_values.is_empty(),"no stale results after rejection")
	var body := RigidBody3D.new()
	var physics := JetSkiWaterPhysicsSystem.new()
	root.add_child(body); body.add_child(physics)
	physics.hull_buoyancy = hull
	physics.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
	check(not physics.ensure_hull_simulation_ready(body),"invalid HULL cannot continue")
	await process_frame
	check(body.freeze,"failed vehicle frozen")
	check(physics.buoyancy_mode == JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1,"no LEGACY substitution")
	physics.configure_hull_buoyancy(collision)
	await process_frame
	check(not body.freeze and physics.ensure_hull_simulation_ready(body),"reconfiguration resumes vehicle")
	var fleet: Array = []
	for i in 6:
		var member := Hull.new(); check(member.configure(collision),"independent fleet initialization")
		fleet.append(member)
	for i in 6:
		for j in range(i+1,6): check(fleet[i]._native_geometry != fleet[j]._native_geometry,"no shared native mutable state")
	fleet.clear()
	body.free(); private_collision.free(); scene.free()
	print("HULL_NATIVE_LIFECYCLE ",JSON.stringify({"checks":checks,"failures":failures,"expected_errors":2}))
	quit(0 if failures.is_empty() else 1)
