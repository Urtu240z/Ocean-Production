extends SceneTree

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var scene: Node=load("res://validation/foam2d_playground.tscn").instantiate()
	root.add_child(scene)
	for frame in 900:
		await process_frame
		if scene.find_child("AjustesSalpicaduras",true,false)!=null: break
	var ski: JetSkiController=scene.get_foam_runtime().vehicles[0]
	ski.freeze=true
	var bow: Node=ski.get_node("BowSprayRoot")
	var spray: Node=bow.get_node("HullSprays")
	bow.set_process(false)
	spray.set_process(false)
	var style: Resource=spray.settings.duplicate(true)
	style.sides_enabled=true
	style.tail_enabled=true
	style.tail_appearance.enabled=true
	style.splash_appearance.enabled=true
	style.sustained_rate_hz=6.0
	spray.configure_settings(style)
	var water: Node=ski.water_physics_system
	water._point_sample_valid.fill(true)
	water._point_depths.fill(0.15)
	water._point_relative_normal_speeds.fill(-2.0)
	water._point_water_normals.fill(Vector3.UP)
	for i in 4: water._point_water_surface_positions[i]=Vector3(-0.5 if i%2==0 else 0.5,0,-1.15 if i<2 else 1.05)
	water.contact_is_airborne=false
	water.contact_is_wet=true
	ski.input_system.state.throttle=1.0
	ski.linear_velocity=-ski.global_basis.z*25.0
	for i in 60:
		bow._process(1.0/60.0)
		spray._process(1.0/60.0)
	assert(bow._contact_growth>0.99)
	var full_dimensions: Vector3=bow.effective_sheet_dimensions
	water._point_depths[0]=-0.2
	water._point_depths[1]=-0.2
	bow._process(1.0/60.0)
	for sheet in bow._sheets: assert(not sheet.visible,"Dry bow emitted from stern-only contact")
	water.contact_is_airborne=true
	water.contact_is_wet=false
	water._point_depths.fill(-0.5)
	bow._process(1.0/60.0)
	for sheet in bow._sheets: assert(not sheet.visible,"Airborne bow film still visible")
	for material in bow._materials: assert(is_zero_approx(material.get_shader_parameter("contact_factor")))
	var spit_frames := 0
	var last_spit := 0.0
	for i in 90:
		spray._process(1.0/60.0)
		if spray._tail.visible:
			assert(spray._tail_material.get_shader_parameter("tail_residual"),"Full jet continued in the air")
			spit_frames+=1
			last_spit=float(i+1)/60.0
	assert(spit_frames>0 and last_spit<=style.tail_residual_seconds+0.02)
	assert(not spray._tail.visible,"Residual water never ran out")
	water.contact_is_airborne=false
	water.contact_is_wet=true
	water._point_depths.fill(0.15)
	bow._process(1.0/60.0)
	var first_size: Vector3=bow.effective_sheet_dimensions
	assert(first_size.length()<full_dimensions.length()*0.25,"Landing spray appeared at full size")
	for i in 30: bow._process(1.0/60.0)
	assert(bow.effective_sheet_dimensions.length()>first_size.length()*3.0)
	# A stationary frozen hull and an old burst must follow a newly rising wave.
	var flat: Basis=spray._basis_flat()
	spray._slots[0].age=-1.0
	spray._launch(0,0.8,1.0,flat,water._point_water_surface_positions,Vector4.ONE)
	var slot: Dictionary=spray._slots[0]
	for height in [-0.7,0.9,-0.3]:
		for i in 4: water._point_water_surface_positions[i].y=height
		water._point_water_normals.fill(Vector3(-0.2,1,0.1).normalized())
		spray._follow_side_surface(slot,0,water)
		var expected: Dictionary=spray._side_surface(0,slot.sheet.global_position,water)
		assert(absf(slot.sheet.global_position.y-expected.height-0.015)<0.0001)
		var slope: Vector2=slot.material.get_shader_parameter("splash_surface_slope")
		assert(slope.length()>0.05,"Side sheet ignored the wave slope")
	assert(spray._slots.size()==4 and spray._tail!=null)
	FileAccess.open("res://temp/hull_spray/water_response_report.json",FileAccess.WRITE).store_string(JSON.stringify({
		"passed":true,"bow_airborne_film_hidden":true,"bow_landing_growth":true,
		"first_landing_size_ratio":first_size.length()/full_dimensions.length(),
		"residual_visible_frames":spit_frames,"last_residual_seconds":last_spit,
		"moving_surface_height_and_slope":true,"extra_water_queries":0,"mesh_instances":5},"\t"))
	print("HULL_SPRAY_WATER_RESPONSE_PASS residual_frames=",spit_frames," last_spit_s=",last_spit)
	await scene.get_child(0)._close_gracefully()
