class_name OceanWaterlineCameraAssist
extends RefCounted
## Keeps only the final render camera on a committed side of the macro surface.

enum Side { ABOVE, UNDER }

const BIAS_SAFETY_M := 0.005
const FULL_BIAS_DISTANCE_M := 0.12

var _anchor: Node3D
var _camera: Camera3D
var _camera_local_from_anchor := Transform3D.IDENTITY
var _side := Side.ABOVE
var _active := false


func configure(anchor: Node3D, render_camera: Camera3D) -> bool:
	if anchor == null or render_camera == null or not is_instance_valid(anchor) or not is_instance_valid(render_camera):
		return false
	_anchor = anchor
	_camera = render_camera
	_camera_local_from_anchor = anchor.global_transform.affine_inverse() * render_camera.global_transform
	_active = true
	return true


func update(local_surface_y: float, bias_m: float, enter_under_m: float, exit_under_m: float, release_distance_m: float) -> bool:
	if not _active or _anchor == null or _camera == null or not is_instance_valid(_anchor) or not is_instance_valid(_camera):
		return false
	var minimum_bias := maxf(enter_under_m, exit_under_m) + BIAS_SAFETY_M
	var bias := maxf(bias_m, minimum_bias)
	var anchor_y := _anchor.global_position.y
	var distance := anchor_y - local_surface_y
	if _side == Side.ABOVE:
		if distance <= enter_under_m:
			_side = Side.UNDER
	elif distance >= exit_under_m:
		_side = Side.ABOVE
	var full_bias_distance := maxf(FULL_BIAS_DISTANCE_M, maxf(enter_under_m, exit_under_m) + bias)
	var release := maxf(release_distance_m, full_bias_distance + 0.001)
	var amount := 1.0 - smoothstep(full_bias_distance, release, absf(distance))
	var final_transform := _anchor.global_transform * _camera_local_from_anchor
	final_transform.origin.y += bias * amount * (1.0 if _side == Side.ABOVE else -1.0)
	_camera.global_transform = final_transform
	return _side == Side.UNDER


func restore() -> void:
	if _active and _anchor != null and _camera != null and is_instance_valid(_anchor) and is_instance_valid(_camera):
		_camera.global_transform = _anchor.global_transform * _camera_local_from_anchor
	_active = false


func is_active() -> bool:
	return _active
