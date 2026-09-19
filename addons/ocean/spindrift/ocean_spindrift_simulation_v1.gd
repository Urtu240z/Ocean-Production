class_name OceanSpindriftSimulationV1
extends RefCounted
## H4.33/H4.34/H4.35/H4.36 render-thread owner of the persistent spindrift fields.
##
## TWO persistent Eulerian 3D fields, each RG16F ping-ponged, advanced by their
## own compute pass on the same fixed step and swapped together under ONE shared
## lifecycle:
##
##   MACRO 96 x 32 x 96     R = macro density mass
##                          G = macro wave/source-coupled mass
##   MICRO 128 x 32 x 128   R = fine aerosol / droplet-cluster density
##                          G = micro wave/source-coupled mass
##
## Invariant on both: 0 <= G <= R.
##
## The macro field remains authoritative for the large mist body and its
## semantics are unchanged from H4.35. The micro field is an ADDITIONAL scale with
## its own faster dynamics and its own history; it is never reconstructed from
## render-side noise. Micro aerosol is injected from the same authoritative Crest
## G source and then evolves independently, so it can persist where macro density
## is zero and move differently from it.
##
## Everything is allocated once. Nothing is created per frame, nothing is read
## back to the CPU.
##
## THREADING CONTRACT (H4.34)
## --------------------------
## The RENDER THREAD is the sole owner of all simulation state: every GPU RID,
## both read indices, the origin, the extent, the clocks, the counters and both
## error strings. The main thread NEVER reads or writes any of those fields; every
## public accessor goes through the mutex publication snapshot below.
##
## Main thread -> render thread: one immutable per-step packet. `advance()` takes
## a deep-copied `config` dictionary plus a `sources` dictionary built fresh on
## the main thread for that single call. Nothing in either packet aliases live
## authoring state, so a later profile edit cannot be observed mid-step.
##
## Render thread -> main thread: `get_publication_snapshot()` returns a copy of a
## single dictionary that the render thread rewrites under `_publication_mutex`.
## The mutex is never held across a RenderingDevice call and hold times are a
## dictionary build plus a copy.
##
## TERMINAL SHUTDOWN (H4.35): shutdown() sets `_shutdown_requested`, a
## render-thread tombstone that advance() checks BEFORE it acquires the
## RenderingDevice or creates anything. A genuinely late queued advance() can
## therefore never resurrect this instance and never recreate GPU resources —
## neither macro nor micro. Once shut down the object is permanently dead;
## re-enabling the system creates a NEW OceanSpindriftSimulationV1.

const ADVECT_SHADER := preload("res://addons/ocean/shaders/spindrift_volume_advect.glsl")
const MICRO_ADVECT_SHADER := preload("res://addons/ocean/shaders/spindrift_micro_advect.glsl")

## 96 x 32 x 96 over a 96 m x 16 m x 96 m local volume: ~1.0 m x 0.5 m x 1.0 m
## base voxels. Fixed: an extent change never recreates a GPU resource.
const RESOLUTION := Vector3i(96, 32, 96)
## 128 x 32 x 128 over the SAME world extent, so micro voxels are ~0.75 x 0.5 x
## 0.75 m. Fixed for H4.36: micro resolution is not an author control. Both grids
## share one world-space origin; the trilinear backtrace handles the different
## voxel metric because it works in world space.
const MICRO_RESOLUTION := Vector3i(128, 32, 128)
const LOCAL_SIZE := Vector3i(8, 4, 8)
const PARAMS_BYTES := 11 * 16
## H4.41 extends only the MICRO uniform block with motion and dissipation
## controls. The macro block and its byte layout remain unchanged.
const MICRO_PARAMS_BYTES := 13 * 16
## Below this turnover the injector keeps filling at the floor rate, so lowering
## the density decay lengthens persistence instead of producing a dead volume.
const INJECTION_TURNOVER_FLOOR := 0.12
const WAVE_GRADIENT_STEP_M := 1.25
const MAX_MASS := 8.0
const MAX_STEP_DT_S := 0.25
const MIN_EXTENT := Vector3(16.0, 2.0, 16.0)
const MAX_EXTENT := Vector3(320.0, 64.0, 320.0)
const STATE_FORMAT := "RG16F"
## Micro injection band, measured against the DISPLACED water surface. Thinner
## than macro: fine droplets are born at the torn crest/lip.
const MICRO_INJECTION_FULL_M := 0.45
const MICRO_INJECTION_TOP_M := 1.60
## Fixed micro scale multipliers. These are implementation couplings, not author
## controls: micro aerosol uses a finer, slightly stronger curl, a somewhat
## higher-frequency local variation, and a little more vertical separation.
const MICRO_CURL_SCALE_MULT := 2.0
const MICRO_VARIATION_SCALE_MULT := 2.0
const MICRO_LIFT_MULT := 1.25

