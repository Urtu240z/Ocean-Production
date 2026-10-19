@tool
extends RefCounted
## One shared production FFT spectrum, without another surface/reflections/VFX.
const SpectrumState = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
const Generation = preload("res://addons/ocean/fft/gpu_resource_generation.gd")
const Solver = preload("res://addons/ocean/fft/gpu_stockham_fft.gd")
var metrics: RefCounted
var metric_slot := 0
var settings: Resource
var generation: RefCounted
var solvers: Array = []
var textures: Array[Texture2DRD] = []
var normals: Array[Texture2DRD] = []
var configs: Array = []
var spectrum: Dictionary = {}
var native: Object
var signature := 0
var ready := false
var time_s := 0.0
var _last_clock := NAN
var _last_dispatch := -INF
var _field_time := -INF
var build_count := 0
var cpu_build_us := 0
var gpu_us := 0.0
var profile_gpu := false
var _timestamp_frame := -1
var _mutex := Mutex.new()
var _prefix := ""
var _query_positions := PackedVector3Array()
var _resolutions := PackedInt32Array([128,128,128])
var _interpolation_modes := PackedInt32Array([1,1,1])
var _empty_points := PackedVector3Array()
var _empty_ranges := PackedVector2Array()
var _native_batch_supported := false

func configure(next: Resource, host: Node3D, slot: int) -> void:
	var profile: Resource = next.wave_profile if next.wave_profile != null else host.get("wave_profile")
	if profile == null: return
	var fingerprint: int = next.fingerprint(profile,int(host.get("simulation_seed")))
	settings = next
	if fingerprint == signature and generation != null: return
	shutdown()
	signature = fingerprint
	configs = profile.build_fft_configs(next.significant_wave_height_m if next.sea_state_mode == 1 else -1.0,
		next.wind_speed_mps,next.wind_direction_degrees,next.swell,next.long_wave_spacing)
	for config in configs: config.choppiness *= next.choppiness_scale
	# This native builder is already used by production weather. It produces the
	# same final H0 bytes consumed by both Stockham and the CPU contact field.
	if ClassDB.class_exists("OceanQueryNative"): native = ClassDB.instantiate("OceanQueryNative")
	spectrum = SpectrumState.build(configs,int(host.get("simulation_seed")),
		next.significant_wave_height_m if next.sea_state_mode == 1 else -1.0,
		profile.combined_significant_wave_height_m(),next.wave_height_scale,
		[next.long_band_scale,next.mid_band_scale,next.short_band_scale],next.mid_fill_amount,7,native)
	if spectrum.is_empty(): return
	if native != null:
		native.call("set_sea_level",0.0)
		native.call("set_gameplay_min_wavelength_m",0.0)
		if not native.call("set_production_spectrum",spectrum.bands): native = null
	_native_batch_supported = native != null and native.has_method("sample_dynamic_lite_local_sea_batch")
	build_count += 1
	generation = Generation.new(build_count)
	_prefix = "Ocean.LocalFFT.%d.%d" % [host.get_instance_id(),slot]
	RenderingServer.call_on_render_thread(generation.create_neutral_resources)
	for band in 3:
		var solver: RefCounted = Solver.new()
		solvers.append(solver)
		textures.append(Texture2DRD.new())
		normals.append(Texture2DRD.new())
		RenderingServer.call_on_render_thread(generation.initialize_solver.bind(solver,configs[band],spectrum.bands[band].h0_rgba32f,_prefix+".%d"%band,[]))

func advance(clock: float) -> void:
	if generation == null: return
	if Engine.is_editor_hint() or is_nan(_last_clock):
		time_s = clock*settings.wave_speed_multiplier
	else:
		time_s += maxf(clock-_last_clock,0.0)*settings.wave_speed_multiplier
	_last_clock = clock
	if not is_equal_approx(time_s,_last_dispatch):
		RenderingServer.call_on_render_thread(_dispatch.bind(generation,solvers.duplicate(),time_s,profile_gpu))
		_last_dispatch = time_s
	ready = true
	for band in solvers.size():
		var state: Dictionary = solvers[band].get_publication_snapshot()
		if not state.get("ready",false):
			ready = false
			break
		textures[band].texture_rd_rid = state.displacement_rid
		normals[band].texture_rd_rid = state.normal_rid

