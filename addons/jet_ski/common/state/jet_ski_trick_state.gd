class_name JetSkiTrickState
extends RefCounted

var preload_state: JetSkiTypes.TrickPreloadState = (
	JetSkiTypes.TrickPreloadState.IDLE
)
var launch_consumed: bool = false

var roll_preload_sign: float = 0.0
var roll_hold_time: float = 0.0
var roll_charge: float = 0.0
var roll_reversal_armed: bool = false
var roll_reversal_direction: float = 0.0
var roll_armed_charge: float = 0.0
var roll_reversal_time_remaining: float = 0.0

var pitch_preload_sign: float = 0.0
var pitch_hold_time: float = 0.0
var pitch_charge: float = 0.0
var pitch_reversal_armed: bool = false
var pitch_reversal_direction: float = 0.0
var pitch_armed_charge: float = 0.0
var pitch_reversal_time_remaining: float = 0.0

var takeoff_pending: bool = false
var time_since_takeoff: float = 0.0
var pending_speed_factor: float = 0.0
var pending_upward_factor: float = 0.0
var pending_depth_factor: float = 0.0
var pending_launch_speed_valid: bool = false
var last_contact_average_depth: float = 0.0
var takeoff_quality: float = 0.0
var takeoff_timing_factor: float = 0.0

var release_active: bool = false
var release_elapsed: float = 0.0
var release_time_remaining: float = 0.0
var release_strength: Vector2 = Vector2.ZERO
var release_charge: Vector2 = Vector2.ZERO
var release_roll_torque: float = 0.0
var release_pitch_torque: float = 0.0

var last_launch_type: JetSkiTypes.RiderTrickLaunchType = (
	JetSkiTypes.RiderTrickLaunchType.NONE
)
var last_launch_charge: Vector2 = Vector2.ZERO
var last_release_strength: Vector2 = Vector2.ZERO


func reset_runtime_state() -> void:
	preload_state = JetSkiTypes.TrickPreloadState.IDLE
	launch_consumed = false
	roll_preload_sign = 0.0
	roll_hold_time = 0.0
	roll_charge = 0.0
	roll_reversal_armed = false
	roll_reversal_direction = 0.0
	roll_armed_charge = 0.0
	roll_reversal_time_remaining = 0.0
	pitch_preload_sign = 0.0
	pitch_hold_time = 0.0
	pitch_charge = 0.0
	pitch_reversal_armed = false
	pitch_reversal_direction = 0.0
	pitch_armed_charge = 0.0
	pitch_reversal_time_remaining = 0.0
	takeoff_pending = false
	time_since_takeoff = 0.0
	pending_speed_factor = 0.0
	pending_upward_factor = 0.0
	pending_depth_factor = 0.0
	pending_launch_speed_valid = false
	last_contact_average_depth = 0.0
	takeoff_quality = 0.0
	takeoff_timing_factor = 0.0
	release_active = false
	release_elapsed = 0.0
	release_time_remaining = 0.0
	release_strength = Vector2.ZERO
	release_charge = Vector2.ZERO
	release_roll_torque = 0.0
	release_pitch_torque = 0.0
	last_launch_type = JetSkiTypes.RiderTrickLaunchType.NONE
	last_launch_charge = Vector2.ZERO
	last_release_strength = Vector2.ZERO