# ---------------------------------------------------------------------------
# RENDER-THREAD OWNED STATE. The main thread must never touch anything below.
# ---------------------------------------------------------------------------
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _surface_sampler := RID()
var _params := RID()
var _state: Array[RID] = [RID(), RID()]
var _micro_shader := RID()
var _micro_pipeline := RID()
var _micro_params := RID()
var _micro_state: Array[RID] = [RID(), RID()]
var _read_index := 0
var _origin := Vector3.ZERO
var _origin_valid := false
var _extent := Vector3(96.0, 16.0, 96.0)
var _simulation_time_s := 0.0
var _steps := 0
var _dispatches := 0
var _micro_dispatches := 0
var _history_clears := 0
var _config_revision := 0
var _ready := false
var _micro_ready := false
var _resource_error := ""
var _micro_error := ""
var _source_error := ""
var _micro_failure_reported := false
## Render-thread tombstone. Set once by shutdown() and never cleared: after it is
## true, advance() returns immediately and can never reacquire the RenderingDevice
## or recreate a single GPU resource, for either field.
var _shutdown_requested := false

# ---------------------------------------------------------------------------
# PUBLICATION. The only thing the main thread may observe.
# ---------------------------------------------------------------------------
var _publication_mutex := Mutex.new()
var _publication: Dictionary = {
	"rid": RID(),
	"origin": Vector3.ZERO,
	"extent": Vector3(96.0, 16.0, 96.0),
	"valid": false,
	"revision": 0,
	"ready": false,
	"resource_error": "",
	"source_error": "",
	"steps": 0,
	"dispatches": 0,
	"history_clears": 0,
	"simulation_time_s": 0.0,
	"read_index": 0,
	"config_revision": 0,
	"shutdown": false,
	"resolution": RESOLUTION,
	"state_format": STATE_FORMAT,
	"micro_rid": RID(),
	"micro_valid": false,
	"micro_resolution": MICRO_RESOLUTION,
	"micro_state_format": STATE_FORMAT,
	"micro_error": "",
	"micro_dispatches": 0,
}


## Single authority for the world-space grid placement. The render shader is fed
## the published origin, so both stages agree by construction. Static and pure,
## so the main thread may call it for a pre-publication placeholder.
static func snapped_origin(anchor_xz: Vector2, sea_level: float, extent: Vector3, resolution: Vector3i) -> Vector3:
	var voxel_x := extent.x / maxf(float(resolution.x), 1.0)
	var voxel_z := extent.z / maxf(float(resolution.z), 1.0)
	var center_x := snappedf(anchor_xz.x, maxf(voxel_x, 0.001))
	var center_z := snappedf(anchor_xz.y, maxf(voxel_z, 0.001))
	return Vector3(center_x - extent.x * 0.5, sea_level, center_z - extent.z * 0.5)


## Main thread. Returns a copy of the render thread's publication snapshot; it
## never exposes a mutable render-thread field.
func get_publication_snapshot() -> Dictionary:
	_publication_mutex.lock()
	var snapshot := _publication.duplicate()
	_publication_mutex.unlock()
	return snapshot


