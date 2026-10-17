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
		spray._tail.free()
		spray._preview(0.02)
		assert(is_instance_valid(spray._tail))
		assert(spray._tail.get_instance_id()!=previous_id)
		assert(spray._tail.visible)
		assert(spray._slots.size()==4 and spray._anchors.size()==3)
		assert(nozzle.get_child_count()==1,"Preview rebuild duplicated the tail")
		assert(nozzle.transform==saved_pose)
		assert(bow.hull_spray_settings.tail_appearance==profile)
		assert(is_equal_approx(profile.preview_speed,25.0))
		assert(is_equal_approx(bow.hull_spray_settings.tail_roundness,0.8))
		await process_frame
	print("HULL_SPRAY_EDITOR_RELOAD_PASS rebuilds=3 anchor_and_settings_preserved=true")
	bow.queue_free()
	await process_frame
	quit()
