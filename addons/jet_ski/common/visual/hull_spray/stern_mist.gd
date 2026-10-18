@tool
extends GPUParticles3D
## One bounded GPU emitter; no additional water queries or CPU particle loop.
const MistShader = preload("res://addons/jet_ski/common/visual/hull_spray/stern_mist.gdshader")
const MistNoise = preload("res://addons/jet_ski/common/visual/hull_spray/stern_mist_noise.tres")
const MistNormal = preload("res://addons/jet_ski/common/visual/hull_spray/stern_mist_normal.tres")
const FlowShader = preload("res://addons/jet_ski/common/visual/hull_spray/stern_mist_flow.gdshader")
var style: Resource
var _material: ShaderMaterial
var _weight := 0.0
var _generated_particles := false
var _configured := false
var _opacity_speed_kmh := 0.0
var _last_flow_origin := Vector3.ZERO
var _flow_pose_valid := false

func configure(value: Resource) -> void:
	if style!=null and style.changed.is_connected(_apply_style): style.changed.disconnect(_apply_style)
	style=value
	if not _configured:
		_configured=true
		_generated_particles=process_material==null
		if _generated_particles:
			local_coords=false
			physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF
			fixed_fps=30
			interpolate=true
			randomness=0.7
			cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			draw_order=GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
			visibility_aabb=AABB(Vector3(-40,-5,-40),Vector3(80,15,80))
		if draw_pass_1==null:
			var quad := QuadMesh.new()
			quad.size=Vector2(0.30,0.30)
			quad.material=ShaderMaterial.new()
			quad.material.shader=MistShader
			quad.material.render_priority=101
			quad.material.set_shader_parameter("mist_noise",MistNoise)
			quad.material.set_shader_parameter("droplet_normal",MistNormal)
			draw_pass_1=quad
		_material=(material_override if material_override!=null else draw_pass_1.material) as ShaderMaterial
		if _generated_particles: process_material=ParticleProcessMaterial.new()
		emitting=false
		visible=false
	if style!=null:
		style.changed.connect(_apply_style)
		_apply_style()

func _exit_tree() -> void:
	if style!=null and style.changed.is_connected(_apply_style): style.changed.disconnect(_apply_style)

func _apply_style() -> void:
	if style==null: return
	# Authored nodes keep all native particle settings, including lifetime/amount.
	if _generated_particles:
		_apply_generated_particles()
		if _material!=null:
			_material.set_shader_parameter("mist_color",style.color)
			_material.set_shader_parameter("mist_opacity",style.opacity)
			_material.set_shader_parameter("turbulence",style.turbulence)
	if not style.enabled: stop()

func _apply_generated_particles() -> void:
	if amount!=style.amount: amount=style.amount
	if not is_equal_approx(lifetime,style.lifetime_s): lifetime=style.lifetime_s
	var p := process_material as ParticleProcessMaterial
	p.emission_shape=ParticleProcessMaterial.EMISSION_SHAPE_BOX
	p.emission_box_extents=Vector3(style.width_m*0.22,0.04,style.length_m*0.16)
	p.direction=Vector3(0,0.35,1)
	p.spread=65.0
	p.initial_velocity_min=0.25
	p.initial_velocity_max=1.1
	p.gravity=Vector3(0,0.12,0)
	p.damping_min=1.0
	p.damping_max=2.0
	p.scale_min=0.65
	p.scale_max=1.25
	p.turbulence_enabled=style.turbulence>0.001
	p.turbulence_noise_strength=style.turbulence*0.65
	p.turbulence_noise_scale=0.65
	p.turbulence_noise_speed=Vector3(1.2,1.5,-0.8)*style.turbulence
	p.turbulence_noise_speed_random=1.8*style.turbulence
	p.turbulence_influence_min=0.25
	p.turbulence_influence_max=0.65
	if p.color_ramp==null:
		var gradient := Gradient.new()
		gradient.offsets=PackedFloat32Array([0.0,0.14,0.35,1.0])
		gradient.colors=PackedColorArray([Color(1,1,1,0),Color.WHITE,Color.WHITE,Color(1,1,1,0)])
		var ramp := GradientTexture1D.new()
		ramp.gradient=gradient
		p.color_ramp=ramp

func stop() -> void:
	_weight=0.0
	emitting=false
	_flow_pose_valid=false
	var flow := process_material as ShaderMaterial
	if flow!=null and flow.shader==FlowShader: flow.set_shader_parameter("guide_active",false)
	# Leave live particles visible until their own lifetime ends in world space.

func step(delta: float, pose: Transform3D, water_y: float, speed_mps: float, _throttle: float, contact: float) -> void:
	if style==null or not style.enabled: stop(); return
	var target: float=smoothstep(style.start_speed_kmh,maxf(style.full_speed_kmh,style.start_speed_kmh+0.1),maxf(speed_mps,0)*3.6)
	# Mist follows water displacement, including coasting with the throttle closed.
	target*=clampf(contact,0,1)
	# Dry contact stops new emissions; existing world particles finish naturally.
	if contact<=0.001: stop(); return
	_weight=lerpf(_weight,target,1.0-exp(-delta*(5.0 if target>_weight else 12.0)))
	var center: Vector3=pose.origin+pose.basis*Vector3(style.offset.x,0,style.offset.z)
	# Vertical authoring remains useful even when the nozzle is submerged.
	center.y=maxf(pose.origin.y,water_y)+style.offset.y
	global_transform=Transform3D(pose.basis,center)
	var flow := process_material as ShaderMaterial
	if flow!=null and flow.shader==FlowShader:
		var hull_velocity := Vector3.ZERO
		if _flow_pose_valid and delta>0.00001:
			hull_velocity=(center-_last_flow_origin)/delta
			hull_velocity.y=0.0
		_last_flow_origin=center
		_flow_pose_valid=true
		flow.set_shader_parameter("hull_transform",global_transform)
		flow.set_shader_parameter("hull_speed_mps",maxf(speed_mps,0.0))
		flow.set_shader_parameter("particle_lifetime_s",lifetime)
		flow.set_shader_parameter("hull_velocity",hull_velocity)
		flow.set_shader_parameter("guide_active",true)
		var side: float=flow.get_shader_parameter("side")
		# Headless editor validation cannot always reflect unassigned shader defaults.
		var width_value: Variant=flow.get_shader_parameter("front_width")
		var z_value: Variant=flow.get_shader_parameter("front_z")
		var front_width: float=0.3 if width_value==null else float(width_value)
		var front_z: float=-2.95 if z_value==null else float(z_value)
		global_position+=pose.basis*Vector3(side*front_width,0,front_z)
	emitting=_weight>0.01
	visible=true
	if _generated_particles: amount_ratio=maxf(_weight,0.001)
	var active_material := material_override as ShaderMaterial
	if active_material==null and draw_pass_1!=null: active_material=draw_pass_1.material as ShaderMaterial
	if active_material!=null and active_material.shader==MistShader:
		active_material.set_shader_parameter("waterline_y",water_y)
		_opacity_speed_kmh=lerpf(_opacity_speed_kmh,maxf(speed_mps,0.0)*3.6,1.0-exp(-delta*6.0))
		active_material.set_shader_parameter("speed_kmh",_opacity_speed_kmh)
