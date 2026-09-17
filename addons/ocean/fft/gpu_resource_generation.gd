class_name OceanGPUResourceGeneration
extends RefCounted
## Render-thread-owned lifecycle token for one FFT generation.
##
## The main thread may retire this token at any time. Every GPU callback checks
## `active` before and after allocation; a retired callback owns its cleanup and
## can therefore safely outlive OpenOceanFFT itself.

static var _global_generation_counter: int = 0

var generation: int
var sequence: int
var active := true
var neutral_ready := false
var neutral_error := ""
var neutral_displacement_rid := RID()
var neutral_normal_rid := RID()
var neutral_crest_rid := RID()
var _publication_mutex := Mutex.new()
var _publication_revision := 0
var _publication_snapshot: Dictionary = {}


func _init(id: int) -> void:
	sequence = id
	# A process-wide counter keeps generations unique even when Godot reuses an
	# object instance ID during a same-frame Ocean rebuild.
	_global_generation_counter += 1
	generation = _global_generation_counter
	_publish_snapshot()


func retire() -> void:
	_publication_mutex.lock()
	active = false
	neutral_ready = false
	_publication_mutex.unlock()
	_publish_snapshot()


func is_active() -> bool:
	_publication_mutex.lock()
	var result: bool = active
	_publication_mutex.unlock()
	return result


func get_publication_snapshot() -> Dictionary:
	_publication_mutex.lock()
	var result: Dictionary = _publication_snapshot.duplicate()
	_publication_mutex.unlock()
	return result


func _publish_snapshot() -> void:
	_publication_mutex.lock()
	_publication_revision += 1
	var resources_ready: bool = active and neutral_ready and neutral_displacement_rid.is_valid() and neutral_normal_rid.is_valid() and neutral_crest_rid.is_valid()
	_publication_snapshot = {
		"generation": generation,
		"sequence": sequence,
		"active": active,
		"neutral_ready": resources_ready,
		"neutral_error": neutral_error,
		"neutral_displacement_rid": neutral_displacement_rid if resources_ready else RID(),
		"neutral_normal_rid": neutral_normal_rid if resources_ready else RID(),
		"neutral_crest_rid": neutral_crest_rid if resources_ready else RID(),
		"publication_revision": _publication_revision,
	}
	_publication_mutex.unlock()


func create_neutral_resources() -> void:
	if not is_active() or get_publication_snapshot().get("neutral_ready", false):
		return
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		neutral_error = "RenderingDevice global no disponible para neutrales FFT."
		_publish_snapshot()
		return

	var created: Array[RID] = []
	var displacement_format := RDTextureFormat.new()
	displacement_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	displacement_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	displacement_format.width = 1
	displacement_format.height = 1
	displacement_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var displacement := rd.texture_create(displacement_format, RDTextureView.new(), [PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array()])
	created.append(displacement)
	if displacement.is_valid():
		rd.set_resource_name(displacement, "Ocean.FFT.NeutralDisplacement.G%d" % generation)

	var normal_format := RDTextureFormat.new()
	normal_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	normal_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	normal_format.width = 1
	normal_format.height = 1
	normal_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var normal := rd.texture_create(normal_format, RDTextureView.new(), [PackedByteArray([0, 0, 0, 60, 0, 0, 0, 60])])
	created.append(normal)
	if normal.is_valid():
		rd.set_resource_name(normal, "Ocean.FFT.NeutralNormal.G%d" % generation)

	var crest_format := RDTextureFormat.new()
	crest_format.format = RenderingDevice.DATA_FORMAT_R16G16_SFLOAT
	crest_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	crest_format.width = 1
	crest_format.height = 1
	crest_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var crest := rd.texture_create(crest_format, RDTextureView.new(), [PackedByteArray([0, 0, 0, 0])])
	created.append(crest)
	if crest.is_valid():
		rd.set_resource_name(crest, "Ocean.CrestFoamNeutral.G%d" % generation)

	if not is_active() or not displacement.is_valid() or not normal.is_valid() or not crest.is_valid():
		for rid in created:
			if rid.is_valid():
				rd.free_rid(rid)
		neutral_error = "No se pudieron crear los neutrales FFT de la generación %d." % generation
		_publish_snapshot()
		return

	_publication_mutex.lock()
	if not active:
		_publication_mutex.unlock()
		for rid in created:
			if rid.is_valid():
				rd.free_rid(rid)
		return
	neutral_displacement_rid = displacement
	neutral_normal_rid = normal
	neutral_crest_rid = crest
	neutral_ready = true
	neutral_error = ""
	_publication_mutex.unlock()
	_publish_snapshot()


func initialize_solver(solver, config: Resource, h0_data: PackedByteArray, resource_prefix: String, crest_settings: Array) -> void:
	if solver == null:
		return
	if not is_active():
		solver.shutdown()
		return
	solver.generation = generation
	solver.initialize(config, h0_data, resource_prefix)
	if not is_active():
		solver.shutdown()
		return
	if solver.ready and crest_settings.size() >= 5:
		solver.set_crest_foam_settings(crest_settings[0], crest_settings[1], crest_settings[2], crest_settings[3], crest_settings[4])


func set_solver_crest_enabled(solver, enabled: bool) -> void:
	if solver == null:
		return
	if not is_active():
		solver.shutdown()
		return
	if solver.generation != generation or not solver.ready:
		return
	solver.set_crest_foam_enabled(enabled)


func set_solver_crest_settings(solver, settings: Array) -> void:
	if solver == null:
		return
	if not is_active():
		solver.shutdown()
		return
	if solver.generation != generation or not solver.ready or settings.size() < 5:
		return
	solver.set_crest_foam_settings(settings[0], settings[1], settings[2], settings[3], settings[4])


func shutdown_gpu() -> void:
	_publication_mutex.lock()
	active = false
	neutral_ready = false
	_publication_mutex.unlock()
	_publish_snapshot()
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		for rid in [neutral_displacement_rid, neutral_normal_rid, neutral_crest_rid]:
			if rid.is_valid():
				rd.free_rid(rid)
	neutral_displacement_rid = RID()
	neutral_normal_rid = RID()
	neutral_crest_rid = RID()
	neutral_ready = false
	_publish_snapshot()
