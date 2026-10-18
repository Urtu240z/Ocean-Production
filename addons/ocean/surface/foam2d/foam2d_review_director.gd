extends Node
## Hull surface effects. Ocean remains the direct water authority.
const REFERENCE_ROOT := "res://addons/ocean/surface/foam2d/references/"
const History := preload("res://addons/ocean/surface/foam2d/projected_wake_history.gd")
const DefaultStyle := preload("res://addons/ocean/surface/foam2d/default_style.tres")
const WaveField := preload("res://addons/ocean/surface/foam2d/hull_wave_field.gd")
const WaveEmitter := preload("res://addons/ocean/surface/foam2d/hull_wave_emitter.gd")
var style: Resource
var mode := "combined"
var vehicles: Array[RigidBody3D] = []
var fft: Node
var surface: Node
var history: RefCounted
var wet := PackedVector4Array()
var birth := PackedVector4Array()
var previous_depth := PackedVector4Array()
var centers := PackedVector4Array()
var inverses: Array[Transform3D] = []
var clock := 0.0
var metrics_active := false
var effect_gpu_ms: Array[float] = []
var frame_gpu_range_ms: Array[float] = []
var timestamp_names: Array[String] = []
var _last_gpu_frame := -1
var _contact := false
var _wake := false
var _projected := false
var _emit_elapsed := 0.0
var _emit_phase := 0.0
var _previous_emit: Array[Vector2] = []
var _emit_valid := PackedByteArray()
var _outward_pulse := PackedFloat32Array()
var contact_update_us := 0
var field_readback := {}
var _ocean: Node
var _surface_pending := false
var surface_bindings := 0
var _running_weights := PackedFloat32Array()
var _running_centers := PackedVector4Array()
var _running_wet := PackedVector4Array()
var _running_inverse: Array[Transform3D] = []
var _presentation_enabled := true
var wave_field: RefCounted
var wave_emitter: RefCounted
var _wave_texture: Texture2DRD
var _wave_previous_texture: Texture2DRD
var _wave_elapsed := 0.0
var _wave_step := 0.05
var _wave_origin := Vector2.ZERO
var _wave_previous_origin := Vector2.ZERO
var _physical_waves := false
var _wave_baked_tick := -1
var _wave_render_state: Dictionary = {}
var wave_gpu_ms: Array[float] = []
var _history_texture: Texture2DRD
var _speed_texture: Texture2DRD
var _neutral_projection_texture: ImageTexture

func _neutral_texture() -> ImageTexture:
	if _neutral_projection_texture == null:
		var image := Image.create(1,1,false,Image.FORMAT_RGBA8)
		image.fill(Color(0,0,0,0))
		_neutral_projection_texture = ImageTexture.create_from_image(image)
	return _neutral_projection_texture

func _history_sampling_texture() -> Texture2D:
	if history != null and history.ready and history.texture_rid.is_valid():
		if _history_texture == null: _history_texture = Texture2DRD.new()
		# This wrapper outlives each FFT runtime. Its material binding cannot be
		# emptied by that runtime's shutdown during a wind/spectrum rebuild.
		if _history_texture.texture_rd_rid != history.texture_rid or _history_texture.get_width() == 0:
			_history_texture.texture_rd_rid = history.texture_rid
		# Texture2DRD publication is asynchronous. A nonempty RD handle alone
		# does not prove that a render-server texture has actually been published.
		if _history_texture.get_width() > 0: return _history_texture
	return _neutral_texture()

func _speed_sampling_texture() -> Texture2D:
	if _projected and history != null and history.ready and history.speed_texture_rid.is_valid():
		if _speed_texture == null: _speed_texture = Texture2DRD.new()
		if _speed_texture.texture_rd_rid != history.speed_texture_rid or _speed_texture.get_width() == 0:
			_speed_texture.texture_rd_rid = history.speed_texture_rid
		if _speed_texture.get_width() > 0: return _speed_texture
	return _neutral_texture()

func _wave_sampling_texture(previous := false) -> Texture2D:
	var texture := _wave_previous_texture if previous else _wave_texture
	if texture != null and wave_field != null and wave_field.ready and texture.get_width() > 0:
		return texture
	return _neutral_texture()

