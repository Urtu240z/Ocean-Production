extends "res://validation/local_sea_native_audit.gd"
const Runtime = preload("res://addons/ocean/areas/ocean_wave_area_runtime.gd")
const BaseRuntime = preload("res://validation/fixtures/local_sea_base/wave_area_runtime.gd")
class ReferenceState extends "res://validation/fixtures/local_sea_base/local_fft_state.gd":
	var contact_count := 0
	func sample(points: PackedVector3Array, clock: float, displaced: bool) -> PackedVector4Array:
		contact_count += points.size()
		return super.sample(points,clock,displaced)
func make_samples(points: PackedVector3Array) -> Array:
	var result: Array = []
	for p in points:
		var sample := WaterSample3D.new()
		sample.valid = true
		sample.surface_position = p
		sample.normal = Vector3.UP
		result.append(sample)
	return result
func run() -> void:
	var host: Node3D = load("res://addons/ocean/ocean.tscn").instantiate()
	var builder: Object = ClassDB.instantiate("OceanQueryNative")
	var actual := Runtime.new()
	var reference := BaseRuntime.new()
	actual.time_s = 3.0
	reference.time_s = 3.0
	actual.displaced = true
	reference.displaced = true
	for slot in 2:
		var settings: Resource = host.local_sea_state_1 if slot==0 else host.local_sea_state_2
		var profile: Resource = host.wave_profile
		var configs: Array = profile.build_fft_configs(-1.0,settings.wind_speed_mps,settings.wind_direction_degrees,settings.swell,settings.long_wave_spacing)
		var spectrum := Spectrum.build(configs,host.simulation_seed,-1.0,profile.combined_significant_wave_height_m(),settings.wave_height_scale,
			[settings.long_band_scale,settings.mid_band_scale,settings.short_band_scale],settings.mid_fill_amount,7,builder)
		var native: Object = ClassDB.instantiate("OceanQueryNative")
		native.set_gameplay_min_wavelength_m(0.0)
		check(native.set_production_spectrum(spectrum.bands),"subset spectrum")
		check(native.build_dynamic_physics_lite(3.0,PackedInt32Array([128,128,128])),"subset field")
		var a := LocalFFT.new()
		var b := ReferenceState.new()
		for state in [a,b]:
			state.native = native
			state.settings = settings
			state.time_s = 3.0
			state._last_clock = 3.0
			state._field_time = 3.0
		a._native_batch_supported = true
		a.metrics = actual.metrics
		a.metric_slot = slot
		actual.states[slot] = a
		reference.states[slot] = b
		var entry := {"inverse":Transform3D(Basis.IDENTITY,Vector3(slot*400.0,0,0)).affine_inverse(),
			"shape":Vector4(75,20,50,0),"blend":Vector4(15,1,1,0),"meta":Vector4(slot,1,1,100),"detail_strength":1.0}
		actual.entries.append(entry)
		reference.entries.append(entry.duplicate(true))
	var results: Array = []
	for count in [14,56,84]:
		var points := PackedVector3Array()
		for i in count: points.append(Vector3((i%2)*400.0+float(i%3)*0.2,0,float(i%7)*0.3))
		var a := make_samples(points)
		var b := make_samples(points)
		actual.metrics.clear()
		actual.metrics.enabled = true
		for state in reference.states: state.contact_count = 0
		actual.apply(a,points,1.0)
		reference.apply(b,points,1.0)
		actual.metrics.enabled = false
		var tick: Dictionary = actual.metrics.ticks[Engine.get_physics_frames()]
		var selected := [tick[&"slot0.sample_contacts"].x,tick[&"slot1.sample_contacts"].x]
		var error := 0.0
		for i in count:
			error = maxf(error,absf(a[i].surface_position.y-b[i].surface_position.y))
			error = maxf(error,a[i].normal.distance_to(b[i].normal))
			error = maxf(error,absf(a[i].velocity.y-b[i].velocity.y))
		check(error<=0.00001,"subset reconstruction parity")
		check(selected[0]==count/2 and selected[1]==count/2,"positive contact union")
		var base_counts := [reference.states[0].contact_count,reference.states[1].contact_count]
		for i in 30:
			actual.apply(a,points,1.0)
			reference.apply(b,points,1.0)
		var times := [[],[]]
		for i in 240:
			for index in ([0,1] if i%2==0 else [1,0]):
				var at := Time.get_ticks_usec()
				if index==0: reference.apply(b,points,1.0)
				else: actual.apply(a,points,1.0)
				times[index].append((Time.get_ticks_usec()-at)/1000.0)
		results.append({"input_contacts":count,"base_queried_per_slot":base_counts,"optimized_queried_per_slot":selected,
			"base_apply_ms":stats(times[0]),"optimized_apply_ms":stats(times[1]),"max_error":error})
	DirAccess.make_dir_recursive_absolute("res://temp/local_sea_audit")
	FileAccess.open("res://temp/local_sea_audit/phase5_subset.json",FileAccess.WRITE).store_string(JSON.stringify({"cases":results,"failures":failures},"\t"))
	print("LOCAL_SEA_SUBSET ",JSON.stringify({"cases":results,"failures":failures}))
	actual.shutdown()
	reference.shutdown()
	host.free()
	quit(0 if failures.is_empty() else 1)
