class_name OceanSpindriftVolumeV1
extends Node3D
## H4.33 local PERSISTENT volumetric spindrift.
##
## Owns:
##   * one OceanSpindriftSimulationV1  (the GPU Eulerian aerosol field)
##   * one Texture3DRD                 (the RD -> render bridge)
##   * one FogVolume                   (the only volumetric volume in the system)
##   * the reversible Environment volumetric-fog contract
##
## Ownership:
##   OceanSpindriftV4
##       └── OceanSpindriftVolumeV1   (this node, top_level)
##               └── FogVolume        (SpindriftVolume)
##
## It remains a PARALLEL path beside the H4.31 particle spindrift: it consumes
## the same Crest G texture through the same world -> source mapping, but it
## never touches sensors, detached pools, emission, hysteresis, LOD, lifetimes,
## the particle shaders or the spray artwork. Crest G is an INJECTION source only;
## it is never the render density.
##
## GPU lifetime: the simulation allocates once and is released only through the
## render thread. The Texture3DRD wrapper is re-pointed after each ping-pong swap;
## the texture RIDs themselves are never reallocated per step.
##
## Cadence: a fixed-rate accumulator lives here, on the main thread, so the
## simulation is dispatched at volumetric_simulation_hz and never at render FPS.

const VOLUME_SHADER := preload("res://addons/ocean/shaders/spindrift_volume.gdshader")
const Simulation := preload("res://addons/ocean/spindrift/ocean_spindrift_simulation_v1.gd")

## Godot 4.7 exposes no integer constants for FogVolume.shape. Its property hint
## is "Ellipsoid (Local),Cone (Local),Cylinder (Local),Box (Local),World (Global)",
## so Box is index 3.
const FOG_SHAPE_BOX := 3
const FOG_VOLUME_LAYER := 1
const DEFAULT_DOMAIN_LONG_M := 512.0
## Column height of the persistent grid. Fixed for V1: neither the resolution nor
## the vertical extent changes at runtime, so a profile edit never reallocates a
## GPU resource.
const SIM_COLUMN_HEIGHT_M := 16.0
## Injection envelope above the DISPLACED water surface. Implementation defaults,
## not tuned art values.
const INJECTION_FULL_M := 0.75
const INJECTION_TOP_M := 2.50
const MAX_STEP_DT_S := 0.25
const MAX_CATCHUP_STEPS := 4
const MIN_FOG_LENGTH_M := 16.0
const MAX_FOG_LENGTH_M := 1024.0
## Safety margin added to the exact camera-to-far-corner distance.
const FOG_LENGTH_SAFETY_M := 4.0
## Write the Environment only when the computed range really moved.
const FOG_LENGTH_EPSILON_M := 0.5

var _profile: OceanSpindriftProfile
var _material: ShaderMaterial
var _fog_volume: FogVolume
var _simulation: OceanSpindriftSimulationV1
var _state_wrapper: Texture3DRD

var _sea_level := 0.0
var _wind_speed_mps := 18.0
var _wind_direction_degrees := 0.0
var _wind_direction := Vector2(1.0, 0.0)
var _ocean_space: Dictionary = {"ocean_scale": 1.0, "clipmap_geometry_scale": 1.0, "revision": 0}

var _domain_long_m := DEFAULT_DOMAIN_LONG_M
var _breaking_rid := RID()
var _displacement_rid := RID()
var _source_bound := false
var _persistent_ready := false
var _persistent_failed := false
var _persistent_failure_reported := false
var _visible := true
var _time_scale := 1.0
var _anchor_xz := Vector2.ZERO
var _camera_position := Vector3.ZERO
var _sim_origin := Vector3.ZERO
var _sim_extent := Vector3(96.0, SIM_COLUMN_HEIGHT_M, 96.0)
var _sim_accumulator_s := 0.0
var _computed_fog_length := 0.0
var _placement_updates := 0
var _bound_revision := -1
var _advance_requests := 0
var _advance_steps_requested := 0

