extends SceneTree
## Promote the saved playground/vehicle authoring values into portable addon defaults.
const SOURCE := "res://validation/hull_wave_physics_playground.tscn"
const JET := "res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn"
const DEST := "res://addons/ocean/presets/hull_wave_playground/"
const BOW := "res://addons/jet_ski/common/visual/bow_spray/bow_spray.tscn"
const MANIFEST := "res://validation/reports/addon_saved_defaults_2026_10_18.json"
var mode := "audit"
var failures: Array[String] = []
var copies := {}

func portable_script_path(path: String) -> String:
	if path.begins_with("res://validation/p4_paradise/"):
		return path.replace("res://validation/p4_paradise/","res://addons/ocean/coastal/resources/")
	return path

func check(ok: bool,label: String) -> void:
	if not ok:
		failures.append(label)
		push_error("SAVED_DEFAULTS: "+label)

func fingerprint(value: Variant) -> Variant:
	if value is Script: return {"script":portable_script_path(value.resource_path)}
	if typeof(value)>=TYPE_PACKED_BYTE_ARRAY:
		return {"type":typeof(value),"size":value.size(),"sha256":var_to_bytes(value).hex_encode().sha256_text()}
	if value is Resource:
		var data := {}
		for property in value.get_property_list():
			var name := str(property.name)
			if (int(property.usage)&PROPERTY_USAGE_STORAGE)==0 or name in ["resource_path","resource_scene_unique_id"]: continue
			data[name]=fingerprint(value.get(name))
		return {"class":value.get_class(),"properties":data}
	if value is Array:
		var result: Array=[]
		for item in value: result.append(fingerprint(item))
		return {"array_type":value.get_typed_builtin(),"values":result}
	if value is Dictionary:
		var result := {}
		for key in value: result[str(key)]=fingerprint(value[key])
		return result
	return {"type":typeof(value),"value":var_to_str(value)}

func clone_value(value: Variant,force_resource := false) -> Variant:
	if value is Script:
		var path := portable_script_path(value.resource_path)
		check(path.begins_with("res://addons/"),"portable script: "+path)
		return value if path==value.resource_path else load(path)
	if value is Resource:
		var path: String=value.resource_path
		if not force_resource and path.begins_with("res://addons/") and not path.contains("::"): return value
		if copies.has(value.get_instance_id()): return copies[value.get_instance_id()]
		if value is Mesh:
			var mesh: Resource=value.duplicate(true)
			copies[value.get_instance_id()]=mesh
			return mesh
		if value is Texture2D and not value is NoiseTexture2D and not value is GradientTexture1D and not value is GradientTexture2D and not path.is_empty() and not path.contains("::"):
			if path.begins_with("res://addons/"): return value
			var target := DEST+"assets/"+path.md5_text().left(10)+"_"+path.get_file()
			DirAccess.make_dir_recursive_absolute(target.get_base_dir())
			check(DirAccess.copy_absolute(path,target)==OK,"copy asset "+path)
			var relocated := load(target)
			copies[value.get_instance_id()]=relocated
			return relocated
		var copy: Resource=value.duplicate(false)
		copies[value.get_instance_id()]=copy
		for property in value.get_property_list():
			var name := str(property.name)
			if (int(property.usage)&PROPERTY_USAGE_STORAGE)==0 or name in ["resource_path","resource_scene_unique_id"]: continue
			copy.set(name,clone_value(value.get(name)))
		return copy
	if value is Array:
		var result: Array=value.duplicate()
		for i in result.size(): result[i]=clone_value(value[i])
		return result
	if value is Dictionary:
		var result: Dictionary=value.duplicate()
		for key in result: result[key]=clone_value(value[key])
		return result
	return value

func clone_tree(source: Node,owner_root: Node=null) -> Node:
	var node: Node=ClassDB.instantiate(source.get_class())
	node.name=source.name
	if source.get_script()!=null: node.set_script(source.get_script())
	for property in source.get_property_list():
		var name := str(property.name)
		if (int(property.usage)&PROPERTY_USAGE_STORAGE)==0 or name in ["name","owner","script","scene_file_path","unique_name_in_owner"]: continue
		var value: Variant=source.get(name)
		if value is Node or value is Callable: continue
		node.set(name,clone_value(value))
	for child in source.get_children():
		var copy := clone_tree(child,owner_root if owner_root!=null else node)
		node.add_child(copy)
		copy.owner=owner_root if owner_root!=null else node
	return node