func _bind_projection_texture(parameter: String, texture: Texture2D, all_variants := false) -> void:
	if not is_instance_valid(surface): return
	surface._set_surface_shader_parameter(parameter,texture)
	if all_variants:
		for material: ShaderMaterial in surface.get("_variant_materials").values():
			material.set_shader_parameter(parameter,texture)

func configure(ocean_fft: Node, skis: Array, requested: String, appearance: Resource = null) -> void:
	fft = ocean_fft
	surface = fft.get("_surface")
	if not is_instance_valid(_ocean):
		_ocean = fft.get_parent()
		_ocean.physics_source_invalidated.connect(_on_ocean_invalidated)
	if vehicles != skis: vehicles.assign(skis)
	mode = requested
	_contact = mode in ["contact", "combined"]
	_wake = mode in ["wake", "combined"]
	_projected = mode in ["contact", "wake", "combined"]
	if style != null and style != appearance and style.changed.is_connected(_apply_style): style.changed.disconnect(_apply_style)
	style = appearance if appearance != null else DefaultStyle.duplicate()
	_previous_emit.resize(12)
	_emit_valid.resize(12)
	_outward_pulse.resize(12)
	process_priority = 100
	wet.resize(12)
	birth.resize(12)
	previous_depth.resize(12)
	centers.resize(12)
	inverses.resize(12)
	inverses.fill(Transform3D.IDENTITY)
	_running_weights.resize(12)
	_running_centers.resize(12)
	_running_wet.resize(12)
	_running_inverse.resize(12)
	_running_inverse.fill(Transform3D.IDENTITY)
	# Build real Base/Optics/SSPR variants from the selected preserved source.
	var original := FileAccess.get_file_as_string(REFERENCE_ROOT+"original/ocean_surface.gdshader.source")
	var source := original
	if mode == "f1f2":
		source = FileAccess.get_file_as_string(REFERENCE_ROOT+"f1f2/ocean_surface.gdshader.source")
	elif mode != "original":
		var begin := source.find("\tif (interaction_foam_enabled) {")
		var end := source.find("// M1_4_PRESENTATION_FOAM_FRAGMENT_END", begin)
		source = source.substr(0, begin) + source.substr(end)
		var functions := FileAccess.get_file_as_string("res://addons/ocean/surface/foam2d/contact_projection.gdshaderinc")
		var fragment := FileAccess.get_file_as_string("res://addons/ocean/surface/foam2d/projected_fragment.inc")
		var wave_functions := FileAccess.get_file_as_string("res://addons/ocean/surface/foam2d/hull_wave_projection.gdshaderinc")
		source = source.replace("void vertex() {",wave_functions+"\nvoid vertex() {")
		source = source.replace("\tVERTEX += surface_displacement;","\tif (hull_waves_enabled) { surface_displacement.y += hull_wave_sample(MODEL_MATRIX[3].xz+VERTEX.xz+surface_displacement.xz).x/max(length(MODEL_MATRIX[1].xyz),0.001); }\n\tVERTEX += surface_displacement;")
		source = source.replace("\tvec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);","\tif (hull_waves_enabled) { vec2 slope=hull_wave_sample(ocean_world_position.xz).yz; shading_normal_world=normalize(shading_normal_world-vec3(slope.x,0.0,slope.y)*shading_normal_world.y); }\n\tvec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);")
		source = source.replace("void fragment() {", functions + "\nvoid fragment() {")
		source = source.replace("\tif (debug_view == 1) ALBEDO = NORMAL * 0.5 + 0.5;", fragment + "\n\tif (debug_view == 1) ALBEDO = NORMAL * 0.5 + 0.5;")
	var shaders: Dictionary = surface.get("_variant_shaders")
	var materials: Dictionary = surface.get("_variant_materials")
	var old_active: ShaderMaterial = surface.get("_material")
	var prepared_active: ShaderMaterial
	var history_texture := _history_sampling_texture()
	var speed_texture := _speed_sampling_texture()
	var wave_texture := _wave_sampling_texture()
	var previous_wave_texture := _wave_sampling_texture(true)
	var style_uniforms: Dictionary = style.shader_parameters() if _projected else {}
	for key in shaders.keys():
		var shader := Shader.new()
		var parts: PackedStringArray = str(key).split(":")
		shader.code = surface._build_shader_source(parts[0] == "optics", parts[1] == "sspr", parts[2] == "detail", parts[3] == "breaker", false, source)
		shaders[key] = shader
		var previous: ShaderMaterial = materials[key]
		var prepared := previous.duplicate() as ShaderMaterial
		prepared.shader = shader
		# Rebind the existing Ocean state after replacing a Shader resource. The
		# ordinary cache would otherwise skip equal values on the new shader.
		var state: Dictionary=surface.get("_surface_parameter_state")
		for parameter in state:
			prepared.set_shader_parameter(parameter,state[parameter])
		prepared.set_shader_parameter("interaction_foam_texture",history_texture)
		if _projected:
			prepared.set_shader_parameter("foam2d_speed_texture",speed_texture)
			for parameter in style_uniforms: prepared.set_shader_parameter(parameter,style_uniforms[parameter])
			prepared.set_shader_parameter("hull_waves_texture",wave_texture)
			prepared.set_shader_parameter("hull_waves_previous_texture",previous_wave_texture)
			prepared.set_shader_parameter("hull_waves_enabled",wave_texture == _wave_texture and previous_wave_texture == _wave_previous_texture and _wave_texture != null and _presentation_enabled)
			prepared.set_shader_parameter("hull_waves_origin",_wave_origin)
			prepared.set_shader_parameter("hull_waves_previous_origin",_wave_previous_origin)
			prepared.set_shader_parameter("hull_waves_blend",clampf(_wave_elapsed/_wave_step,0.0,1.0))
			prepared.set_shader_parameter("interaction_foam_origin_xz",history.region_origin if history != null else Vector2.ZERO)
			prepared.set_shader_parameter("interaction_foam_domain_m",128.0)
			prepared.set_shader_parameter("foam2d_time",clock)
		materials[key] = prepared
		if previous == old_active: prepared_active = prepared
	# Publish a complete material instead of changing the shader layout on a
	# material that can still be drawn with the previous texture bindings.
	if prepared_active != null:
		surface.set("_material",prepared_active)
		surface._assign_material_to_surface_geometry(prepared_active)
	_bind_projection_texture("interaction_foam_texture",history_texture,true)
	if _projected:
		_bind_projection_texture("foam2d_speed_texture",speed_texture,true)
		_bind_projection_texture("hull_waves_texture",wave_texture,true)
		_bind_projection_texture("hull_waves_previous_texture",previous_wave_texture,true)
	if mode not in ["original", "f1f2"]:
		var flags := {"foam2d_contact_enabled":_contact,"foam2d_wake_enabled":_wake,
			"foam2d_vehicle_count":vehicles.size() if _contact else 0}
		for parameter in flags:
			surface._set_surface_shader_parameter(parameter,flags[parameter])
			for material: ShaderMaterial in materials.values(): material.set_shader_parameter(parameter,flags[parameter])
	# Replace only the visual interaction field; never replace a water provider.
	var old: RefCounted = fft.get("_interaction_foam")
	var wrapper: Texture2DRD = fft.get("_interaction_foam_texture")
	wrapper.texture_rd_rid = RID()
	fft.set("_interaction_foam_published_rid", RID())
	if old != null and old != history: RenderingServer.call_on_render_thread(old.shutdown)
	var initialize_history := history == null or not _projected
	if _projected:
		if history == null: history = History.new()
		if not style.changed.is_connected(_apply_style): style.changed.connect(_apply_style)
		_apply_style()
	elif mode in ["original", "f1f2"]:
		var reference := REFERENCE_ROOT+("original/" if mode == "original" else "f1f2/")
		var path := reference+"ocean_interaction_foam.gd.source"
		var code := FileAccess.get_file_as_string(path)
		code = code.replace("res://addons/ocean/shaders/interaction_foam_update.glsl",reference+"interaction_foam_update.glsl")
		# Timestamp instrumentation is identical and excludes CPU command submission.
		code = code.replace("var list := _rd.compute_list_begin()", "_rd.capture_timestamp(\"FoamLegacy.begin\")\n\tvar list := _rd.compute_list_begin()")
		code = code.replace("_rd.compute_list_end()", "_rd.compute_list_end()\n\t_rd.capture_timestamp(\"FoamLegacy.end\")")
		var script := GDScript.new()
		script.source_code = code
		assert(script.reload() == OK)
		history = script.new()
	else:
		# No history allocation or advance in contact-only mode.
		fft.set("_interaction_foam", null)
		fft.persistent_foam_enabled = false
		return
	fft.set("_interaction_foam", history)
	fft.persistent_foam_enabled = true
	if initialize_history: RenderingServer.call_on_render_thread(history.initialize)
	_surface_pending = false
	surface_bindings += 1
	set_process(true)
	set_enabled(_presentation_enabled)