## RENDER THREAD. Exactly one fixed step.
##
## anchor_xz / sea_level: placement inputs (value types).
## sources: RD texture RIDs + ocean space scalars for this step.
## config:  deep-copied authoring snapshot for this step.
func advance(anchor_xz: Vector2, sea_level: float, sources: Dictionary, config: Dictionary, dt: float) -> void:
	# Terminal check FIRST: a late queued call must never acquire the
	# RenderingDevice, create a pipeline or allocate a texture.
	if _shutdown_requested:
		return
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_resource_error = "RenderingDevice global no disponible para el volumen persistente."
		_publish()
		return
	if not _resource_error.is_empty():
		return
	if not _ready and not _create_resources():
		return
	# Micro is created by _create_resources() too, but its failure is NOT fatal:
	# macro volumetric spindrift keeps working and only the micro contribution is
	# disabled. See _report_micro_failure().
	# The world-space extent is a render-thread decision. Changing it changes the
	# voxel metric, so history is invalidated exactly once. Resolution and every
	# GPU resource stay untouched.
	var requested := _sanitized_extent(config)
	if not requested.is_equal_approx(_extent):
		_extent = requested
		if _origin_valid:
			_origin_valid = false
			_history_clears += 1
		_publish()
	if not _sources_valid(sources):
		_publish()
		return
	var step := clampf(dt, 0.0, MAX_STEP_DT_S)
	if step <= 0.0:
		return
	var target := snapped_origin(anchor_xz, sea_level, _extent, RESOLUTION)
	var history_valid := _origin_valid \
		and absf(target.x - _origin.x) < _extent.x \
		and absf(target.y - _origin.y) < _extent.y \
		and absf(target.z - _origin.z) < _extent.z
	if _origin_valid and not history_valid:
		_history_clears += 1
	_config_revision += 1
	if not _dispatch_step(target, sea_level, sources, config, step, history_valid):
		_publish()
		return
	_simulation_time_s += step
	_origin = target
	_origin_valid = true
	_read_index = 1 - _read_index
	_steps += 1
	_publish()


## RENDER THREAD. Every RID is freed here and only here, and the tombstone makes
## this terminal. The caller detaches the Texture3DRD wrapper and the material
## binding before queuing this, so nothing in the render graph still references a
## freed texture. Idempotent: a second call is a no-op.
func shutdown() -> void:
	if _shutdown_requested:
		return
	_shutdown_requested = true
	_ready = false
	if _rd != null:
		for rid in [_state[0], _state[1], _micro_state[0], _micro_state[1], _params, _micro_params, _pipeline, _micro_pipeline, _shader, _micro_shader, _sampler, _surface_sampler]:
			if rid.is_valid():
				_rd.free_rid(rid)
	_state = [RID(), RID()]
	_micro_state = [RID(), RID()]
	_params = RID()
	_micro_params = RID()
	_pipeline = RID()
	_micro_pipeline = RID()
	_shader = RID()
	_micro_shader = RID()
	_sampler = RID()
	_surface_sampler = RID()
	_micro_ready = false
	_rd = null
	_origin = Vector3.ZERO
	_origin_valid = false
	_simulation_time_s = 0.0
	# Publish the terminal state with a monotonically increasing revision.
	_publication_mutex.lock()
	_publication["rid"] = RID()
	_publication["micro_rid"] = RID()
	_publication["valid"] = false
	_publication["micro_valid"] = false
	_publication["ready"] = false
	_publication["shutdown"] = true
	_publication["resource_error"] = _resource_error
	_publication["source_error"] = _source_error
	_publication["micro_error"] = _micro_error
	_publication["steps"] = _steps
	_publication["dispatches"] = _dispatches
	_publication["micro_dispatches"] = _micro_dispatches
	_publication["history_clears"] = _history_clears
	_publication["config_revision"] = _config_revision
	_publication["revision"] = int(_publication["revision"]) + 1
	_publication_mutex.unlock()


func _create_resources() -> bool:
	if _rd == null:
		_resource_error = "RenderingDevice no disponible."
		_publish()
		return false
	var spirv := ADVECT_SHADER.get_spirv()
	var compile_error: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		_resource_error = compile_error
		_publish()
		return false
	_shader = _rd.shader_create_from_spirv(spirv, "OceanSpindriftVolumeAdvect")
	if not _shader.is_valid():
		_resource_error = "No se pudo crear el shader de adveccion."
		_publish()
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_resource_error = "No se pudo crear el pipeline de adveccion."
		_release_partial()
		_publish()
		return false
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)
	var surface := RDSamplerState.new()
	surface.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	surface.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	surface.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	surface.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	surface.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_surface_sampler = _rd.sampler_create(surface)
	_params = _rd.uniform_buffer_create(PARAMS_BYTES)
	_state[0] = _create_state_texture(RESOLUTION, "Ocean.SpindriftVolume.StateA")
	_state[1] = _create_state_texture(RESOLUTION, "Ocean.SpindriftVolume.StateB")
	if not _sampler.is_valid() or not _surface_sampler.is_valid() or not _params.is_valid() or not _state[0].is_valid() or not _state[1].is_valid():
		_resource_error = "No se pudieron crear las texturas 3D RG16F del volumen."
		_release_partial()
		_publish()
		return false
	_ready = true
	# Micro is a separate, non-fatal stage. If it fails, macro stays functional.
	_create_micro_resources()
	_publish()
	return true


