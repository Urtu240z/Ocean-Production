extends "res://validation/physics/phys_branch_continuity_runner.gd"
## Offline replay of CPU-only captures emitted by phys_branch_live_runner.
## Dense seeds are diagnostic evidence, not exhaustive root enumeration.
func _run() -> void:
	var ocean: Node = OCEAN_SCENE.instantiate(); ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for p in ["breakers", "crest_foam", "surface_foam"]: ocean.set(p, false)
	root.add_child(ocean)
	for _i in 20: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	var c: Dictionary = ocean.get_node("OpenOceanFFT").call("get_phys3_coastal_snapshot")
	var reports: Array = []
	for name in DirAccess.get_files_at("res://.godot"):
		if not name.begins_with("branch_failure_") or not name.ends_with(".bin"): continue
		var f := FileAccess.open("res://.godot/" + name, FileAccess.READ); var cap: Dictionary = f.get_var(); f.close()
		var native: Object = ClassDB.instantiate("OceanQueryNative")
		if not native.call("prepare_production_spectrum", cap.bands): _fail("replay spectrum"); return
		ADAPTER.configure_coastal(native, c)
		var time: float = cap.rows[20]
		if absf(time - float(cap.bands[0].wave_time)) > 1e-8: _fail("capture time association"); return
		native.call("build_dynamic_physics_fields", time)
		for i in 4:
			if cap.rows[i * CS] > 0.5: continue
			var w: Vector3 = cap.targets[i]; var seeds: Array = []
			for iz in 61:
				for ix in 61:
					var x: float = w.x + (ix - 30) * 0.05; var z: float = w.z + (iz - 30) * 0.05
					var a: PackedFloat64Array = native.call("sample_dynamic_material_q", x, z)
					seeds.append([sqrt(pow(x + a[2] - w.x, 2) + pow(z + a[4] - w.z, 2)), x, z])
			seeds.sort_custom(func(a, b): return a[0] < b[0])
			var solutions: Array = []
			for j in 32:
				var root := _micro_newton(native, w.x, w.z, seeds[j][1], seeds[j][2])
				if root[0] < 0.001: solutions.append(root)
			reports.append({"file": name, "contact": i, "time": time, "world": [w.x, w.z],
				"original_residual": cap.rows[i * CS + 13], "coarse_best": seeds[0], "roots": solutions,
				"edge": _edge(native, float(c.field_origin.x), w.x, w.z)})
		native.call("clear")
	if reports.is_empty(): _fail("no failed captures; run phys_branch_live_runner first"); return
	var out := FileAccess.open("res://.godot/branch_failure_diagnosis.json", FileAccess.WRITE); out.store_string(JSON.stringify(reports, "\t")); out.close()
	print("BRANCH_FAILURE_DIAG=" + JSON.stringify(reports)); quit(0)

func _micro_newton(native: Object, wx: float, wz: float, x: float, z: float) -> Array:
	var residual := INF
	for iteration in 40:
		var a: PackedFloat64Array = native.call("sample_dynamic_material_q", x, z)
		var rx: float = x + a[2] - wx; var rz: float = z + a[4] - wz; residual = sqrt(rx * rx + rz * rz)
		if residual < 0.000001: return [residual, x, z, iteration]
		var e := 0.0003125
		var xp: PackedFloat64Array = native.call("sample_dynamic_material_q", x + e, z)
		var xm: PackedFloat64Array = native.call("sample_dynamic_material_q", x - e, z)
		var zp: PackedFloat64Array = native.call("sample_dynamic_material_q", x, z + e)
		var zm: PackedFloat64Array = native.call("sample_dynamic_material_q", x, z - e)
		var j00: float = 1.0 + (xp[2] - xm[2]) / (2 * e); var j01: float = (zp[2] - zm[2]) / (2 * e)
		var j10: float = (xp[4] - xm[4]) / (2 * e); var j11: float = 1.0 + (zp[4] - zm[4]) / (2 * e)
		var det: float = j00 * j11 - j01 * j10
		if absf(det) < 1e-10: break
		var dx: float = (j11 * rx - j01 * rz) / det; var dz: float = (-j10 * rx + j00 * rz) / det
		var scale: float = minf(1.0, 0.1 / maxf(0.1, sqrt(dx * dx + dz * dz)))
		var accepted := false
		for _k in 16:
			var tx: float = x - dx * scale; var tz: float = z - dz * scale
			var b: PackedFloat64Array = native.call("sample_dynamic_material_q", tx, tz)
			var next: float = sqrt(pow(tx + b[2] - wx, 2) + pow(tz + b[4] - wz, 2))
			if next < residual: x = tx; z = tz; accepted = true; break
			scale *= 0.5
		if not accepted: break
	return [residual, x, z, 40]

func _edge(native: Object, origin_x: float, wx: float, wz: float) -> Array:
	var sides: Array = []
	for side in [-1.0, 1.0]:
		var x: float = origin_x + side * 0.000001
		var candidates: Array = []
		var last_z: float = wz - 2.0
		var last: PackedFloat64Array = native.call("sample_dynamic_material_q", x, last_z)
		var last_r: float = last_z + last[4] - wz
		for i in 800:
			var z: float = wz - 2.0 + (i + 1) * 0.005
			var a: PackedFloat64Array = native.call("sample_dynamic_material_q", x, z)
			var rz: float = z + a[4] - wz
			if rz * last_r <= 0.0:
				var lo: float = last_z; var hi: float = z; var low_r: float = last_r
				for _j in 32:
					var mid: float = (lo + hi) * 0.5
					var b: PackedFloat64Array = native.call("sample_dynamic_material_q", x, mid)
					var mr: float = mid + b[4] - wz
					if mr * low_r <= 0.0: hi = mid
					else: lo = mid; low_r = mr
				var qz: float = (lo + hi) * 0.5
				var b: PackedFloat64Array = native.call("sample_dynamic_material_q", x, qz)
				candidates.append({"q": [x, qz], "world_x": x + b[2], "world_x_error": x + b[2] - wx,
					"world_z_error": qz + b[4] - wz, "displacement": [b[2], b[3], b[4]]})
			last_z = z; last_r = rz
		sides.append({"side": side, "roots_z": candidates})
	return sides