func set_enabled(value: bool) -> void:
	_presentation_enabled = value
	if not is_instance_valid(surface): return
	fft.persistent_foam_enabled = value
	if not value and (style == null or not style.wave_physics_enabled): _stop_waves()
	var flags := {"foam2d_contact_enabled":_contact and value,"foam2d_wake_enabled":_wake and value,"foam2d_running_count":0}
	for parameter in flags:
		var setting: Variant = flags[parameter]
		surface._set_surface_shader_parameter(parameter,setting)
		for material: ShaderMaterial in surface.get("_variant_materials").values(): material.set_shader_parameter(parameter,setting)

func set_vehicles(skis: Array) -> void:
	if vehicles == skis: return
	vehicles.assign(skis)
	# A removed/added boat must not inherit another boat's last stamp position.
	_emit_valid.fill(0)
	wet.fill(Vector4.ZERO)
	birth.fill(Vector4.ZERO)
	_running_weights.fill(0.0)
	_outward_pulse.fill(0.0)
	if _contact: surface._set_surface_shader_parameter("foam2d_vehicle_count",vehicles.size())

func _on_ocean_invalidated() -> void:
	if not _projected: return
	_surface_pending = true
	# Ocean will retire this FFT runtime. Keep the visual history alive in the
	# director, outside that runtime's teardown, until the replacement is ready.
	if is_instance_valid(fft) and fft.get("_interaction_foam") == history:
		# The old surface remains visible during Ocean's rebuild debounce. Keep
		# both samplers valid before detaching ownership from the retiring FFT.
		_bind_projection_texture("interaction_foam_texture",_history_sampling_texture(),true)
		_bind_projection_texture("foam2d_speed_texture",_speed_sampling_texture(),true)
		_bind_projection_texture("hull_waves_texture",_wave_sampling_texture(),true)
		_bind_projection_texture("hull_waves_previous_texture",_wave_sampling_texture(true),true)
		fft.set("_interaction_foam",null)

