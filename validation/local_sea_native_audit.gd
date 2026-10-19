extends SceneTree
const Spectrum = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
const LocalFFT = preload("res://addons/ocean/areas/ocean_local_fft_state.gd")
const BaseFFT = preload("res://validation/fixtures/local_sea_base/local_fft_state.gd")
var failures: Array = []
var report := {"field_builds":[],"queries":[],"resolution_experiment":[],"failures":[]}
func _initialize() -> void: call_deferred("run")
func stats(values: Array) -> Dictionary:
	if values.is_empty(): return {"n":0}
	values.sort()
	return {"n":values.size(),"p50":values[int((values.size()-1)*0.5)],"p95":values[int((values.size()-1)*0.95)]}
func check(ok: bool,label: String) -> void:
	if not ok: failures.append(label)
func run() -> void:
	var host: Node3D = load("res://addons/ocean/ocean.tscn").instantiate()
	var builder: Object = ClassDB.instantiate("OceanQueryNative")
	if not builder.has_method("sample_dynamic_lite_local_sea_batch"):
		push_error("Native batch method missing")
		host.free()
		quit(1)
		return
	for slot in 2:
		for chop in [1.0,2.0]:
			var settings: Resource = (host.local_sea_state_1 if slot==0 else host.local_sea_state_2).duplicate(true)
			settings.choppiness_scale = chop
			var profile: Resource = host.wave_profile
			var configs: Array = profile.build_fft_configs(-1.0,settings.wind_speed_mps,settings.wind_direction_degrees,settings.swell,settings.long_wave_spacing)
			for config in configs: config.choppiness *= chop
			var spectrum := Spectrum.build(configs,host.simulation_seed,-1.0,profile.combined_significant_wave_height_m(),settings.wave_height_scale,
				[settings.long_band_scale,settings.mid_band_scale,settings.short_band_scale],settings.mid_fill_amount,7,builder)
			var natives: Array = []
			for resolution in [PackedInt32Array([128,128,128]),PackedInt32Array([128,128,64])]:
				var native: Object = ClassDB.instantiate("OceanQueryNative")
				native.set_gameplay_min_wavelength_m(0.0)
				check(native.set_production_spectrum(spectrum.bands),"spectrum accepted")
				natives.append(native)
				for i in 30: check(native.build_dynamic_physics_lite(i/60.0,resolution),"warm field")
				var total: Array = []
				var bands := [[],[],[]]
				var memory := 0
				for i in 240:
					var at := Time.get_ticks_usec()
					check(native.build_dynamic_physics_lite((i+30)/60.0,resolution),"field built")
					total.append((Time.get_ticks_usec()-at)/1000.0)
					var profile_row: Dictionary = native.get_dynamic_lite_profile()
					memory = profile_row.memory_bytes
					for band in 3: bands[band].append(profile_row.band_build_us[band]/1000.0)
				report.field_builds.append({"slot":slot,"chop_scale":chop,"resolution":Array(resolution),
					"total_ms":stats(total),"band_ms":[stats(bands[0]),stats(bands[1]),stats(bands[2])],"field_memory_bytes":memory})
			var native: Object = natives[0]
			check(native.build_dynamic_physics_lite(3.0,PackedInt32Array([128,128,128])),"query field")
			var actual := LocalFFT.new()
			var reference := BaseFFT.new()
			for state in [actual,reference]:
				state.native = native
				state.settings = settings
				state.time_s = 3.0
				state._last_clock = 3.0
				state._field_time = 3.0
			actual._native_batch_supported = true
			for mode in [false,true]:
				for count in [14,56,84]:
					var points := PackedVector3Array()
					for i in count: points.append(Vector3(-106.0+i*4.1,0.0,-80.0+float(i%17)*9.4))
					var error := Vector4.ZERO
					for movement in 20:
						var moved := points.duplicate()
						for i in moved.size(): moved[i] += Vector3(movement*0.75,0,movement*0.31)
						var a: PackedVector4Array = actual.sample(moved,3.0,mode)
						var b: PackedVector4Array = reference.sample(moved,3.0,mode)
						check(a.size()==count and b.size()==count,"batch size")
						for i in mini(a.size(),b.size()):
							for axis in 4: error[axis] = maxf(error[axis],absf(a[i][axis]-b[i][axis]))
					for axis in 4: check(error[axis] <= 0.000001,"native exact slope/height/VY")
					for i in 30:
						actual.sample(points,3.0,mode)
						reference.sample(points,3.0,mode)
					var times := [[],[]]
					for i in 240:
						for index in ([0,1] if i%2==0 else [1,0]):
							var at := Time.get_ticks_usec()
							if index==0: reference.sample(points,3.0,mode)
							else: actual.sample(points,3.0,mode)
							times[index].append((Time.get_ticks_usec()-at)/1000.0)
					report.queries.append({"slot":slot,"chop_scale":chop,"displaced":mode,"contacts":count,"native_positions":count*5,
						"base_bridge_ms":stats(times[0]),"native_batch_ms":stats(times[1]),"max_error_h_sx_sz_vy":[error.x,error.y,error.z,error.w]})
			var max_error := Vector4.ZERO
			for step in 30:
				var points := PackedVector3Array()
				for i in 84: points.append(Vector3(-110.0+i*3.1+step*0.75,0.0,-80+float(i%17)*9.4))
				for n in 2: natives[n].build_dynamic_physics_lite(step/60.0,[PackedInt32Array([128,128,128]),PackedInt32Array([128,128,64])][n])
				for mode in [0,1]:
					var a: PackedVector4Array = natives[0].sample_dynamic_lite_local_sea_batch(points,mode,Vector2.ONE,1.0)
					var b: PackedVector4Array = natives[1].sample_dynamic_lite_local_sea_batch(points,mode,Vector2.ONE,1.0)
					for i in mini(a.size(),b.size()):
						for axis in 4: max_error[axis] = maxf(max_error[axis],absf(a[i][axis]-b[i][axis]))
			report.resolution_experiment.append({"slot":slot,"chop_scale":chop,"max_error_h_sx_sz_vy":[max_error.x,max_error.y,max_error.z,max_error.w],"adopted":false})
	report.failures = failures
	DirAccess.make_dir_recursive_absolute("res://temp/local_sea_audit")
	var file := FileAccess.open("res://temp/local_sea_audit/phase3_native.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("LOCAL_SEA_NATIVE ",JSON.stringify({"field_cases":report.field_builds.size(),"query_cases":report.queries.size(),"failures":failures}))
	host.free()
	quit(0 if failures.is_empty() else 1)
