extends SceneTree
## Full production vehicle/emitter/native sampler on flat authoritative water.
## Isolates self-feedback from ocean weather and visual settings.
const Vehicle := preload("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn")
const WaveState := preload("res://addons/ocean/physics/water/hull_wave_state.gd")

class HullWater extends WaterSurfaceProvider3D:
	var body: JetSkiController
	var physical := false
	var state := WaveState.new()
	var style: Resource = preload("res://addons/ocean/surface/foam2d/default_style.tres").duplicate(true)

	func prepare_water_queries(_pose: Transform3D, _points: PackedVector3Array,
			_extra: PackedVector3Array, dt: float) -> void:
		state.advance(Engine.get_physics_frames(), dt, [body], style)

	func sample_water(position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
		var sample := out_sample.reset() if out_sample != null else WaterSample3D.new()
		sample.valid = true
		sample.normal = Vector3.UP
		sample.surface_position = Vector3(position.x, 0, position.z)
		sample.signed_depth = -position.y
		if physical:
			var samples: Array[WaterSample3D] = [sample]
			state.apply(samples, PackedVector3Array([position]), style,
				body.get_instance_id(), body.global_position)
		return sample

var failures: Array[String] = []

func _initialize() -> void:
	if "--production" in OS.get_cmdline_user_args():
		production_run.call_deferred()
	else:
		run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("HULL_SELF_FLOTATION: " + message)

func trial(physical: bool) -> Dictionary:
	var water := HullWater.new()
	water.physical = physical
	root.add_child(water)
	var ski: JetSkiController = Vehicle.instantiate()
	water.body = ski
	ski.configure_water_provider(water)
	ski.collision_layer = 0
	ski.collision_mask = 0
	ski.position = Vector3(0, 0.2143, 0)
	ski.linear_velocity = Vector3(0, 0, -12)
	root.add_child(ski)
	Input.action_press("throttle", 1.0)
	var height := 0.0
	var pitch := 0.0
	var speed := 0.0
	var surface := 0.0
	for tick in 480:
		await physics_frame
		check(ski.global_transform.is_finite() and ski.linear_velocity.is_finite(), "finite vehicle")
		if tick >= 360:
			height += ski.position.y / 120.0
			pitch += ski.global_basis.get_euler().x / 120.0
			speed += ski.linear_velocity.slide(Vector3.UP).length() / 120.0
			surface += water.sample_water(ski.global_position).surface_position.y / 120.0
	Input.action_release("throttle")
	var result := {"enabled":physical,"height_m":height,"pitch_rad":pitch,
		"speed_mps":speed,"own_surface_m":surface,"packets":water.state.emitter.packets.size()}
	print("HULL_SELF_TRIAL ",JSON.stringify(result))
	ski.queue_free()
	water.queue_free()
	await physics_frame
	return result

func run() -> void:
	var off := await trial(false)
	var on := await trial(true)
	check(int(on.packets) > 0, "real moving vehicle emits its own waves")
	check(absf(on.speed_mps-off.speed_mps) < 0.5, "same forward driving speed")
	check(absf(on.height_m-off.height_m) < 0.005,
		"enabling own-wave physics preserves cruising flotation within 5 mm")
	print("HULL_SELF_FLOTATION_%s delta_m=%.6f errors=%d" % [
		"PASS" if failures.is_empty() else "FAIL",on.height_m-off.height_m,failures.size()])
	quit(0 if failures.is_empty() else 1)

func cruising_height(ski: JetSkiController) -> float:
	for tick in 180: await physics_frame
	var height := 0.0
	for tick in 60:
		await physics_frame
		height += ski.global_position.y / 60.0
	return height

func production_run() -> void:
	var world := load("res://gameplay/jet_ski_ocean.tscn").instantiate() as Node3D
	var ocean := world.get_node("Production/Ocean") as Ocean
	ocean.hull_foam_settings = ocean.get_hull_foam_settings().duplicate(true)
	ocean.wave_height_scale = 0.0
	ocean.wind_speed_mps = 3.0
	ocean.set("foam_deformation_enabled",true)
	ocean.set("foam_wave_physics_enabled",false)
	root.add_child(world)
	for frame in 1800:
		await process_frame
		if bool(world.get("ready_to_drive")): break
	check(bool(world.get("ready_to_drive")),"production Ocean initializes")
	if not bool(world.get("ready_to_drive")): quit(1); return
	var ski: JetSkiController = world.get("ski")
	ski.collision_layer = 0
	ski.collision_mask = 0
	Input.action_press("throttle",1.0)
	var off := await cruising_height(ski)
	ocean.set("foam_wave_physics_enabled",true)
	var on := await cruising_height(ski)
	var state := ocean.get_physical_hull_wave_state()
	check(state != null and state.emitter.packets.size() > 0,"Inspector toggle enables real physical own waves")
	ocean.set("foam_wave_physics_enabled",false)
	var restored := await cruising_height(ski)
	Input.action_release("throttle")
	check(absf(on-off) < 0.005,"actual Ocean enable preserves cruising height within 5 mm")
	check(absf(restored-off) < 0.005,"actual Ocean disable also preserves cruising height")
	print("HULL_SELF_PRODUCTION_%s off=%.6f on=%.6f restored=%.6f delta_m=%.6f errors=%d" % [
		"PASS" if failures.is_empty() else "FAIL",off,on,restored,on-off,failures.size()])
	root.remove_child(world)
	world.queue_free()
	for frame in 10: await process_frame
	quit(0 if failures.is_empty() else 1)