func _try_rebind_surface() -> void:
	if not is_instance_valid(_ocean): return
	var replacement: Node = _ocean.get("_open_ocean")
	if not is_instance_valid(replacement) or replacement == fft: return
	# The replacement node exists before GPU publication builds its materials.
	if not replacement.get("_surface_initialized"): return
	configure(replacement,vehicles,mode,style)

func _exit_tree() -> void:
	if _projected: _on_ocean_invalidated()
	if style != null and style.changed.is_connected(_apply_style): style.changed.disconnect(_apply_style)
	_bind_projection_texture("interaction_foam_texture",_neutral_texture(),true)
	if _projected: _bind_projection_texture("foam2d_speed_texture",_neutral_texture(),true)
	if _history_texture != null: _history_texture.texture_rd_rid = RID()
	if _speed_texture != null: _speed_texture.texture_rd_rid = RID()
	# Projected history is owned here; legacy references remain FFT-owned.
	if _projected and history != null: RenderingServer.call_on_render_thread(history.shutdown)
	_stop_waves()

func _stop_waves() -> void:
	_wave_render_state = {}
	if is_instance_valid(_ocean): _ocean.publish_hull_wave_render_state({})
	if is_instance_valid(surface):
		# Disabled samplers are still part of the GPU material layout. Replace
		# every binding before clearing the wrapper and freeing the atlas.
		_bind_projection_texture("hull_waves_texture",_neutral_texture(),true)
		_bind_projection_texture("hull_waves_previous_texture",_neutral_texture(),true)
		surface._set_surface_shader_parameter("hull_waves_enabled",false)
		surface.set_interaction_displacement_bound(0.0)
		for material: ShaderMaterial in surface.get("_variant_materials").values(): material.set_shader_parameter("hull_waves_enabled",false)
	if _wave_texture != null: _wave_texture.texture_rd_rid = RID()
	if _wave_previous_texture != null: _wave_previous_texture.texture_rd_rid = RID()
	if wave_field != null: RenderingServer.call_on_render_thread(wave_field.shutdown)
	wave_field = null
	wave_emitter = null
	_wave_texture = null
	_wave_previous_texture = null
	_wave_elapsed = 0.0
	_wave_step = 0.05
	_wave_origin = Vector2.ZERO
	_wave_previous_origin = Vector2.ZERO

