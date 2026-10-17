extends SceneTree

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var scene: Node = load("res://validation/foam2d_playground.tscn").instantiate()
	root.add_child(scene)
	for frame in 900:
		await process_frame
		if scene.get_foam_runtime() != null and scene.get_foam_runtime().history != null: break
	assert(scene.get_foam_runtime() != null)
	for frame in 120: await process_frame
	var ski: Node = scene.get_foam_runtime().vehicles[0]
	var retired_fx: Node = ski.get_node("WaterContactFx")
	assert(retired_fx.get_child_count() == 0, "Retired ring or placeholder particles were created")
	assert(not retired_fx.is_processing())
	assert(ski.has_node("BowSprayRoot"), "The original bow spray must remain")
	var controls: Control = scene.find_child("AjustesEspuma",true,false)
	assert(controls != null and controls.widgets.size() == 41)
	var style: Resource = controls.style
	var before: Dictionary = style.shader_parameters()
	var before_motion: Vector3 = style.motion_parameters()
	var before_edges: Vector2 = style.edge_parameters()
	var before_outward: Vector2 = style.outward_parameters()
	var before_shape: Vector2 = style.shape_parameters()
	controls.widgets.initial_width_m.value = 1.15
	controls.widgets.lifetime_s.value = 11.0
	assert(scene.get_foam_runtime().history.get("_shape").is_equal_approx(Vector2(1.15,11.0)))
	var running_before: Resource = style.duplicate()
	controls.widgets.running_strength.value = 2.25
	controls.widgets.running_roughness.value = 0.81
	controls.widgets.running_specular.value = 0.12
	controls.widgets.running_color.color_changed.emit(Color(0.94,0.98,1.0,1.0))
	controls.widgets.running_full_kmh.value = 45.0
	controls.widgets.running_enabled.button_pressed = false
	assert(not style.running_enabled and is_equal_approx(style.running_strength,2.25))
	controls.widgets.running_enabled.button_pressed = true
	assert(style.running_enabled)
	for parameter in before:
		if not str(parameter).begins_with("foam2d_running_"):
			assert(style.shader_parameters()[parameter] == before[parameter],"Running controls changed existing foam")
	assert(style.history_parameters() == running_before.history_parameters())
	controls.widgets.calm_foam_strength.value = 1.21
	controls.widgets.roughness.value = 0.73
	controls.widgets.specular.value = 0.37
	controls.widgets.wake_opening_degrees.value = 6.0
	assert(is_equal_approx(style.get_wake_opening_degrees(),6.0))
	controls.widgets.motion_strength.value = 0.31
	controls.widgets.motion_speed.value = 0.85
	controls.widgets.edge_irregularity.value = 0.41
	controls.widgets.edge_fade.value = 0.63
	controls.widgets.outward_speed.value = 0.95
	controls.widgets.impact_outward_boost.value = 1.85
	assert(scene.get_foam_runtime().history.get("_outward").is_equal_approx(Vector2(0.95,1.85)))
	assert(scene.get_foam_runtime().history.get("_edges").is_equal_approx(Vector2(0.41,0.63)))
	controls.widgets.filament_deformation.value = 0.57
	controls.widgets.filament_speed.value = 1.15
	controls.widgets.water_tint.color_changed.emit(Color(0.12,0.48,0.62,1))
	assert(is_equal_approx(style.calm_foam_strength,1.21))
	assert(director_motion(controls).is_equal_approx(Vector3(style.wake_spread,0.31,0.85)))
	var director: Node = scene.get_foam_runtime()
	var checks := 0
	for material: ShaderMaterial in director.surface.get("_variant_materials").values():
		assert(is_equal_approx(material.get_shader_parameter("foam2d_calm_strength"),1.21))
		assert(is_equal_approx(material.get_shader_parameter("foam2d_roughness"),0.73))
		assert(is_equal_approx(material.get_shader_parameter("foam2d_specular"),0.37))
		assert(is_equal_approx(material.get_shader_parameter("foam2d_filament_deformation"),0.57))
		assert(is_equal_approx(material.get_shader_parameter("foam2d_filament_speed"),1.15))
		assert(is_equal_approx(material.get_shader_parameter("foam2d_running_strength"),2.25))
		assert(is_equal_approx(material.get_shader_parameter("foam2d_running_roughness"),0.81))
		assert(is_equal_approx(material.get_shader_parameter("foam2d_running_specular"),0.12))
		checks += 5
	style.calm_foam_strength = before.foam2d_calm_strength
	style.roughness = before.foam2d_roughness
	style.specular = before.foam2d_specular
	style.water_tint = before.foam2d_water_tint
	style.wake_spread = before_motion.x
	style.motion_strength = before_motion.y
	style.motion_speed = before_motion.z
	style.edge_irregularity = before_edges.x
	style.edge_fade = before_edges.y
	style.outward_speed = before_outward.x
	style.impact_outward_boost = before_outward.y
	style.filament_deformation = before.foam2d_filament_deformation
	style.filament_speed = before.foam2d_filament_speed
	style.initial_width_m = before_shape.x
	style.lifetime_s = before_shape.y
	controls.widgets.calm_foam_strength.value = style.calm_foam_strength
	controls.widgets.roughness.value = style.roughness
	controls.widgets.specular.value = style.specular
	controls.widgets.water_tint.color = style.water_tint
	controls.widgets.wake_opening_degrees.set_value_no_signal(style.get_wake_opening_degrees())
	controls.widgets.motion_strength.value = style.motion_strength
	controls.widgets.motion_speed.value = style.motion_speed
	controls.widgets.edge_irregularity.value = style.edge_irregularity
	controls.widgets.edge_fade.value = style.edge_fade
	controls.widgets.outward_speed.value = style.outward_speed
	controls.widgets.impact_outward_boost.value = style.impact_outward_boost
	controls.widgets.filament_deformation.value = style.filament_deformation
	controls.widgets.filament_speed.value = style.filament_speed
	# Exercise the same F7 path the user uses, without selecting runtime particles.
	var event := InputEventKey.new()
	event.keycode = KEY_F7
	event.pressed = true
	controls._unhandled_key_input(event)
	assert(controls.panel.visible)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://temp/foam2d/revision4_controls.png")
	controls._unhandled_key_input(event)
	assert(not controls.panel.visible)
	# Save through the real button path, using a disposable resource file.
	var saved_style: Resource = style.duplicate()
	var saved_path := "res://temp/foam2d/revision4_saved_style.tres"
	saved_style.take_over_path(saved_path)
	controls.style = saved_style
	controls._save()
	var reloaded: Resource = ResourceLoader.load(saved_path,"",ResourceLoader.CACHE_MODE_IGNORE)
	assert(reloaded != null and is_equal_approx(reloaded.calm_foam_strength,style.calm_foam_strength))
	assert(is_equal_approx(reloaded.roughness,style.roughness))
	controls.style = style
	assert(reloaded.motion_parameters().is_equal_approx(style.motion_parameters()))
	assert(reloaded.edge_parameters().is_equal_approx(style.edge_parameters()))
	assert(reloaded.outward_parameters().is_equal_approx(style.outward_parameters()))
	assert(is_equal_approx(reloaded.filament_deformation,style.filament_deformation))
	assert(is_equal_approx(reloaded.filament_speed,style.filament_speed))
	assert(is_equal_approx(reloaded.running_strength,2.25) and is_equal_approx(reloaded.running_full_kmh,45.0))
	assert(reloaded.running_color.is_equal_approx(style.running_color))
	for key in controls.widgets:
		if str(key).begins_with("running_"): style.set(key,running_before.get(key))
	print("FOAM2D_CONTROLS_PASS widgets=41 live_material_checks=",checks," save_reload=passed running_independent=true retired_visuals=0 bow_spray=preserved")
	await scene.get_child(0)._close_gracefully()

func director_motion(controls: Control) -> Vector3:
	return controls.get_tree().root.find_child("HullFoam",true,false).history.get("_motion")
