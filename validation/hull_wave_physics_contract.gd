extends SceneTree
## Native/GPU numerical contract. Readback is validation-only, never gameplay.
const State := preload("res://addons/ocean/physics/water/hull_wave_state.gd")
const Style := preload("res://addons/ocean/surface/foam2d/foam2d_style.gd")
const Field := preload("res://addons/ocean/surface/foam2d/hull_wave_field.gd")
var _pixels := PackedFloat32Array()
var _received := false

func _initialize() -> void:
	run.call_deferred()

func publish(native: Object, packets: Array[Dictionary], clock: float) -> void:
	var rows := PackedFloat64Array()
	var owners := PackedInt64Array()
	for p in packets:
		rows.append_array(PackedFloat64Array([p.position.x,p.position.y,p.forward.x,p.forward.y,
			p.amplitude,p.speed,p.width,p.wavelength,p.life,p.half_length,p.born,p.rise,p.fade,
			p.get("inverse_speed",0.0),p.get("start_radius",0.0),p.get("source_start",clock-100000.0),
			p.get("birth_distance",0.65),1.0 if p.impact else 0.0]))
		owners.append(p.owner)
	assert(native.publish_hull_waves(rows,owners,clock))

func value(native: Object, position: Vector3, owner := 0, delay := 0.0, cap := 0.0) -> PackedFloat64Array:
	return native.sample_hull_waves(PackedVector3Array([position]),owner,Vector3.ZERO,delay,3.0,cap)

func packets() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for owner in [1,2]:
		for i in 40:
			var time := 20.0-float(i)*0.4
			result.append({"owner":owner,"position":Vector2(float(owner-1)*0.8,8.0*(20.0-time)+2.72),
				"forward":Vector2(0,-1),"born":time-2.72/8.0,"life":20.0,"amplitude":0.3,
				"speed":0.7,"width":1.1,"wavelength":4.0,"half_length":2.72,"impact":false,
				"start_radius":0.5,"rise":0.75,"fade":2.0,"inverse_speed":0.125,"time_span":0.34,
				"source_start":0.0,"birth_distance":0.65})
	result.append({"owner":1,"position":Vector2(0,10),"forward":Vector2(0,-1),"born":18.5,
		"life":4.0,"amplitude":0.2,"speed":1.0,"width":1.2,"wavelength":5.0,
		"half_length":1.0,"impact":true,"start_radius":0.0,"rise":0.4,"fade":1.4})
	return result