func _update_waves(delta: float) -> void:
	var physical: RefCounted = _ocean.get_physical_hull_wave_state() if is_instance_valid(_ocean) else null
	if not style.deformation_enabled or not _projected or not (_presentation_enabled or physical != null):
		if wave_field != null: _stop_waves()
		return
	if _physical_waves != (physical != null):
		_stop_waves()
		_physical_waves = physical != null
		_wave_baked_tick = -1
	if wave_field == null:
		wave_field = WaveField.new()
		wave_emitter = WaveEmitter.new()
		_wave_texture = Texture2DRD.new()
		_wave_previous_texture = Texture2DRD.new()
		RenderingServer.call_on_render_thread(wave_field.initialize)
	var wave_clock := clock
	if physical != null:
		wave_emitter = physical.emitter
		wave_clock = physical.clock
	else:
		wave_emitter.update(delta,clock,vehicles,style)
	# Short rises need enough samples at the moving bow; normal rises keep the
	# cheaper rate. This only changes the bounded visual atlas, never the FFT.
	_wave_step = 1.0/60.0 if style.wake_wave_rise_s < 0.25 and not wave_emitter.packets.is_empty() else 0.05
	if physical != null: _wave_step = get_physics_process_delta_time()
	_wave_elapsed += delta
	var camera := get_viewport().get_camera_3d()
	var center := camera.global_position if camera != null else (vehicles[0].global_position if not vehicles.is_empty() else Vector3.ZERO)
	if wave_field.ready:
		surface.set_interaction_displacement_bound(style.deformation_max_height_m)
		if _wave_texture.texture_rd_rid != wave_field.texture_rid or _wave_texture.get_width() == 0: _wave_texture.texture_rd_rid = wave_field.texture_rid
		if _wave_previous_texture.texture_rd_rid != wave_field.previous_texture_rid or _wave_previous_texture.get_width() == 0: _wave_previous_texture.texture_rd_rid = wave_field.previous_texture_rid
		var texture := _wave_sampling_texture()
		_bind_projection_texture("hull_waves_texture",texture)
		var previous_texture := _wave_sampling_texture(true)
		_bind_projection_texture("hull_waves_previous_texture",previous_texture)
		surface._set_surface_shader_parameter("hull_waves_max_height",style.deformation_max_height_m)
		surface._set_surface_shader_parameter("hull_waves_physical",physical != null)
		surface._set_surface_shader_parameter("hull_waves_enabled",texture == _wave_texture and previous_texture == _wave_previous_texture)
		if (physical != null and _wave_baked_tick != physical.tick) or (physical == null and _wave_elapsed >= _wave_step):
			_wave_elapsed = fmod(_wave_elapsed,_wave_step)
			var origin := (Vector2(center.x,center.z)/0.25).round()*0.25-Vector2.ONE*64.0
			RenderingServer.call_on_render_thread(wave_field.draw.bind(wave_emitter.packets.duplicate(true),origin,wave_clock))
			if physical != null: _wave_baked_tick = physical.tick
			_wave_previous_origin = _wave_origin
			_wave_origin = origin
		surface._set_surface_shader_parameter("hull_waves_origin",_wave_origin)
		surface._set_surface_shader_parameter("hull_waves_previous_origin",_wave_previous_origin)
		var blend := clampf(_wave_elapsed/_wave_step,0.0,1.0)
		if physical != null:
			blend = Engine.get_physics_interpolation_fraction() if ProjectSettings.get_setting("physics/common/physics_interpolation",false) else 1.0
		surface._set_surface_shader_parameter("hull_waves_blend",blend)
		_wave_render_state = {"hull_waves_enabled":texture == _wave_texture and previous_texture == _wave_previous_texture,
			"hull_waves_texture":wave_field.texture_rid,"hull_waves_previous_texture":wave_field.previous_texture_rid,
			"hull_waves_origin":_wave_origin,"hull_waves_previous_origin":_wave_previous_origin,
			"hull_waves_blend":blend,"hull_waves_max_height":style.deformation_max_height_m,
			"hull_waves_physical":physical != null}
		if is_instance_valid(_ocean): _ocean.publish_hull_wave_render_state(_wave_render_state)

