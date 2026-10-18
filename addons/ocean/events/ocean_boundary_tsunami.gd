@tool
class_name OceanBoundaryTsunami
extends Node3D
## Optional gameplay boundary. One concentric, inescapable incident per target.
signal wave_started
signal target_caught(target: Node3D,direction: Vector3)
signal wave_finished
const Snapshot = preload("res://addons/ocean/events/ocean_tsunami_state.gd")
enum State { ARMED, APPROACHING, CAUGHT, WAITING_FOR_REARM }
@export_group("References")
@export var ocean: Node3D
@export var target: Node3D
## If empty, this node's global position defines the map centre.
@export var boundary_center: Node3D
## Optional explicit safe recovery marker. Otherwise remember the last safe pose.
@export var recovery_point: Node3D
@export_group("Boundary")
@export var enabled:=true
@export_range(10,100000,1,"suffix:m") var boundary_radius_m:=1000.0
@export_range(0,1000,1,"suffix:m") var rearm_margin_m:=50.0
@export_group("Tsunami")
@export_range(5,200,1,"suffix:m") var wave_height_m:=60.0
@export_range(10,2000,1,"suffix:m") var spawn_distance_m:=220.0
@export_range(1,200,0.5,"suffix:m/s") var wave_speed_mps:=35.0
## Extra closing speed over any inward escape speed measured from the target.
@export_range(1,100,0.5,"suffix:m/s") var minimum_closing_speed_mps:=25.0
@export_range(1,120,0.5,"suffix:s") var maximum_catch_time_s:=12.0
@export_range(1,300,1,"suffix:m") var front_width_m:=30.0
@export_range(1,500,1,"suffix:m") var back_width_m:=90.0
@export_range(0,1,0.01) var trough_ratio:=0.25
@export_range(0.1,10,0.1,"suffix:s") var rise_time_s:=1.5
@export_range(0.1,15,0.1,"suffix:s") var fade_time_s:=4.0
@export_group("Impact")
@export_range(0,500,1) var forward_impulse:=8.0
@export_range(0,500,1) var up_impulse:=5.0
var snapshot:=Snapshot.new()
var state:=State.ARMED
var elapsed:=0.0
var radius:=0.0
var _center:=Vector2.ZERO
var _previous_target:=Vector2.ZERO
var _fade_elapsed:=0.0
var _hit_amplitude:=0.0
var _reset_seen:=false
var _last_tick: int=-1
var _safe_transform:=Transform3D.IDENTITY
var _has_safe_transform:=false
var _crest_speed:=0.0

func _ready() -> void:
	if Engine.is_editor_hint(): return
	if is_instance_valid(ocean) and ocean.has_method("register_boundary_tsunami"):
		if not ocean.register_boundary_tsunami(self): enabled=false
	if is_instance_valid(target) and target.has_signal("reset_completed"):
		target.connect("reset_completed",_on_target_reset)

func _exit_tree() -> void:
	if not Engine.is_editor_hint() and is_instance_valid(ocean) and ocean.has_method("unregister_boundary_tsunami"): ocean.unregister_boundary_tsunami(self)
	snapshot.clear()

func _physics_process(delta: float) -> void:
	if not Engine.is_editor_hint(): advance(Engine.get_physics_frames(),delta)

func advance(tick: int,delta: float) -> void:
	if tick==_last_tick: return
	_last_tick=tick
	if not enabled or not is_instance_valid(target) or not is_instance_valid(ocean) or not ocean.get("enabled"):
		snapshot.clear()
		state=State.ARMED
		return
	var p:=Vector2(target.global_position.x,target.global_position.z)
	var centre_node: Node3D=boundary_center if is_instance_valid(boundary_center) else self
	var centre:=Vector2(centre_node.global_position.x,centre_node.global_position.z)
	match state:
		State.ARMED:
			if p.distance_to(centre)<=maxf(boundary_radius_m-rearm_margin_m,0.0):
				_safe_transform=Transform3D(Basis.IDENTITY,target.global_position)
				_has_safe_transform=true
			if not _target_wiped_out() and p.distance_to(centre)>boundary_radius_m: activate()
		State.APPROACHING:
			var dt:=maxf(delta,0.000001)
			elapsed+=dt
			var previous_gap:=radius-_previous_target.distance_to(_center)
			var distance:=p.distance_to(_center)
			var inward_speed:=maxf((_previous_target.distance_to(_center)-distance)/dt,0.0)
			var gap:=maxf(radius-distance,0.0)
			var speed:=maxf(wave_speed_mps,inward_speed+minimum_closing_speed_mps)
			speed=maxf(speed,gap/maxf(maximum_catch_time_s-elapsed,dt))
			_crest_speed=speed
			radius=maxf(radius-speed*dt,0.0)
			_update_snapshot(-speed)
			if radius-distance<=0.0 or previous_gap<=0.0 or elapsed>=maximum_catch_time_s:
				_catch_target(p)
		State.CAUGHT:
			_fade_elapsed+=maxf(delta,0.0)
			radius=maxf(radius-_crest_speed*maxf(delta,0.0),0.0)
			snapshot.center_radius.z=radius
			var fade:=1.0-smoothstep(0.0,fade_time_s,_fade_elapsed)
			var slope: float=-6.0*clampf(_fade_elapsed/fade_time_s,0,1)*(1.0-clampf(_fade_elapsed/fade_time_s,0,1))/fade_time_s
			snapshot.center_radius.w=_hit_amplitude*fade
			snapshot.motion=Vector4(-_crest_speed if radius>0.0 else 0.0,_hit_amplitude*slope,trough_ratio,0)
			if _fade_elapsed>=fade_time_s:
				snapshot.clear()
				state=State.WAITING_FOR_REARM
				wave_finished.emit()
		State.WAITING_FOR_REARM:
			if not _target_wiped_out() and p.distance_to(centre)<=maxf(boundary_radius_m-rearm_margin_m,0.0):
				if _reset_seen or not target.has_signal("reset_completed"): state=State.ARMED
	_previous_target=p

