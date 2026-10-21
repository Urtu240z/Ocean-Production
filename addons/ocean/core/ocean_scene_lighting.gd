@tool
extends RefCounted
## Main-thread lighting snapshot shared by Ocean's visual consumers. No water
## queries, readbacks, sky baking or dependency on a time-of-day addon.

var _frame := -1
var _state: Dictionary = {}
var _scene_id := 0
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _next_search_ms := 0


func invalidate() -> void:
	_frame = -1
	_scene_id = 0
	_next_search_ms = 0
	_sun = null
	_moon = null


func sample(ocean: Node3D, explicit_sun: DirectionalLight3D, explicit_moon: DirectionalLight3D, environment_node: WorldEnvironment) -> Dictionary:
	var frame := Engine.get_process_frames()
	if frame == _frame:
		return _state
	_frame = frame
	var scene := ocean.get_tree().current_scene
	if Engine.is_editor_hint():
		scene = ocean.get_tree().edited_scene_root
	if scene == null:
		scene = ocean.get_tree().root
	var scene_id := scene.get_instance_id()
	if scene_id != _scene_id or not is_instance_valid(_sun) or (_moon != null and not is_instance_valid(_moon)):
		if scene_id != _scene_id or Time.get_ticks_msec() >= _next_search_ms:
			_scene_id = scene_id
			_next_search_ms = Time.get_ticks_msec() + 2000
			var lights := scene.find_children("*", "DirectionalLight3D", true, false)
			_sun = explicit_sun if is_instance_valid(explicit_sun) else (lights[0] as DirectionalLight3D if not lights.is_empty() else null)
			_moon = explicit_moon if is_instance_valid(explicit_moon) else null
			# Auto moon is deliberately unambiguous. Larger lighting rigs can bind
			# both references in Ocean's inspector instead of relying on node names.
			if _moon == null and lights.size() == 2:
				_moon = lights[1] as DirectionalLight3D if lights[0] == _sun else lights[0] as DirectionalLight3D
	var sun := explicit_sun if is_instance_valid(explicit_sun) else _sun
	var moon := explicit_moon if is_instance_valid(explicit_moon) else _moon
	if moon == sun:
		moon = null
	var sun_energy := _energy(sun)
	var moon_energy := _energy(moon)
	var sun_color := sun.light_color.srgb_to_linear() if is_instance_valid(sun) else Color.BLACK
	var moon_color := moon.light_color.srgb_to_linear() if is_instance_valid(moon) else Color.BLACK
	var direct := Vector3(sun_color.r, sun_color.g, sun_color.b) * sun_energy + Vector3(moon_color.r, moon_color.g, moon_color.b) * moon_energy
	var environment: Environment = environment_node.environment if is_instance_valid(environment_node) else ocean.get_world_3d().environment
	var ambient := Vector3.ZERO
	var ambient_tint := Vector3.ZERO
	if environment != null and environment.ambient_light_source != Environment.AMBIENT_SOURCE_DISABLED:
		var color := environment.ambient_light_color.srgb_to_linear()
		# Sky3D authors this color even when its sky contribution is 100%.
		# Keep its chroma separate from direct-light energy and the sky estimate.
		if environment.ambient_light_energy > 0.0:
			ambient_tint = Vector3(color.r, color.g, color.b)
		var sky_weight := 0.0
		if environment.ambient_light_source == Environment.AMBIENT_SOURCE_SKY or (environment.ambient_light_source == Environment.AMBIENT_SOURCE_BG and environment.background_mode == Environment.BG_SKY):
			sky_weight = environment.ambient_light_sky_contribution
		# Approximate sky irradiance from the actual celestial lights. Reading
		# a GPU sky cubemap back to the CPU every frame would introduce stalls.
		ambient = (Vector3(color.r, color.g, color.b) * (1.0 - sky_weight) + direct * sky_weight) * maxf(environment.ambient_light_energy, 0.0)
	var dominant := moon if moon_energy > sun_energy else sun
	var dominant_energy := maxf(sun_energy, moon_energy)
	var dominant_color := moon_color if moon_energy > sun_energy else sun_color
	_state = {
		"directional_irradiance": direct, "ambient_irradiance": ambient,
		"ambient_tint": ambient_tint,
		"direction": dominant.global_transform.basis.z.normalized() if is_instance_valid(dominant) else Vector3.UP,
		"color": dominant_color, "energy": dominant_energy,
		"sun_id": sun.get_instance_id() if is_instance_valid(sun) else 0,
		"moon_id": moon.get_instance_id() if is_instance_valid(moon) else 0,
	}
	return _state


func _energy(light: DirectionalLight3D) -> float:
	if not is_instance_valid(light) or not light.is_inside_tree() or not light.is_visible_in_tree() or light.editor_only:
		return 0.0
	# basis.z points from water towards the source, opposite the light rays.
	return maxf(light.light_energy, 0.0) * smoothstep(-0.05, 0.10, light.global_transform.basis.z.normalized().y)