func get_wave_render_state() -> Dictionary:
	return _wave_render_state.duplicate()

func _apply_style() -> void:
	if not _projected or not is_instance_valid(surface): return
	var parameters: Dictionary = style.shader_parameters()
	for parameter in parameters:
		surface._set_surface_shader_parameter(parameter, parameters[parameter])
		# Apply editor changes to cached variants too, before a profile switch.
		for material: ShaderMaterial in surface.get("_variant_materials").values():
			material.set_shader_parameter(parameter,parameters[parameter])
	if history != null: history.set_appearance(style.history_parameters())
	if history != null: history.set_motion(style.motion_parameters())
	if history != null: history.set_edges(style.edge_parameters())
	if history != null: history.set_outward(style.outward_parameters())
	if history != null and history.has_method("set_shape"): history.set_shape(style.shape_parameters())
	if history != null and history.has_method("set_update_hz"): history.set_update_hz(style.wake_update_hz)
	if not style.deformation_enabled and wave_field != null: _stop_waves()

func _update_running_foam(delta: float) -> void:
	# Appearance only: consume the four existing V1 samples, without new queries.
	var count := 0
	var bounds := Vector4(INF,INF,-INF,-INF)
	var enabled: bool = _contact and style.running_enabled and style.running_strength > 0.0
	var radius: float = maxf(style.running_half_width,style.running_half_length)+1.0
	for i in mini(vehicles.size(),12):
		var ski := vehicles[i]
		var physics: Node = ski.get("water_physics_system")
		var contact := Vector4.ZERO
		if enabled and not physics.contact_is_airborne:
			for point in mini(4,mini(physics.point_sample_valid.size(),physics.point_depths.size())):
				if physics.point_sample_valid[point]:
					contact[point] = smoothstep(-0.005,0.13,physics.point_depths[point])
		if contact == Vector4.ZERO:
			_running_weights[i] = 0.0
			continue
		var velocity := ski.linear_velocity
		var speed := Vector2(velocity.x,velocity.z).length()*3.6
		var target: float = style.running_speed_weight(speed)
		_running_weights[i] = lerpf(_running_weights[i],target,1.0-exp(-maxf(delta,0.0)/maxf(style.running_response_seconds,0.05)))
		if _running_weights[i] <= 0.001: continue
		var transform := ski.get_global_transform_interpolated()
		_running_inverse[count] = transform.affine_inverse()
		_running_centers[count] = Vector4(transform.origin.x,transform.origin.z,_running_weights[i],0.0)
		_running_wet[count] = contact
		bounds.x = minf(bounds.x,transform.origin.x-radius)
		bounds.y = minf(bounds.y,transform.origin.z-radius)
		bounds.z = maxf(bounds.z,transform.origin.x+radius)
		bounds.w = maxf(bounds.w,transform.origin.z+radius)
		count += 1
	if count > 0:
		# Snapshots keep Ocean's parameter cache from aliasing our mutable arrays.
		surface._set_surface_shader_parameter("foam2d_running_inverse",_running_inverse.duplicate())
		surface._set_surface_shader_parameter("foam2d_running_center",_running_centers.duplicate())
		surface._set_surface_shader_parameter("foam2d_running_wet",_running_wet.duplicate())
		surface._set_surface_shader_parameter("foam2d_running_bounds",bounds)
	surface._set_surface_shader_parameter("foam2d_running_count",count)

