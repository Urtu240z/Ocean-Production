@tool
@static_unload
extends Node3D
## Nozzle-locked tail and visual emitters; existing V1 supplies gameplay contacts.
const Gate := preload("res://addons/jet_ski/common/visual/hull_spray/spray_impact_gate.gd")
const ResidualGate := preload("res://addons/jet_ski/common/visual/hull_spray/tail_residual_gate.gd")
const SprayShader := preload("res://addons/jet_ski/common/visual/bow_spray/bow_spray.gdshader")
const SternMist := preload("res://addons/jet_ski/common/visual/hull_spray/stern_mist.gd")
const TEXTURES := "res://addons/jet_ski/common/visual/hull_spray/textures/"
var settings: Resource = load("res://addons/jet_ski/common/visual/hull_spray/default_style.tres")
static var _meshes: Dictionary = {}
static var _atlases: Dictionary = {}
static var _atlas_info: Dictionary = {}
var gate := Gate.new()
var _residual := ResidualGate.new()
# Keep this leaf visual independent of the vehicle script's preload graph.
var _vehicle: Node3D
var _slots: Array[Dictionary] = []
var _anchors: Array[Node3D] = []
var _tail: MeshInstance3D
var _tail_material: ShaderMaterial
var _mist: GPUParticles3D
var _mist_emitters: Array[GPUParticles3D] = []
var _tail_intensity := 0.0
var _tail_frame := 0.0
var _tail_bank := 0.0
var _scene_light_tint := Vector3.ONE
var _scene_tint_refresh := 0.0
var _active_variant := -1
var _enabled := false
var _applying_style := false
var _water_defaults_ready := false
var _layouts: Dictionary = {}
var _clocks := [{"distortion":0.0,"normal":0.0,"volume":0.0,"scale":0.0,"height":0.0},
	{"distortion":0.0,"normal":0.0,"volume":0.0,"scale":0.0,"height":0.0}]
var _attachment := PackedVector3Array([Vector3.ZERO,Vector3.ZERO,Vector3.ZERO])
var pool_dropped := 0
var rendered_bursts := Vector2i.ZERO

func _ready() -> void:
	# @tool script reloads can retain freed preview references without rerunning
	# _ready. Rebuilding must be idempotent and preserve all artist-owned anchors.
	if settings!=null and settings.changed.is_connected(_apply_style): settings.changed.disconnect(_apply_style)
	# The helper is transient, including across @tool reloads.
	for child in get_children():
		if child.name=="_SternMist":
			remove_child(child)
			child.queue_free()
	_mist=null
	_mist_emitters.clear()
	if Engine.is_editor_hint():
		for label in ["SplashLeft","SplashRight","TailJet"]:
			var anchor := get_parent().get_node_or_null(label)
			if anchor==null: continue
			for child in anchor.get_children():
				if child is MeshInstance3D and (str(child.name).begins_with("_Burst") or child.name=="_Jet"):
					anchor.remove_child(child)
					child.queue_free()
	_slots.clear()
	_anchors.clear()
	_tail=null
	_tail_material=null
	_applying_style=false
	_enabled=Engine.is_editor_hint() or bool(ProjectSettings.get_setting("jet_ski/hull_spray_enabled",true))
	if not _enabled:
		set_process(false)
		return
	var ancestor := get_parent()
	while ancestor!=null and not ancestor.has_method("get_water_provider"): ancestor=ancestor.get_parent()
	_vehicle=ancestor as Node3D
	if not Engine.is_editor_hint() and _vehicle==null:
		set_process(false)
		return
	var owner_root := get_parent()
	settings=owner_root.hull_spray_settings
	for label in ["SplashLeft","SplashRight","TailJet"]: _anchors.append(owner_root.get_node(label))
	if _vehicle!=null: gate.rng.seed=absi(str(_vehicle.get_path()).hash())+1769
	_residual.rng.seed=gate.rng.seed+8917
	var test_mode: String="default" if Engine.is_editor_hint() else ProjectSettings.get_setting("jet_ski/hull_spray_mode","default")
	if test_mode!="default":
		settings=settings.duplicate(true)
		settings.sides_enabled=test_mode in ["sides","all3","all4"]
		settings.tail_enabled=test_mode in ["tail3","tail4","all3","all4"]
		settings.tail_variant=1 if test_mode in ["tail4","all4"] else 0
	if _atlas_info.is_empty(): _atlas_info=JSON.parse_string(FileAccess.get_file_as_string(TEXTURES+"atlas_info.json"))
	for index in 4:
		var sheet := _sheet("_Burst%d"%(index%2),_anchors[index/2])
		_slots.append({"sheet":sheet,"material":sheet.material_override,"age":-1.0,"frame":0.0,
			"rate":1.0,"strength":0.0,"speed":0.0,"origin":Vector3.ZERO,"velocity":Vector3.ZERO})
	_tail=_sheet("_Jet",_anchors[2])
	_tail_material=_tail.material_override
	_mist=owner_root.get_node_or_null("SternMist") as GPUParticles3D
	if _mist==null:
		_mist=SternMist.new()
		_mist.name="_SternMist"
		add_child(_mist)
	_mist.top_level=true
	_mist_emitters.assign([_mist])
	var right := owner_root.get_node_or_null("SternMistRight") as GPUParticles3D
	if right!=null:
		right.top_level=true
		_mist_emitters.append(right)
	settings.changed.connect(_apply_style)
	_apply_style()

