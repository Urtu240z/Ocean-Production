extends SceneTree
## GPU regression: sampling cadence must not create transverse bands.
const Field := preload("res://addons/ocean/surface/foam2d/hull_wave_field.gd")
const ORIGIN := Vector2(-64,-64)
const OUTPUT := "res://temp/foam2d/continuous_waves"
var _pixels := PackedFloat32Array()
var _received := false

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	var field := Field.new()
	RenderingServer.call_on_render_thread(field.initialize)
	for frame in 300:
		await process_frame
		if field.ready or not field.last_error.is_empty(): break
	assert(field.ready,field.last_error)
	var dense := await draw_field(field,make_packets(0.2),20.0)
	var sparse := await draw_field(field,make_packets(1.2),20.0)
	var cadence := difference(dense,sparse)
	assert(cadence.rms < 0.003 and cadence.maximum < 0.02,"Emission cadence left seams: %s" % cadence)
	save_height(dense,"continuous_dense.png")
	save_height(sparse,"continuous_sparse.png")
	var legacy_result := {}
	var legacy_path := OUTPUT.path_join("before/hull_wave_field.gd")
	if FileAccess.file_exists(legacy_path):
		var legacy: RefCounted = load(legacy_path).new()
		RenderingServer.call_on_render_thread(legacy.initialize)
		for frame in 300:
			await process_frame
			if legacy.ready or not legacy.last_error.is_empty(): break
		assert(legacy.ready,legacy.last_error)
		var old_dense := await draw_field(legacy,make_packets(0.2,false,0.7,true),20.0)
		var old_sparse := await draw_field(legacy,make_packets(1.2,false,0.7,true),20.0)
		legacy_result = difference(old_dense,old_sparse)
		save_height(old_dense,"previous_dense.png")
		save_height(old_sparse,"previous_sparse.png")
		assert(legacy_result.rms > cadence.rms*3.0,"Fixture did not reproduce the prior cadence artifact")
		RenderingServer.call_on_render_thread(legacy.shutdown)
	var reversed := await draw_field(field,make_packets(0.2,true),20.0)
	var reverse_error := difference(dense,reversed,true)
	assert(reverse_error.rms < 0.003,"Reverse did not preserve the outward wave: %s" % reverse_error)
	var owners := make_packets(0.2)
	for packet in make_packets(0.2):
		packet.owner = 2
		owners.append(packet)
	var doubled := await draw_field(field,owners,20.0)
	var owner_error := difference(dense,doubled,false,2.0)
	assert(owner_error.rms < 0.003,"Independent boats were averaged together")
	var normals := gradient_error(dense)
	assert(normals < 0.025,"Slopes do not follow the continuous geometry: %s" % normals)
	var later := await draw_field(field,make_packets(0.2),21.0)
	var slow_travel := crest_x(later)-crest_x(dense)
	var fast_now := await draw_field(field,make_packets(0.2,false,2.0),20.0)
	var fast_later := await draw_field(field,make_packets(0.2,false,2.0),21.0)
	var fast_travel := crest_x(fast_later)-crest_x(fast_now)
	assert(absf(slow_travel-0.7) <= 0.3 and absf(fast_travel-2.0) <= 0.3,"Speed control did not move the crest: %s / %s" % [slow_travel,fast_travel])
	var front_report := await check_front(field)
	# Scratch buffers must be cleared between owners and draws.
	var empty: Array[Dictionary] = []
	var zero := await draw_field(field,empty,21.0)
	assert(zero.count(0.0) == zero.size(),"Old wave data survived an empty update")
	var report := {"passed":true,"cadence_0_2_vs_1_2_s":cadence,"previous_cadence":legacy_result,
		"reverse":reverse_error,"two_boat_superposition":owner_error,"slope_rms_error":normals,
		"crest_travel_1_s":{"speed_0_7_mps":slow_travel,"speed_2_mps":fast_travel},"live_front_rise_0_1":front_report,"field":field.diagnostic_state()}
	FileAccess.open(OUTPUT.path_join("continuity_report.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("HULL_WAVE_CONTINUITY_PASS ",JSON.stringify(report))
	RenderingServer.call_on_render_thread(field.shutdown)
	for frame in 3: await process_frame
	quit()

func make_packets(interval: float, reverse := false, outward_speed := 0.7, legacy := false, clock := 20.0, rise := 0.75) -> Array[Dictionary]:
	var packets: Array[Dictionary] = []
	var speed := 8.0
	var forward := Vector2(0,1 if reverse else -1)
	var half_length := maxf(maxf(speed*interval*0.85,speed*rise*0.6),1.0)
	var count := floori(clock/interval)
	for i in range(1,count+1):
		var time := float(i)*interval
		var position := -forward*speed*(clock-time)
		packets.append({"owner":1,"position":position-forward*half_length,"forward":forward,
			"born":time if legacy else time-half_length/speed,"life":20.0,
			"amplitude":0.4*(speed*interval/(1.5*half_length) if legacy else 1.0),"speed":outward_speed,
			"width":1.1,"wavelength":4.0,"half_length":half_length,"impact":false,
			"start_radius":0.5,"rise":rise,"fade":2.0,"inverse_speed":1.0/speed,"time_span":half_length/speed})
	return packets

func check_front(field: RefCounted) -> Dictionary:
	var before: RefCounted
	var path := "res://temp/foam2d/live_front/before/hull_wave_field.gd"
	if FileAccess.file_exists(path):
		before = load(path).new()
		RenderingServer.call_on_render_thread(before.initialize)
		for frame in 300:
			await process_frame
			if before.ready: break
		assert(before.ready,before.last_error)
	var samples: Array[float] = []
	var previous: Array[float] = []
	var ahead := 0.0
	for i in 37:
		var clock := 24.0+float(i)/30.0
		var packets := make_packets(1.2,false,0.7,false,clock,0.1)
		if before != null:
			var old_pixels := await draw_field(before,packets,clock)
			previous.append(old_pixels[(258*512+258)*4])
		var elapsed: float = clock-floorf(clock/1.2)*1.2
		if elapsed > 0.00001:
			var length := maxf(8.0*elapsed*0.85,1.0)
			packets.append({"owner":1,"position":Vector2(0,length),"forward":Vector2(0,-1),"born":clock-length/8.0,
				"life":20.0,"amplitude":0.4,"speed":0.7,"width":1.1,"wavelength":4.0,"half_length":length,
				"impact":false,"start_radius":0.5,"rise":0.1,"fade":2.0,"inverse_speed":0.125,"time_span":length/8.0,
				"source_start":0.0,"birth_distance":0.65})
		var pixels := await draw_field(field,packets,clock)
		samples.append(pixels[(258*512+258)*4])
		ahead = maxf(ahead,absf(pixels[(255*512+258)*4]))
	var span: float = samples.max()-samples.min()
	assert(samples.min() > 0.15 and span < 0.015,"Near-bow wave still pulsed: %s" % [samples])
	assert(ahead < 0.0001,"Live front generated water ahead of the bow")
	var old_span: float = previous.max()-previous.min() if not previous.is_empty() else 0.0
	if before != null:
		assert(old_span > 0.03,"Fixture did not reproduce the old birth pulse")
		RenderingServer.call_on_render_thread(before.shutdown)
	return {"duration_s":20.0,"rise_s":0.1,"archive_interval_s":1.2,"sample_distance_from_bow_m":0.625,
		"minimum_height_m":samples.min(),"height_span_m":span,"previous_height_span_m":old_span,"ahead_height_m":ahead}

func draw_field(field: RefCounted, packets: Array[Dictionary], clock: float) -> PackedFloat32Array:
	_received = false
	RenderingServer.call_on_render_thread(func():
		field.draw(packets,ORIGIN,clock)
		var bytes: PackedByteArray = field.get("_rd").texture_get_data(field.texture_rid,0)
		var image := Image.create_from_data(512,512,false,Image.FORMAT_RGBAH,bytes)
		image.convert(Image.FORMAT_RGBAF)
		_pixels = image.get_data().to_float32_array()
		_received = true)
	for frame in 300:
		await process_frame
		if _received: break
	assert(_received,"GPU readback timed out")
	return _pixels

func difference(first: PackedFloat32Array, second: PackedFloat32Array, mirror := false, multiplier := 1.0) -> Dictionary:
	var square := 0.0
	var maximum := 0.0
	var count := 0
	for y in range(320,448): # 16–48 m behind the hull, clear of birth and expiry.
		for x in range(224,288):
			var a := first[(y*512+x)*4]*multiplier
			var b := second[((511-y if mirror else y)*512+x)*4]
			var error := absf(a-b)
			square += error*error
			maximum = maxf(maximum,error)
			count += 1
	return {"rms":sqrt(square/count),"maximum":maximum}

func gradient_error(pixels: PackedFloat32Array) -> float:
	var square := 0.0
	var count := 0
	for y in range(320,448):
		for x in range(224,288):
			var i := (y*512+x)*4
			var dx := (pixels[i+4]-pixels[i-4])/0.5
			var dz := (pixels[i+512*4]-pixels[i-512*4])/0.5
			square += pow(dx-pixels[i+1],2.0)+pow(dz-pixels[i+2],2.0)
			count += 2
	return sqrt(square/count)

func crest_x(pixels: PackedFloat32Array) -> float:
	var y := 352 # z = 24.125 m.
	var best := -INF
	var location := 0.0
	for x in range(258,320):
		var height := pixels[(y*512+x)*4]
		if height > best:
			best = height
			location = ORIGIN.x+(float(x)+0.5)*0.25
	return location

func save_height(pixels: PackedFloat32Array, filename: String) -> void:
	var image := Image.create(512,512,false,Image.FORMAT_RGB8)
	for y in 512:
		for x in 512:
			var height := pixels[(y*512+x)*4]
			image.set_pixel(x,511-y,Color(0.08+maxf(height,0.0)*2.0,0.08,0.08+maxf(-height,0.0)*2.0))
	image.save_png(OUTPUT.path_join(filename))