var _environment: Environment
var _environment_original: Dictionary = {}
var _environment_mutated := false
var _environment_unavailable_logged := false


func _ready() -> void:
	# The volume places itself in world space and must not inherit the camera
	# tracking transform of its owner.
	top_level = true


func configure(profile: OceanSpindriftProfile, sea_level: float, wind_speed_mps: float, wind_direction_degrees: float) -> void:
	_profile = profile
	_sea_level = sea_level
	_wind_speed_mps = maxf(wind_speed_mps, 0.0)
	_wind_direction_degrees = wind_direction_degrees
	var radians := deg_to_rad(_wind_direction_degrees)
	_wind_direction = Vector2(cos(radians), sin(radians))
	if _wind_direction.length_squared() < 0.000001:
		_wind_direction = Vector2(1.0, 0.0)
	_wind_direction = _wind_direction.normalized()
	_create_volume()
	_apply_profile()
	_acquire_environment()
	_ensure_volumetric_fog()
	set_process(true)


func set_ocean_space(contract: Dictionary) -> void:
	_ocean_space = contract.duplicate(true)
	_apply_placement(true)


func set_visible(visible: bool) -> void:
	_visible = visible
	_refresh_fog_visibility()


func set_time_scale(scale: float) -> void:
	# Used by the temporary H4.31 freeze helper: it stops the simulation clock
	# without touching the GPU resources, the material or any particle pool.
	_time_scale = maxf(scale, 0.0)


func bind_sources(data: Dictionary) -> void:
	## The compute pass needs real RenderingDevice RIDs, so the Texture2DRD
	## wrappers are unwrapped here. Nothing is ever read back to the CPU.
	if not bool(data.get("ready", false)):
		_source_bound = false
		_breaking_rid = RID()
		_displacement_rid = RID()
		return
	var breaking: Variant = data.get("breaking_activity_long")
	var displacement: Variant = data.get("displacement_long")
	var breaking_wrapper := breaking as Texture2DRD
	var displacement_wrapper := displacement as Texture2DRD
	_breaking_rid = breaking_wrapper.texture_rd_rid if breaking_wrapper != null else RID()
	_displacement_rid = displacement_wrapper.texture_rd_rid if displacement_wrapper != null else RID()
	var domains: Vector3 = data.get("domains", Vector3(DEFAULT_DOMAIN_LONG_M, 0.0, 0.0))
	_domain_long_m = domains.x
	_source_bound = _breaking_rid.is_valid() and _displacement_rid.is_valid()


func update(delta: float, anchor_xz: Vector2, camera_world_position: Vector3) -> void:
	if _material == null or _profile == null or _simulation == null:
		return
	_anchor_xz = anchor_xz
	_camera_position = camera_world_position
	_apply_placement(false)
	_observe_publication()
	# The camera-to-farthest-corner distance changes continuously, so the fog
	# range is refreshed every frame while this system owns the value.
	_refresh_fog_length()
	# Stepping depends only on the source being published and the path not having
	# hard-failed. It must NOT depend on _persistent_ready: that flag is set by a
	# successful publication, which in turn needs a completed step.
	if _persistent_failed or not _source_bound or _time_scale <= 0.0:
		return
	var fixed_dt := 1.0 / clampf(_profile.volumetric_simulation_hz, 10.0, 60.0)
	var elapsed := clampf(maxf(delta, 0.0) * _time_scale, 0.0, MAX_STEP_DT_S)
	_sim_accumulator_s = minf(_sim_accumulator_s + elapsed, fixed_dt * float(MAX_CATCHUP_STEPS))
	var steps := mini(int(floor(_sim_accumulator_s / fixed_dt)), MAX_CATCHUP_STEPS)
	if steps <= 0:
		return
	_sim_accumulator_s -= fixed_dt * float(steps)
	# -----------------------------------------------------------------------
	# H4.34 thread isolation. Both packets are built FRESH here, on the main
	# thread, from primitive values only, and are handed to the render thread by
	# value. Nothing in them aliases live authoring state, so a later profile edit
	# cannot be observed in the middle of a step. The render thread owns every
	# simulation field it mutates; the main thread reaches them only through the
	# mutex publication snapshot.
	# -----------------------------------------------------------------------
	var ocean_space_snapshot: Dictionary = _ocean_space.duplicate(true)
	var sources := {
		"breaking_activity_long_rid": _breaking_rid,
		"displacement_long_rid": _displacement_rid,
		"domains": Vector3(_domain_long_m, 0.0, 0.0),
		"ocean_space": ocean_space_snapshot,
		"wind_direction": _wind_direction,
		"wind_speed_mps": _wind_speed_mps,
	}
	var config := _build_step_config()
	_advance_requests += 1
	for _step in steps:
		_advance_steps_requested += 1
		# Queued on the render thread, exactly like the existing P3/P6 owners.
		# The Callable keeps the simulation alive, so a late call after shutdown
		# is a harmless no-op rather than a use-after-free.
		RenderingServer.call_on_render_thread(_simulation.advance.bind(_anchor_xz, _sea_level, sources, config, fixed_dt))


