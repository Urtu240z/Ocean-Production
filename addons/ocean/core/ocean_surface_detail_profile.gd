@tool
class_name OceanSurfaceDetailProfile
extends Resource
## P5.5 V3 Surface Detail authoring values. The procedural textures are kept
## inside the portable addon and default to the active V3 resources.

const DEFAULT_NORMAL_TEXTURE_A := preload("res://addons/ocean/surface/detail/surface_normal_a.tres")
const DEFAULT_NORMAL_TEXTURE_B := preload("res://addons/ocean/surface/detail/surface_normal_b.tres")
const DEFAULT_WARP_TEXTURE := preload("res://addons/ocean/surface/detail/surface_warp_noise.tres")

@export_group("Assets")
@export var normal_texture_a: Texture2D = DEFAULT_NORMAL_TEXTURE_A:
	set(value):
		normal_texture_a = value
		emit_changed()
@export var normal_texture_b: Texture2D = DEFAULT_NORMAL_TEXTURE_B:
	set(value):
		normal_texture_b = value
		emit_changed()
@export var warp_texture: Texture2D = DEFAULT_WARP_TEXTURE:
	set(value):
		warp_texture = value
		emit_changed()

@export_group("Authoring")
@export_range(0.0, 1.0, 0.01) var wave_follow := 1.0:
	set(value):
		wave_follow = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.25, 100.0, 0.05, "suffix:m") var normal_world_size_a := 34.15:
	set(value):
		normal_world_size_a = maxf(value, 0.25)
		emit_changed()
@export_range(0.25, 100.0, 0.05, "suffix:m") var normal_world_size_b := 2.4:
	set(value):
		normal_world_size_b = maxf(value, 0.25)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var normal_strength := 1.18:
	set(value):
		normal_strength = clampf(value, 0.0, 2.0)
		emit_changed()

@export_group("Advanced")
@export var flow_direction_a := Vector2(0.82, 0.57):
	set(value):
		flow_direction_a = value
		emit_changed()
@export var flow_direction_b := Vector2(-0.46, 0.89):
	set(value):
		flow_direction_b = value
		emit_changed()
@export_range(-3.0, 3.0, 0.01) var flow_speed_a := 0.24:
	set(value):
		flow_speed_a = value
		emit_changed()
@export_range(-3.0, 3.0, 0.01) var flow_speed_b := -0.17:
	set(value):
		flow_speed_b = value
		emit_changed()
@export_range(2.0, 300.0, 0.5, "suffix:m") var warp_world_size := 14.5:
	set(value):
		warp_world_size = maxf(value, 2.0)
		emit_changed()
@export_range(0.0, 12.0, 0.05) var warp_strength := 1.15:
	set(value):
		warp_strength = clampf(value, 0.0, 12.0)
		emit_changed()
@export_range(0.0, 2000.0, 1.0, "suffix:m") var fade_start_m := 180.0:
	set(value):
		fade_start_m = maxf(value, 0.0)
		if fade_end_m < fade_start_m: fade_end_m = fade_start_m
		emit_changed()
@export_range(1.0, 4000.0, 1.0, "suffix:m") var fade_end_m := 800.0:
	set(value):
		fade_end_m = maxf(value, fade_start_m)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var far_strength := 0.18:
	set(value):
		far_strength = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Internal")
@export_range(0, 2, 1) var quality := 2:
	set(value):
		quality = clampi(value, 0, 2)
		emit_changed()
