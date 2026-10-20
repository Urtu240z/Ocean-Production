extends SceneTree
const Spectrum = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label)

func run() -> void:
	var host: Node3D = load("res://addons/ocean/ocean.tscn").instantiate()
	var builder: Object = ClassDB.instantiate("OceanQueryNative")
	var points := PackedVector3Array()
	for i in 24: points.append(Vector3(i*13.713-120,1.5,i*-7.919+60))
	var resolutions := PackedInt32Array([128,128,128])
	var cubic := PackedInt32Array([1,1,1])
	for mode in [1,2]:
		for slot in 2:
			var settings: Resource = host.get("local_sea_state_1" if slot == 0 else "local_sea_state_2")
			var profile: Resource = host.get("wave_profile")
			var configs: Array = profile.build_fft_configs(-1.0,settings.wind_speed_mps,settings.wind_direction_degrees,settings.swell,settings.long_wave_spacing)
			for config in configs: config.choppiness *= settings.choppiness_scale
			var source: Dictionary = Spectrum.build(configs,int(host.get("simulation_seed")),-1.0,
				profile.combined_significant_wave_height_m(),settings.wave_height_scale,
				[settings.long_band_scale,settings.mid_band_scale,settings.short_band_scale],settings.mid_fill_amount,7,builder)
			var sync: Object = ClassDB.instantiate("OceanQueryNative")
			var async_native: Object = ClassDB.instantiate("OceanQueryNative")
			check(sync.call("set_production_spectrum",source.bands),"sync spectrum")
			check(async_native.call("set_production_spectrum",source.bands),"async spectrum")
			check(async_native.call("set_dynamic_lite_execution_mode",mode),"mode")
			var time := 0.0
			for tick in 32:
				if tick != 12: time += settings.wave_speed_multiplier/60.0
				if tick == 20: time = 0.25
				check(sync.call("build_dynamic_physics_lite",time,resolutions),"sync build")
				check(async_native.call("consume_dynamic_lite",tick,time,resolutions),"async consume")
				for query_mode in [0,1]:
					var a: PackedFloat64Array = sync.call("sample_dynamic_lite_surface_queries",points,cubic,query_mode,Vector3.ONE,PackedVector3Array(),Vector2.ZERO,Vector2.ONE,PackedVector2Array())
					var b: PackedFloat64Array = async_native.call("sample_dynamic_lite_surface_queries",points,cubic,query_mode,Vector3.ONE,PackedVector3Array(),Vector2.ZERO,Vector2.ONE,PackedVector2Array())
					check(a.size() == b.size() and a.size() == 1+points.size()*13,"query shape")
					for i in range(1,mini(a.size(),b.size())):
						check(a[i] == b[i],"mode %d slot %d tick %d query %d value %d"%[mode,slot,tick,query_mode,i])
						checks += 1
				var a: PackedVector4Array = sync.call("sample_dynamic_lite_local_sea_batch",points,1,Vector2.ONE,settings.wave_speed_multiplier)
				var b: PackedVector4Array = async_native.call("sample_dynamic_lite_local_sea_batch",points,1,Vector2.ONE,settings.wave_speed_multiplier)
				check(a == b,"local sea displaced height/normal/velocity")
				var stats: Dictionary = async_native.call("get_dynamic_lite_async_stats")
				check(stats.tick == tick and stats.time == time,"exact snapshot key")
				check(async_native.call("request_dynamic_lite",tick+1,time+settings.wave_speed_multiplier/60.0,resolutions),"prediction")
			check(async_native.call("set_dynamic_lite_execution_mode",0),"rollback mode")
			# Re-import H0 at the same resolution while a speculative job exists.
			check(async_native.call("set_dynamic_lite_execution_mode",mode),"hot enable")
			check(async_native.call("request_dynamic_lite",100,10.0,resolutions),"pre-change job")
			async_native.call("clear")
			check(async_native.call("set_production_spectrum",source.bands),"hot spectrum")
			check(async_native.call("consume_dynamic_lite",101,0.0,resolutions),"post-change field")
			# The original same-lattice H0 import retains phase recurrence. Verify
			# that retiring a forecast does not introduce a phase reinitialization.
			var replacement: Array = source.bands.duplicate(true)
			for band in replacement:
				band.h0_rgba32f = builder.call("scale_production_h0",band.h0_rgba32f,1.125)
			sync.call("clear")
			check(sync.call("set_production_spectrum",source.bands),"hot reference source")
			check(sync.call("build_dynamic_physics_lite",0.0,resolutions),"hot reference reset")
			for step in 9:
				check(sync.call("build_dynamic_physics_lite",step*0.01,resolutions),"hot reference phase")
				check(async_native.call("consume_dynamic_lite",102+step,step*0.01,resolutions),"hot async phase")
			var next_time := 0.09
			check(async_native.call("request_dynamic_lite",111,next_time,resolutions),"hot forecast")
			for target in [sync,async_native]:
				target.call("clear")
				check(target.call("set_production_spectrum",replacement),"replacement H0")
			check(sync.call("build_dynamic_physics_lite",next_time,resolutions),"replacement baseline")
			check(async_native.call("consume_dynamic_lite",111,next_time,resolutions),"replacement async")
			var hot_a: PackedVector4Array = sync.call("sample_dynamic_lite_local_sea_batch",points,1,Vector2.ONE,settings.wave_speed_multiplier)
			var hot_b: PackedVector4Array = async_native.call("sample_dynamic_lite_local_sea_batch",points,1,Vector2.ONE,settings.wave_speed_multiplier)
			check(hot_a == hot_b,"same-lattice hot H0 parity")
			var hot_raw_a: PackedFloat64Array = sync.call("sample_dynamic_lite_surface_queries",points,cubic,1,Vector3.ONE,PackedVector3Array(),Vector2.ZERO,Vector2.ONE,PackedVector2Array())
			var hot_raw_b: PackedFloat64Array = async_native.call("sample_dynamic_lite_surface_queries",points,cubic,1,Vector3.ONE,PackedVector3Array(),Vector2.ZERO,Vector2.ONE,PackedVector2Array())
			check(hot_raw_a.size() == hot_raw_b.size(),"hot raw shape")
			for i in range(1,mini(hot_raw_a.size(),hot_raw_b.size())):
				check(hot_raw_a[i] == hot_raw_b[i],"hot raw double parity")
				checks += 1
			async_native.call("set_dynamic_lite_execution_mode",0)
			sync = null
			async_native = null
	# A newly created/reconfigured local resource must inherit the effective
	# shared mode before it can answer a query. Retiring the provider must also
	# release leases retained by local objects and invalidate their field cache.
	var owner_provider := CpuFftWaterProvider.new()
	host.set("_cpu_water_provider",owner_provider)
	for mode in [1,2]:
		var local_state := preload("res://addons/ocean/areas/ocean_local_fft_state.gd").new()
		var settings: Resource = host.get("local_sea_state_1")
		local_state.configure_physics_only(settings,host)
		var main_native: Object = ClassDB.instantiate("OceanQueryNative")
		check(main_native.call("set_production_spectrum",local_state.spectrum.bands),"epoch source")
		owner_provider.native = main_native
		check(main_native.call("set_dynamic_lite_execution_mode",mode),"epoch root mode")
		local_state.shutdown()
		local_state.configure_physics_only(settings,host)
		check(local_state.native.call("get_dynamic_lite_execution_mode") == mode,"local inherits effective root mode")
		check(main_native.call("get_dynamic_worker_count") == (3 if mode == 1 else 4),"epoch global worker cap")
		check(local_state.consume_physics_tick(Engine.get_physics_frames(),0.5),"epoch complete local snapshot")
		var scheduler := preload("res://addons/ocean/physics/water/async_fft_physics_driver.gd").new()
		scheduler.configure(owner_provider)
		scheduler.set("_runtime",RefCounted.new())
		scheduler.set("_states",[local_state,null])
		scheduler.retire_for_reconfigure()
		check(main_native.call("get_dynamic_lite_execution_mode") == 0,"root epoch retired")
		check(local_state.native.call("get_dynamic_lite_execution_mode") == 0,"local epoch retired")
		check(local_state.get("_field_time") == -INF,"retired field metadata invalidated")
		local_state.shutdown()
		scheduler.free()
	owner_provider.free()
	host.free()
	print("ASYNC_INTEGRATION ",JSON.stringify({"exact_query_values":checks,"failures":failures}))
	quit(0 if failures.is_empty() else 1)
