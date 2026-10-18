extends SceneTree
## Runs with --editor --script in a disposable process, leaving the user's editor alone.
class RootFixture extends Node3D:
	var hull_spray_settings: Resource

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	assert(Engine.is_editor_hint())
	var bow := RootFixture.new()
	bow.hull_spray_settings=load("res://addons/jet_ski/common/visual/hull_spray/default_style.tres").duplicate(true)
	bow.hull_spray_settings.tail_appearance.preview_in_editor=true
	bow.hull_spray_settings.tail_appearance.preview_speed=25.0
	bow.hull_spray_settings.stern_mist.preview_in_editor=true
	bow.hull_spray_settings.stern_mist.preview_speed_kmh=50.0
	var saved_roundness: float=bow.hull_spray_settings.tail_roundness
	var source: Node=load("res://addons/jet_ski/common/visual/bow_spray/bow_spray.tscn").instantiate()
	var authored_mist: GPUParticles3D=source.get_node("SternMist")
	var authored_right: GPUParticles3D=source.get_node("SternMistRight")
	source.remove_child(authored_mist)
	source.remove_child(authored_right)
	source.free()
	bow.add_child(authored_mist)
	bow.add_child(authored_right)
	root.add_child(bow)
	for label in ["SplashLeft","SplashRight","TailJet"]:
		var anchor := Node3D.new()
		anchor.name=label
		bow.add_child(anchor)
	var nozzle: Node3D=bow.get_node("TailJet")
	nozzle.position=Vector3(0,-0.2636896,1.25)
	var saved_pose := nozzle.transform
	var spray: Node3D=load("res://addons/jet_ski/common/visual/hull_spray/jet_ski_hull_spray.gd").new()
	bow.add_child(spray)
	spray.set_process(false)
	var profile: Resource=bow.hull_spray_settings.tail_appearance
	for cycle in 3:
		var previous_id: int=spray._tail.get_instance_id()
		var previous_mist_id: int=spray._mist.get_instance_id()
		var previous_right_id: int=authored_right.get_instance_id()
		spray._tail.free()
		spray._preview(0.02)
		assert(is_instance_valid(spray._tail))
		assert(spray._tail.get_instance_id()!=previous_id)
		assert(spray._tail.visible)
		assert(spray._slots.size()==4 and spray._anchors.size()==3)
		assert(nozzle.get_child_count()==1,"Preview rebuild duplicated the tail")
		assert(spray.get_child_count()==0,"Preview rebuild generated a duplicate mist")
		assert(spray._mist.get_instance_id()==previous_mist_id,"Preview rebuild replaced the authored mist")
		assert(spray._mist_emitters.size()==2,"Both lateral emitters must be configured")
		assert(authored_right.get_instance_id()==previous_right_id and authored_right.emitting and authored_right.visible,"Right preview must survive rebuilds and emit")
		assert(authored_right.style==bow.hull_spray_settings.stern_mist)
		assert(spray._mist.visible and spray._mist.emitting,"Mist editor preview depends on gameplay throttle")
		assert(spray._mist.style==bow.hull_spray_settings.stern_mist)
		assert(nozzle.transform==saved_pose)
		assert(bow.hull_spray_settings.tail_appearance==profile)
		assert(is_equal_approx(profile.preview_speed,25.0))
		assert(is_equal_approx(bow.hull_spray_settings.tail_roundness,saved_roundness))
		await process_frame
	print("HULL_SPRAY_EDITOR_RELOAD_PASS rebuilds=3 anchor_and_settings_preserved=true")
	bow.queue_free()
	for frame in 12: await process_frame
	quit()