## Creates the micro field. Failure is deliberately contained: the macro volume
## must keep working, so this only records _micro_error and reports it once.
func _create_micro_resources() -> void:
	if _rd == null or _micro_ready:
		return
	var spirv := MICRO_ADVECT_SHADER.get_spirv()
	var compile_error: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		_micro_error = compile_error
		_report_micro_failure()
		return
	_micro_shader = _rd.shader_create_from_spirv(spirv, "OceanSpindriftMicroAdvect")
	if not _micro_shader.is_valid():
		_micro_error = "No se pudo crear el shader micro."
		_report_micro_failure()
		return
	_micro_pipeline = _rd.compute_pipeline_create(_micro_shader)
	if not _micro_pipeline.is_valid():
		_micro_error = "No se pudo crear el pipeline micro."
		_release_micro_resources()
		_report_micro_failure()
		return
	_micro_params = _rd.uniform_buffer_create(MICRO_PARAMS_BYTES)
	_micro_state[0] = _create_state_texture(MICRO_RESOLUTION, "Ocean.SpindriftVolume.MicroA")
	_micro_state[1] = _create_state_texture(MICRO_RESOLUTION, "Ocean.SpindriftVolume.MicroB")
	if not _micro_params.is_valid() or not _micro_state[0].is_valid() or not _micro_state[1].is_valid():
		_micro_error = "No se pudieron crear las texturas 3D RG16F micro."
		_release_micro_resources()
		_report_micro_failure()
		return
	_micro_ready = true
	_micro_error = ""


func _report_micro_failure() -> void:
	_micro_ready = false
	if _micro_failure_reported:
		return
	_micro_failure_reported = true
	print("SPINDRIFT VOLUMETRIC | micro aerosol unavailable (%s); macro volumetric spindrift stays active, H4.31 particles untouched" % _micro_error)


func _release_micro_resources() -> void:
	_micro_ready = false
	if _rd != null:
		for rid in [_micro_state[0], _micro_state[1], _micro_params, _micro_pipeline, _micro_shader]:
			if rid.is_valid():
				_rd.free_rid(rid)
	_micro_state = [RID(), RID()]
	_micro_params = RID()
	_micro_pipeline = RID()
	_micro_shader = RID()