func _process(delta: float) -> void:
	if _projected and (_surface_pending or not is_instance_valid(surface)):
		_try_rebind_surface()
		if _surface_pending or not is_instance_valid(surface): return
	if not is_instance_valid(surface):
		set_process(false)
		return
	if not _presentation_enabled:
		if _projected: _update_waves(delta)
		return
	var started := Time.get_ticks_usec()
	if _projected: _update_running_foam(delta)
	clock += delta
	if _projected: _update_waves(delta)
	if _projected:
		var camera := get_viewport().get_camera_3d()
		var center := camera.global_position if camera != null else vehicles[0].global_position
		history.set_view_center(Vector2(center.x, center.z))
	if history != null and history.ready:
		var material: ShaderMaterial=surface.get("_material")
		_bind_projection_texture("interaction_foam_texture",_history_sampling_texture())
		if _projected: _bind_projection_texture("foam2d_speed_texture",_speed_sampling_texture())
		material.set_shader_parameter("interaction_foam_origin_xz",history.region_origin)
		material.set_shader_parameter("interaction_foam_domain_m",128.0)
		if _projected: material.set_shader_parameter("foam2d_time",clock)
	if _projected:
		_emit_elapsed += delta
		_emit_phase += delta
		var emit_step: float = 1.0 / style.wake_update_hz
		var emit_now: bool = _emit_phase + 0.000001 >= emit_step and history != null and history.ready
		var emit_interval := minf(_emit_elapsed, 0.20)
		for i in vehicles.size():
			var ski := vehicles[i]
			var physics: Node = ski.get("water_physics_system")
			var live_wet := false
			var pressure := 0.0
			if mode == "contact":
				inverses[i] = ski.get_global_transform_interpolated().affine_inverse()
				centers[i] = Vector4(ski.global_position.x, ski.global_position.z, 0.0, 0.0)
			for point in 4:
				var valid: bool = physics.point_sample_valid[point] and not physics.contact_is_airborne
				var depth: float = physics.point_depths[point] if valid else -0.1
				var target := smoothstep(-0.005, 0.13, depth) if valid else 0.0
				live_wet = live_wet or target > 0.02
				var vertical := absf(physics.point_relative_normal_speeds[point]) if valid else 0.0
				var change := absf(depth - previous_depth[i][point]) / maxf(delta, 0.001)
				# Ordinary bobbing stays blue; strong normal impacts can whiten foam.
				var activity: float = clampf((maxf(vertical-0.55,0.0)*0.14 + maxf(change-1.25,0.0)*0.025)*style.impact_sensitivity,0.0,1.0)*target
				# Visual pressure envelope: wetting and normal impacts, no new query.
				pressure = maxf(pressure,maxf(activity,maxf(target-wet[i][point],0.0)*0.65))
				wet[i][point] = lerpf(wet[i][point], target, 1.0-exp(-delta*(9.0 if target>wet[i][point] else 4.0)))
				birth[i][point] = lerpf(birth[i][point], activity, 1.0-exp(-delta*5.0))
				previous_depth[i][point] = depth
			_outward_pulse[i] = maxf(_outward_pulse[i]*exp(-delta*4.0),pressure) if live_wet else 0.0
			if emit_now:
				var transform := ski.get_global_transform_interpolated()
				var forward := Vector2(-transform.basis.z.x, -transform.basis.z.z).normalized()
				# A small hull-local offset; sweep only the distance actually travelled.
				var position: Vector2 = Vector2(transform.origin.x, transform.origin.z) + forward * style.wake_emission_forward_m
				var previous := _previous_emit[i] if _emit_valid[i] != 0 else position
				if previous.distance_to(position) > 6.0: previous = position
				var travelled_speed := previous.distance_to(position) / maxf(emit_interval, 0.001)
				var any_wet := live_wet and maxf(maxf(wet[i].x, wet[i].y), maxf(wet[i].z, wet[i].w)) > 0.02
				if any_wet and (mode != "wake" or travelled_speed >= 0.4):
					history.submit_hull(position, previous, forward, travelled_speed, wet[i], birth[i], emit_interval,_outward_pulse[i])
				_previous_emit[i] = position
				_emit_valid[i] = 1 if any_wet else 0
		if emit_now:
			_emit_elapsed = 0.0
			_emit_phase = maxf(fmod(_emit_phase + 0.000001,emit_step) - 0.000001,0.0)
		# Array is reference-valued: snapshot it so the material-state cache cannot
		# mistake an in-place transform update for an unchanged uniform.
		if mode == "contact":
			surface._set_surface_shader_parameter("foam2d_hull_inverse", inverses.duplicate())
			surface._set_surface_shader_parameter("foam2d_center", centers.duplicate())
	contact_update_us = Time.get_ticks_usec() - started
	RenderingServer.call_on_render_thread(_capture_gpu)

