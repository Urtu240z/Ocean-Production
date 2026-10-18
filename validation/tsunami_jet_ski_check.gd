extends SceneTree
var failures: Array[String]=[]
var resets:=0
func _initialize() -> void:
	Engine.max_fps=120
	call_deferred("run")
func check(ok: bool,label: String) -> void:
	if not ok: failures.append(label); push_error(label)
func run() -> void:
	root.size=Vector2i(320,240)
	var world:=Node3D.new()
	root.add_child(world)
	var ocean: Node3D=load("res://addons/ocean/ocean.tscn").instantiate()
	for key in ["coastal","reflections","underwater_medium","enable_spindrift","surface_detail"]: ocean.set(key,false)
	ocean.set("sea_level",0.0)
	ocean.set("sea_state_mode",1)
	ocean.set("significant_wave_height_m",0.0)
	world.add_child(ocean)
	var ski: RigidBody3D=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
	ski.ocean=ocean
	ski.freeze=true
	ski.position=Vector3(10,1,0)
	world.add_child(ski)
	ski.reset_completed.connect(func(reason: StringName):
		if reason==&"boundary_tsunami": resets+=1)
	var ready:=false
	for i in 2400:
		await process_frame
		if bool(ski.get_node("OceanConnection").get("ready_to_drive")):
			ready=true; break
	check(ready,"real Jet Ski connects to Ocean")
	if not ready: quit(1); return
	check(ski.wipeout_system==null,"standalone Jet Ski has no game-specific wipeout system")
	var safe:=Transform3D(Basis.IDENTITY,Vector3(10,1,0))
	check(ski.request_boundary_tsunami_wipeout(Vector3.LEFT,8,5,safe),"real standalone adapter activates fallback")
	check(ski.is_wipeout_active() and ski.is_wipeout_control_locked(),"real vehicle controls locked")
	ski.wipeout_system.recovery_delay_s=0.15
	for i in 30: await physics_frame
	check(resets==1,"real reset completes once")
	check(not ski.is_wipeout_active() and not ski.is_wipeout_control_locked(),"real controls unlock after recovery")
	check(absf(ski.global_position.x-10)<1.0,"real vehicle returns to recorded safe position")
	print("TSUNAMI_JET_SKI_RESULT failures=",failures," resets=",resets)
	world.queue_free()
	for i in 10: await process_frame
	quit(0 if failures.is_empty() else 1)