func _release_partial() -> void:
	_release_micro_resources()
	if _rd == null:
		return
	for rid in [_state[0], _state[1], _params, _pipeline, _shader, _sampler, _surface_sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_state = [RID(), RID()]
	_params = RID()
	_pipeline = RID()
	_shader = RID()
	_sampler = RID()
	_surface_sampler = RID()
	_ready = false
	_rd = null


func _create_state_texture(resolution: Vector3i, resource_name: String) -> RID:
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16G16_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = resolution.x
	format.height = resolution.y
	format.depth = resolution.z
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial := PackedByteArray()
	initial.resize(resolution.x * resolution.y * resolution.z * 4)
	var rid: RID = _rd.texture_create(format, RDTextureView.new(), [initial])
	if rid.is_valid():
		_rd.set_resource_name(rid, resource_name)
	return rid


func _sanitized_extent(config: Dictionary) -> Vector3:
	var requested: Vector3 = config.get("extent", _extent)
	return Vector3(
		clampf(requested.x, MIN_EXTENT.x, MAX_EXTENT.x),
		clampf(requested.y, MIN_EXTENT.y, MAX_EXTENT.y),
		clampf(requested.z, MIN_EXTENT.z, MAX_EXTENT.z))


func _sources_valid(sources: Dictionary) -> bool:
	for key in ["breaking_activity_long_rid", "displacement_long_rid"]:
		var rid: RID = sources.get(key, RID())
		if not rid.is_valid() or _rd == null or not _rd.texture_is_valid(rid):
			_source_error = "Crest G / LONG displacement no publicados todavia."
			return false
	_source_error = ""
	return true


func _dispatch_step(origin: Vector3, sea_level: float, sources: Dictionary, config: Dictionary, dt: float, history_valid: bool) -> bool:
	if _rd == null or not _pipeline.is_valid() or not _ready:
		return false
	var breaking: RID = sources.get("breaking_activity_long_rid", RID())
	var displacement: RID = sources.get("displacement_long_rid", RID())
	_rd.buffer_update(_params, 0, PARAMS_BYTES, _pack_params(origin, sea_level, sources, config, dt, history_valid).to_byte_array())
	var set: RID = UniformSetCacheRD.get_cache(_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler, _state[_read_index]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_state[1 - _read_index]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_surface_sampler, breaking]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_surface_sampler, displacement]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 4, [_params]),
	])
	if not set.is_valid() or not _rd.uniform_set_is_valid(set):
		_resource_error = "Uniform set invalido durante la adveccion."
		return false
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list,
		ceili(float(RESOLUTION.x) / float(LOCAL_SIZE.x)),
		ceili(float(RESOLUTION.y) / float(LOCAL_SIZE.y)),
		ceili(float(RESOLUTION.z) / float(LOCAL_SIZE.z)))
	_rd.compute_list_end()
	_dispatches += 1
	# Micro advances on the SAME fixed step, with the same origin, history flag
	# and dt, and participates in the SAME read-index swap. A micro failure here
	# disables only the micro contribution: macro already advanced successfully.
	if _micro_ready:
		_dispatch_micro_step(origin, sea_level, sources, config, dt, history_valid)
	return true


func _dispatch_micro_step(origin: Vector3, sea_level: float, sources: Dictionary, config: Dictionary, dt: float, history_valid: bool) -> void:
	if _rd == null or not _micro_ready or not _micro_pipeline.is_valid():
		return
	var breaking: RID = sources.get("breaking_activity_long_rid", RID())
	var displacement: RID = sources.get("displacement_long_rid", RID())
	_rd.buffer_update(_micro_params, 0, MICRO_PARAMS_BYTES, _pack_micro_params(origin, sea_level, sources, config, dt, history_valid).to_byte_array())
	var set: RID = UniformSetCacheRD.get_cache(_micro_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler, _micro_state[_read_index]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_micro_state[1 - _read_index]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_surface_sampler, breaking]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_surface_sampler, displacement]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 4, [_micro_params]),
	])
	if not set.is_valid() or not _rd.uniform_set_is_valid(set):
		_micro_error = "Uniform set invalido durante la adveccion micro."
		_report_micro_failure()
		return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _micro_pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list,
		ceili(float(MICRO_RESOLUTION.x) / float(LOCAL_SIZE.x)),
		ceili(float(MICRO_RESOLUTION.y) / float(LOCAL_SIZE.y)),
		ceili(float(MICRO_RESOLUTION.z) / float(LOCAL_SIZE.z)))
	_rd.compute_list_end()
	_micro_dispatches += 1