func _build_step_config() -> Dictionary:
	## Immutable per-step authoring snapshot. Every value is a primitive copy, and
	## the world-space extent travels with it so the render thread can apply an
	## extent change itself instead of the main thread mutating render state.
	return {
		"extent": Vector3(_sim_radius_m() * 2.0, SIM_COLUMN_HEIGHT_M, _sim_radius_m() * 2.0),
		"density_decay": maxf(_profile.volumetric_density_decay, 0.0),
		"wave_memory_decay": maxf(_profile.volumetric_wave_memory_decay, 0.0001),
		"source_threshold": _profile.volumetric_source_threshold,
		"source_gain": _profile.volumetric_source_gain,
		"wind_advection": _profile.volumetric_wind_advection,
		"injection_full_m": INJECTION_FULL_M,
		"injection_top_m": INJECTION_TOP_M,
		"wave_push_mps": _profile.volumetric_wave_push,
		"lift_mps": _profile.volumetric_lift_strength,
		"flow_variation_strength": _profile.volumetric_flow_variation_strength,
		"flow_variation_scale": _profile.volumetric_flow_variation_scale,
		"curl_strength_mps": _profile.volumetric_curl_strength,
		"curl_scale": _profile.volumetric_curl_scale,
		"curl_speed": _profile.volumetric_curl_speed,
	}


