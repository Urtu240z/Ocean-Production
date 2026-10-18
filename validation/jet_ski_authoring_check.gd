extends SceneTree
const Rules:=preload("res://addons/jet_ski/editor/authoring_rules.gd")

func _initialize() -> void:
	run.call_deferred()

func snapshot(node: Node) -> Dictionary:
	var values: Dictionary={}
	for property in node.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.usage & PROPERTY_USAGE_STORAGE:
			values[property.name]=node.get(property.name)
	return values

func check_help(folder: String) -> int:
	var count:=0
	for child in DirAccess.get_directories_at(folder): count+=check_help(folder.path_join(child))
	for file in DirAccess.get_files_at(folder):
		if not file.ends_with(".gd"): continue
		var path:=folder.path_join(file)
		var lines:=FileAccess.get_file_as_string(path).split("\n")
		for index in lines.size():
			var line:=lines[index].strip_edges()
			if not line.begins_with("@export"): continue
			if line.begins_with("@export_group") or line.begins_with("@export_subgroup") or line.begins_with("@export_category") or line.begins_with("@export_storage"): continue
			assert(index>0 and lines[index-1].strip_edges().begins_with("##"),"Missing Inspector help: "+path+":"+str(index+1))
			count+=1
	return count

func run() -> void:
	var help_count:=check_help("res://addons/jet_ski")
	assert(help_count==441,"Unexpected editable property coverage")
	var scene: PackedScene=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn")
	var ski: Node=scene.instantiate()
	var original:=snapshot(ski)
	var normal_count:=0
	var total_count:=0
	for entry in ski.get_property_list():
		if not entry.usage & PROPERTY_USAGE_SCRIPT_VARIABLE or not entry.usage & PROPERTY_USAGE_EDITOR: continue
		total_count+=1
		if Rules.visible(ski,entry.name): normal_count+=1
	assert(ski.drive_mode==2,"Default driving preset changed")
	assert(not ski.show_legacy_settings)
	assert(not Rules.visible(ski.get_node("ProductionSetup"),"stabilized_angular_mode",true))
	for key in ["buoyancy_mode","hull_response_mode","heavy_pitch_inertia_multiplier","buoyancy_strength_per_point","wet_pitch_damping"]:
		assert(not Rules.visible(ski,key,true),"All-mode view leaked Legacy setting: "+key)
	var group: String=""
	for property in ski.get_property_list():
		if property.usage & PROPERTY_USAGE_GROUP: group=property.name
		if property.name in ["buoyancy_mode","hull_response_mode","heavy_pitch_inertia_multiplier","buoyancy_strength_per_point","wet_pitch_damping"]:
			assert(group=="Legacy","Legacy property is mixed into standard physics")
		if property.name=="hull_v1_bow_braking_mps2": assert(group=="Buoyancy Physics")
	assert(not Rules.visible(ski,"buoyancy_strength_per_point"))
	assert(not Rules.visible(ski,"heavy_pitch_inertia_multiplier"))
	assert(not Rules.visible(ski,"forward_engine_force"))
	assert(Rules.visible(ski,"hull_v1_bow_braking_mps2"))
	assert(Rules.visible(ski,"nose_up_max_angle_degrees"))
	assert(snapshot(ski)==original,"Filtering changed serialized values")
	ski.drive_mode=0
	assert(Rules.visible(ski,"forward_engine_force"))
	ski.drive_mode=2
	ski.show_legacy_settings=true
	for entry in ski.get_property_list():
		if entry.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and entry.usage & PROPERTY_USAGE_EDITOR:
			assert(Rules.visible(ski,entry.name,true),"Explicit all-mode/Legacy view removed "+str(entry.name))
	ski.hull_response_mode=1
	assert(Rules.visible(ski,"heavy_pitch_inertia_multiplier"))
	assert(not Rules.visible(ski,"hull_v1_arcade_enabled"))
	assert(not Rules.visible(ski,"powered_trim_enabled"))
	assert(Rules.visible(ski,"nose_up_limit_enabled"),"Global pitch limit was hidden in Heavy mode")
	ski.buoyancy_mode=0
	assert(Rules.visible(ski,"buoyancy_strength_per_point"))
	assert(not Rules.visible(ski,"hull_response_mode"))
	assert(not Rules.visible(ski,"heavy_pitch_inertia_multiplier"))
	var setup:=ski.get_node("ProductionSetup")
	setup.water_race_mode=false
	assert(not Rules.visible(ski,"buoyancy_strength_per_point"))
	assert(Rules.visible(ski,"buoyancy_damping_full_depth_m"))
	var water:=ski.get_node("Systems/WaterPhysicsSystem")
	assert(Rules.visible(water,"equilibrium_depth"))
	assert(Rules.visible(water,"damping_ratio"))
	setup.water_race_mode=true
	assert(not Rules.visible(water,"equilibrium_depth"))
	assert(not Rules.visible(water,"damping_ratio"))
	ski.buoyancy_mode=1
	ski.hull_response_mode=0
	assert(Rules.visible(water,"damping_ratio"))
	setup.stabilized_angular_mode=false
	ski.buoyancy_mode=0
	assert(not Rules.visible(ski,"wet_pitch_damping"))
	setup.stabilized_angular_mode=true
	ski.buoyancy_mode=1
	var handling:=ski.get_node("ArcadeHandling")
	ski.use_arcade_turn_continuity=false
	assert(not Rules.visible(handling,"use_effective_water_contact"))
	ski.use_arcade_turn_continuity=true
	assert(Rules.visible(handling,"use_effective_water_contact"))
	handling.use_yaw_rate_controller=false
	assert(not Rules.visible(handling,"maximum_desired_yaw_rate"))
	handling.use_yaw_rate_controller=true
	ski.use_arcade_turn_continuity=original.use_arcade_turn_continuity
	# Revert test edits before serialization, and preserve all old mode values.
	for key in original: ski.set(key,original[key])
	assert(snapshot(ski)==original)
	var packed:=PackedScene.new()
	assert(packed.pack(ski)==OK)
	DirAccess.make_dir_recursive_absolute("res://temp/jet_ski_authoring")
	var path: String="res://temp/jet_ski_authoring/roundtrip.tscn"
	assert(ResourceSaver.save(packed,path)==OK)
	var restored: Node=ResourceLoader.load(path,"",ResourceLoader.CACHE_MODE_IGNORE).instantiate()
	assert(snapshot(restored)==original,"Save/load changed a root setting")
	for node in [ski.get_node("BowSprayRoot"),ski.get_node("BowSprayRoot").get("splash_settings")]:
		var retired: Array=node.get_property_list().filter(func(p):return p.name=="droplets_atlas")
		assert(retired.size()==1 and not retired[0].usage & PROPERTY_USAGE_EDITOR and retired[0].usage & PROPERTY_USAGE_STORAGE)
	assert(not water.get_property_list().filter(func(p):return p.name=="buoyancy_draft_offset_m")[0].usage & PROPERTY_USAGE_EDITOR)
	print("JET_SKI_AUTHORING_PASS total=",total_count," active_normal=",normal_count,
		" documented_exports=",help_count," mode_filters=true custom_engine=true roundtrip=true saved_values_preserved=true")
	ski.free()
	restored.free()
	quit()
