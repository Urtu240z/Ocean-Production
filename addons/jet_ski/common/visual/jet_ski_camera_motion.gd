extends RefCounted
## Render-only camera translation and angular shake. Reads water telemetry;
## never applies forces, changes the vehicle, or queries the ocean again.
var enabled := true
var speed_start_mps := 10.0
var speed_full_mps := 28.0
var speed_amplitude_m := 0.035
var submerged_amplitude_m := 0.12
var speed_rotation_degrees := 0.4
var submerged_rotation_degrees := 2.0
var chase_frequency_hz := 1.3
var submerged_frequency_hz := 6.0
var response_rate := 5.0
var rotation_offset_radians := Vector3.ZERO

var _noise := FastNoiseLite.new()
var _chase_phase := 0.0
var _load_phase := 0.0
var _speed_weight := 0.0
var _load_weight := 0.0


func _init() -> void:
	_noise.seed = 7319
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0


func reset() -> void:
	_speed_weight = 0.0
	_load_weight = 0.0
	rotation_offset_radians = Vector3.ZERO


func update(delta: float, speed_mps: float, root_depth_m: float,
		drag_acceleration_mps2: float, has_water_contact: bool) -> Vector2:
	if not enabled:
		reset()
		return Vector2.ZERO
	var speed_target := smoothstep(speed_start_mps, maxf(speed_full_mps, speed_start_mps + 0.1), speed_mps)
	# Immersion must coincide with motion: a stopped, submerged ski stays calm.
	var load_target := smoothstep(0.15, 0.9, root_depth_m) * smoothstep(1.0, 8.0, speed_mps)
	load_target *= lerpf(0.5, 1.0, smoothstep(0.5, 4.0, drag_acceleration_mps2))
	if not has_water_contact: load_target = 0.0
	var blend := 1.0 - exp(-maxf(delta, 0.0) * maxf(response_rate, 0.01))
	_speed_weight = lerpf(_speed_weight, speed_target, blend)
	_load_weight = lerpf(_load_weight, load_target, blend)
	_chase_phase += delta * chase_frequency_hz
	_load_phase += delta * submerged_frequency_hz
	var chase := Vector2(_noise.get_noise_2d(_chase_phase, 0.0),
		_noise.get_noise_2d(_chase_phase, 17.0) * 0.75)
	var loaded := Vector2(_noise.get_noise_2d(_load_phase, 43.0),
		_noise.get_noise_2d(_load_phase, 79.0) * 0.75)
	# Pitch/yaw move even distant scenery and the sky across the image.
	# A little roll adds vibration without a pronounced swinging horizon.
	var chase_rotation := Vector3(_noise.get_noise_2d(_chase_phase, 103.0),
		_noise.get_noise_2d(_chase_phase, 127.0), _noise.get_noise_2d(_chase_phase, 149.0) * 0.25)
	var loaded_rotation := Vector3(_noise.get_noise_2d(_load_phase, 173.0),
		_noise.get_noise_2d(_load_phase, 197.0), _noise.get_noise_2d(_load_phase, 223.0) * 0.25)
	rotation_offset_radians = chase_rotation * deg_to_rad(speed_rotation_degrees) \
		* _speed_weight * (1.0 - _load_weight) \
		+ loaded_rotation * deg_to_rad(submerged_rotation_degrees) * _load_weight
	# Blend rather than add both effects so immersion has a bounded amplitude.
	return chase * speed_amplitude_m * _speed_weight * (1.0 - _load_weight) \
		+ loaded * submerged_amplitude_m * _load_weight