func get_runtime_state() -> Dictionary:
	var snapshot := _simulation.get_publication_snapshot() if _simulation != null else {}
	var published_extent: Vector3 = snapshot.get("extent", _sim_extent)
	var requested_extent := Vector3(_sim_radius_m() * 2.0, SIM_COLUMN_HEIGHT_M, _sim_radius_m() * 2.0)
	return {
		"enabled": _profile.volumetric_enabled if _profile != null else false,
		"volume_present": _fog_volume != null,
		"volume_count": 1 if _fog_volume != null else 0,
		"persistent": true,
		"persistent_ready": _persistent_ready,
		"persistent_failed": _persistent_failed,
		"persistent_error": str(snapshot.get("resource_error", "")),
		"source_ready": _source_bound,
		"source_error": str(snapshot.get("source_error", "")),
		"source_authority": "crest_g_long",
		"source_channel": 1,
		"source_mapping": "world_xz / domain_long_m + 0.5",
		"source_role": "injection_only",
		"source_placement": "inverse_displaced_crest_one_iteration",
		"domain_long_m": _domain_long_m,
		"state_format": "RG16F",
		"state_channels": "R=density_mass G=wave_coupled_mass",
		"resolution": snapshot.get("resolution", Simulation.RESOLUTION),
		"sim_extent_m": published_extent,
		"requested_sim_extent": requested_extent,
		"published_sim_extent": published_extent,
		"sim_origin_world": snapshot.get("origin", _sim_origin),
		"sim_published_valid": snapshot.get("valid", false),
		"sim_steps": snapshot.get("steps", 0),
		"sim_dispatches": snapshot.get("dispatches", 0),
		"sim_history_clears": snapshot.get("history_clears", 0),
		"sim_simulation_time_s": snapshot.get("simulation_time_s", 0.0),
		"sim_publish_revision": snapshot.get("revision", 0),
		"sim_read_index": snapshot.get("read_index", 0),
		"thread_config_revision": snapshot.get("config_revision", 0),
		"sim_advance_requests": _advance_requests,
		"sim_advance_steps_requested": _advance_steps_requested,
		"simulation_hz": _profile.volumetric_simulation_hz if _profile != null else 0.0,
		"shape": "BOX",
		"volume_center_world": published_extent * 0.5 + (snapshot.get("origin", _sim_origin) as Vector3),
		"volume_size_m": published_extent,
		"anchor_world_xz": _anchor_xz,
		"placement_updates": _placement_updates,
		"wind_direction_xz": _wind_direction,
		"wind_speed_mps": _wind_speed_mps,
		"wind_advection_fraction": _profile.volumetric_wind_advection if _profile != null else 0.0,
		"effective_wind_advection_mps": _wind_speed_mps * (_profile.volumetric_wind_advection if _profile != null else 0.0),
		"time_scale": _time_scale,
		"visible": _visible,
		"fog_visible": _fog_volume.visible if _fog_volume != null else false,
		"state_texture_bound": _state_wrapper != null and _state_wrapper.texture_rd_rid.is_valid(),
		"environment_acquired": _environment != null and is_instance_valid(_environment),
		"environment_volumetric_fog_enabled": _environment.volumetric_fog_enabled if _environment != null and is_instance_valid(_environment) else false,
		"environment_mutated": _environment_mutated,
		"environment_original": _environment_original.duplicate(true),
		"computed_fog_length": _computed_fog_length,
		"camera_to_farthest_volume_corner": _computed_fog_length - FOG_LENGTH_SAFETY_M,
		"hide_legacy_streaks": _profile.volumetric_hide_legacy_streaks if _profile != null else false,
		"density": _profile.volumetric_density if _profile != null else 0.0,
		"recenter_rule": "integer_voxel_snapped_origin_with_explicit_previous_origin_backtrace",
		"world_origin_rule": "history_preserved_up_to_one_volume_extent_cleared_beyond",
	}


func _horizontal_scale() -> float:
	return maxf(float(_ocean_space.get("clipmap_geometry_scale", 1.0)), 0.0001)


func _sim_radius_m() -> float:
	var authored := _profile.volumetric_sim_radius_m if _profile != null else 48.0
	return clampf(authored, 8.0, 160.0)


func _create_volume() -> void:
	if _fog_volume != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = VOLUME_SHADER
	_state_wrapper = Texture3DRD.new()
	_material.set_shader_parameter(&"persistent_state", _state_wrapper)
	_fog_volume = FogVolume.new()
	_fog_volume.name = &"SpindriftVolume"
	_fog_volume.shape = FOG_SHAPE_BOX
	_fog_volume.layers = FOG_VOLUME_LAYER
	# FogVolume only exposes size/shape/material in Godot 4.7: density, albedo
	# and emission are entirely the fog shader's output.
	_fog_volume.material = _material
	_fog_volume.visible = false
	add_child(_fog_volume)
	if _simulation == null:
		_simulation = Simulation.new()
	_apply_placement(true)


