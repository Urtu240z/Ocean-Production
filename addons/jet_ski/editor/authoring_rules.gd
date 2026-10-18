@tool
extends RefCounted
## Inspector-only filtering. Values remain serialized and gameplay is untouched.
const ROOT := "res://addons/jet_ski/common/core/jet_ski_controller.gd"
const WATER := "res://addons/jet_ski/common/systems/jet_ski_water_physics_system.gd"
const HANDLING := "res://addons/jet_ski/common/handling/jet_ski_arcade_handling.gd"
const LEGACY_SUPPORT := ["buoyancy_strength_per_point","buoyancy_damping_per_point",
	"buoyancy_damping_full_depth_m","max_submersion_depth","deep_buoyancy_start_depth",
	"deep_buoyancy_strength_per_point","deep_buoyancy_force_limit_per_meter","max_buoyancy_force_per_point"]
const LEGACY_ANGULAR := ["buoyancy_torque_scale","wet_pitch_damping","wet_roll_damping",
	"wet_yaw_damping","max_buoyancy_force_rise_N_per_s","buoyancy_reentry_torque_ramp_seconds"]
const CUSTOM_ENGINE := ["forward_engine_force","reverse_engine_force",
	"forward_thrust_falloff_start_speed","forward_thrust_falloff_end_speed"]
const CONTINUITY := ["use_effective_water_contact","use_yaw_rate_controller","use_progressive_lateral_grip",
	"use_landing_blend","water_contact_rise_time","water_contact_release_time","micro_air_steering_ratio",
	"yaw_rate_reference_length","maximum_desired_yaw_rate","yaw_rate_steering_strength","yaw_rate_damping",
	"maximum_yaw_torque","landing_blend_time"]
const REFRESH_PROPERTIES := ["buoyancy_mode","hull_response_mode","drive_mode","hull_v1_arcade_enabled",
	"heavy_upright_enabled","powered_trim_enabled","nose_up_limit_enabled","auto_nose_recovery_enabled",
	"landing_penetration_enabled","turn_lean_enabled","rider_weight_shift_enabled","submarine_dive_enabled",
	"manual_ejection_enabled","water_recovery_enabled","ocean","use_arcade_turn_continuity",
	"water_race_mode","stabilized_angular_mode","combined_rider_inertia","arcade_handling_enabled",
	"use_effective_water_contact","use_yaw_rate_controller","use_landing_blend"]

static func script_path(object: Object) -> String:
	var script: Script=object.get_script()
	return script.resource_path if script!=null else ""

static func handles(object: Object) -> bool:
	return script_path(object) in [ROOT,WATER,HANDLING]

static func flag(object: Object, key: String, fallback := true) -> bool:
	var value: Variant=object.get(key) if is_instance_valid(object) else null
	return fallback if value==null else bool(value)

static func parent_vehicle(object: Object) -> Node:
	var node:=object as Node
	while node!=null:
		if script_path(node)==ROOT: return node
		node=node.get_parent()
	return null

static func visible(object: Object, property: String, show_all := false) -> bool:
	if show_all: return true
	var vehicle:=parent_vehicle(object)
	if vehicle==null: return true
	var hull: bool=int(vehicle.get("buoyancy_mode"))==1
	var heavy: bool=hull and int(vehicle.get("hull_response_mode"))==1
	var arcade: bool=hull and not heavy and flag(vehicle,"hull_v1_arcade_enabled")
	var setup:=vehicle.get_node_or_null("ProductionSetup")
	# The shipped node name is resolved by script, not required by hosts.
	if setup==null:
		for child in vehicle.find_children("*","Node",true,false):
			if script_path(child).ends_with("/jet_ski_production_setup.gd"): setup=child; break
	var race:=flag(setup,"water_race_mode")
	var path:=script_path(object)
	if path==ROOT:
		if property in ["ocean_path","water_provider_path"]: return vehicle.get("ocean")==null
		if property=="hull_response_mode": return hull
		if property=="buoyancy_damping_full_depth_m": return not hull
		if property in LEGACY_SUPPORT: return not hull and race
		if property in LEGACY_ANGULAR: return not hull and flag(setup,"stabilized_angular_mode")
		if property.begins_with("heavy_"):
			if not heavy: return false
			if property in ["heavy_wave_tilt_influence","heavy_normal_lateral_influence","heavy_upright_response_rate"]:
				return flag(vehicle,"heavy_upright_enabled")
		if property.begins_with("hull_v1_"):
			if property=="hull_v1_arcade_enabled": return hull and not heavy
			return arcade
		if property.begins_with("powered_trim_"): return arcade and (property=="powered_trim_enabled" or flag(vehicle,"powered_trim_enabled"))
		if property.begins_with("nose_up_"): return property=="nose_up_limit_enabled" or flag(vehicle,"nose_up_limit_enabled")
		if property.begins_with("nose_recovery_"): return flag(vehicle,"auto_nose_recovery_enabled")
		if property in ["landing_penetration_enabled","landing_entry_speed_threshold","landing_upward_damping_multiplier"]:
			return hull and not heavy and (property=="landing_penetration_enabled" or flag(vehicle,"landing_penetration_enabled"))
		if property.begins_with("rider_inertia_"): return flag(setup,"combined_rider_inertia")
		if property in CUSTOM_ENGINE: return int(vehicle.get("drive_mode"))==0
		if property.begins_with("turn_lean_"): return property=="turn_lean_enabled" or flag(vehicle,"turn_lean_enabled")
		if property.begins_with("rider_") and property!="rider_weight_shift_enabled": return flag(vehicle,"rider_weight_shift_enabled")
		if property=="submarine_max_duration": return flag(vehicle,"submarine_dive_enabled") and not arcade
		if property.begins_with("submarine_"): return property=="submarine_dive_enabled" or flag(vehicle,"submarine_dive_enabled")
		if property.begins_with("manual_ejection_"): return property=="manual_ejection_enabled" or flag(vehicle,"manual_ejection_enabled")
		if property.begins_with("recovery_"): return flag(vehicle,"water_recovery_enabled")
	elif path==WATER:
		if property=="equilibrium_depth": return not hull and not race
		if property=="damping_ratio": return hull or not race
		if property=="buoyancy_normal_influence": return not hull and race
	elif path==HANDLING:
		if property in CONTINUITY:
			if not flag(vehicle,"use_arcade_turn_continuity",false): return false
			if property in ["water_contact_rise_time","water_contact_release_time"]: return flag(object,"use_effective_water_contact")
			if property.begins_with("yaw_rate_") or property in ["maximum_desired_yaw_rate","maximum_yaw_torque"]: return flag(object,"use_yaw_rate_controller")
			if property=="landing_blend_time": return flag(object,"use_landing_blend")
	return true
