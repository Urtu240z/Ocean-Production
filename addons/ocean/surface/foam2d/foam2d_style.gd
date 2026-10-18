@tool
extends Resource
class_name Foam2DStyle
## Ocean surface effects. These settings do not alter water queries or buoyancy.
@export_group("Hull Foam")
@export_subgroup("Appearance")
@export var water_tint := Color(0.08,0.36,0.45,1.0):
	set(value): water_tint=value; emit_changed()
@export var white_color := Color(0.85,0.93,0.94,1.0):
	set(value): white_color=value; emit_changed()
@export_range(0.0,2.0,0.01) var opacity := 0.85:
	set(value): opacity=value; emit_changed()
@export_range(0.0,1.0,0.01) var tint_strength := 0.20:
	set(value): tint_strength=value; emit_changed()
## Blue filaments remain visible at rest without intense whitening.
@export_range(0.0,2.0,0.01) var calm_foam_strength := 0.90:
	set(value): calm_foam_strength=value; emit_changed()
@export_range(0.0,1.0,0.01) var roughness := 0.62:
	set(value): roughness=value; emit_changed()
@export_range(0.0,1.0,0.01) var specular := 0.24:
	set(value): specular=value; emit_changed()
@export_range(0.0,0.04,0.001) var normal_strength := 0.008:
	set(value): normal_strength=value; emit_changed()
@export_subgroup("Agitation and Whitening")
@export_range(0.0,0.95,0.01) var whitening_threshold := 0.38:
	set(value): whitening_threshold=value; emit_changed()
@export_range(0.02,0.8,0.01) var whitening_transition := 0.32:
	set(value): whitening_transition=value; emit_changed()
@export_range(0.0,1.5,0.01) var white_strength := 0.85:
	set(value): white_strength=value; emit_changed()
@export_range(0.0,3.0,0.05) var impact_sensitivity := 1.0:
	set(value): impact_sensitivity=value; emit_changed()
@export_range(0.05,2.0,0.01) var agitation_decay := 0.28:
	set(value): agitation_decay=value; emit_changed()
@export_subgroup("Generation and Irregularity")
@export_range(0.3,4.0,0.05) var patch_size := 1.7:
	set(value): patch_size=value; emit_changed()
@export_range(0.0,1.0,0.01) var variation := 0.95:
	set(value): variation=value; emit_changed()
## Inward and outward contour variation, in metres.
@export_range(0.0,0.6,0.01) var edge_irregularity := 0.32:
	set(value): edge_irregularity=value; emit_changed()
## Soft edge width around newly deposited hull foam, in metres.
@export_range(0.2,0.8,0.01) var edge_fade := 0.45:
	set(value): edge_fade=value; emit_changed()
@export_range(0.0,2.0,0.05) var emission := 0.90:
	set(value): emission=value; emit_changed()
@export_subgroup("Motion and Wake")
## Shared foam deposition and transport frequency, limited by actual rendering FPS.
@export_enum("20 Hz:20","30 Hz:30","60 Hz:60") var wake_update_hz: int = 30:
	set(value): wake_update_hz=value if value in [20,30,60] else 30; emit_changed()
## Source offset towards the bow from the hull centre; never draws a wake ahead of travel.
@export_range(-0.5,1.0,0.05,"suffix:m") var wake_emission_forward_m := 0.20:
	set(value): wake_emission_forward_m=value; emit_changed()
## Full width of newly deposited foam. Independent of its subsequent opening angle.
@export_range(0.2,4.0,0.01,"suffix:m") var initial_width_m := 0.56:
	set(value): initial_width_m=value; emit_changed()
## Approximate foam lifetime with a gradual fade. Density and transport also affect visibility.
@export_range(1.0,60.0,0.5,"suffix:s") var lifetime_s := 24.0:
	set(value): lifetime_s=value; emit_changed()
## Outward transport speed from inside the hull, in metres per second.
@export_range(0.0,2.0,0.05) var outward_speed := 0.75:
	set(value): outward_speed=value; emit_changed()
## Additional outward transport following a wave impact or landing.
@export_range(0.0,4.0,0.05) var impact_outward_boost := 1.50:
	set(value): impact_outward_boost=value; emit_changed()
## Lateral expansion scale; one restores the original opening.
@export_range(0.0,1.5,0.01) var wake_spread := 0.35:
	set(value): wake_spread=value; emit_changed()
## Optional drift of the entire foam patch, independent of internal filament motion.
@export_range(0.0,1.0,0.01) var motion_strength := 0.0:
	set(value): motion_strength=value; emit_changed()
@export_range(0.0,2.0,0.05) var motion_speed := 0.60:
	set(value): motion_speed=value; emit_changed()
## Local filament deformation without translating the foam coverage.
@export_range(0.0,0.8,0.01) var filament_deformation := 0.45:
	set(value): filament_deformation=value; emit_changed()
@export_range(0.0,3.0,0.05) var filament_speed := 0.75:
	set(value): filament_speed=value; emit_changed()

