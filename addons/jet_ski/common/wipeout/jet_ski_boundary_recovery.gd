extends Node
## Standalone fallback when the host game has not installed its own wipeout system.
var vehicle: RigidBody3D
var recovery_transform:=Transform3D.IDENTITY
var active:=false
var elapsed:=0.0
var recovery_delay_s:=4.0

func _ready() -> void:
	set_physics_process(false)
	vehicle.connect("reset_completed",_on_reset)

func request_wipeout(context: RefCounted) -> bool:
	if active or not is_instance_valid(vehicle) or context.reason!=&"boundary_tsunami": return false
	active=true
	elapsed=0.0
	vehicle.sleeping=false
	vehicle.apply_central_impulse(context.incident_impulse*vehicle.mass)
	vehicle.apply_torque_impulse(vehicle.global_basis.x*vehicle.mass*2.0)
	set_physics_process(true)
	return true

func is_wipeout_active() -> bool: return active
func is_vehicle_control_locked() -> bool: return active

func _physics_process(delta: float) -> void:
	if not active: return
	elapsed+=delta
	if elapsed>=recovery_delay_s: request_recovery()

func request_recovery() -> bool:
	if not active or not is_instance_valid(vehicle): return false
	active=false
	set_physics_process(false)
	vehicle.call("recover_from_boundary_tsunami",recovery_transform)
	return true

func _on_reset(_reason: StringName) -> void:
	active=false
	set_physics_process(false)