func _dispatch(token: RefCounted, owned_solvers: Array, time: float, capture: bool) -> void:
	if not token.is_active(): return
	var rd := RenderingServer.get_rendering_device()
	if capture:
		if rd.get_captured_timestamps_frame() != _timestamp_frame:
			_timestamp_frame = rd.get_captured_timestamps_frame()
			var start := 0
			for i in rd.get_captured_timestamps_count():
				var label := rd.get_captured_timestamp_name(i)
				if label == _prefix+".begin": start = rd.get_captured_timestamp_gpu_time(i)
				elif label == _prefix+".end" and start > 0:
					_mutex.lock()
					gpu_us = float(rd.get_captured_timestamp_gpu_time(i)-start)/1000.0
					_mutex.unlock()
		rd.capture_timestamp(_prefix+".begin")
	for solver in owned_solvers: solver.dispatch(time,0.0)
	if capture: rd.capture_timestamp(_prefix+".end")

func sample(points: PackedVector3Array, clock: float, displaced: bool) -> PackedVector4Array:
	var measured: bool = metrics != null and metrics.enabled
	var start := Time.get_ticks_usec() if measured else 0
	var result := _sample(points, clock, displaced)
	if measured:
		metrics.record(StringName("slot%d.sample"%metric_slot), Time.get_ticks_usec()-start)
		metrics.record(StringName("slot%d.sample_contacts"%metric_slot), 0, points.size())
	return result

func _sample(points: PackedVector3Array, clock: float, displaced: bool) -> PackedVector4Array:
	var result := PackedVector4Array()
	if native == null: return result
	var time: float = clock*settings.wave_speed_multiplier if Engine.is_editor_hint() or is_nan(_last_clock) else time_s+(clock-_last_clock)*settings.wave_speed_multiplier
	if not is_equal_approx(time,_field_time):
		var start := Time.get_ticks_usec()
		if not native.call("build_dynamic_physics_lite",time,_resolutions): return result
		cpu_build_us = Time.get_ticks_usec()-start
		if metrics != null and metrics.enabled:
			metrics.record(StringName("slot%d.build_128_128_128"%metric_slot), cpu_build_us)
		_field_time = time
	if _native_batch_supported:
		var query_start := Time.get_ticks_usec() if metrics != null and metrics.enabled else 0
		var values: PackedVector4Array = native.call("sample_dynamic_lite_local_sea_batch",points,
			1 if displaced else 0,Vector2(settings.clipmap_geometry_scale,settings.ocean_scale),settings.wave_speed_multiplier)
		if metrics != null and metrics.enabled:
			metrics.record(StringName("slot%d.native_query"%metric_slot),Time.get_ticks_usec()-query_start)
			metrics.record(StringName("slot%d.native_positions"%metric_slot),0,points.size()*5)
		return values
	# Centre and neighbours use the same production displacement inversion as
	# the native provider. Normals include ocean-space scales and local chop.
	_query_positions.resize(points.size()*5)
	const E := 0.1
	for i in points.size():
		var p := points[i]
		_query_positions[i*5] = p
		_query_positions[i*5+1] = p+Vector3(E,0,0)
		_query_positions[i*5+2] = p-Vector3(E,0,0)
		_query_positions[i*5+3] = p+Vector3(0,0,E)
		_query_positions[i*5+4] = p-Vector3(0,0,E)
	var query_start := Time.get_ticks_usec() if metrics != null and metrics.enabled else 0
	var packed: PackedFloat64Array = native.call("sample_dynamic_lite_surface_queries",_query_positions,
		_interpolation_modes,1 if displaced else 0,Vector3.ONE,_empty_points,Vector2.ZERO,
		Vector2(settings.clipmap_geometry_scale,settings.ocean_scale),_empty_ranges)
	if metrics != null and metrics.enabled:
		metrics.record(StringName("slot%d.native_query"%metric_slot), Time.get_ticks_usec()-query_start)
		metrics.record(StringName("slot%d.native_positions"%metric_slot), 0, _query_positions.size())
	if packed.size() != 1+_query_positions.size()*13: return result
	result.resize(points.size())
	for i in points.size():
		var row := 1+i*5*13
		if packed[row] < 0.5: return PackedVector4Array()
		result[i] = Vector4(packed[row+1],(packed[row+14]-packed[row+27])/(2*E),
			(packed[row+40]-packed[row+53])/(2*E),packed[row+2]*settings.wave_speed_multiplier)
	return result

func shutdown() -> void:
	ready = false
	for texture in textures+normals: texture.texture_rd_rid = RID()
	textures.clear()
	normals.clear()
	if generation != null:
		generation.retire()
		for solver in solvers: RenderingServer.call_on_render_thread(solver.shutdown)
		RenderingServer.call_on_render_thread(generation.shutdown_gpu)
	generation = null
	solvers.clear()
	native = null
	_native_batch_supported = false
	_last_dispatch = -INF
	_field_time = -INF
