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
	assert(restored_ocean.get("foam_running_enabled") == saved_running and restored_ocean.get("foam_deformation_enabled") == saved_deformation)
	for key in ["deformation_max_height_m","wake_wave_height_m","impact_wave_height_m"]: assert(is_equal_approx(restored_ocean.get("foam_"+key),2.0))
	assert(is_equal_approx(original.initial_width_m,saved_width),"Saved user resource was mutated")
	scene.free()
	restored.free()
	print("FOAM2D_OCEAN_AUTHORING_PASS controls=",names.size()," roundtrip=true independent_oceans=true disabled_states_preserved=true")
	quit()