func _pack_params(origin: Vector3, sea_level: float, sources: Dictionary, config: Dictionary, dt: float, history_valid: bool) -> PackedFloat32Array:
	## std140 layout, 11 x vec4. Keep this table and the AdvectParams block in
	## spindrift_volume_advect.glsl in sync; every field is documented there.
	var domains: Vector3 = sources.get("domains", Vector3(512.0, 137.0, 37.0))
	var ocean_space: Dictionary = sources.get("ocean_space", {})
	var horizontal_scale := maxf(float(ocean_space.get("clipmap_geometry_scale", 1.0)), 0.0001)
	var ocean_surface_scale := maxf(float(ocean_space.get("ocean_scale", 1.0)), 0.0001)
	var wind_direction: Vector2 = sources.get("wind_direction", Vector2(1.0, 0.0))
	var wind_speed := maxf(float(sources.get("wind_speed_mps", 0.0)), 0.0)
	# H4.34: the atmospheric wind actually imparted to the aerosol is a fraction
	# of the real wind speed. The compute shader multiplies wind.z by wind.w.
	var wind_advection := clampf(_config_float(config, "wind_advection", 0.08), 0.0, 0.5)
	var density_decay := maxf(_config_float(config, "density_decay", 0.12), 0.0)
	var wave_decay := maxf(_config_float(config, "wave_memory_decay", 1.60), 0.0001)
	# Normalising by the steady-state ratio is what makes the affinity proxy read
	# ~1 on a continuously fed crest and -> 0 for a parcel whose crest has gone.
	var steady_ratio := clampf(density_decay / wave_decay, 0.02, 1.0)
	return PackedFloat32Array([
		origin.x, origin.y, origin.z, dt,
		_extent.x, _extent.y, _extent.z, _simulation_time_s,
		_origin.x, _origin.y, _origin.z, 1.0 if history_valid else 0.0,
		domains.x, domains.y, domains.z, 0.0,
		wind_direction.x, wind_direction.y, wind_speed, wind_advection,
		density_decay, wave_decay, maxf(density_decay, INJECTION_TURNOVER_FLOOR), MAX_MASS,
		_config_float(config, "source_threshold", 0.55), _config_float(config, "source_gain", 1.0), _config_float(config, "injection_full_m", 0.75), _config_float(config, "injection_top_m", 2.50),
		_config_float(config, "wave_push_mps", 0.80), steady_ratio, WAVE_GRADIENT_STEP_M * horizontal_scale, 0.0,
		_config_float(config, "curl_strength_mps", 1.00), maxf(_config_float(config, "curl_scale", 0.030), 0.0001), _config_float(config, "curl_speed", 0.12), 0.0,
		clampf(_config_float(config, "flow_variation_strength", 0.45), 0.0, 1.0), maxf(_config_float(config, "flow_variation_scale", 0.012), 0.0001), 0.05, _config_float(config, "lift_mps", 0.12),
		sea_level, horizontal_scale, ocean_surface_scale, 0.0,
	])


