extends SceneTree
const Boundary=preload("res://addons/ocean/events/ocean_boundary_tsunami.gd")
const Snapshot=preload("res://addons/ocean/events/ocean_tsunami_state.gd")
class WipeoutReceiver extends Node:
	var reason:=&""
	var impulse:=Vector3.ZERO
	func request_wipeout(context: RefCounted) -> bool:
		reason=context.reason
		impulse=context.incident_impulse
		return true
class Host extends Node3D:
	var enabled:=true
	var sea_level:=0.0
	func register_boundary_tsunami(_source: Node3D) -> bool: return true
	func unregister_boundary_tsunami(_source: Node3D) -> void: pass
class FallbackVehicle extends RigidBody3D:
	signal reset_completed(reason: StringName)
	var recovered:=false
	func recover_from_boundary_tsunami(pose: Transform3D) -> void:
		global_transform=pose
		recovered=true
		reset_completed.emit(&"boundary_tsunami")
class Target extends Node3D:
	signal reset_completed(reason: StringName)
	var hits:=0
	var impulse:=Vector3.ZERO
	func is_wipeout_active() -> bool: return false
	func request_boundary_tsunami_wipeout(direction: Vector3,forward: float,up: float,_recovery: Transform3D=Transform3D.IDENTITY) -> bool:
		hits+=1
		impulse=direction*forward+Vector3.UP*up
		return true
var failures: Array[String]=[]
func check(ok: bool,label: String) -> void:
	if not ok: failures.append(label); push_error(label)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	for scenario in ["stationary","outward","inward","lateral"]:
		var host:=Host.new()
		root.add_child(host)
		var target:=Target.new()
		host.add_child(target)
		var boundary=Boundary.new()
		boundary.ocean=host
		boundary.target=target
		boundary.boundary_radius_m=100.0
		boundary.rearm_margin_m=10.0
		boundary.spawn_distance_m=150.0
		boundary.maximum_catch_time_s=8.0
		boundary.position=Vector3(225,0,-137)
		host.add_child(boundary)
		boundary.set_physics_process(false)
		target.global_position=Vector3(324,500,-137)
		boundary.advance(0,1.0/60)
		check(boundary.state==Boundary.State.ARMED,"inside radius ignores altitude")
		target.position.x+=2
		boundary.advance(1,1.0/60)
		check(boundary.state==Boundary.State.APPROACHING,"outside shifted centre triggers")
		target.reset_completed.emit(&"outside_safety_recovery")
		check(boundary.state==Boundary.State.APPROACHING,"outside safety recovery does not cancel pursuit")
		var tick:=2
		while boundary.state==Boundary.State.APPROACHING and tick<600:
			match scenario:
				"outward": target.position.x+=100.0/60.0
				"inward": target.position.x=maxf(target.position.x-100.0/60.0,225)
				"lateral": target.position=Vector3(225+cos(tick*0.05)*101,0,-137+sin(tick*0.05)*101)
			boundary.advance(tick,1.0/60)
			tick+=1
		check(target.hits==1 and boundary.state==Boundary.State.CAUGHT,scenario+" is caught once")
		check(boundary.elapsed<=8.02,scenario+" catches within deadline")
		check(target.impulse.is_finite() and target.impulse.y==boundary.up_impulse,"wipeout adapter receives impulse")
		check(absf(boundary.radius-Vector2(target.global_position.x-225,target.global_position.z+137).length())<0.001,"crest coincides with target on swept crossing")
		target.global_position=Vector3(225,0,-137)
		target.reset_completed.emit(&"test_recovery")
		boundary.advance(tick,1.0/60)
		check(boundary.state==Boundary.State.ARMED and boundary.snapshot.center_radius.w==0,"recovery clears wave and rearms inside margin")
		host.free()
	var state=Snapshot.new()
	state.center_radius=Vector4(225,-137,300,60)
	state.shape=Vector4(30,90,36,66)
	state.motion=Vector4(-35,2,0.25,0)
	var max_slope_error:=0.0
	var max_velocity_error:=0.0
	# Keep the finite time interval away from the asymmetric crest's width join.
	for x in [450.0,510.0,536.0,560.0,600.0]:
		var p:=Vector2(x,-130)
		var value: Vector4=state.sample(p)
		const E:=0.01
		var slope: float=(state.sample(p+Vector2(E,0)).x-state.sample(p-Vector2(E,0)).x)/(2*E)
		max_slope_error=maxf(max_slope_error,absf(slope-value.y))
		var original: Vector4=state.center_radius
		state.center_radius.z=original.z+state.motion.x*E
		state.center_radius.w=original.w+state.motion.y*E
		var plus: float=state.sample(p).x
		state.center_radius.z=original.z-state.motion.x*E
		state.center_radius.w=original.w-state.motion.y*E
		var minus: float=state.sample(p).x
		state.center_radius=original
		max_velocity_error=maxf(max_velocity_error,absf((plus-minus)/(2*E)-value.w))
	check(max_slope_error<0.004,"CPU slope matches derivative")
	check(max_velocity_error<0.02,"CPU vertical velocity matches moving wave")
	var ski: RigidBody3D=load("res://addons/jet_ski/common/core/jet_ski_controller.gd").new()
	var receiver:=WipeoutReceiver.new()
	ski._wipeout_system=receiver
	check(ski.request_boundary_tsunami_wipeout(Vector3.LEFT,8.0,5.0),"real Jet Ski adapter accepts wipeout")
	check(receiver.reason==&"boundary_tsunami" and receiver.impulse==Vector3(-8,5,0),"real Jet Ski receives existing WipeoutContext")
	ski.free()
	receiver.free()
	var standalone:=FallbackVehicle.new()
	root.add_child(standalone)
	var fallback: Node=load("res://addons/jet_ski/common/wipeout/jet_ski_boundary_recovery.gd").new()
	fallback.vehicle=standalone
	fallback.recovery_transform=Transform3D(Basis.IDENTITY,Vector3(25,1,0))
	standalone.add_child(fallback)
	var context: RefCounted=load("res://addons/jet_ski/common/wipeout/wipeout_context.gd").new(&"boundary_tsunami",Vector3(8,5,0))
	check(fallback.request_wipeout(context) and fallback.is_vehicle_control_locked(),"standalone fallback locks controls")
	check(fallback.request_recovery() and standalone.recovered and standalone.position==Vector3(25,1,0),"standalone fallback returns to safe position")
	check(not fallback.is_wipeout_active(),"standalone fallback unlocks after reset")
	context.reason=&"manual_ejection"
	check(not fallback.request_wipeout(context),"fallback does not change unrelated manual ejection behaviour")
	standalone.free()
	print("TSUNAMI_BOUNDARY_RESULT failures=",failures," slope_error=",max_slope_error," velocity_error=",max_velocity_error)
	quit(0 if failures.is_empty() else 1)
