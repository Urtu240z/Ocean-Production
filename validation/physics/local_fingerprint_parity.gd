extends SceneTree
const Reference = preload("res://validation/fixtures/local_fingerprint_reference.gd")
const CustomSettings = preload("res://validation/fixtures/local_fingerprint_custom_settings.gd")
const CustomBand = preload("res://validation/fixtures/local_fingerprint_custom_band.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(settings: Resource, profile: Resource, label: String) -> void:
	for seed in [0,7,2147483647]:
		checks += 1
		var a := Reference.values(settings,profile,seed)
		var b: Array = settings.fingerprint_values(profile,seed)
		if var_to_bytes(a) != var_to_bytes(b) or hash(a) != settings.fingerprint(profile,seed):
			failures.append(label+" seed="+str(seed)+" reference="+str(a)+" candidate="+str(b))

func mutate(resource: Resource, settings: Resource, profile: Resource, label: String) -> void:
	for property in resource.get_property_list():
		if not property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE: continue
		var original: Variant = resource.get(property.name)
		var value: Variant = original
		if original is float: value = original+0.137
		elif original is int: value = original+1
		elif original is Vector2: value = original+Vector2(0.1,0.2)
		elif original is String: value = original+" parity"
		else: continue
		resource.set(property.name,value)
		check(settings,profile,label+"."+str(property.name))
		resource.set(property.name,original)

func benchmark(settings: Resource, profile: Resource) -> Array:
	var rows := []
	# Four alternating blocks; each call includes live input reads and hashing.
	for variant in ["A","B","B","A"]:
		var durations := PackedInt64Array()
		var checksum := 0
		for iteration in range(-32,1000):
			var started := Time.get_ticks_usec()
			for _slot in 2:
				checksum ^= Reference.fingerprint(settings,profile,7) if variant == "A" else settings.fingerprint(profile,7)
			if iteration >= 0: durations.append(Time.get_ticks_usec()-started)
		var total := 0
		for duration in durations: total += duration
		durations.sort()
		rows.append({"variant":variant,"calls_per_iteration":2,"iterations":durations.size(),
			"mean_us":float(total)/durations.size(),"p50_us":durations[500],"p95_us":durations[950],"checksum":checksum})
	return rows

func run() -> void:
	var profile: Resource = load("res://addons/ocean/presets/ocean_production/wave_profile.tres").duplicate(true)
	var settings := OceanLocalSeaState.new()
	check(settings,profile,"base")
	mutate(settings,settings,profile,"settings")
	mutate(profile,settings,profile,"profile")
	for name in ["long_band","mid_band","short_band"]:
		var band: Resource = profile.get(name)
		mutate(band,settings,profile,name)
		profile.set(name,null)
		check(settings,profile,name+" null")
		profile.set(name,CustomBand.new())
		check(settings,profile,name+" custom")
		profile.set(name,band)
	settings.wave_profile = profile
	check(settings,profile,"explicit profile")
	check(CustomSettings.new(),profile,"custom settings")
	var custom := CustomSettings.new()
	custom.custom_spectrum_setting = 2.75
	check(custom,profile,"custom settings hot edit")
	var report := {"checks":checks,"failures":failures,"same_tick_mutations":true,"microbench":benchmark(settings,profile)}
	DirAccess.make_dir_recursive_absolute("res://temp/native_performance_2")
	var output := "res://temp/native_performance_2/fingerprint_parity.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	var file := FileAccess.open(output,FileAccess.WRITE)
	file.store_string(JSON.stringify(report)); file.close()
	print("NP2_FINGERPRINT checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