func _observe_publication() -> void:
	## Main thread. Never renders fog without a valid published persistent state,
	## and reports a hard GPU resource failure exactly once.
	if _simulation == null:
		return
	var snapshot := _simulation.get_publication_snapshot()
	var resource_error := str(snapshot.get("resource_error", ""))
	if not resource_error.is_empty():
		_report_persistent_failure(resource_error)
		return
	var revision: int = int(snapshot.get("revision", -1))
	var valid := bool(snapshot.get("valid", false))
	if valid and not _persistent_ready:
		_persistent_ready = true
		_ensure_volumetric_fog()
	if revision == _bound_revision:
		_refresh_fog_visibility()
		return
	_bound_revision = revision
	# The microstructure is carried by the same clock the simulation advances on,
	# so the render-side flow can never drift away from the advected density.
	_material.set_shader_parameter(&"sim_time_s", float(snapshot.get("simulation_time_s", 0.0)))
	var rid: RID = snapshot.get("rid", RID())
	if valid and rid.is_valid():
		if _state_wrapper.texture_rd_rid != rid:
			# Only the wrapper's RID changes after a swap. The Texture3DRD object
			# and the material parameter identity are reused every step.
			_state_wrapper.texture_rd_rid = rid
			_material.set_shader_parameter(&"persistent_state", _state_wrapper)
		_apply_placement(true)
	elif _state_wrapper.texture_rd_rid.is_valid():
		_state_wrapper.texture_rd_rid = RID()
		_material.set_shader_parameter(&"persistent_state", _state_wrapper)
	_refresh_fog_visibility()


func _report_persistent_failure(reason: String) -> void:
	## A clear, single diagnostic. The persistent path is disabled outright; the
	## rest of Ocean V4 keeps working and no incorrect fake density is rendered.
	## Legacy streaks are never re-enabled here: if the author hid them, they stay
	## hidden.
	_persistent_failed = true
	_persistent_ready = false
	if _fog_volume != null:
		_fog_volume.visible = false
	if _persistent_failure_reported:
		return
	_persistent_failure_reported = true
	print("SPINDRIFT VOLUMETRIC | persistent 3D state unavailable (%s); volumetric path disabled, H4.31 particles untouched" % reason)


func _refresh_fog_visibility() -> void:
	if _fog_volume == null:
		return
	_fog_volume.visible = _visible \
		and _persistent_ready \
		and not _persistent_failed \
		and _state_wrapper != null \
		and _state_wrapper.texture_rd_rid.is_valid()


func _apply_placement(force: bool) -> void:
	if _fog_volume == null:
		return
	var radius := _sim_radius_m()
	var size := Vector3(radius * 2.0, SIM_COLUMN_HEIGHT_M, radius * 2.0)
	if not size.is_equal_approx(_sim_extent):
		# The requested extent only ever travels to the render thread inside the
		# per-step config packet. The main thread never mutates simulation state,
		# and no GPU resource is recreated for a world-space size change.
		_sim_extent = size
		force = true
	# The simulation is the single authority for the grid origin, so the render
	# shader and the compute pass can never disagree. Before the first published
	# step the placeholder origin is used and the fog stays hidden anyway.
	var origin: Vector3 = _sim_origin
	var snapshot := _simulation.get_publication_snapshot() if _simulation != null else {}
	if bool(snapshot.get("valid", false)):
		origin = snapshot.get("origin", origin)
		_sim_extent = snapshot.get("extent", _sim_extent)
	else:
		origin = Simulation.snapped_origin(_anchor_xz, _sea_level, _sim_extent, Simulation.RESOLUTION)
	if not force and origin.is_equal_approx(_sim_origin):
		return
	_sim_origin = origin
	_fog_volume.size = _sim_extent
	global_position = _sim_origin + _sim_extent * 0.5
	_refresh_fog_length()
	if _material != null:
		_material.set_shader_parameter(&"sim_origin", _sim_origin)
		_material.set_shader_parameter(&"sim_extent", _sim_extent)
	_placement_updates += 1