func _capture_gpu() -> void:
	var rd := RenderingServer.get_rendering_device()
	var frame := rd.get_captured_timestamps_frame()
	if frame == _last_gpu_frame: return
	_last_gpu_frame = frame
	var start := -1
	var wave_start := -1
	var count := rd.get_captured_timestamps_count()
	if timestamp_names.is_empty() and count > 0:
		for i in count: timestamp_names.append(rd.get_captured_timestamp_name(i))
	if not metrics_active: return
	for i in count:
		var name := rd.get_captured_timestamp_name(i)
		if name in ["Foam2D.begin", "FoamLegacy.begin"]: start = rd.get_captured_timestamp_gpu_time(i)
		if name in ["Foam2D.end", "FoamLegacy.end"] and start >= 0:
			effect_gpu_ms.append(float(rd.get_captured_timestamp_gpu_time(i) - start) / 1000000.0)
		if name == "HullWaves.begin": wave_start = rd.get_captured_timestamp_gpu_time(i)
		if name == "HullWaves.end" and wave_start >= 0:
			wave_gpu_ms.append(float(rd.get_captured_timestamp_gpu_time(i)-wave_start)/1000000.0)

func diagnostic_state() -> Dictionary:
	return {"mode": mode, "wet": Array(wet.slice(0, vehicles.size())), "birth": Array(birth.slice(0, vehicles.size())),
		"outward_pressure":Array(_outward_pulse.slice(0,vehicles.size())),
		"running_weights":Array(_running_weights.slice(0,vehicles.size())),
		"waves":wave_emitter.diagnostic_state() if wave_emitter != null else {"enabled":false,"texture_bytes":0},
		"wave_field":wave_field.diagnostic_state() if wave_field != null else {},
		"wave_update_hz":1.0/_wave_step if wave_field != null else 0.0,
		"surface_bindings":surface_bindings,"surface_pending":_surface_pending,
		"clock": clock, "contact_cpu_us": contact_update_us, "extra_physics_queries": 0,
		"new_contact_meshes": 0, "shared_foam": _projected,
		"backface_gate": "upward FFT normal dot viewer, surface air blend and signed camera height"}

func read_field() -> void:
	var rd := RenderingServer.get_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(rgba16f,set=0,binding=0) readonly uniform image2D fields;
layout(std430,set=0,binding=1) writeonly buffer Out { vec4 values[]; } output_data;
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);output_data.values[p.y*512+p.x]=imageLoad(fields,p);}
"""
	var shader := rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
	var pipeline := rd.compute_pipeline_create(shader)
	var buffer := rd.storage_buffer_create(512*512*16)
	var input := RDUniform.new()
	input.binding=0
	input.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE
	input.add_id(history.texture_rid)
	var output := RDUniform.new()
	output.binding=1
	output.uniform_type=RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output.add_id(buffer)
	var set_rid := rd.uniform_set_create([input,output],shader,0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,pipeline)
	rd.compute_list_bind_uniform_set(list,set_rid,0)
	rd.compute_list_dispatch(list,64,64,1)
	rd.compute_list_end()
	var values := rd.buffer_get_data(buffer).to_float32_array()
	var maximum := 0.0
	var minimum := INF
	var active := 0
	for i in range(0,values.size(),4):
		maximum=maxf(maximum,values[i])
		minimum=minf(minimum,values[i])
		if values[i]>0.02: active+=1
	field_readback={"max_foam":maximum,"min_foam":minimum,"active_above_002":active,"field_hash":hash(values)}
	for rid in [set_rid,buffer,pipeline,shader]: rd.free_rid(rid)
