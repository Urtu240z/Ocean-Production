extends SceneTree
## GPU regression: birth stays at the hull, reversing does not teleport foam,
## and lateral transport opens the older trail. Readbacks are outside benchmarks.
const History := preload("res://addons/ocean/surface/foam2d/projected_wake_history.gd")
var finished := false
var result := {}

func _initialize() -> void:
	RenderingServer.call_on_render_thread(_exercise)
	_wait.call_deferred()

func _wait() -> void:
	while not finished: await process_frame
	FileAccess.open("res://temp/foam2d/motion_contract.json",FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
	print("FOAM2D_CONTRACT ",result)
	quit(0 if result.get("passed",false) else 1)

func _exercise() -> void:
	var history := History.new()
	history.initialize()
	if not history.ready:
		result={"passed":false,"error":history.last_error}
		finished=true
		return
	history.set_view_center(Vector2.ZERO)
	history.set_motion(Vector3(1.0,0.0,0.0))
	for i in 12:
		history.submit_hull(Vector2.ZERO,Vector2.ZERO,Vector2(0,-1),0.0,Vector4.ONE,Vector4.ZERO,0.075)
		history.advance(0.075)
	var stationary := _snapshot(history)
	history.submit_hull(Vector2(0,0.02),Vector2.ZERO,Vector2(0,-1),0.02/0.075,Vector4.ONE,Vector4.ZERO,0.075)
	history.advance(0.075)
	var reverse_start := _snapshot(history)
	for step in 100:
		var previous := Vector2(0,0.02+step*0.2)
		var current := previous+Vector2(0,0.2)
		history.submit_hull(current,previous,Vector2(0,-1),0.2/0.075,Vector4.ONE,Vector4.ONE*0.7,0.075)
		history.advance(0.075)
	var trail := _snapshot(history)
	var narrow := _trail_motion(Vector3(0.35,0.0,0.0))
	var closed := _trail_motion(Vector3.ZERO)
	var still := _rest_motion(Vector3.ZERO)
	var moving := _rest_motion(Vector3(0.0,0.60,0.60))
	var radial := _pulse_transport(0.0,0.75)
	var impact := _pulse_transport(1.0,0.75)
	var fixed := _pulse_transport(0.0,0.0)
	var original_shape := _shape_lifetime(Vector2(0.56,24.0))
	var wide_shape := _shape_lifetime(Vector2(1.6,24.0))
	var short_shape := _shape_lifetime(Vector2(0.56,2.0))
	var failures: Array[String]=[]
	if stationary.active == 0: failures.append("No foam was deposited")
	if reverse_start.min_y < -2.2 or reverse_start.max_y > 2.3: failures.append("Reverse birth escaped the hull footprint")
	if trail.old_half_width < trail.new_half_width+0.5: failures.append("Older foam did not open laterally")
	if stationary.max_agitation > 0.01: failures.append("Calm stationary foam acquired whitening energy")
	if trail.max_agitation < 0.4: failures.append("Agitated foam did not receive whitening energy")
	if stationary.quadrants.min() <= 0: failures.append("A wet hull quadrant did not receive foam")
	if history.max_sweep_m > 0.201: failures.append("Deposit extended beyond actual travel")
	if narrow.old_half_width >= trail.old_half_width-0.4: failures.append("Narrow setting did not reduce wake expansion")
	if closed.old_half_width >= narrow.old_half_width-0.3: failures.append("Zero opening did not close the fan")
	if moving.centroid.distance_to(still.centroid) < 0.10: failures.append("Calm foam did not move independently of the wake")
	if radial.first.max_x > 0.65 or radial.first.min_x < -0.65: failures.append("Birth did not stay beneath the inner hull")
	if radial.last.mean_abs_x < radial.first.mean_abs_x+0.10: failures.append("Pigment did not move from the centre towards the sides")
	if impact.last.mean_abs_x < radial.last.mean_abs_x+0.15: failures.append("Impact did not strengthen outward transport")
	if absf(fixed.last.mean_abs_x-fixed.first.mean_abs_x)>0.04: failures.append("Disabled outward transport still expanded the pigment")
	if wide_shape.first.mean_abs_x < original_shape.first.mean_abs_x+0.1: failures.append("Initial width did not widen the birth footprint")
	if short_shape.last.active >= original_shape.last.active: failures.append("Short lifetime did not fade foam earlier")
	result={"passed":failures.is_empty(),"failures":failures,"stationary":stationary,
		"reverse_after_2cm":reverse_start,"trail_after_20m":trail,"narrow":narrow,"closed":closed,
		"still":still,"moving":moving,"history":history.diagnostic_state()}
	result.radial_pulse=radial
	result.impact_pulse=impact
	result.transport_disabled=fixed
	result.original_shape=original_shape
	result.wide_shape=wide_shape
	result.short_shape=short_shape
	history.shutdown()
	finished=true

func _shape_lifetime(shape: Vector2) -> Dictionary:
	var history := History.new()
	history.initialize()
	history.set_view_center(Vector2.ZERO)
	history.set_motion(Vector3.ZERO)
	history.set_outward(Vector2.ZERO)
	history.set_shape(shape)
	for step in 12:
		history.submit_hull(Vector2.ZERO,Vector2.ZERO,Vector2(0,-1),0.0,Vector4.ONE,Vector4.ZERO,0.075)
		history.advance(0.075)
	var first := _snapshot(history)
	for step in 60: history.advance(0.075)
	var last := _snapshot(history)
	history.shutdown()
	return {"first":first,"last":last}

func _pulse_transport(pressure: float, speed: float) -> Dictionary:
	var history := History.new()
	history.initialize()
	history.set_view_center(Vector2.ZERO)
	history.set_motion(Vector3.ZERO) # Wake opening zero must not stop contact transport.
	history.set_outward(Vector2(speed,1.5))
	for step in 4:
		history.submit_hull(Vector2.ZERO,Vector2.ZERO,Vector2(0,-1),0.0,Vector4.ONE,Vector4.ZERO,0.075,pressure)
		history.advance(0.075)
	var first := _snapshot(history)
	# No more deposits: a growing footprint alone cannot pass this check.
	for step in 20: history.advance(0.075)
	var last := _snapshot(history)
	history.shutdown()
	return {"first":first,"last":last,"emission_stopped":true}

func _trail_motion(motion: Vector3) -> Dictionary:
	var history := History.new()
	history.initialize()
	history.set_motion(motion)
	history.set_view_center(Vector2.ZERO)
	for step in 100:
		var previous := Vector2(0,0.02+step*0.2)
		var current := previous+Vector2(0,0.2)
		history.submit_hull(current,previous,Vector2(0,-1),0.2/0.075,Vector4.ONE,Vector4.ONE*0.7,0.075)
		history.advance(0.075)
	var snapshot := _snapshot(history)
	history.shutdown()
	return snapshot

func _rest_motion(motion: Vector3) -> Dictionary:
	var history := History.new()
	history.initialize()
	history.set_motion(motion)
	history.set_view_center(Vector2.ZERO)
	for step in 12:
		history.submit_hull(Vector2.ZERO,Vector2.ZERO,Vector2(0,-1),0.0,Vector4.ONE,Vector4.ZERO,0.075)
		history.advance(0.075)
	for step in 32: history.advance(0.075)
	var snapshot := _snapshot(history)
	history.shutdown()
	return snapshot

func _snapshot(history: RefCounted) -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute="""#version 450
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
	var lo := Vector2(INF,INF)
	var hi := Vector2(-INF,-INF)
	var active := 0
	var old_width := 0.0
	var new_width := 0.0
	var quadrants := PackedInt32Array([0,0,0,0])
	var max_agitation := 0.0
	var mass := 0.0
	var weighted_position := Vector2.ZERO
	var weighted_abs_x := 0.0
	for cell in 512*512:
		if values[cell*4] < 0.005: continue
		var point: Vector2 = history.region_origin+Vector2((cell%512)+0.5,(cell/512)+0.5)*0.25
		lo=lo.min(point)
		hi=hi.max(point)
		active+=1
		mass += values[cell*4]
		weighted_position += point * values[cell*4]
		weighted_abs_x += absf(point.x)*values[cell*4]
		quadrants[(0 if point.x<0.0 else 1)+(0 if point.y<0.0 else 2)]+=1
		max_agitation=maxf(max_agitation,values[cell*4+3]/maxf(values[cell*4],0.00001))
		if point.y>6.0 and point.y<11.0: old_width=maxf(old_width,absf(point.x))
		if point.y>18.0 and point.y<21.0: new_width=maxf(new_width,absf(point.x))
	var area := maxf((hi.x-lo.x+0.25)*(hi.y-lo.y+0.25)/0.0625,1.0)
	for rid in [set_rid,buffer,pipeline,shader]: rd.free_rid(rid)
	return {"active":active,"min_x":lo.x,"max_x":hi.x,"min_y":lo.y,"max_y":hi.y,
		"centroid":weighted_position/maxf(mass,0.00001),
		"mean_abs_x":weighted_abs_x/maxf(mass,0.00001),
		"filled_fraction":active/area,"old_half_width":old_width,"new_half_width":new_width,
		"quadrants":Array(quadrants),"max_agitation":max_agitation}