func save_scene(node: Node,path: String) -> void:
	var packed := PackedScene.new()
	check(packed.pack(node)==OK,"pack "+path)
	check(ResourceSaver.save(packed,path)==OK,"save "+path)

func save_default_resource(value: Resource,path: String) -> void:
	var previous_uid := ResourceLoader.get_resource_uid(path)
	check(ResourceSaver.save(value,path)==OK,"save default resource "+path)
	if previous_uid!=ResourceUID.INVALID_ID:
		check(ResourceSaver.set_uid(path,previous_uid)==OK,"preserve resource UID "+path)

func tree_values(node: Node) -> Dictionary:
	var nodes := {}
	var queue: Array[Node]=[node]
	while not queue.is_empty():
		var item: Node=queue.pop_front()
		var properties := {}
		for property in item.get_property_list():
			var name := str(property.name)
			if (int(property.usage)&PROPERTY_USAGE_STORAGE)==0 or name in ["name","owner","scene_file_path","unique_name_in_owner"]: continue
			var value: Variant=item.get(name)
			if value is Node or value is Callable: continue
			properties[name]=fingerprint(value)
		nodes[str(node.get_path_to(item))]=properties
		for child in item.get_children(): queue.append(child)
	return nodes

func verify() -> void:
	var data: Dictionary=normalize_json(JSON.parse_string(FileAccess.get_file_as_string(MANIFEST)))
	var default_ocean: Node=load("res://addons/ocean/ocean.tscn").instantiate()
	var actual := author_properties(default_ocean)
	for name in data.ocean:
		check(fingerprint(actual.get(name))==data.ocean[name],"exact Ocean default: "+name)
	var source: Node=load(SOURCE).instantiate()
	var source_ocean: Node=source.get_node("JetSkiOcean/Production/Ocean")
	for name in data.ocean:
		check(fingerprint(source_ocean.get(name))==data.ocean[name],"saved playground unchanged: "+name)
	var jet: Node=load(JET).instantiate()
	check(tree_values(jet)==data.jet,"exact saved Jet Ski tree")
	var bow: Node=load(BOW).instantiate()
	check(tree_values(bow)==data.bow,"exact default BowSprayRoot tree")
	check(tree_values(jet.get_node("BowSprayRoot"))==data.bow,"Jet Ski and component defaults agree")
	default_ocean.free()
	source.free()
	jet.free()
	bow.free()
	print("SAVED_DEFAULTS_VERIFY ",JSON.stringify({"passed":failures.is_empty(),"failures":failures,"ocean_properties":data.ocean.size(),"bow_nodes":data.bow.size()}))
	quit(0 if failures.is_empty() else 1)

func normalize_json(value: Variant) -> Variant:
	# Fingerprints store actual numeric author values as strings; JSON numbers
	# here are only integer type/count metadata, parsed by Godot as floats.
	if value is float: return int(value)
	if value is Dictionary:
		for key in value: value[key]=normalize_json(value[key])
	elif value is Array:
		for index in value.size(): value[index]=normalize_json(value[index])
	return value

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="): mode=arg.get_slice("=",1)
	run.call_deferred()

func author_properties(node: Node) -> Dictionary:
	var result := {}
	for property in node.get_property_list():
		var usage := int(property.usage)
		var name := str(property.name)
		if (usage & PROPERTY_USAGE_STORAGE)==0 or (usage & PROPERTY_USAGE_SCRIPT_VARIABLE)==0 or name=="script": continue
		var value: Variant=node.get(name)
		if value is Node or value is Callable: continue
		result[name]=value
	return result

