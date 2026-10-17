@tool
extends Node
## Manual review only. Reuses the gameplay scene and its unchanged controls/camera.
const Controls := preload("res://addons/ocean/surface/foam2d/foam2d_controls.gd")
const SprayControls := preload("res://addons/jet_ski/common/visual/hull_spray/spray_controls.gd")

func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		ProjectSettings.set_setting("foam2d/review_mode",get_node("JetSkiOcean/Production/Ocean").get("foam_mode"))

func get_foam_runtime() -> Node:
	return get_node("JetSkiOcean/Production/Ocean").get_hull_foam_runtime()

func _ready() -> void:
	if Engine.is_editor_hint(): return
	var world: Node = get_node("JetSkiOcean")
	while not world.ready_to_drive:
		await get_tree().process_frame
	var ocean: Node = world.get_node("Production/Ocean")
	while ocean.get_hull_foam_runtime() == null: await get_tree().process_frame
	var director: Node = ocean.get_hull_foam_runtime()
	var canvas := CanvasLayer.new()
	canvas.layer = 20
	add_child(canvas)
	var label := Label.new()
	label.position = Vector2(20, 205)
	label.text = "HULL FOAM · %s\nSettings: Ocean → Hull Foam / Running Foam / Hull Waves" % director.mode
	label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.85))
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	canvas.add_child(label)
	var controls := Controls.new()
	controls.name = "AjustesEspuma"
	canvas.add_child(controls)
	controls.configure(ocean.get_hull_foam_settings())
	var spray: Node=world.ski.get_node_or_null("BowSprayRoot/HullSprays")
	if spray!=null:
		var spray_controls := SprayControls.new()
		spray_controls.name="AjustesSalpicaduras"
		canvas.add_child(spray_controls)
		spray_controls.configure(spray.settings)
	print("FOAM2D_MANUAL_READY mode=", director.mode," owner=Ocean")
