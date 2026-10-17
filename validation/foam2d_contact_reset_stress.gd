extends SceneTree
const ContactState := preload("res://addons/ocean/physics/water/local_surface_contact_state.gd")
class ReentrantContacts:
	extends "res://addons/ocean/physics/water/local_surface_contact_state.gd"
	var clones := 0
	func clone_sample(sample: WaterSample3D) -> WaterSample3D:
		clones += 1
		if clones == 12: reset()
		return super.clone_sample(sample)
var state := ContactState.new()
var positions := PackedVector3Array()
var samples: Array[WaterSample3D] = []

func _initialize() -> void:
	for index in 64:
		positions.append(Vector3(index*0.01,0,0))
		var sample := WaterSample3D.new()
		sample.valid = true
		sample.surface_position = positions[index] + Vector3.UP*0.25
		sample.signed_depth = 0.25
		samples.append(sample)
	var resetter := Thread.new()
	resetter.start(reset_loop)
	var passed := true
	for iteration in 120:
		var published = state.publish(samples,positions,PackedFloat64Array(),float(iteration),1.0/60.0)
		if published == null or published.size() != samples.size(): passed = false
	resetter.wait_to_finish()
	var published = state.publish(samples,positions,PackedFloat64Array(),121.0,1.0/60.0)
	passed = passed and published != null and state.last_samples.size() == samples.size()
	var reentrant := ReentrantContacts.new()
	var nested = reentrant.publish(samples,positions,PackedFloat64Array(),122.0,1.0/60.0)
	passed = passed and nested != null and nested.size() == samples.size() and reentrant.last_samples.is_empty()
	print("CONTACT_RESET_STRESS passed=",passed," concurrent_resets=400 batches=120 reentrant_reset_at=11")
	quit(0 if passed else 1)

func reset_loop() -> void:
	for iteration in 400:
		state.reset()
		OS.delay_usec(10)
