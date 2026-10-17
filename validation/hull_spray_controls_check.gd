extends SceneTree

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var scene: Node=load("res://validation/foam2d_playground.tscn").instantiate()
	root.add_child(scene)
	for frame in 900:
		await process_frame
		if scene.find_child("AjustesSalpicaduras",true,false)!=null: break
	var controls: Control=scene.get_node("AjustesSalpicaduras") if scene.has_node("AjustesSalpicaduras") else scene.find_child("AjustesSalpicaduras",true,false)
	assert(controls!=null)
	var ski: Node=scene.get_foam_runtime().vehicles[0]
	var spray: Node=ski.get_node("BowSprayRoot/HullSprays")
	assert(spray._slots.size()==4 and spray._tail!=null)
	assert(ski.has_node("BowSprayRoot"))
	var original: Resource=spray.settings
	var style: Resource=original.duplicate(true)
	style.take_over_path("res://temp/hull_spray/saved_test_style.tres")
	spray.configure_settings(style)
	controls.style=style
	var bow: Node=ski.get_node("BowSprayRoot")
	for anchor in ["SplashLeft","SplashRight","TailJet"]: assert(bow.has_node(anchor))
	assert(not ski.has_node("HullSprayRoot"))
	var exported := 0
	var in_bow := false
	var categories: Array[String]=[]
	for property in bow.get_script().get_script_property_list():
		if (property.usage&PROPERTY_USAGE_CATEGORY)!=0:
			if property.name in ["Bow Spray","Splash","Tail Jet"]: categories.append(property.name)
			in_bow=property.name=="Bow Spray"
			continue
		if not in_bow: continue
		if (property.usage&PROPERTY_USAGE_EDITOR)==0 or (property.usage&PROPERTY_USAGE_STORAGE)==0: continue
		if property.name in ["hull_spray_settings","bow_spray_enabled","contact_build_seconds","contact_initial_scale"]: continue
		assert(property.name in style.splash_appearance,"Missing appearance control: "+property.name)
		exported+=1
	assert(exported>60)
	assert(categories==["Bow Spray","Splash","Tail Jet"])
	assert(spray._tail_material.shader==bow._materials[0].shader)
	assert(not bool(bow._materials[0].get_shader_parameter("anchored_sprite_mode")))
	assert(bool(spray._tail_material.get_shader_parameter("anchored_sprite_mode")))
	style.elevation_degrees=0.0
	for slot in spray._slots:
		assert(is_zero_approx(slot.material.get_shader_parameter("splash_elevation_angle")))
	style.elevation_degrees=5.0
	for slot in spray._slots:
		assert(is_equal_approx(slot.material.get_shader_parameter("splash_elevation_angle"),deg_to_rad(5.0)))
	var bow_color: Color=bow.spray_tint
	var side_color: Color=style.splash_appearance.spray_tint
	style.tail_appearance.spray_tint=Color(0.2,0.7,1.0)
	style.tail_appearance.water_roughness=0.31
	style.tail_appearance.foam_opacity=0.24
	style.tail_appearance.edge_softness=0.23
	assert(spray._tail_material.get_shader_parameter("spray_color")==style.tail_appearance.spray_tint)
	assert(is_equal_approx(spray._tail_material.get_shader_parameter("water_roughness"),0.31))
	assert(is_equal_approx(spray._tail_material.get_shader_parameter("foam_opacity"),0.24))
	assert(is_equal_approx(spray._tail_material.get_shader_parameter("edge_softness"),0.23))
	assert(style.splash_appearance.spray_tint==side_color and bow.spray_tint==bow_color)
	var shared_mesh: ArrayMesh=spray._tail.mesh
	style.tail_appearance.volume_layers=5
	assert(spray._tail.mesh.surface_get_array_len(0)==5*17*13)
	style.tail_appearance.volume_layers=2
	assert(spray._tail.mesh==shared_mesh)
	# Pause the PNG phase while independent distortion/normal clocks keep moving.
	spray.set_process(false)
	style.tail_appearance.preview_in_editor=true
	style.tail_enabled=false
	style.tail_appearance.preview_speed=25.0
	style.tail_appearance.anim_fps=0.0
	var frame_before: float=spray._tail_frame
	var normal_before: float=spray._clocks[1].normal
	spray._preview(0.2)
	assert(spray._tail.visible,"Editor preview incorrectly depends on runtime emission")
	assert(is_equal_approx(spray._tail_frame,frame_before))
	assert(spray._clocks[1].normal>normal_before)
	style.tail_appearance.anim_fps=12.0
	spray._preview(0.2)
	assert(spray._tail_frame>frame_before)
	style.tail_appearance.preview_in_editor=false
	style.splash_appearance.preview_in_editor=false
	style.tail_enabled=true
	spray._preview(0.0)
	spray.set_process(true)
	var atlas_ids := {}
	for cycle in 12:
		for variant in 2:
			controls.variant.select(variant)
			controls.variant.item_selected.emit(variant)
			await process_frame
			var texture: Texture2D=spray._tail_material.get_shader_parameter("flipbook_texture")
			assert(spray._active_variant==variant+3)
			assert(int(spray._tail_material.get_shader_parameter("flipbook_frames"))==(48 if variant==0 else 24))
			if atlas_ids.has(variant): assert(atlas_ids[variant]==texture.get_rid())
			atlas_ids[variant]=texture.get_rid()
	assert(spray._atlases.size()==3,"Switching variants created extra atlases")
	for slot in spray._slots: assert(slot.sheet.mesh==spray._slots[0].sheet.mesh)
	assert(spray._tail.mesh!=spray._slots[0].sheet.mesh)
	style.sides_enabled=false
	style.tail_enabled=false
	for frame in 8: await process_frame
	assert(not spray._tail.visible)
	for slot in spray._slots: assert(not slot.sheet.visible)
	style.sides_enabled=true
	style.tail_enabled=true
	style.tail_variant=1
	assert(ResourceSaver.save(style,style.resource_path)==OK)
	var loaded: Resource=ResourceLoader.load(style.resource_path,"",ResourceLoader.CACHE_MODE_IGNORE)
	assert(loaded.tail_variant==1 and loaded.sides_enabled and loaded.tail_enabled)
	assert(is_equal_approx(loaded.tail_appearance.anim_fps,12.0))
	assert(loaded.tail_appearance.spray_tint==Color(0.2,0.7,1.0))
	# Save/reload the node itself: the three sections retain separate values.
	var preview_node: Node=load("res://addons/jet_ski/common/visual/bow_spray/bow_spray.tscn").instantiate()
	preview_node.hull_spray_settings=style.duplicate(true)
	preview_node.anim_fps=26.7
	preview_node.splash_preview_in_editor=false
	preview_node.tail_preview_in_editor=true
	preview_node.tail_preview_speed=25.0
	preview_node.tail_variant=1
	preview_node.splash_elevation_degrees=7.5
	preview_node.tail_turn_response=3.5
	preview_node.tail_roundness=0.92
	preview_node.tail_downward_curve=0.6
	preview_node.splash_sustained_rate_hz=8.0
	preview_node.splash_burst_lifetime=0.22
	preview_node.tail_residual_seconds=0.42
	preview_node.tail_residual_strength=0.7
	preview_node.contact_build_seconds=0.28
	assert(preview_node.preview_in_editor==false)
	assert(preview_node.splash_settings!=preview_node.tail_settings)
	var packed := PackedScene.new()
	assert(packed.pack(preview_node)==OK)
	assert(ResourceSaver.save(packed,"res://temp/hull_spray/three_sections_roundtrip.tscn")==OK)
	preview_node.free()
	var saved: PackedScene=ResourceLoader.load("res://temp/hull_spray/three_sections_roundtrip.tscn","",ResourceLoader.CACHE_MODE_IGNORE)
	var restored: Node=saved.instantiate()
	assert(is_equal_approx(restored.anim_fps,26.7))
	assert(not restored.splash_preview_in_editor and restored.tail_preview_in_editor)
	assert(is_equal_approx(restored.tail_preview_speed,25.0) and restored.tail_variant==1)
	assert(is_equal_approx(restored.splash_elevation_degrees,7.5))
	assert(is_equal_approx(restored.tail_turn_response,3.5))
	assert(is_equal_approx(restored.tail_roundness,0.92))
	assert(is_equal_approx(restored.tail_downward_curve,0.6))
	assert(is_equal_approx(restored.splash_sustained_rate_hz,8.0))
	assert(is_equal_approx(restored.splash_burst_lifetime,0.22))
	assert(is_equal_approx(restored.tail_residual_seconds,0.42))
	assert(is_equal_approx(restored.tail_residual_strength,0.7))
	assert(is_equal_approx(restored.contact_build_seconds,0.28))
	restored.free()
	var open_button: Button=controls.get_node("AbrirSalpicaduras")
	var close_button: Button=controls.panel.find_child("CerrarSalpicaduras",true,false)
	assert(not controls.panel.visible)
	open_button.pressed.emit()
	assert(controls.panel.visible)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://temp/hull_spray/controls.png")
	close_button.pressed.emit()
	assert(not controls.panel.visible)
	open_button.pressed.emit()
	assert(controls.panel.visible)
	open_button.pressed.emit()
	assert(not controls.panel.visible)
	spray.configure_settings(original)
	FileAccess.open("res://temp/hull_spray/controls_report.json",FileAccess.WRITE).store_string(JSON.stringify({
		"passed":true,"variant_switches":24,"cached_atlases":3,"shared_static_mesh":true,
		"save_reload":true,"open_close_buttons":true,"bow_spray_preserved":true,
		"matching_export_controls":exported,"shared_bow_shader":true,"independent_profiles":true,
		"live_material_updates":true,"paused_png_independent_clocks":true,"mesh_layer_cache":true,
		"inspector_sections":categories,"node_save_reload":true,"tail_preview_without_throttle":true,
		"lateral_elevation_export":true},"\t"))
	print("HULL_SPRAY_CONTROLS_PASS switches=24 cached_atlases=3 save_reload=true")
	await scene.get_child(0)._close_gracefully()
