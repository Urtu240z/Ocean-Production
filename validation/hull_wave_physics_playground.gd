@tool
extends "res://validation/foam2d_playground.gd"
## Explicit opt-in test scene. The consolidated playground keeps its saved settings.
func _enter_tree() -> void:
	super()
	if Engine.is_editor_hint(): return
	var ocean: Ocean=get_node("JetSkiOcean/Production/Ocean")
	var world: Node=get_node("JetSkiOcean")
	world.spawn_vehicle=false
	var manual_vehicle: JetSkiController=get_node_or_null("JetSki") as JetSkiController
	world.vehicle=manual_vehicle
	if is_instance_valid(manual_vehicle):
		manual_vehicle.freeze=true
		manual_vehicle.configure_ocean(ocean)
	ocean.hull_foam_settings=ocean.get_hull_foam_settings().duplicate(true)
	ocean.set("foam_deformation_enabled",true)
	ocean.set("foam_wave_physics_enabled",true)