@export_group("Running Foam", "running_")
@export_subgroup("Speed Response", "running_")
## Independent local hull reinforcement; does not change resting foam or the wake.
@export var running_enabled := true:
	set(value): running_enabled=value; emit_changed()
@export_range(0.0,30.0,0.5) var running_start_kmh := 0.5:
	set(value): running_start_kmh=value; emit_changed()
@export_range(1.0,100.0,0.5) var running_full_kmh := 50.0:
	set(value): running_full_kmh=value; emit_changed()
## Values below one introduce a gentle contribution at lower speeds.
@export_range(0.25,3.0,0.05) var running_speed_curve := 0.65:
	set(value): running_speed_curve=value; emit_changed()
@export_range(0.05,2.0,0.05) var running_response_seconds := 0.30:
	set(value): running_response_seconds=value; emit_changed()
@export_subgroup("Appearance", "running_")
@export var running_color := Color(0.97,0.99,1.0,1.0):
	set(value): running_color=value; emit_changed()
@export_range(0.0,3.0,0.05) var running_strength := 1.8:
	set(value): running_strength=value; emit_changed()
@export_range(0.0,1.0,0.01) var running_whiteness := 1.0:
	set(value): running_whiteness=value; emit_changed()
@export_range(0.0,1.0,0.01) var running_roughness := 0.75:
	set(value): running_roughness=value; emit_changed()
@export_range(0.0,1.0,0.01) var running_specular := 0.18:
	set(value): running_specular=value; emit_changed()
@export_range(0.0,0.04,0.001) var running_normal_strength := 0.008:
	set(value): running_normal_strength=value; emit_changed()
@export_subgroup("Coverage", "running_")
## Distances from the hull centre, with an irregular feathered boundary.
@export_range(0.5,2.5,0.05) var running_half_width := 1.25:
	set(value): running_half_width=value; emit_changed()
@export_range(1.0,3.5,0.05) var running_half_length := 2.0:
	set(value): running_half_length=value; emit_changed()
@export_range(0.15,1.0,0.05) var running_edge_fade := 0.55:
	set(value): running_edge_fade=value; emit_changed()

@export_group("Hull Waves")
@export_subgroup("General")
## Adds hull-generated displacement to the Ocean surface.
@export var deformation_enabled := false:
	set(value): deformation_enabled=value; emit_changed()
## Maximum combined wake and impact displacement relative to the FFT surface.
@export_range(0.01,2.0,0.01,"suffix:m") var deformation_max_height_m := 2.0:
	set(value): deformation_max_height_m=value; emit_changed()
@export_enum("Normal","Wave Height","Wave Normals") var deformation_debug_view := 0:
	set(value): deformation_debug_view=value; emit_changed()
@export_subgroup("Physics", "wave_physics_")
## Experimental: share the analytic hull waves with authoritative water queries.
## Requires Deformation Enabled. Independent of Hull Foam Enabled and camera position.
@export var wave_physics_enabled := false:
	set(value): wave_physics_enabled=value; emit_changed()
## Smooth local protection from newly emitted own waves. Old own wakes remain physical.
@export_range(0.0,2.0,0.05,"suffix:s") var wave_physics_self_delay_s := 0.8:
	set(value): wave_physics_self_delay_s=value; emit_changed()
@export_range(0.5,5.0,0.1,"suffix:m") var wave_physics_self_radius_m := 3.0:
	set(value): wave_physics_self_radius_m=value; emit_changed()
## Safety limit on the added vertical water velocity for extreme artistic settings.
@export_range(0.5,15.0,0.1,"suffix:m/s") var wave_physics_max_vertical_speed_mps := 5.0:
	set(value): wave_physics_max_vertical_speed_mps=value; emit_changed()
@export_subgroup("Wake", "wake_wave_")
@export_range(0.0,2.0,0.01,"suffix:m") var wake_wave_height_m := 0.25:
	set(value): wake_wave_height_m=value; emit_changed()
@export_range(0.3,8.0,0.05,"suffix:m") var wake_wave_width_m := 1.1:
	set(value): wake_wave_width_m=value; emit_changed()
@export_range(1.0,20.0,0.1,"suffix:m") var wake_wave_wavelength_m := 4.0:
	set(value): wake_wave_wavelength_m=value; emit_changed()
## Outward crest travel speed, independent of foam, lifetime and fade.
@export_range(0.0,10.0,0.05,"suffix:m/s") var wake_wave_speed_mps := 0.7:
	set(value): wake_wave_speed_mps=value; emit_changed()
@export_range(1.0,20.0,0.25,"suffix:s") var wake_wave_duration_s := 4.0:
	set(value): wake_wave_duration_s=value; emit_changed()
## Time for each wake segment to reach full height; larger values soften its onset.
@export_range(0.1,3.0,0.05,"suffix:s") var wake_wave_rise_s := 0.75:
	set(value): wake_wave_rise_s=value; emit_changed()