func activate() -> bool:
	if Engine.is_editor_hint() or not enabled or state!=State.ARMED or not is_instance_valid(target) or not is_instance_valid(ocean): return false
	var centre_node: Node3D=boundary_center if is_instance_valid(boundary_center) else self
	_center=Vector2(centre_node.global_position.x,centre_node.global_position.z)
	_previous_target=Vector2(target.global_position.x,target.global_position.z)
	radius=_previous_target.distance_to(_center)+maxf(spawn_distance_m,front_width_m*2.0)
	elapsed=0.0
	_fade_elapsed=0.0
	_crest_speed=0.0
	_reset_seen=false
	state=State.APPROACHING
	_update_snapshot(0.0)
	wave_started.emit()
	return true

func _update_snapshot(radius_velocity: float) -> void:
	var t:=clampf(elapsed/maxf(rise_time_s,0.1),0,1)
	var amplitude:=wave_height_m*smoothstep(0.0,1.0,t)
	var rate:=wave_height_m*6.0*t*(1.0-t)/maxf(rise_time_s,0.1)
	snapshot.center_radius=Vector4(_center.x,_center.y,radius,amplitude)
	snapshot.shape=Vector4(front_width_m,back_width_m,front_width_m*1.2,front_width_m*2.2)
	snapshot.motion=Vector4(radius_velocity,rate,trough_ratio,0)

func _catch_target(point: Vector2) -> void:
	state=State.CAUGHT
	# Swept crossing can overshoot on a long frame. Align the visible crest with
	# the actual target at the instant of impact instead of emitting a remote hit.
	radius=point.distance_to(_center)
	snapshot.center_radius.z=radius
	_hit_amplitude=snapshot.center_radius.w
	var radial:=(_center-point).normalized()
	var direction:=Vector3(radial.x,0,radial.y)
	if target.has_method("request_boundary_tsunami_wipeout"):
		target.call("request_boundary_tsunami_wipeout",direction,forward_impulse,up_impulse,_recovery_transform())
	target_caught.emit(target,direction)

func _recovery_transform() -> Transform3D:
	if is_instance_valid(recovery_point): return recovery_point.global_transform
	if _has_safe_transform: return _safe_transform
	if target.has_method("get_respawn_transform"):
		var respawn: Transform3D=target.call("get_respawn_transform")
		if Vector2(respawn.origin.x,respawn.origin.z).distance_to(_center)<boundary_radius_m-rearm_margin_m: return respawn
	var radial:=(_previous_target-_center).normalized()
	var safe:=_center+radial*maxf(boundary_radius_m-rearm_margin_m-front_width_m*2.0,0.0)
	return Transform3D(Basis.IDENTITY,Vector3(safe.x,float(ocean.get("sea_level"))+1.5,safe.y))

func _target_wiped_out() -> bool:
	return target.has_method("is_wipeout_active") and bool(target.call("is_wipeout_active"))

func _on_target_reset(_reason: StringName) -> void:
	_reset_seen=true
	if state==State.APPROACHING and is_instance_valid(target):
		var p:=Vector2(target.global_position.x,target.global_position.z)
		# A physics recovery that still leaves the boat outside is not an escape.
		if p.distance_to(_center)>maxf(boundary_radius_m-rearm_margin_m,0.0): return
	if state in [State.APPROACHING,State.CAUGHT]:
		snapshot.clear()
		state=State.WAITING_FOR_REARM
		wave_finished.emit()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings:=PackedStringArray()
	if ocean==null or not ocean.has_method("register_boundary_tsunami"): warnings.append("Assign the Ocean receiving the tsunami.")
	if target==null: warnings.append("Assign the Jet Ski or target vehicle.")
	elif not target.has_method("request_boundary_tsunami_wipeout"):
		warnings.append("Custom targets: connect target_caught to the game's defeat/recovery logic.")
	return warnings