func _config_float(config: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = config.get(key, fallback)
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return fallback
	var result := float(value)
	return result if is_finite(result) else fallback


func _pack_micro_params(origin: Vector3, sea_level: float, sources: Dictionary, config: Dictionary, dt: float, history_valid: bool) -> PackedFloat32Array:
	## Same std140 layout as _pack_params, but with the micro substitutions. Kept
	## separate on purpose so the macro packing above stays byte-identical to
	## H4.35: H4.36 must add micro without retuning macro.
	##
	## Micro couplings baked here instead of in the shader, so the micro shader
	## stays structurally identical to the macro one:
	##   wind.z        = wind_speed * volumetric_micro_wind_multiplier
	##   curl.x        = curl_strength * volumetric_micro_curl_multiplier
	##   curl.y        = curl_scale * MICRO_CURL_SCALE_MULT
	##   curl.z        = curl_speed * volumetric_micro_turbulence_speed_multiplier
	##                   (H4.39A: micro internal rotation evolves faster than macro;
	##                    this is DEFORMATION speed, not transport speed)
	##   variation.y   = flow_variation_scale * MICRO_VARIATION_SCALE_MULT
	##   variation.w   = lift * MICRO_LIFT_MULT
	##   wave.w        = volumetric_micro_seed_scale
	##   motion        = launch speed, residual lift fraction, curl fraction,
	##                  local variation fraction
	##   dissipation   = height start, height end, extra decay rate, unused
	var domains: Vector3 = sources.get("domains", Vector3(512.0, 137.0, 37.0))
	var ocean_space: Dictionary = sources.get("ocean_space", {})
	var horizontal_scale := maxf(float(ocean_space.get("clipmap_geometry_scale", 1.0)), 0.0001)
	var ocean_surface_scale := maxf(float(ocean_space.get("ocean_scale", 1.0)), 0.0001)
	var wind_direction: Vector2 = sources.get("wind_direction", Vector2(1.0, 0.0))
	var wind_speed := maxf(float(sources.get("wind_speed_mps", 0.0)), 0.0) * maxf(_config_float(config, "micro_wind_multiplier", 1.5), 0.0)
	var wind_advection := clampf(_config_float(config, "wind_advection", 0.08), 0.0, 0.5)
	var density_decay := maxf(_config_float(config, "micro_density_decay", 0.65), 0.0)
	var wave_decay := maxf(_config_float(config, "micro_wave_memory_decay", 2.80), 0.0001)
	var steady_ratio := clampf(density_decay / wave_decay, 0.02, 1.0)
	return PackedFloat32Array([
		origin.x, origin.y, origin.z, dt,
		_extent.x, _extent.y, _extent.z, _simulation_time_s,
		_origin.x, _origin.y, _origin.z, 1.0 if history_valid else 0.0,
		domains.x, domains.y, domains.z, 0.0,
		wind_direction.x, wind_direction.y, wind_speed, wind_advection,
		density_decay, wave_decay, maxf(density_decay, INJECTION_TURNOVER_FLOOR), MAX_MASS,
		_config_float(config, "source_threshold", 0.55), _config_float(config, "micro_source_gain", 1.0), MICRO_INJECTION_FULL_M, MICRO_INJECTION_TOP_M,
		_config_float(config, "wave_push_mps", 0.80), steady_ratio, WAVE_GRADIENT_STEP_M * horizontal_scale, maxf(_config_float(config, "micro_seed_scale", 0.80), 0.0001),
		maxf(_config_float(config, "curl_strength_mps", 1.00), 0.0) * maxf(_config_float(config, "micro_curl_multiplier", 1.8), 0.0), maxf(_config_float(config, "curl_scale", 0.030), 0.0001) * MICRO_CURL_SCALE_MULT, _config_float(config, "curl_speed", 0.12) * maxf(_config_float(config, "micro_turbulence_speed_multiplier", 4.0), 0.0), 0.0,
		clampf(_config_float(config, "flow_variation_strength", 0.45), 0.0, 1.0), maxf(_config_float(config, "flow_variation_scale", 0.012), 0.0001) * MICRO_VARIATION_SCALE_MULT, 0.05, maxf(_config_float(config, "lift_mps", 0.12), 0.0) * MICRO_LIFT_MULT,
		sea_level, horizontal_scale, ocean_surface_scale, 0.0,
		_config_float(config, "micro_launch_speed_mps", 6.0), _config_float(config, "micro_residual_lift_fraction", 0.15), _config_float(config, "micro_curl_motion_fraction", 0.45), _config_float(config, "micro_variation_fraction", 0.50),
		_config_float(config, "micro_dissipation_height_start_m", 1.0), _config_float(config, "micro_dissipation_height_end_m", 3.5), _config_float(config, "micro_extra_decay_mps", 2.0), 0.0,
	])


func _publish() -> void:
	## RENDER THREAD. Builds the whole publication payload outside the mutex, then
	## swaps it in with a tiny critical section. No RenderingDevice call is ever
	## made while the mutex is held.
	var payload := {
		"rid": _state[_read_index] if _origin_valid and _state[_read_index].is_valid() else RID(),
		"origin": _origin,
		"extent": _extent,
		"valid": _origin_valid and _state[_read_index].is_valid(),
		"ready": _ready,
		"resource_error": _resource_error,
		"source_error": _source_error,
		"steps": _steps,
		"dispatches": _dispatches,
		"history_clears": _history_clears,
		"simulation_time_s": _simulation_time_s,
		"read_index": _read_index,
		"config_revision": _config_revision,
		"shutdown": _shutdown_requested,
		"resolution": RESOLUTION,
		"state_format": STATE_FORMAT,
		"micro_rid": _micro_state[_read_index] if _origin_valid and _micro_ready and _micro_state[_read_index].is_valid() else RID(),
		"micro_valid": _origin_valid and _micro_ready and _state[_read_index].is_valid() and _micro_state[_read_index].is_valid(),
		"micro_resolution": MICRO_RESOLUTION,
		"micro_state_format": STATE_FORMAT,
		"micro_error": _micro_error,
		"micro_dispatches": _micro_dispatches,
	}
	_publication_mutex.lock()
	payload["revision"] = int(_publication["revision"]) + 1
	_publication = payload
	_publication_mutex.unlock()


func _uniform(type: int, binding: int, ids: Array) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		var rid: RID = id
		uniform.add_id(rid)
	return uniform