func _exit_tree() -> void:
	if settings!=null and settings.changed.is_connected(_apply_style): settings.changed.disconnect(_apply_style)
	# Runtime children are released with their anchor parent. During an editor
	# script reload the anchors survive, so remove only the generated previews.
	if Engine.is_editor_hint():
		for slot in _slots:
			if is_instance_valid(slot.sheet): slot.sheet.queue_free()
		if is_instance_valid(_tail): _tail.queue_free()
		if is_instance_valid(_mist) and _mist.name=="_SternMist": _mist.queue_free()

func configure_settings(value: Resource) -> void:
	if value==null: return
	if settings!=null and settings.changed.is_connected(_apply_style): settings.changed.disconnect(_apply_style)
	settings=value
	if _enabled and _tail_material!=null:
		settings.changed.connect(_apply_style)
		_apply_style()

func _ensure_profiles() -> bool:
	if settings==null: return false
	# Existing editor instances can retain null defaults when @tool exports are
	# added during hot reload. Fill only missing profiles, preserving edits.
	if settings.get("splash_appearance")==null:
		settings.set("splash_appearance",load("res://addons/jet_ski/common/visual/hull_spray/splash_appearance.tres"))
	if settings.get("tail_appearance")==null:
		settings.set("tail_appearance",load("res://addons/jet_ski/common/visual/hull_spray/tail_appearance.tres"))
	if settings.get("stern_mist")==null:
		settings.set("stern_mist",load("res://addons/jet_ski/common/visual/hull_spray/stern_mist_style.tres"))
	var defaults := {"tail_turn_response":5.0,"tail_roundness":0.8,"tail_downward_curve":0.45,
		"sustained_rate_hz":6.0,"side_burst_lifetime":0.30,"tail_residual_seconds":0.55,"tail_residual_strength":0.65,
		"tail_surface_fade_depth_m":0.25,"tail_water_core_strength":0.45}
	for key in defaults:
		if settings.get(key)==null:
			settings.set(key,defaults[key])
	_water_defaults_ready=settings.get("splash_appearance")!=null and settings.get("tail_appearance")!=null
	return _water_defaults_ready


func _update_scene_light_tint(delta: float) -> void:
	_scene_tint_refresh -= delta
	if _scene_tint_refresh > 0.0:
		return
	_scene_tint_refresh = 0.12
	if is_instance_valid(_vehicle) and is_instance_valid(_vehicle.get("ocean")):
		var ocean := _vehicle.get("ocean") as Ocean
		_scene_light_tint = ocean.get_scene_lighting_tint() if ocean != null else Vector3.ONE
	else:
		_scene_light_tint = Vector3.ONE