func run() -> void:
	if mode=="verify":
		verify()
		return
	var world: Node=load(SOURCE).instantiate()
	var ocean: Node=world.get_node("JetSkiOcean/Production/Ocean")
	var jet: Node=load(JET).instantiate()
	var values := author_properties(ocean)
	var resources := {}
	for key in values:
		if values[key] is Resource: resources[key]=values[key].resource_path
	var bow: Node=jet.get_node("BowSprayRoot")
	print("DEFAULTS_AUDIT ",JSON.stringify({"ocean_properties":values.size(),"resources":resources,"bow_properties":author_properties(bow).size(),"bow_children":bow.get_children().map(func(child): return str(child.name)),"ocean_wind":ocean.get("wind_speed_mps"),"ocean_foam":ocean.get("foam_emission"),"left_amount":bow.get_node("SternMist").amount,"left_lifetime":bow.get_node("SternMist").lifetime,"right_amount":bow.get_node("SternMistRight").amount,"right_lifetime":bow.get_node("SternMistRight").lifetime}))
	if mode=="freeze":
		DirAccess.make_dir_recursive_absolute(DEST)
		var omitted := {}
		if not bool(values.get("coastal",false)) and values.get("coastal_bake")!=null:
			omitted["coastal_bake"]={"path":values.coastal_bake.resource_path,"reason":"Inactive legacy island bake; source remains saved in repository and is not a portable runtime default."}
			values.erase("coastal_bake")
		var expected := {}
		for key in values: expected[key]=fingerprint(values[key])
		var jet_expected := tree_values(jet)
		var bow_expected := tree_values(bow)
		var destination: Node=ClassDB.instantiate("Node3D")
		destination.name="Ocean"
		destination.set_script(ocean.get_script())
		for key in values:
			var value: Variant=values[key]
			if value is Resource:
				var copy: Resource=clone_value(value,true)
				var path := DEST+str(key)+".tres"
				check(ResourceSaver.save(copy,path)==OK,"save portable profile "+str(key))
				copy.take_over_path(path)
				destination.set(key,copy)
			else: destination.set(key,value)
		for key in values:
			if fingerprint(destination.get(key))!=fingerprint(values[key]):
				check(false,"promoted Ocean author value: "+str(key))
		save_scene(destination,DEST+"ocean.tscn")
		save_scene(destination,"res://addons/ocean/ocean.tscn")
		for entry in [["hull_foam_settings","res://addons/ocean/surface/foam2d/default_style.tres"],["wave_profile","res://addons/ocean/resources/default_wave_profile.tres"],["quality_profile","res://addons/ocean/resources/default_quality_profile.tres"]]:
			save_default_resource(destination.get(entry[0]),entry[1])
		var settings: Resource=bow.get("hull_spray_settings")
		for entry in [[settings,"default_style.tres"],[settings.get("splash_appearance"),"splash_appearance.tres"],[settings.get("tail_appearance"),"tail_appearance.tres"],[settings.get("stern_mist"),"stern_mist_style.tres"]]:
			save_default_resource(entry[0],"res://addons/jet_ski/common/visual/hull_spray/"+entry[1])
		var new_bow := clone_tree(bow)
		check(tree_values(new_bow)==bow_expected,"rebuilt component matches author values")
		save_scene(new_bow,BOW)
		var lighting := Node3D.new()
		lighting.name="PlaygroundLightingReference"
		var production: Node=world.get_node("JetSkiOcean/Production")
		for label in ["WorldEnvironment","Sun"]:
			var original := production.get_node_or_null(label)
			if original!=null:
				var copy := clone_tree(original)
				lighting.add_child(copy)
				copy.owner=lighting
		save_scene(lighting,DEST+"lighting_reference.tscn")
		var file := FileAccess.open(MANIFEST,FileAccess.WRITE)
		file.store_string(JSON.stringify({"source_scene":SOURCE,"source_vehicle":JET,"ocean":expected,"jet":jet_expected,"bow":bow_expected,"inactive_preserved_in_source":omitted},"\t"))
		file.close()
		destination.free()
		new_bow.free()
		lighting.free()
		print("SAVED_DEFAULTS_FREEZE ",JSON.stringify({"passed":failures.is_empty(),"failures":failures,"ocean_properties":expected.size(),"bow_nodes":bow_expected.size()}))
	world.free()
	jet.free()
	quit(0 if failures.is_empty() else 1)
