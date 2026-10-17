@tool
extends Resource
class_name HullSprayStyle
## Inspector entry on BowSprayRoot. Independent profiles use Bow Spray controls.
@export_group("Splash")
@export var sides_enabled := true:
	set(v): sides_enabled=v; emit_changed()
@export_range(0.0,12.0,0.1) var sustained_rate_hz := 6.0:
	set(v): sustained_rate_hz=clampf(v,0.0,12.0); emit_changed()
@export_range(0.12,0.8,0.01) var side_burst_lifetime := 0.30:
	set(v): side_burst_lifetime=clampf(v,0.12,0.8); emit_changed()
@export_range(0.2,6.0,0.05) var impact_threshold := 0.75:
	set(v): impact_threshold=v; emit_changed()
@export_range(0.15,1.5,0.01) var cooldown := 0.45:
	set(v): cooldown=v; emit_changed()
@export_range(0.02,0.3,0.01) var side_delay := 0.14:
	set(v): side_delay=v; emit_changed()
@export_range(0.0,1.0,0.05) var side_velocity_inheritance := 0.85:
	set(v): side_velocity_inheritance=v; emit_changed()
## Sideways launch angle above the sea plane; zero is horizontal.
@export_range(0.0,20.0,0.5) var elevation_degrees := 5.0:
	set(v): elevation_degrees=clampf(v,0.0,20.0); emit_changed()
@export var splash_appearance: Resource = load("res://addons/jet_ski/common/visual/hull_spray/splash_appearance.tres"):
	set(v):
		_disconnect_profile(splash_appearance)
		splash_appearance=v
		_connect_profile(v)
		emit_changed()
@export_group("Tail Jet", "tail_")
@export var tail_enabled := true:
	set(v): tail_enabled=v; emit_changed()
@export_range(0.0,1.0,0.01) var tail_residual_seconds := 0.55:
	set(v): tail_residual_seconds=clampf(v,0.0,1.0); emit_changed()
@export_range(0.0,1.0,0.01) var tail_residual_strength := 0.65:
	set(v): tail_residual_strength=clampf(v,0.0,1.0); emit_changed()
@export_enum("Splash 3", "Splash 4") var tail_variant := 0:
	set(v): tail_variant=clampi(v,0,1); emit_changed()
## Bank-driven downstream bend response, in inverse seconds.
@export_range(0.1,20.0,0.1) var tail_turn_response := 5.0:
	set(v): tail_turn_response=clampf(v,0.1,20.0); emit_changed()
## Vertical diameter relative to the cone width. Does not move the nozzle.
@export_range(0.15,1.5,0.01) var tail_roundness := 0.8:
	set(v): tail_roundness=clampf(v,0.15,1.5); emit_changed()
## Downward drop at the far end, before Spray Scale is applied.
@export_range(0.0,2.0,0.01) var tail_downward_curve := 0.45:
	set(v): tail_downward_curve=clampf(v,0.0,2.0); emit_changed()
@export var tail_appearance: Resource = load("res://addons/jet_ski/common/visual/hull_spray/tail_appearance.tres"):
	set(v):
		_disconnect_profile(tail_appearance)
		tail_appearance=v
		_connect_profile(v)
		emit_changed()

func _init() -> void:
	_connect_profile(splash_appearance)
	_connect_profile(tail_appearance)

func _connect_profile(value: Resource) -> void:
	if value!=null and not value.changed.is_connected(_profile_changed): value.changed.connect(_profile_changed)

func _disconnect_profile(value: Resource) -> void:
	if value!=null and value.changed.is_connected(_profile_changed): value.changed.disconnect(_profile_changed)

func _profile_changed() -> void:
	emit_changed()

# Compatibility for the optional quick panel and existing gate/probes.
# Inspector appearance fields are the single source of truth.
var speed_start: float:
	get: return splash_appearance.speed_start
	set(v): splash_appearance.speed_start=v
var side_opacity: float:
	get: return splash_appearance.spray_opacity
	set(v): splash_appearance.spray_opacity=v
var side_width: float:
	get: return splash_appearance.sheet_width
	set(v): splash_appearance.sheet_width=v
var side_height: float:
	get: return splash_appearance.sheet_height
	set(v): splash_appearance.sheet_height=v
var side_fps: float:
	get: return splash_appearance.anim_fps
	set(v): splash_appearance.anim_fps=v
var tail_opacity: float:
	get: return tail_appearance.spray_opacity
	set(v): tail_appearance.spray_opacity=v
var tail_length: float:
	get: return tail_appearance.sheet_length
	set(v): tail_appearance.sheet_length=v
var tail_width: float:
	get: return tail_appearance.sheet_width
	set(v): tail_appearance.sheet_width=v
var tail_height: float:
	get: return tail_appearance.sheet_height
	set(v): tail_appearance.sheet_height=v
var tail_fps: float:
	get: return tail_appearance.anim_fps
	set(v): tail_appearance.anim_fps=v