static func _mesh(layer_count: int, tail_cone: bool = false) -> ArrayMesh:
	layer_count=clampi(layer_count,1,5)
	var key := layer_count+100 if tail_cone else layer_count
	if _meshes.has(key): return _meshes[key]
	var columns := 17 if tail_cone else 9
	var rows := 13 if tail_cone else 7
	var vertices := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for layer in layer_count:
		var start := vertices.size()
		var coordinate := float(layer)*2.0/float(layer_count-1)-1.0 if layer_count>1 else 0.0
		for y in rows:
			for x in columns:
				vertices.append(Vector3(float(x)/(columns-1),float(y)/(rows-1),0))
				uv.append(Vector2(float(x)/(columns-1),float(y)/(rows-1)))
				uv2.append(Vector2(coordinate,float(layer)/float(layer_count)))
				normals.append(Vector3.FORWARD)
		for y in rows-1:
			for x in columns-1:
				var i := start+y*columns+x
				indices.append_array(PackedInt32Array([i,i+columns,i+1,i+1,i+columns,i+columns+1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices
	arrays[Mesh.ARRAY_NORMAL]=normals
	arrays[Mesh.ARRAY_TEX_UV]=uv
	arrays[Mesh.ARRAY_TEX_UV2]=uv2
	arrays[Mesh.ARRAY_INDEX]=indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	_meshes[key]=mesh
	return mesh

func _sheet(label: String, anchor: Node3D) -> MeshInstance3D:
	var sheet := MeshInstance3D.new()
	sheet.name=label
	sheet.physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF
	sheet.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sheet.sorting_use_aabb_center=false
	sheet.custom_aabb=AABB(Vector3(-12,-12,-12),Vector3(24,24,24))
	var material := ShaderMaterial.new()
	material.shader=SprayShader
	sheet.material_override=material
	anchor.add_child(sheet)
	sheet.top_level=true
	sheet.hide()
	return sheet

func _layout(profile: Resource, index: int) -> Dictionary:
	if not _atlases.has(index): _atlases[index]=load(TEXTURES+"splash_%d_atlas.png"%index)
	var info: Dictionary=_atlas_info[str(index)]
	var sequence: Array[Texture2D]=[]
	if profile.use_image_sequence:
		for texture in profile.image_sequence:
			if texture!=null: sequence.append(texture)
	var texture: Texture2D=profile.flipbook_texture if profile.flipbook_texture!=null else _atlases[index]
	var grid := Vector2(info.grid[0],info.grid[1])
	var frames: int=info.frames
	if profile.flipbook_texture!=null:
		grid=Vector2(maxi(profile.frames_x,1),maxi(profile.frames_y,1))
		if profile.auto_detect_atlas_grid:
			var detected := _detect_atlas_grid(texture)
			if detected.x>1 and detected.y>1: grid=Vector2(detected)
		frames=clampi(profile.flipbook_frames,1,int(grid.x*grid.y))
	return {"texture":texture,"grid":grid,"frames":sequence.size() if not sequence.is_empty() else frames,
		"sequence":sequence,"pivot":profile.sprite_pivot if profile.use_custom_pivot else Vector2(info.pivot[0],info.pivot[1])}

func _apply_profile(material: ShaderMaterial, profile: Resource, layout: Dictionary, is_tail: bool) -> void:
	material.render_priority=profile.spray_render_priority
	for key in ["solid_occlusion_bias","volume_depth","volume_verticality","undulation_strength",
		"undulation_frequency","undulation_speed","spray_opacity","spray_scale","distortion_strength",
		"breakup_strength","alpha_from_luminance","alpha_cutoff","alpha_softness","alpha_gain",
		"edge_softness","side_fade_strength","frame_crop","flipbook_flip_y","steering_tilt_strength",
		"spray_whiteness","spray_saturation","spray_brightness","water_appearance_enabled","foam_opacity",
		"water_opacity","water_tint","normal_texture","normal_strength","normal_tiling","water_roughness",
		"highlight_strength","animation_smoothing","sequence_frame_crop"]:
		material.set_shader_parameter(key,profile.get(key))
	material.set_shader_parameter("spray_color",profile.spray_tint)
	material.set_shader_parameter("side_fade_angle",deg_to_rad(profile.side_fade_angle))
	material.set_shader_parameter("volume_layers",clampi(profile.volume_layers,1,5))
	material.set_shader_parameter("has_normal_texture",profile.normal_texture!=null)
	material.set_shader_parameter("has_breakup_mask",profile.breakup_mask!=null)
	material.set_shader_parameter("has_distortion",profile.distortion_texture!=null)
	material.set_shader_parameter("breakup_mask",profile.breakup_mask)
	material.set_shader_parameter("distortion_texture",profile.distortion_texture)
	material.set_shader_parameter("anchored_sprite_mode",true)
	material.set_shader_parameter("sprite_tail",is_tail)
	material.set_shader_parameter("splash_surface_fit",not is_tail and not Engine.is_editor_hint())
	material.set_shader_parameter("sprite_loop",is_tail)
	material.set_shader_parameter("sprite_pivot",layout.pivot)
	material.set_shader_parameter("has_image_sequence",not layout.sequence.is_empty())
	material.set_shader_parameter("has_flipbook",true)
	material.set_shader_parameter("flipbook_texture",layout.texture)
	material.set_shader_parameter("flipbook_grid",layout.grid)
	material.set_shader_parameter("flipbook_frames",layout.frames)
	material.set_shader_parameter("speed_factor",1.0)

func _apply_style() -> void:
	if not _enabled or _tail_material==null or _applying_style: return
	_applying_style=true
	if not _ensure_profiles():
		_applying_style=false
		return
	_layouts[0]=_layout(settings.splash_appearance,2)
	_active_variant=settings.tail_variant+3
	_layouts[1]=_layout(settings.tail_appearance,_active_variant)
	for index in _slots.size():
		var slot: Dictionary=_slots[index]
		slot.sheet.mesh=_mesh(settings.splash_appearance.volume_layers)
		_apply_profile(slot.material,settings.splash_appearance,_layouts[0],false)
		slot.material.set_shader_parameter("splash_elevation_angle",deg_to_rad(settings.elevation_degrees))
		slot.material.set_shader_parameter("side_sign",-1.0 if index<2 else 1.0)
		slot.material.set_shader_parameter("phase_offset",float(index)*0.37)
	_tail.mesh=_mesh(settings.tail_appearance.volume_layers,true)
	_apply_profile(_tail_material,settings.tail_appearance,_layouts[1],true)
	_tail_material.set_shader_parameter("tail_roundness",settings.tail_roundness)
	_tail_material.set_shader_parameter("tail_downward_curve",settings.tail_downward_curve)
	_tail_material.set_shader_parameter("tail_surface_fade_depth",settings.tail_surface_fade_depth_m)
	_tail_material.set_shader_parameter("tail_water_core_strength",settings.tail_water_core_strength)
	for emitter in _mist_emitters:
		if is_instance_valid(emitter): emitter.configure(settings.stern_mist)
	_tail_frame=fposmod(_tail_frame,float(_layouts[1].frames))
	_applying_style=false

func _basis_flat() -> Basis:
	var pose := _vehicle.global_transform if Engine.is_editor_hint() else _vehicle.get_global_transform_interpolated()
	var back := pose.basis.z
	back.y=0
	back=back.normalized() if back.length_squared()>0.01 else Vector3.BACK
	return Basis(Vector3.UP.cross(back),Vector3.UP,back)

func _anchor_pose(index: int, flat: Basis) -> Transform3D:
	if _vehicle==null or Engine.is_editor_hint(): return _anchors[index].global_transform
	var local := _vehicle.global_transform.affine_inverse()*_anchors[index].global_transform
	# The nozzle inherits the complete interpolated hull pose, including jumps,
	# pitch and bank. Only the detached lateral bursts use the sea-plane basis.
	if index==2: return _vehicle.get_global_transform_interpolated()*local
	return Transform3D(flat*local.basis,_vehicle.get_global_transform_interpolated()*local.origin)

func _update_tail_bank(delta: float) -> void:
	var target: float=settings.tail_appearance.preview_steering
	if not Engine.is_editor_hint() and _vehicle!=null:
		var up := _basis_flat().inverse()*_vehicle.get_global_transform_interpolated().basis.y.normalized()
		target=clampf(atan2(-up.x,up.y)/deg_to_rad(35.0),-1.0,1.0)
	_tail_bank=lerpf(_tail_bank,target,1.0-exp(-delta*settings.tail_turn_response))

func _speed(profile: Resource, speed: float) -> float:
	return smoothstep(profile.speed_start,maxf(profile.speed_full,profile.speed_start+0.01),maxf(speed,0.0))

func _submersion(profile: Resource, depth: float) -> float:
	return 1.0-smoothstep(profile.submersion_fade_start_depth,maxf(profile.submersion_hide_depth,profile.submersion_fade_start_depth+0.01),depth) if is_finite(depth) else 0.0

func _advance_clock(index: int, delta: float, profile: Resource, speed: float, weight: float) -> void:
	var clock: Dictionary=_clocks[index]
	clock.distortion+=delta*maxf(profile.distortion_speed,0.0)*lerpf(0.8,1.3,speed)
	clock.normal+=delta*maxf(profile.normal_scroll_speed,0.0)*lerpf(0.8,1.3,speed)
	clock.volume+=delta*maxf(profile.undulation_speed,0.0)
	clock.scale+=delta*maxf(profile.layer_scale_variation_speed,0.0)*weight
	clock.height+=delta*maxf(profile.sheet_height_variation_speed,0.0)*weight

func _animate(material: ShaderMaterial, profile: Resource, index: int, speed: float, weight: float, side: int) -> void:
	var clock: Dictionary=_clocks[index]
	material.set_shader_parameter("scene_light_tint",_scene_light_tint)
	material.set_shader_parameter("animation_time",clock.distortion)
	material.set_shader_parameter("normal_time",clock.normal)
	material.set_shader_parameter("volume_time",clock.volume)
	# Tail bend follows the hull bank, never the keyboard's discrete -1/0/+1.
	material.set_shader_parameter("steering",_tail_bank if index==1 else (_vehicle.steering_input if not Engine.is_editor_hint() and _vehicle!=null else profile.preview_steering))
	var scales := Vector4.ONE
	var fifth := 1.0
	for layer in clampi(profile.volume_layers,1,5):
		var phase := float(layer)*2.094395+float(side)*1.17
		var rate := 0.88+float(layer)*0.12+float(side)*0.07
		var wave := sin(clock.scale*TAU*rate+phase)*0.7+sin(clock.scale*TAU*rate*1.31+phase+1.3)*0.3
		var value: float=1.0+clampf(profile.layer_scale_variation_percent,0,50)*0.01*weight*wave
		if layer<4: scales[layer]=value
		else: fifth=value
	material.set_shader_parameter("layer_scale_factors",scales)
	material.set_shader_parameter("layer_scale_factor_5",fifth)
	var dimensions := Vector3(profile.sheet_length_low,profile.sheet_width_low,profile.sheet_height_low).lerp(Vector3(profile.sheet_length,profile.sheet_width,profile.sheet_height),speed)
	var height_wave := sin(clock.height*TAU)*0.7+sin(clock.height*TAU*0.63+1.7)*0.3
	dimensions.z*=1.0+clampf(profile.sheet_height_variation_percent,0,75)*0.01*weight*height_wave
	material.set_shader_parameter("sheet_length",dimensions.x)
	material.set_shader_parameter("sheet_width",dimensions.y)
	material.set_shader_parameter("sheet_height",dimensions.z)

func _set_frame(material: ShaderMaterial, index: int, position: float, loop: bool) -> void:
	var layout: Dictionary=_layouts[index]
	material.set_shader_parameter("frame_position",position)
	if layout.sequence.is_empty(): return
	var count: int=layout.sequence.size()
	var current := int(floor(position))
	var frames := PackedInt32Array([current-1,current,current+1,current+2])
	var keys := ["sequence_previous_texture","sequence_texture","sequence_next_texture","sequence_following_texture"]
	for i in 4:
		var frame := posmod(frames[i],count) if loop else clampi(frames[i],0,count-1)
		material.set_shader_parameter(keys[i],layout.sequence[frame])
	material.set_shader_parameter("sequence_blend",position-floor(position))

func _slide(index: int, profile: Resource, y: float, delta: float) -> Vector3:
	if not profile.attachment_slide_enabled:
		_attachment[index]=Vector3.ZERO
		return Vector3.ZERO
	var pitch := deg_to_rad(profile.preview_pitch_degrees) if Engine.is_editor_hint() else asin(clampf(-_vehicle.global_basis.z.normalized().y,-1,1))
	var factor := pitch/deg_to_rad(maxf(profile.attachment_pitch_full_degrees,1))
	factor+=clampf((_anchors[index].global_position.y-y)/maxf(profile.attachment_height_full,0.05),-1,1)*profile.attachment_height_influence
	factor=clampf(factor,-1,1)
	var shift: float=factor*(profile.nose_up_slide if factor>=0 else profile.nose_down_slide)
	var aft := Vector3.BACK if _vehicle==null else _basis_flat().z
	_attachment[index]=_attachment[index].lerp(aft*shift,1.0-exp(-delta*profile.attachment_response))
	return _attachment[index]

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		_preview(delta)
		return
	if not is_instance_valid(_vehicle) or _vehicle.water_physics_system==null: return
	if not _water_defaults_ready and not _ensure_profiles(): return
	_update_scene_light_tint(delta)
	var water = _vehicle.water_physics_system
	var valid = water.point_sample_valid
	var depths = water.point_depths
	var normal_speeds = water.point_relative_normal_speeds
	var surfaces = water.point_water_surface_positions
	if mini(mini(valid.size(),depths.size()),mini(normal_speeds.size(),surfaces.size()))<4:
		for slot in _slots:
			slot.sheet.hide()
			slot.age=-1.0
		_tail.hide()
		_tail_intensity=0.0
		for emitter in _mist_emitters:
			if is_instance_valid(emitter): emitter.stop()
		_residual.step(delta,false,false,0.0,0.0)
		return
	var wet := Vector4.ZERO
	var impact := Vector4.ZERO
	var shallowest := INF
	for point in 4:
		if not valid[point]: continue
		wet[point]=smoothstep(-0.005,0.10,depths[point])
		impact[point]=maxf(-normal_speeds[point],0.0)*wet[point]
		shallowest=minf(shallowest,depths[point])
	var profile: Resource=settings.splash_appearance
	var tail_profile: Resource=settings.tail_appearance
	var sub := _submersion(profile,shallowest)
	var tail_sub := _submersion(tail_profile,shallowest)
	var flat := _basis_flat()
	_update_tail_bank(delta)
	var forward_speed: float=_vehicle.linear_velocity.dot(-flat.z)
	var speed := _speed(profile,forward_speed)
	var tail_speed := _speed(tail_profile,forward_speed)
	var airborne: bool=water.contact_is_airborne
	var fired: Vector2=gate.step(delta,forward_speed,Vector2(maxf(wet.x,wet.z),maxf(wet.y,wet.w)),
		Vector2(maxf(impact.x,impact.z),maxf(impact.y,impact.w)),airborne or sub<=0.01 or not profile.enabled,settings)
	_advance_clock(0,delta,profile,speed,1.0 if not airborne and profile.enabled and settings.sides_enabled else 0.0)
	_advance_clock(1,delta,tail_profile,tail_speed,_tail_intensity)
	for side in 2:
		var y: float=(surfaces[side].y*wet[side]+surfaces[side+2].y*wet[side+2])/maxf(wet[side]+wet[side+2],0.001)
		_slide(side,profile,y,delta)
		if fired[side]>0.0: _launch(side,fired[side],speed,flat,surfaces,wet)
	for index in _slots.size():
		var slot: Dictionary=_slots[index]
		if slot.age<0.0: continue
		if not settings.sides_enabled or not profile.enabled or sub<=0.01:
			slot.age=-1.0
			slot.sheet.hide()
			continue
		slot.age+=delta
		slot.frame+=delta*maxf(profile.anim_fps,0)*lerpf(profile.anim_speed_low,profile.anim_speed_high,speed)*slot.rate
		if slot.frame>=_layouts[0].frames or slot.age>=settings.side_burst_lifetime:
			slot.age=-1.0
			slot.sheet.hide()
			continue
		var life: float=maxf(slot.frame/float(_layouts[0].frames),slot.age/settings.side_burst_lifetime)
		var fade := smoothstep(0.04,0.18,life)*(1.0-smoothstep(0.65,1.0,life))
		slot.sheet.global_position=slot.origin+slot.velocity*((1.0-exp(-slot.age*1.5))/1.5)
		_follow_side_surface(slot,index/2,water)
		_set_frame(slot.material,0,slot.frame,false)
		slot.material.set_shader_parameter("sprite_age",slot.age)
		slot.material.set_shader_parameter("contact_factor",slot.strength*fade*sub)
		_animate(slot.material,profile,0,slot.speed,clampf(slot.strength,0,1),index/2)
	var stern_wet := maxf(wet.z,wet.w)
	if is_instance_valid(_mist):
		var stern_y: float=(surfaces[2].y*wet.z+surfaces[3].y*wet.w)/maxf(wet.z+wet.w,0.001)
		var nozzle := _anchor_pose(2,flat)
		for emitter in _mist_emitters:
			if is_instance_valid(emitter): emitter.step(delta,Transform3D(flat,nozzle.origin),stern_y,forward_speed,_vehicle.throttle_input,0.0 if airborne else stern_wet*tail_sub,_scene_light_tint)
	var target := 0.0
	if settings.tail_enabled and tail_profile.enabled and not airborne and stern_wet>0.05:
		target=smoothstep(0.04,0.6,_vehicle.throttle_input)*lerpf(0.3,1.0,tail_speed)*stern_wet*tail_sub
	var residual_enabled: bool=settings.tail_enabled and tail_profile.enabled and tail_sub>0.01
	var spit: float=_residual.step(delta,target>0.01,residual_enabled,settings.tail_residual_seconds,settings.tail_residual_strength)
	var residual_mode: bool=(airborne or stern_wet<=0.05) and spit>0.001
	_tail_intensity=lerpf(_tail_intensity,target,1.0-exp(-delta*(10.0 if target>_tail_intensity else 16.0)))
	if airborne or stern_wet<=0.05: _tail_intensity=spit if residual_mode else 0.0
	if not residual_enabled: _tail_intensity=0.0
	_tail_material.set_shader_parameter("tail_residual",residual_mode)
	_tail.visible=_tail_intensity*tail_profile.spray_opacity>0.002
	if _tail.visible:
		var pose := _anchor_pose(2,flat)
		var y: float=(surfaces[2].y*wet.z+surfaces[3].y*wet.w)/maxf(wet.z+wet.w,0.001)
		# Water height clips the spray; it must not relocate the physical nozzle.
		_tail.global_transform=pose
		_tail_frame=fposmod(_tail_frame+delta*maxf(tail_profile.anim_fps,0)*lerpf(tail_profile.anim_speed_low,tail_profile.anim_speed_high,tail_speed),float(_layouts[1].frames))
		_set_frame(_tail_material,1,_tail_frame,true)
		_tail_material.set_shader_parameter("sprite_waterline_y",y)
		_tail_material.set_shader_parameter("contact_factor",_tail_intensity)
		_tail_material.set_shader_parameter("attachment_offset",pose.basis.inverse()*_slide(2,tail_profile,y,delta))
		_animate(_tail_material,tail_profile,1,tail_speed,_tail_intensity,2)

func _launch(side: int, strength: float, speed: float, flat: Basis, surfaces: PackedVector3Array, wet: Vector4) -> void:
	var index := -1
	for candidate in range(side*2,side*2+2):
		if _slots[candidate].age<0.0:
			index=candidate
			break
	if index<0:
		pool_dropped+=1
		return
	var slot: Dictionary=_slots[index]
	var pose := _anchor_pose(side,flat)
	# With just the bow or stern wet, emit at that actual contact station rather
	# than beneath a dry middle section of the hull.
	if (wet[side]<0.05)!=(wet[side+2]<0.05):
		var touching := side if wet[side]>=0.05 else side+2
		pose.origin+=flat.z*(surfaces[touching]-pose.origin).dot(flat.z)
	var total := wet[side]+wet[side+2]
	var y: float=(surfaces[side].y*wet[side]+surfaces[side+2].y*wet[side+2])/maxf(total,0.001)
	slot.sheet.global_transform=pose
	_follow_side_surface(slot,side,_vehicle.water_physics_system)
	slot.origin=pose.origin
	slot.origin.y=slot.sheet.global_position.y
	slot.velocity=Vector3(_vehicle.linear_velocity.x,0,_vehicle.linear_velocity.z)*settings.side_velocity_inheritance
	slot.age=0.0
	slot.frame=0.0
	slot.rate=gate.rng.randf_range(0.88,1.15)
	slot.strength=strength
	slot.speed=speed
	slot.material.set_shader_parameter("sprite_waterline_y",y)
	var offset := pose.basis.inverse()*_attachment[side]
	offset.y=0.0
	slot.material.set_shader_parameter("attachment_offset",offset)
	slot.sheet.show()
	rendered_bursts[side]+=1

func _side_surface(side: int, point: Vector3, water: Variant) -> Dictionary:
	var samples: PackedVector3Array=water.point_water_surface_positions
	var valid=water.point_sample_valid
	var front := side
	var rear := side+2
	if not valid[front] and not valid[rear]: return {}
	if not valid[front]: front=rear
	if not valid[rear]: rear=front
	var a := samples[front]
	var b := samples[rear]
	if not a.is_finite() or not b.is_finite(): return {}
	var span := Vector2(b.x-a.x,b.z-a.z)
	var t := clampf(Vector2(point.x-a.x,point.z-a.z).dot(span)/maxf(span.length_squared(),0.001),0.0,1.0)
	var sample := a.lerp(b,t)
	var normal := Vector3.UP
	var normals=water.get("point_water_normals")
	if normals!=null and normals.size()>=4:
		normal=normals[front].lerp(normals[rear],t).normalized()
	if not normal.is_finite() or normal.y<0.25: normal=Vector3.UP
	sample.y-=(normal.x*(point.x-sample.x)+normal.z*(point.z-sample.z))/maxf(normal.y,0.25)
	return {"height":sample.y,"normal":normal}

func _follow_side_surface(slot: Dictionary, side: int, water: Variant) -> void:
	var surface := _side_surface(side,slot.sheet.global_position,water)
	if surface.is_empty():
		slot.sheet.hide()
		return
	var point: Vector3=slot.sheet.global_position
	point.y=surface.height+0.015
	slot.sheet.global_position=point
	var normal: Vector3=slot.sheet.global_basis.transposed()*surface.normal
	var slope := Vector2(-normal.x,-normal.z)/maxf(normal.y,0.25)
	slot.material.set_shader_parameter("splash_surface_slope",slope)
	slot.material.set_shader_parameter("sprite_waterline_y",surface.height)

func _preview(delta: float) -> void:
	if _tail_material==null or not is_instance_valid(_tail):
		if not Engine.is_editor_hint(): return
		_ready()
		if _tail_material==null or not is_instance_valid(_tail): return
	if not _ensure_profiles(): return
	if _layouts.is_empty(): _apply_style()
	if _layouts.is_empty(): return
	_update_tail_bank(delta)
	if is_instance_valid(_mist) and settings.stern_mist!=null:
		var mist_style: Resource=settings.stern_mist
		var pose: Transform3D=_anchors[2].global_transform
		var back:=pose.basis.z
		back.y=0.0
		back=back.normalized() if back.length_squared()>0.001 else Vector3.BACK
		pose.basis=Basis(Vector3.UP.cross(back),Vector3.UP,back)
		# Editor preview ignores gameplay wetness/throttle, just like Tail Jet.
		for emitter in _mist_emitters:
			if is_instance_valid(emitter): emitter.step(delta,pose,pose.origin.y,mist_style.preview_speed_kmh/3.6,1.0,1.0 if mist_style.preview_in_editor else 0.0)
	for index in 2:
		var profile: Resource=settings.splash_appearance if index==0 else settings.tail_appearance
		# Preview is explicitly independent of runtime throttle/contact/emission.
		# An artist can tune the jet even when its gameplay emitter is disabled.
		var active: bool=profile.preview_in_editor and profile.enabled
		var speed := _speed(profile,profile.preview_speed)
		_advance_clock(index,delta,profile,speed,1.0 if active else 0.0)
		if index==0:
			for side in 2:
				var slot: Dictionary=_slots[side*2]
				slot.sheet.visible=active
				_slots[side*2+1].sheet.hide()
				if not active: continue
				slot.sheet.global_transform=_anchor_pose(side,Basis.IDENTITY)
				slot.frame=fposmod(slot.frame+delta*maxf(profile.anim_fps,0)*lerpf(profile.anim_speed_low,profile.anim_speed_high,speed),float(_layouts[0].frames))
				slot.material.set_shader_parameter("sprite_loop",true)
				slot.material.set_shader_parameter("sprite_age",0.0)
				slot.material.set_shader_parameter("sprite_waterline_y",slot.sheet.global_position.y-0.05)
				slot.material.set_shader_parameter("contact_factor",1.0)
				slot.material.set_shader_parameter("attachment_offset",slot.sheet.global_basis.inverse()*_slide(side,profile,slot.sheet.global_position.y,delta))
				_set_frame(slot.material,0,slot.frame,true)
				slot.material.set_shader_parameter("splash_surface_fit",false)
				_animate(slot.material,profile,0,speed,1.0,side)
		else:
			_tail.visible=active
			if not active: continue
			_tail.global_transform=_anchor_pose(2,Basis.IDENTITY)
			_tail_frame=fposmod(_tail_frame+delta*maxf(profile.anim_fps,0)*lerpf(profile.anim_speed_low,profile.anim_speed_high,speed),float(_layouts[1].frames))
			_tail_material.set_shader_parameter("sprite_waterline_y",_tail.global_position.y-0.05)
			_tail_material.set_shader_parameter("contact_factor",1.0)
			_tail_material.set_shader_parameter("tail_residual",false)
			_tail_material.set_shader_parameter("attachment_offset",_tail.global_basis.inverse()*_slide(2,profile,_tail.global_position.y,delta))
			_set_frame(_tail_material,1,_tail_frame,true)
			_animate(_tail_material,profile,1,speed,1.0,2)

func _detect_atlas_grid(texture: Texture2D) -> Vector2i:
	var image := texture.get_image()
	if image==null or image.is_empty(): return Vector2i.ZERO
	if image.is_compressed() and image.decompress()!=OK: return Vector2i.ZERO
	image.resize(160,160,Image.INTERPOLATE_NEAREST)
	var columns := PackedInt32Array()
	var rows := PackedInt32Array()
	columns.resize(160)
	rows.resize(160)
	for y in 160:
		for x in 160:
			if image.get_pixel(x,y).a>0.75:
				columns[x]+=1
				rows[y]+=1
	return Vector2i(_alpha_bands(columns),_alpha_bands(rows))

func _alpha_bands(values: PackedInt32Array) -> int:
	var peak := 0
	for value in values: peak=maxi(peak,value)
	var count := 0
	var run := 0
	for value in values:
		if float(value)>float(peak)*0.12: run+=1
		else:
			if run>=2: count+=1
			run=0
	if run>=2: count+=1
	return count if count<=32 else 0

func diagnostic_state() -> Dictionary:
	return {"enabled":_enabled,"variant":_active_variant,"tail_visible":_tail.visible if _tail!=null else false,
		"clock":gate.elapsed,"tail_intensity":_tail_intensity,"events":gate.event_count,"rendered_bursts":rendered_bursts,
		"pool_dropped":pool_dropped,"mesh_instances":_slots.size()+(1 if _tail!=null else 0),
		"shared_atlases":_atlases.size(),"cached_mesh_variants":_meshes.size(),"extra_water_queries":0,
		"shared_bow_shader":true}
