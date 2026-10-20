extends SceneTree
const Hull = preload("res://addons/jet_ski/common/systems/jet_ski_hull_buoyancy_v1.gd")
const ROW := 10
var report := {"geometry":{},"parity":{"values":0,"bit_differences":0,"max_absolute":0.0,"max_relative":0.0,"first":[],"nonfinite":0},"conservation":{"full_volume_bit_differences":0,"max_complement_absolute_gd":0.0,"max_complement_absolute_native":0.0,"max_complement_relative":0.0},"benchmarks":[]}
var fixtures: Array = []

func _initialize() -> void: call_deferred("run")

func option(key: String, fallback: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(key+"="): return arg.trim_prefix(key+"=")
	return fallback

func upload(hull: RefCounted) -> Object:
	var native: Object = ClassDB.instantiate("HullBuoyancyGeometryNative")
	var vertices := PackedVector3Array()
	var offsets := PackedInt32Array([0])
	for cell in hull.cells:
		vertices.append_array(cell.tetrahedra)
		offsets.append(vertices.size())
	assert(native.configure_geometry(vertices,offsets,hull.local_points))
	return native

func make_fixture(hull: RefCounted, transform: Transform3D, height: float, slope: Vector3, draft: float, label: String) -> Dictionary:
	var surfaces := PackedVector3Array()
	var normals := PackedVector3Array()
	var valid := PackedByteArray()
	var samples: Array[WaterSample3D] = []
	for i in hull.local_points.size():
		var point: Vector3 = transform*hull.local_points[i]
		var sample := WaterSample3D.new()
		sample.valid = true
		sample.surface_position = Vector3(point.x,height+sin(i*0.71)*0.07,point.z)
		sample.normal = slope
		samples.append(sample)
		surfaces.append(sample.surface_position); normals.append(slope); valid.append(1)
	return {"transform":transform,"surfaces":surfaces,"normals":normals,"valid":valid,"samples":samples,"draft":draft,"label":label}

func compare_number(a: float, b: float, path: String) -> void:
	report.parity["values"] += 1
	if not is_finite(a) or not is_finite(b): report.parity.nonfinite += 1
	if PackedFloat64Array([a]).to_byte_array() == PackedFloat64Array([b]).to_byte_array(): return
	var absolute := absf(a-b)
	var relative := absolute/maxf(maxf(absf(a),absf(b)),1e-300)
	report.parity.bit_differences += 1
	report.parity.max_absolute = maxf(report.parity.max_absolute,absolute)
	report.parity.max_relative = maxf(report.parity.max_relative,relative)
	if report.parity.first.size() < 12: report.parity.first.append({"path":path,"gdscript":a,"native":b,"absolute":absolute,"relative":relative})

func reference_moment(hull: RefCounted, index: int, fixture: Dictionary) -> Vector4:
	var sample: WaterSample3D = fixture.samples[index]
	var normal := sample.normal.normalized()
	var local_normal: Vector3 = fixture.transform.basis.transposed()*normal
	var local_surface: Vector3 = fixture.transform.affine_inverse()*sample.surface_position
	var plane_d := local_normal.dot(local_surface)-normal.y*float(fixture.draft)
	var vertices: PackedVector3Array = hull.cells[index].tetrahedra
	var moment := Vector4.ZERO
	for j in range(0,vertices.size(),4):
		moment += hull._submerged_tetra(vertices[j],vertices[j+1],vertices[j+2],vertices[j+3],local_normal,plane_d)
	return moment

func check_fixture(hull: RefCounted, native: Object, fixture: Dictionary) -> void:
	var packed: PackedFloat64Array = native.integrate_cells(fixture.transform,fixture.surfaces,fixture.normals,fixture.valid,fixture.draft)
	assert(packed.size() == hull.cells.size()*ROW)
	for i in hull.cells.size():
		var actual: Dictionary = hull.integrate_cell(i,fixture.transform,fixture.samples[i],fixture.draft)
		var moment := reference_moment(hull,i,fixture)
		var expected := PackedFloat64Array([1.0,actual.volume,actual.center.x,actual.center.y,actual.center.z,actual.depth,moment.x,moment.y,moment.z,moment.w])
		for j in ROW: compare_number(expected[j],packed[i*ROW+j],"%s/cell%d/component%d"%[fixture.label,i,j])

func percentile(values: PackedInt64Array, q: float) -> float:
	var ordered := values.duplicate(); ordered.sort()
	var p := (ordered.size()-1)*q
	return lerpf(ordered[int(p)],ordered[mini(int(p)+1,ordered.size()-1)],p-floor(p))/1000.0

func run_benchmark(hull: RefCounted, fleet: int, label: String, count: int) -> Dictionary:
	var objects: Array = []
	var surfaces: Array = []; var normals: Array = []; var masks: Array = []
	var volumes: Array = []; var centers: Array = []; var depths: Array = []
	for body in fleet:
		objects.append(upload(hull))
		var v := PackedVector3Array(); v.resize(12); surfaces.append(v)
		v = PackedVector3Array(); v.resize(12); normals.append(v)
		var flags := PackedByteArray(); flags.resize(12); masks.append(flags)
		var numbers := PackedFloat64Array(); numbers.resize(12); volumes.append(numbers)
		numbers = PackedFloat64Array(); numbers.resize(12); depths.append(numbers)
		v = PackedVector3Array(); v.resize(12); centers.append(v)
	var timings := PackedInt64Array()
	var checksum := 0.0
	for iteration in range(-48,count):
		var fixture: Dictionary = fixtures[posmod(iteration,fixtures.size())]
		var start := Time.get_ticks_usec()
		for body in fleet:
			var packed := PackedFloat64Array()
			if label.begins_with("B"):
				# Included: full input preparation, one extension call, result decode,
				# equivalent per-cell Dictionary and writes used by downstream physics.
				for i in 12:
					var sample: WaterSample3D = fixture.samples[i]
					surfaces[body][i] = sample.surface_position
					normals[body][i] = sample.normal
					masks[body][i] = int(sample.valid)
				packed = objects[body].integrate_cells(fixture.transform,surfaces[body],normals[body],masks[body],fixture.draft)
			for i in 12:
				var result: Dictionary
				if label.begins_with("A"):
					result = hull.integrate_cell(i,fixture.transform,fixture.samples[i],fixture.draft)
				else:
					var offset := i*ROW
					result = {"volume":packed[offset+1],"center":Vector3(packed[offset+2],packed[offset+3],packed[offset+4]),"depth":packed[offset+5]}
				volumes[body][i] = result.volume
				centers[body][i] = result.center
				depths[body][i] = result.depth
		var elapsed := Time.get_ticks_usec()-start
		if iteration >= 0: timings.append(elapsed)
		checksum += float(volumes[0][0])
	var sum_us := 0.0
	for value in timings: sum_us += value
	return {"fleet":fleet,"label":label,"n":timings.size(),"mean_ms":sum_us/count/1000.0,"p50_ms":percentile(timings,.5),"p95_ms":percentile(timings,.95),"p99_ms":percentile(timings,.99),"checksum":checksum}

func run() -> void:
	if not ClassDB.class_exists("HullBuoyancyGeometryNative"):
		push_error("Build the isolated native class before running this fixture")
		quit(1); return
	var scene: Node = load("res://validation/hull_wave_physics_playground.tscn").instantiate()
	var hull := Hull.new()
	assert(hull.configure(scene.get_node("JetSki/CollisionShape3D")))
	var counts := []
	for cell in hull.cells: counts.append(cell.tetrahedra.size()/4)
	report.geometry = {"tetrahedra_per_cell":counts,"volume":hull.total_volume_m3,"cells":hull.cells.size()}
	var native := upload(hull)
	var poses := [Vector3.ZERO,Vector3(.75,0,0),Vector3(0,0,.8),Vector3(1.3,0,0),Vector3(0,0,PI)]
	for pose in poses:
		for height in [-5.0,-.2,0.0,.2,5.0]:
			for slope in [Vector3.UP,Vector3(-.3,1,.2)]:
				fixtures.append(make_fixture(hull,Transform3D(Basis.from_euler(pose),Vector3(.17,-.11,.29)),height,slope,.05,"pose%s/height%s/slope%s"%[pose,height,slope]))
	var rng := RandomNumberGenerator.new(); rng.seed = 4701
	for i in 180:
		var pose := Vector3(rng.randf_range(-PI,PI),rng.randf_range(-PI,PI),rng.randf_range(-PI,PI))
		fixtures.append(make_fixture(hull,Transform3D(Basis.from_euler(pose),Vector3(.33,-.17,.71)),rng.randf_range(-1.5,1.5),Vector3(rng.randf_range(-.9,.9),1,rng.randf_range(-.9,.9)),rng.randf_range(0,.15),"random%d"%i))
	var vertex: Vector3 = hull.cells[0].tetrahedra[0]
	for draft in [0.0,1e-12,-1e-12,1e-8,-1e-8,1e-6,-1e-6]:
		fixtures.append(make_fixture(hull,Transform3D.IDENTITY,vertex.y,Vector3.UP,draft,"clip_boundary%s"%draft))
	for i in 25:
		fixtures.append(make_fixture(hull,Transform3D(Basis.IDENTITY,Vector3(0,1.2-i*.1,0)),0.0,Vector3(-.2,1,.3),.05,"fast_entry%d"%i))
	for fixture in fixtures: check_fixture(hull,native,fixture)
	var full := make_fixture(hull,Transform3D.IDENTITY,100.0,Vector3.UP,0.0,"full_conservation")
	var full_values: PackedFloat64Array = native.integrate_cells(full.transform,full.surfaces,full.normals,full.valid,0.0)
	for i in 12:
		if PackedFloat64Array([full_values[i*ROW+1]]).to_byte_array() != PackedFloat64Array([float(hull.cells[i].volume)]).to_byte_array():
			report.conservation.full_volume_bit_differences += 1
	for height in [-.3,0.0,.2]:
		var above := make_fixture(hull,Transform3D.IDENTITY,height,Vector3.UP,0.0,"complement_up")
		var below := make_fixture(hull,Transform3D.IDENTITY,height,Vector3.DOWN,0.0,"complement_down")
		var va: PackedFloat64Array = native.integrate_cells(above.transform,above.surfaces,above.normals,above.valid,0.0)
		var vb: PackedFloat64Array = native.integrate_cells(below.transform,below.surfaces,below.normals,below.valid,0.0)
		for i in 12:
			var a: Dictionary = hull.integrate_cell(i,above.transform,above.samples[i],0.0)
			var b: Dictionary = hull.integrate_cell(i,below.transform,below.samples[i],0.0)
			var volume := float(hull.cells[i].volume)
			var error_gd := absf(float(a.volume)+float(b.volume)-volume)
			var error_native := absf(va[i*ROW+1]+vb[i*ROW+1]-volume)
			report.conservation.max_complement_absolute_gd = maxf(report.conservation.max_complement_absolute_gd,error_gd)
			report.conservation.max_complement_absolute_native = maxf(report.conservation.max_complement_absolute_native,error_native)
			report.conservation.max_complement_relative = maxf(report.conservation.max_complement_relative,error_native/volume)
	# Exactly the same algorithm on nearly degenerate and zero-volume tetrahedra.
	for scale in [0.0,1e-12,1e-8,1e-5]:
		var tiny := Hull.new()
		tiny.local_points = PackedVector3Array([Vector3(.25,scale*.25,.25)])
		tiny.cells = [{"tetrahedra":PackedVector3Array([Vector3.ZERO,Vector3(1,0,0),Vector3(0,scale,0),Vector3(0,0,1)])}]
		var tiny_native := upload(tiny)
		for height in [-1e-8,0.0,1e-8,1.0]: check_fixture(tiny,tiny_native,make_fixture(tiny,Transform3D.IDENTITY,height,Vector3.UP,0.0,"degenerate%s/height%s"%[scale,height]))
	if option("--benchmark","false") == "true" and report.parity.bit_differences == 0 and report.parity.nonfinite == 0:
		for fleet in [1,6]:
			for label in ["A1","B1","B2","A2"]: report.benchmarks.append(run_benchmark(hull,fleet,label,int(option("--iterations","600"))))
	DirAccess.make_dir_recursive_absolute("res://temp/hull_native_1")
	var file := FileAccess.open("res://temp/hull_native_1/isolated.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report)); file.close()
	scene.free()
	print("HULL_NATIVE_ISOLATED ",JSON.stringify(report))
	quit(0 if report.parity.bit_differences == 0 and report.parity.nonfinite == 0 else 2)