func _apply_profile() -> void:
	if _material == null or _profile == null:
		return
	var density_decay := maxf(_profile.volumetric_density_decay, 0.0)
	var wave_decay := maxf(_profile.volumetric_wave_memory_decay, 0.0001)
	# Steady-state ratio of the two decay rates. The affinity proxy is normalised
	# by it, so a continuously fed crest reads ~1 and a stale parcel decays to 0.
	# Both the compute pass and the render pass derive it from the same two rates.
	var steady_ratio := clampf(density_decay / wave_decay, 0.02, 1.0)
	_material.set_shader_parameter(&"sea_level", _sea_level)
	_material.set_shader_parameter(&"height_m", _profile.volumetric_height_m)
	_material.set_shader_parameter(&"volume_density", _profile.volumetric_density)
	_material.set_shader_parameter(&"edge_fade", _profile.volumetric_edge_fade)
	_material.set_shader_parameter(&"wind_direction", _wind_direction)
	_material.set_shader_parameter(&"wind_speed_mps", _wind_speed_mps)
	_material.set_shader_parameter(&"wind_advection", _profile.volumetric_wind_advection)
	_material.set_shader_parameter(&"curl_strength", _profile.volumetric_curl_strength)
	_material.set_shader_parameter(&"curl_scale", _profile.volumetric_curl_scale)
	_material.set_shader_parameter(&"curl_speed", _profile.volumetric_curl_speed)
	_material.set_shader_parameter(&"granule_strength", _profile.volumetric_granule_strength)
	_material.set_shader_parameter(&"granule_scale", _profile.volumetric_granule_scale)
	_material.set_shader_parameter(&"granule_speed", _profile.volumetric_granule_speed)
	_material.set_shader_parameter(&"granule_threshold", _profile.volumetric_granule_threshold)
	_material.set_shader_parameter(&"affinity_steady_ratio", steady_ratio)
	_material.set_shader_parameter(&"albedo_color", Color(_profile.volumetric_albedo, 1.0))
	_material.set_shader_parameter(&"emission_strength", _profile.volumetric_emission)
	# Simulation parameters are NOT pushed to the simulation here. They travel in
	# the immutable per-step config packet built in update(), so an artistic edit
	# can never be observed by a step that is already in flight.
	_apply_placement(true)


func _refresh_fog_length() -> void:
	## H4.34. The volumetric fog range must contain the WHOLE local volume as seen
	## from the camera, not just its radius: the camera is not guaranteed to sit at
	## the volume centre, and the distance to an XZ corner alone is already
	## radius * sqrt(2). The required range is therefore the exact AABB
	## far-corner distance, plus a small safety margin.
	##
	## Only ever written while this system owns the value. If the scene already had
	## volumetric fog enabled, the authored length is left completely alone.
	if not _environment_mutated:
		return
	if _environment == null or not is_instance_valid(_environment):
		return
	var min_corner := _sim_origin
	var max_corner := _sim_origin + _sim_extent
	var far_axis := Vector3(
		maxf(absf(_camera_position.x - min_corner.x), absf(_camera_position.x - max_corner.x)),
		maxf(absf(_camera_position.y - min_corner.y), absf(_camera_position.y - max_corner.y)),
		maxf(absf(_camera_position.z - min_corner.z), absf(_camera_position.z - max_corner.z)))
	if not far_axis.is_finite():
		return
	var required := far_axis.length() + FOG_LENGTH_SAFETY_M
	var original_length := float(_environment_original.get("volumetric_fog_length", MIN_FOG_LENGTH_M))
	_computed_fog_length = clampf(required, maxf(original_length, MIN_FOG_LENGTH_M), MAX_FOG_LENGTH_M)
	# Only touch the Environment when the value really moved, so a smooth camera
	# does not dirty the resource every frame.
	if absf(_environment.volumetric_fog_length - _computed_fog_length) > FOG_LENGTH_EPSILON_M:
		_environment.volumetric_fog_length = _computed_fog_length


func _acquire_environment() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var world := viewport.find_world_3d()
	if world == null:
		return
	_environment = world.environment


