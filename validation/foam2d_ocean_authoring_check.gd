extends SceneTree

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var scene: Node = load("res://validation/foam2d_playground.tscn").instantiate()
	var ocean: Ocean = scene.get_node("JetSkiOcean/Production/Ocean")
	var original := ocean.get_hull_foam_settings()
	var saved_width: float = original.initial_width_m
	var saved_running: bool = original.running_enabled
	var saved_deformation: bool = original.deformation_enabled
	# Never save the shared user preset from an automated test.
	ocean.hull_foam_settings = original.duplicate(true)
	var names: Array[String] = []
	var groups: Array[String] = []
	for entry in ocean.get_property_list():
		if str(entry.name).begins_with("foam_"): names.append(entry.name)
		if entry.usage & PROPERTY_USAGE_GROUP: groups.append(entry.name)
	for group in ["Hull Foam","Running Foam","Hull Waves"]:
		assert(groups.count(group) == 1,"Missing or duplicate authoring group: "+group)
	for key in ["initial_width_m","lifetime_s","outward_speed","water_tint","running_enabled","deformation_enabled","wake_wave_height_m","impact_wave_height_m","wake_wave_rise_s","wake_wave_fade_s","wake_wave_response_s","impact_wave_rise_s","impact_wave_fade_s","wake_wave_speed_mps","impact_wave_speed_mps"]:
		assert(names.has("foam_"+key),"Missing Ocean control "+key)
	assert(names.has("foam_wake_opening_degrees") and names.has("foam_enabled"))
	assert(names.has("foam_wake_wave_birth_distance_m"))
	assert(names.has("foam_wake_update_hz") and names.has("foam_wake_emission_forward_m"))
	for key in ["wave_physics_enabled","wave_physics_self_delay_s","wave_physics_self_radius_m","wave_physics_max_vertical_speed_mps"]:
		assert(names.has("foam_"+key),"Missing physical hull wave control "+key)
	for key in ["relief_enabled","relief_height_m","relief_detail_size_m","relief_cavity_strength","relief_roughness","relief_specular"]:
		assert(names.has("foam_"+key),"Missing white foam relief control "+key)
	ocean.set("foam_relief_height_m",0.036)
	ocean.set("foam_relief_detail_size_m",0.24)
	ocean.set("foam_relief_cavity_strength",0.42)
	ocean.set("foam_relief_roughness",0.84)
	ocean.set("foam_relief_specular",0.12)
	var speed_values := {"low_speed_white_strength":0.24,"high_speed_white_strength":1.35,"white_low_speed_kmh":4.0,"white_high_speed_kmh":42.0}
	for key in speed_values:
		assert(names.has("foam_"+key),"Missing speed whitening control "+key)
		ocean.set("foam_"+key,speed_values[key])
	var pattern_values:={"white_patch_strength":0.72,"white_patch_size_m":2.2}
	pattern_values.merge({"fresh_wake_strength":1.25,"fresh_wake_settling_s":1.1})
	for key in pattern_values:
		assert(names.has("foam_"+key),"Missing white pocket control "+key)
		ocean.set("foam_"+key,pattern_values[key])
	# Constructor defaults stay opt-in; preserve an artist's saved preset choice.
	assert(not load("res://addons/ocean/surface/foam2d/foam2d_style.gd").new().wave_physics_enabled)
	ocean.set("foam_wave_physics_enabled",true)
	var saved_mode: String=ocean.get("foam_mode")
	for reference in ["original","f1f2"]:
		ocean.set("foam_mode",reference)
		assert(not ocean._hull_waves_requested(),"Historical comparison included new physical waves")
	ocean.set("foam_mode",saved_mode)
	ocean.set("foam_wave_physics_self_delay_s",1.1)
	var cadence_entry: Dictionary = ocean.get_property_list().filter(func(item): return item.name == "foam_wake_update_hz")[0]
	assert(cadence_entry.hint == PROPERTY_HINT_ENUM and cadence_entry.hint_string == "20 Hz:20,30 Hz:30,60 Hz:60")
	for hz in [20,30,60]:
		ocean.set("foam_wake_update_hz",hz)
		assert(ocean.get("foam_wake_update_hz") == hz)
	ocean.set("foam_wake_update_hz",30)
	ocean.set("foam_wake_emission_forward_m",0.25)
	var saved_duration: float = ocean.get("foam_wake_wave_duration_s")
	ocean.set("foam_wake_wave_speed_mps",2.75)
	assert(is_equal_approx(ocean.get("foam_wake_wave_duration_s"),saved_duration),"Speed changed duration")
	assert(ocean.get("foam_running_enabled") == saved_running,"User's reinforcement setting was reset")
	assert(ocean.get("foam_deformation_enabled") == saved_deformation,"User's wave setting was reset")
	var before: Dictionary = ocean.get_hull_foam_settings().shader_parameters()
	ocean.set("foam_initial_width_m",1.2)
	ocean.set("foam_lifetime_s",12.0)
	ocean.set("foam_wake_opening_degrees",12.0)
	assert(is_equal_approx(ocean.get("foam_wake_opening_degrees"),12.0))
	assert(ocean.get_hull_foam_settings().shape_parameters().is_equal_approx(Vector2(1.2,12.0)))
	assert(ocean.get_hull_foam_settings().shader_parameters() == before)
	var other := Ocean.new()
	assert(other.get_hull_foam_settings() != ocean.get_hull_foam_settings(),"Independent Ocean settings leaked")
	other.free()
	for key in ["deformation_max_height_m","wake_wave_height_m","impact_wave_height_m"]:
		var entry: Dictionary = ocean.get_property_list().filter(func(item): return item.name == "foam_"+key)[0]
		assert(float(str(entry.hint_string).split(",")[1]) >= 2.0,"Height export excludes 2 m: "+key)
		ocean.set("foam_"+key,2.0)
	# Round-trip the real nested authoring scene, including inherited Ocean.
	ocean.set("foam_relief_enabled",false)
	ocean.set("foam_fresh_wake_enabled",false)
	var packed := PackedScene.new()
	assert(packed.pack(scene) == OK)
	DirAccess.make_dir_recursive_absolute("res://temp/foam2d/ocean_controls")
	var path := "res://temp/foam2d/ocean_controls/authoring_roundtrip.tscn"
	assert(ResourceSaver.save(packed,path) == OK)
	var restored: Node = ResourceLoader.load(path,"",ResourceLoader.CACHE_MODE_IGNORE).instantiate()
	var restored_ocean: Ocean = restored.get_node("JetSkiOcean/Production/Ocean")
	assert(is_equal_approx(restored_ocean.get("foam_initial_width_m"),1.2))
	assert(restored_ocean.get("foam_wake_update_hz") == 30)
	assert(is_equal_approx(restored_ocean.get("foam_wake_emission_forward_m"),0.25))
	assert(is_equal_approx(restored_ocean.get("foam_lifetime_s"),12.0))
	assert(is_equal_approx(restored_ocean.get("foam_wake_opening_degrees"),12.0))
	assert(is_equal_approx(restored_ocean.get("foam_wake_wave_speed_mps"),2.75),"Wave movement speed did not round-trip")
	assert(restored_ocean.get("foam_wave_physics_enabled"))
	assert(not restored_ocean.get("foam_relief_enabled"),"Disabled relief state did not round-trip")
	assert(not restored_ocean.get("foam_fresh_wake_enabled"),"Disabled fresh wake state did not round-trip")
	for key in speed_values:
		assert(is_equal_approx(restored_ocean.get("foam_"+key),speed_values[key]),"Speed whitening control did not round-trip: "+key)
	for key in pattern_values:
		assert(is_equal_approx(restored_ocean.get("foam_"+key),pattern_values[key]),"White pocket control did not round-trip: "+key)
	for pair in [["relief_height_m",0.036],["relief_detail_size_m",0.24],["relief_cavity_strength",0.42],["relief_roughness",0.84],["relief_specular",0.12]]:
		assert(is_equal_approx(restored_ocean.get("foam_"+pair[0]),pair[1]),"Relief control did not round-trip")
	assert(is_equal_approx(restored_ocean.get("foam_wave_physics_self_delay_s"),1.1))
	assert(restored_ocean.get("foam_running_enabled") == saved_running and restored_ocean.get("foam_deformation_enabled") == saved_deformation)
	for key in ["deformation_max_height_m","wake_wave_height_m","impact_wave_height_m"]: assert(is_equal_approx(restored_ocean.get("foam_"+key),2.0))
	assert(is_equal_approx(original.initial_width_m,saved_width),"Saved user resource was mutated")
	scene.free()
	restored.free()
	print("FOAM2D_OCEAN_AUTHORING_PASS controls=",names.size()," roundtrip=true independent_oceans=true disabled_states_preserved=true")
	quit()