## Spatial onset feathering beside the bow, without delaying the wave in seconds.
@export_range(0.1,3.0,0.05,"suffix:m") var wake_wave_birth_distance_m := 0.65:
	set(value): wake_wave_birth_distance_m=value; emit_changed()
## Final fade time, automatically limited by the segment lifetime.
@export_range(0.1,6.0,0.1,"suffix:s") var wake_wave_fade_s := 1.8:
	set(value): wake_wave_fade_s=value; emit_changed()
## Smooths intensity changes during acceleration and renewed water contact.
@export_range(0.05,3.0,0.05,"suffix:s") var wake_wave_response_s := 0.5:
	set(value): wake_wave_response_s=value; emit_changed()
@export_range(0.0,30.0,0.5,"suffix:km/h") var wake_wave_min_speed_kmh := 4.0:
	set(value): wake_wave_min_speed_kmh=value; emit_changed()
@export_range(10.0,100.0,1.0,"suffix:km/h") var wake_wave_full_speed_kmh := 50.0:
	set(value): wake_wave_full_speed_kmh=value; emit_changed()
@export_subgroup("Impacts", "impact_wave_")
@export_range(0.3,8.0,0.05,"suffix:m") var impact_wave_width_m := 1.3:
	set(value): impact_wave_width_m=value; emit_changed()
@export_range(1.0,20.0,0.1,"suffix:m") var impact_wave_wavelength_m := 5.0:
	set(value): impact_wave_wavelength_m=value; emit_changed()
@export_range(0.0,2.0,0.01,"suffix:m") var impact_wave_height_m := 0.45:
	set(value): impact_wave_height_m=value; emit_changed()
@export_range(0.0,10.0,0.05,"suffix:m/s") var impact_wave_speed_mps := 2.5:
	set(value): impact_wave_speed_mps=value; emit_changed()
@export_range(1.0,20.0,0.25,"suffix:s") var impact_wave_duration_s := 3.0:
	set(value): impact_wave_duration_s=value; emit_changed()
@export_range(0.1,3.0,0.05,"suffix:s") var impact_wave_rise_s := 0.45:
	set(value): impact_wave_rise_s=value; emit_changed()
@export_range(0.1,6.0,0.1,"suffix:s") var impact_wave_fade_s := 1.4:
	set(value): impact_wave_fade_s=value; emit_changed()
@export_range(0.3,8.0,0.1,"suffix:m/s") var impact_wave_min_speed_mps := 1.5:
	set(value): impact_wave_min_speed_mps=value; emit_changed()

func running_speed_weight(speed_kmh: float) -> float:
	if not running_enabled: return 0.0
	var t := clampf((maxf(speed_kmh,0.0)-running_start_kmh)/maxf(running_full_kmh-running_start_kmh,0.1),0.0,1.0)
	return pow(t,maxf(running_speed_curve,0.25))

func shader_parameters() -> Dictionary:
	return {"foam2d_water_tint":water_tint,"foam2d_white_color":white_color,
		"foam2d_opacity":opacity,"foam2d_tint_strength":tint_strength,
		"foam2d_calm_strength":calm_foam_strength,
		"foam2d_roughness":roughness,"foam2d_specular":specular,
		"foam2d_normal_strength":normal_strength,"foam2d_white_threshold":whitening_threshold,
		"foam2d_white_transition":whitening_transition,"foam2d_white_strength":white_strength,
		"foam2d_patch_size":patch_size,"foam2d_variation":variation,
		"foam2d_filament_deformation":filament_deformation,"foam2d_filament_speed":filament_speed,
		"foam2d_running_color":running_color,"foam2d_running_strength":running_strength,
		"foam2d_running_whiteness":running_whiteness,"foam2d_running_roughness":running_roughness,
		"foam2d_running_specular":running_specular,"foam2d_running_normal_strength":running_normal_strength,
		"foam2d_running_size":Vector3(running_half_width,running_half_length,running_edge_fade),
		"hull_waves_max_height":deformation_max_height_m,"hull_waves_debug":deformation_debug_view}

func history_parameters() -> Vector4:
	return Vector4(patch_size,variation,agitation_decay,emission)

func motion_parameters() -> Vector3:
	return Vector3(wake_spread,motion_strength,motion_speed)

func edge_parameters() -> Vector2:
	return Vector2(edge_irregularity,edge_fade)

func outward_parameters() -> Vector2:
	return Vector2(outward_speed,impact_outward_boost)

func shape_parameters() -> Vector2:
	return Vector2(initial_width_m,lifetime_s)

func get_wake_opening_degrees() -> float:
	return rad_to_deg(2.0*atan(0.144*wake_spread))

func set_wake_opening_degrees(degrees: float) -> void:
	# Nominal full angle at the flow's mean irregularity, before its speed cap.
	wake_spread = clampf(tan(deg_to_rad(degrees*0.5))/0.144,0.0,1.5)