func _ensure_volumetric_fog() -> void:
	## A FogVolume only renders when the active Environment has volumetric fog
	## enabled. This is done reversibly:
	##   * if volumetric fog is already ON, nothing is written at all;
	##   * if it is OFF, only "enabled", "density" and "length" are touched, the
	##     originals are stored and restored when the prototype goes away;
	##   * global volumetric fog density is forced to 0, so the prototype never
	##     introduces global fog into the scene.
	## The Environment is only touched once the persistent field really exists, so
	## a failed prototype leaves the scene exactly as it found it.
	if Engine.is_editor_hint():
		return
	if not _persistent_ready or _persistent_failed:
		return
	if _environment == null or not is_instance_valid(_environment):
		_acquire_environment()
	if _environment == null or not is_instance_valid(_environment):
		return
	if _environment.volumetric_fog_enabled or _environment_mutated:
		return
	_environment_original = {
		"volumetric_fog_enabled": _environment.volumetric_fog_enabled,
		"volumetric_fog_density": _environment.volumetric_fog_density,
		"volumetric_fog_length": _environment.volumetric_fog_length,
	}
	_environment.volumetric_fog_enabled = true
	_environment.volumetric_fog_density = 0.0
	_environment_mutated = true
	_refresh_fog_length()
	print("SPINDRIFT VOLUMETRIC | volumetric fog was OFF; enabled reversibly (global density=0, length=%.0fm)" % _environment.volumetric_fog_length)


func _current_environment() -> Environment:
	var viewport := get_viewport()
	if viewport == null:
		return null
	var world := viewport.find_world_3d()
	return world.environment if world != null else null


func _poll_environment() -> void:
	## The WorldEnvironment may not exist yet on the frame the prototype is
	## created, and the active environment can be replaced by a scene change, so
	## the resolution stays live instead of being cached once.
	if Engine.is_editor_hint():
		set_process(false)
		return
	if _persistent_failed:
		set_process(false)
		return
	if not _persistent_ready:
		return
	var current := _current_environment()
	if current == null:
		if not _environment_unavailable_logged:
			_environment_unavailable_logged = true
			print("SPINDRIFT VOLUMETRIC | no WorldEnvironment yet; retrying until the scene provides one")
		return
	if current != _environment:
		restore_environment()
		_environment = current
		_environment_unavailable_logged = false
		_ensure_volumetric_fog()
		return
	if _environment_mutated:
		return
	_ensure_volumetric_fog()
	if not _environment_mutated:
		# Volumetric fog was already enabled by the scene: nothing to poll for.
		set_process(false)


func restore_environment() -> void:
	if not _environment_mutated:
		return
	_environment_mutated = false
	if _environment == null or not is_instance_valid(_environment):
		_environment_original.clear()
		return
	_environment.volumetric_fog_enabled = bool(_environment_original.get("volumetric_fog_enabled", false))
	_environment.volumetric_fog_density = float(_environment_original.get("volumetric_fog_density", _environment.volumetric_fog_density))
	_environment.volumetric_fog_length = float(_environment_original.get("volumetric_fog_length", _environment.volumetric_fog_length))
	_environment_original.clear()
	print("SPINDRIFT VOLUMETRIC | environment volumetric fog settings restored")


func shutdown() -> void:
	## Order matters: every render-graph reference to the GPU textures is dropped
	## on the main thread FIRST, and only then are the owning RIDs freed on the
	## render thread, so no invalid RID can survive.
	restore_environment()
	set_process(false)
	_persistent_ready = false
	_bound_revision = -1
	_breaking_rid = RID()
	_displacement_rid = RID()
	_source_bound = false
	if _fog_volume != null and is_instance_valid(_fog_volume):
		_fog_volume.visible = false
	if _material != null:
		_material.set_shader_parameter(&"persistent_state", null)
	if _state_wrapper != null:
		_state_wrapper.texture_rd_rid = RID()
	if _simulation != null:
		# The Callable keeps the simulation alive until the render thread runs
		# this, so a late queued advance() cannot dereference a freed object.
		RenderingServer.call_on_render_thread(_simulation.shutdown)
		_simulation = null


func _process(_delta: float) -> void:
	_poll_environment()


func _exit_tree() -> void:
	shutdown()
