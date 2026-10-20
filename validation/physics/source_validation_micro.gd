extends SceneTree
const Reference = preload("res://validation/fixtures/source_validation_reference_provider.gd")
var failures: Array[String] = []
var checks := 0
var host: Ocean
var field: OpenOceanFFT
var surface: Node3D
var original: CpuFftWaterProvider
var candidate: CpuFftWaterProvider

func _initialize() -> void: call_deferred("run")
func check(ok: bool,label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func setup(provider: CpuFftWaterProvider) -> void:
	host.set("_open_ocean",field)
	host.set("_physics_source_status","OK"); host.set("_physics_source_revision",2)
	host.set("_initializing",false); host.set("_rebuild_requested",false); host.set("_rebuild_debounce_remaining",-1.0)
	host.enabled = true; host.open_ocean_fft = true; host.sea_level = 0.0
	field.set("_surface",surface); field.set("_surface_initialized",true); field.set("_phys2_spectrum_generation",7)
	var space: RefCounted = field.get("_ocean_space")
	space.ocean_scale = 1.0; space.clipmap_geometry_scale = 1.0; space.revision = 4
	provider.ocean_root = host; provider.fft = field; provider.native = RefCounted.new()
	provider.field_ready = true; provider.water_sync_status = "OK"; provider.water_sync_reason = ""
	provider.set("_source_match_supported",true)
	provider.set("_failed_spectrum_key","")
	provider.set("_synced_fft_instance_id",field.get_instance_id())
	provider.set("_synced_ocean_revision",2); provider.set("_last_fft_spectrum_generation",7)
	provider.set("_synced_ocean_space_revision",4)
	provider.ocean_height_scale = 1.0; provider.ocean_horizontal_scale = 1.0; provider.sea_level = 0.0
func stats(values: PackedInt64Array) -> Dictionary:
	var sorted := values.duplicate(); sorted.sort()
	var sum := 0.0
	for v in values: sum += v
	return {"n":values.size(),"mean_ms":sum/values.size()/1000.0,"p50_ms":sorted[int(values.size()*.5)]/1000.0,
		"p95_ms":sorted[int(values.size()*.95)]/1000.0,"p99_ms":sorted[int(values.size()*.99)]/1000.0}
func bench(provider: CpuFftWaterProvider, boats: int,label: String) -> Dictionary:
	setup(provider)
	var times := PackedInt64Array()
	for iteration in range(-64,800):
		var started := Time.get_ticks_usec()
		for i in boats*19:
			assert(provider._is_water_source_current())
		if iteration >= 0: times.append(Time.get_ticks_usec()-started)
	return {"label":label,"boats":boats,"metrics":stats(times)}
func run() -> void:
	host = Ocean.new(); field = OpenOceanFFT.new(); surface = Node3D.new()
	original = Reference.new(); candidate = CpuFftWaterProvider.new()
	var scenarios := ["unchanged","status","rebuilding","initializing","debounce","disabled","fft_disabled",
		"source","revision","spectrum","space_revision","vertical","horizontal","sea_level",
		"invalid_vertical","invalid_horizontal","infinite_scale","surface","failed_spectrum","failed_field","native_missing","fft_missing"]
	var tick := Engine.get_physics_frames()
	for scenario in scenarios:
		var outputs := []
		for provider in [original,candidate]:
			setup(provider)
			var space: RefCounted = field.get("_ocean_space")
			match scenario:
				"status": host.set("_physics_source_status","ERROR")
				"rebuilding": host.set("_rebuild_requested",true)
				"initializing": host.set("_initializing",true)
				"debounce": host.set("_rebuild_debounce_remaining",.1)
				"disabled": host.enabled = false
				"fft_disabled": host.open_ocean_fft = false
				"source": provider.set("_synced_fft_instance_id",-1)
				"revision": host.set("_physics_source_revision",3)
				"spectrum": field.set("_phys2_spectrum_generation",8)
				"space_revision": space.revision = 5
				"vertical": space.ocean_scale = 1.2
				"horizontal": space.clipmap_geometry_scale = 1.2
				"sea_level": host.sea_level = .3
				"invalid_vertical": space.ocean_scale = NAN
				"invalid_horizontal": space.clipmap_geometry_scale = -1.0
				"infinite_scale": space.ocean_scale = INF; provider.ocean_height_scale = INF
				"surface": field.set("_surface_initialized",false)
				"failed_spectrum": provider.set("_failed_spectrum_key","%d:2:7"%field.get_instance_id())
				"failed_field": provider.field_ready = false
				"native_missing": provider.native = null
				"fft_missing": provider.fft = null
			var valid: bool = provider._is_water_source_current()
			outputs.append([valid,provider.water_sync_status,provider.water_sync_reason,provider.field_ready,
				provider.get("_contact_reset_epoch"),provider.fft == null])
			check(valid == (scenario == "unchanged"),scenario+" validity")
		check(var_to_bytes(outputs[0]) == var_to_bytes(outputs[1]),scenario+" exact state and effects")
	check(Engine.get_physics_frames() == tick,"all hot changes inside one tick")
	var results := []
	for boats in [1,6]:
		for label in ["A1","B1","B2","A2"]:
			results.append(bench(original if label.begins_with("A") else candidate,boats,label))
	var report := {"checks":checks,"failures":failures,"benchmarks":results,"validations_per_boat":19}
	DirAccess.make_dir_recursive_absolute("res://temp/scaling_2")
	var output := FileAccess.open("res://temp/scaling_2/source_micro.json",FileAccess.WRITE)
	output.store_string(JSON.stringify(report,"\t")); output.close()
	print("SOURCE_VALIDATION ",JSON.stringify(report))
	original.free(); candidate.free(); surface.free(); field.free(); host.free()
	quit(0 if failures.is_empty() else 1)
