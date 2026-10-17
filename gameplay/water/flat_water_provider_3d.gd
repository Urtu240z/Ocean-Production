class_name FlatWaterProvider3D
extends WaterSurfaceProvider3D
## Standalone world-space horizontal plane. No Ocean, FFT or native dependency.
@export var water_height: float = 0.0
@export var water_velocity := Vector3.ZERO
@export var water_enabled := true


func sample_water(world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	var sample := out_sample.reset() if out_sample != null else WaterSample3D.new()
	if not water_enabled or not world_position.is_finite() or not is_finite(water_height) \
			or not water_velocity.is_finite():
		return sample
	sample.valid = true
	sample.surface_position = Vector3(world_position.x, water_height, world_position.z)
	sample.normal = Vector3.UP
	sample.velocity = water_velocity
	sample.signed_depth = water_height - world_position.y
	sample.provider = self
	sample.sample_physics_tick = Engine.get_physics_frames()
	sample.sample_time_seconds = float(sample.sample_physics_tick) / float(Engine.physics_ticks_per_second)
	return sample