func run() -> void:
	assert(ClassDB.class_exists("OceanQueryNative"))
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	assert(native.has_method("publish_hull_waves"),"Updated native extension was not loaded")
	var ps := packets()
	publish(native,ps,20.0)
	var field := Field.new()
	RenderingServer.call_on_render_thread(field.initialize)
	for frame in 600:
		await process_frame
		if field.ready or not field.last_error.is_empty(): break
	assert(field.ready,field.last_error)
	RenderingServer.call_on_render_thread(func():
		field.draw(ps,Vector2(-64,-64),20.0)
		var image := Image.create_from_data(512,512,false,Image.FORMAT_RGBAH,field.get("_rd").texture_get_data(field.texture_rid,0))
		image.convert(Image.FORMAT_RGBAF)
		_pixels = image.get_data().to_float32_array()
		_received = true)
	for frame in 600:
		await process_frame
		if _received: break
	assert(_received)
	var points := PackedVector3Array()
	for z in range(272,352,3):
		for x in range(240,272,2): points.append(Vector3(-64+(x+0.5)*0.25,0,-64+(z+0.5)*0.25))
	var values: PackedFloat64Array = native.sample_hull_waves(points,0,Vector3.ZERO,0.0,3.0,0.0)
	var max_error := Vector3.ZERO
	for i in points.size():
		var x := int((points[i].x+64.0)/0.25)
		var z := int((points[i].z+64.0)/0.25)
		for component in 3:
			max_error[component] = maxf(max_error[component],absf(values[i*4+component]-_pixels[(z*512+x)*4+component]))
	assert(max_error.x<0.004 and max_error.y<0.012 and max_error.z<0.012,"Native/GPU mismatch: %s" % max_error)
	var derivative_error := Vector3.ZERO
	for q in [Vector3(1.125,0,10.125),Vector3(-1.125,0,12.125),Vector3(2.125,0,6.125)]:
		var h := 0.0002
		var center := value(native,q)
		var dx := (value(native,q+Vector3(h,0,0))[0]-value(native,q-Vector3(h,0,0))[0])/(2*h)
		var dz := (value(native,q+Vector3(0,0,h))[0]-value(native,q-Vector3(0,0,h))[0])/(2*h)
		publish(native,ps,20+h)
		var future := value(native,q)[0]
		publish(native,ps,20-h)
		var past := value(native,q)[0]
		publish(native,ps,20.0)
		derivative_error.x=maxf(derivative_error.x,absf(dx-center[1]))
		derivative_error.y=maxf(derivative_error.y,absf(dz-center[2]))
		derivative_error.z=maxf(derivative_error.z,absf((future-past)/(2*h)-center[3]))
	assert(derivative_error.length()<0.002,"Analytic derivatives: %s" % derivative_error)
	var impact: Array[Dictionary] = [ps[-1].duplicate(true)]
	impact[0].position=Vector2.ZERO
	impact[0].born=0.0
	publish(native,impact,0.2)
	var raw := value(native,Vector3(0.2,0,0),0)
	var own := value(native,Vector3(0.2,0,0),1,0.8)
	var other := value(native,Vector3(0.2,0,0),2,0.8)
	assert(absf(own[0])<absf(raw[0])*0.5 and other==raw,"Self protection affected another owner")
	publish(native,impact,1.6)
	assert(value(native,Vector3(1.6,0,0),1,0.8)==value(native,Vector3(1.6,0,0),0),"Old own wake was excluded")
	# The returned sample's depth, normal and velocity must compose once, and
	# invalid base water must remain invalid. Geometry history is tested in runtime.
	var state := State.new()
	state.set("_native",native)
	state.set("_ready",true)
	var style := Style.new()
	var samples: Array[WaterSample3D] = [WaterSample3D.new(),WaterSample3D.new()]
	samples[0].valid=true
	samples[0].normal=Vector3.UP
	var query := PackedVector3Array([Vector3(1.6,-0.2,0),Vector3.ZERO])
	var expected := value(native,query[0])
	state.apply(samples,query,style)
	assert(absf(samples[0].surface_position.y-expected[0])<0.000001)
	assert(absf(samples[0].signed_depth-expected[0]-0.2)<0.000001)
	assert(samples[0].normal.distance_to(Vector3(-expected[1],1,-expected[2]).normalized())<0.00001)
	assert(not samples[1].valid)
	# Empty and malformed publications cannot retain stale waves.
	assert(not native.publish_hull_waves(PackedFloat64Array([1.0]),PackedInt64Array([1]),2.0))
	assert(value(native,Vector3.ZERO)==PackedFloat64Array([0,0,0,0]))
	var report := {"passed":true,"gpu_points":points.size(),"gpu_max_height_slope_error":str(max_error),
		"derivative_max_error":str(derivative_error),"self_recent_attenuated":true,"old_self_and_other_owner_physical":true,
		"sample_composition":true,"invalid_publication_cleared":true}
	print("HULL_WAVE_PHYSICS_CONTRACT_PASS ",JSON.stringify(report))
	DirAccess.make_dir_recursive_absolute("res://temp/hull_wave_physics")
	FileAccess.open("res://temp/hull_wave_physics/contract.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	RenderingServer.call_on_render_thread(field.shutdown)
	for frame in 5: await process_frame
	quit()
