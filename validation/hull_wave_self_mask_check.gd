extends SceneTree
## Shipping native extension: ownership, protected hull footprint and C1 release.
var native: Object
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("HULL_SELF_MASK: " + message)

func publish(clock: float) -> void:
	# Symmetric landing ring also exercises derivatives with no trail-age terms.
	var row := PackedFloat64Array([0,0,0,-1,0.6,0.7,3,6,8,1,0,0.1,2,0,0,0,0.65,1])
	check(native.publish_hull_waves(row,PackedInt64Array([17]),clock),"publish valid packet")

func value(position: Vector3, owner := 17, delay := 0.8) -> PackedFloat64Array:
	return native.sample_hull_waves(PackedVector3Array([position]),owner,Vector3.ZERO,delay,3.0,2.0)

func run() -> void:
	native = ClassDB.instantiate("OceanQueryNative")
	check(native != null and native.has_method("sample_hull_waves"),"native sampler available")
	if native == null: quit(1); return
	publish(0.2)
	for point in [Vector3.ZERO,Vector3(-0.6,0,-1.55),Vector3(0.6,0,1.55),Vector3(0,0,-2)]:
		check(value(point) == PackedFloat64Array([0,0,0,0]),
			"recent own height, slopes and vertical velocity are neutral over the whole hull")
		check(value(point,23) == value(point,0),"other owners retain the exact physical wave")
		check(value(point,17,0.0) == value(point,0),"zero delay still disables self protection")
	check(absf(value(Vector3(1,0,0),0)[0]) > 0.05,"fixture contains a meaningful physical wave")
	for time in [1.6,2.0,3.0]:
		publish(time)
		check(value(Vector3(1,0,0)) == value(Vector3(1,0,0),0),"old own waves remain fully physical")
	publish(0.2)
	check(value(Vector3(6,0,0)) == value(Vector3(6,0,0),0),"spatial release restores own waves outside the near hull")
	var max_error := 0.0
	var step := 0.0001
	for setup in [Vector2(1.0,1.0),Vector2(0.2,4.0),Vector2(1.1,4.0)]:
		publish(setup.x)
		var point := Vector3(setup.y,0,0.7)
		var center := value(point)
		var dx := (value(point+Vector3(step,0,0))[0]-value(point-Vector3(step,0,0))[0])/(2*step)
		var dz := (value(point+Vector3(0,0,step))[0]-value(point-Vector3(0,0,step))[0])/(2*step)
		publish(setup.x+step)
		var future := value(point)[0]
		publish(setup.x-step)
		var past := value(point)[0]
		max_error = maxf(max_error,maxf(absf(dx-center[1]),maxf(absf(dz-center[2]),absf((future-past)/(2*step)-center[3]))))
	check(max_error < 0.001,"self protection retains coherent analytic spatial/time derivatives")
	print("HULL_SELF_MASK_%s derivative_error=%.8f errors=%d" % [
		"PASS" if failures.is_empty() else "FAIL",max_error,failures.size()])
	quit(0 if failures.is_empty() else 1)
