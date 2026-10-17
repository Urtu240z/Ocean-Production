@tool
extends Resource
class_name SprayAppearance
## Same visual controls as BowSprayRoot; each new emitter has an independent profile.
const DEFAULT_DISTORTION = preload("res://addons/jet_ski/common/visual/bow_spray/bow_spray_distortion.tres")
const DEFAULT_WATER_NORMAL = preload("res://addons/jet_ski/common/visual/bow_spray/bow_spray_water_normal.tres")

@export_group("General")
@export var enabled: bool = true:
	set(value): enabled=value; emit_changed()
## Higher values draw later than other transparent materials (water uses 0).
@export_range(-128, 127, 1) var spray_render_priority: int = 100:
	set(value): spray_render_priority=value; emit_changed()
## Horizontal world speed, in metres per second.
@export_range(0.0, 40.0, 0.1) var speed_start: float = 2.5:
	set(value): speed_start=value; emit_changed()
@export_range(0.1, 60.0, 0.1) var speed_full: float = 16.0:
	set(value): speed_full=value; emit_changed()
@export_range(0.0, 1.0, 0.01) var spray_opacity: float = 0.65:
	set(value): spray_opacity=value; emit_changed()
@export_range(0.1, 3.0, 0.01) var spray_scale: float = 1.0:
	set(value): spray_scale=value; emit_changed()
@export_range(0.0, 0.15, 0.001) var distortion_strength: float = 0.025:
	set(value): distortion_strength=value; emit_changed()
@export_range(0.0, 1.0, 0.01) var breakup_strength: float = 0.7:
	set(value): breakup_strength=value; emit_changed()
## Maximum visual roll in radians at full steering; does not rotate the vehicle.
@export_range(0.0, 0.5, 0.005) var steering_tilt_strength: float = 0.14:
	set(value): steering_tilt_strength=value; emit_changed()

@export_group("Textures and Flipbook")
## Plays separate PNGs in array order; falls back to the atlas when empty.
@export var use_image_sequence: bool = true:
	set(value): use_image_sequence=value; emit_changed()
@export var image_sequence: Array[Texture2D] = []:
	set(value): image_sequence=value; emit_changed()
## Left, top, right, bottom margins. Splash_1 starts near X=.43, Y=.5.
## The upper fan maps to the sheet, with its emission point on the hull edge.
@export var sequence_frame_crop: Vector4 = Vector4(0.42, 0.0, 0.0, 0.5):
	set(value): sequence_frame_crop=value; emit_changed()
## bow_spray_flipbook.png: RGBA atlas, row-major, starting at top left.
@export var flipbook_texture: Texture2D:
	set(value): flipbook_texture=value; emit_changed()
## foam_breakup_mask.png: white retains spray, black removes it.
@export var breakup_mask: Texture2D:
	set(value): breakup_mask=value; emit_changed()
## distortion_noise.png: repeating RG noise. Procedural noise until assigned.
@export var distortion_texture: Texture2D = DEFAULT_DISTORTION:
	set(value): distortion_texture=value; emit_changed()
## Reserved for phase 2; does not create secondary droplets in this V1.
@export var droplets_atlas: Texture2D:
	set(value): droplets_atlas=value; emit_changed()
@export_range(1, 32, 1) var frames_x: int = 8:
	set(value): frames_x=value; emit_changed()
@export_range(1, 32, 1) var frames_y: int = 8:
	set(value): frames_y=value; emit_changed()
## Alpha-band heuristic for imperfect atlases. Disable to use frames_x / frames_y.
@export var auto_detect_atlas_grid: bool = true:
	set(value): auto_detect_atlas_grid=value; emit_changed()
## Clamped to grid capacity; use 1 for a single image.
@export_range(1, 1024, 1) var flipbook_frames: int = 64:
	set(value): flipbook_frames=value; emit_changed()
@export_group("Animation")
## Base PNG frames per second; zero pauses the current frame phase.
@export_range(0.0, 60.0, 0.1) var anim_fps: float = 20.0:
	set(value): anim_fps=value; emit_changed()
## Actual PNG rate = anim_fps * multiplier blended by real horizontal speed.
@export_range(0.0, 4.0, 0.01) var anim_speed_low: float = 0.8:
	set(value): anim_speed_low=value; emit_changed()
@export_range(0.0, 4.0, 0.01) var anim_speed_high: float = 1.3:
	set(value): anim_speed_high=value; emit_changed()
## 0: two-frame crossfade. 1: smooth four-frame temporal blend (not optical flow).
@export_range(0.0, 1.0, 0.01) var animation_smoothing: float = 0.75:
	set(value): animation_smoothing=value; emit_changed()
## Independent UV noise clock. Zero freezes distortion without pausing PNGs.
@export_range(0.0, 4.0, 0.01) var distortion_speed: float = 0.35:
	set(value): distortion_speed=value; emit_changed()
## Supplied sprites have their waterline at the bottom of each frame.
@export var flipbook_flip_y: bool = true:
	set(value): flipbook_flip_y=value; emit_changed()

@export_group("Atlas Cleanup")
## Enable for an atlas on a black background without usable transparency.
@export var alpha_from_luminance: bool = false:
	set(value): alpha_from_luminance=value; emit_changed()
@export_range(0.0, 1.0, 0.005) var alpha_cutoff: float = 0.04:
	set(value): alpha_cutoff=value; emit_changed()
@export_range(0.001, 0.5, 0.005) var alpha_softness: float = 0.08:
	set(value): alpha_softness=value; emit_changed()
@export_range(0.0, 4.0, 0.05) var alpha_gain: float = 1.0:
	set(value): alpha_gain=value; emit_changed()
## Per-cell UV margins: left, top, right, bottom. Fractions of one frame.
@export var frame_crop: Vector4 = Vector4.ZERO:
	set(value): frame_crop=value; emit_changed()

@export_group("Soft Edges and Side View")
## Fraction of sheet UVs feathered at the outer borders.
@export_range(0.02, 0.4, 0.01) var edge_softness: float = 0.15:
	set(value): edge_softness=value; emit_changed()
## Suppresses ribbon outlines when seen edge-on; zero disables angle fading.
@export_range(0.0, 1.0, 0.01) var side_fade_strength: float = 1.0:
	set(value): side_fade_strength=value; emit_changed()
## Angle measured from the sheet plane; full opacity above this angle.
@export_range(1.0, 45.0, 0.5) var side_fade_angle: float = 20.0:
	set(value): side_fade_angle=value; emit_changed()

@export_group("Spray Color")
@export_color_no_alpha var spray_tint: Color = Color(0.88, 0.96, 1.0):
	set(value): spray_tint=value; emit_changed()
## 0 keeps source colours; 1 makes every visible droplet white.
@export_range(0.0, 1.0, 0.01) var spray_whiteness: float = 0.0:
	set(value): spray_whiteness=value; emit_changed()
## 0 grayscale, 1 original saturation, >1 stronger colour.
@export_range(0.0, 2.0, 0.01) var spray_saturation: float = 1.0:
	set(value): spray_saturation=value; emit_changed()
@export_range(0.0, 4.0, 0.01) var spray_brightness: float = 1.0:
	set(value): spray_brightness=value; emit_changed()

@export_group("Water Appearance and Highlights")
## ON adds a transparent water film and scene-light specular highlights.
@export var water_appearance_enabled: bool = true:
	set(value): water_appearance_enabled=value; emit_changed()
## Multiplies the PNG foam opacity. Lower this to reveal water and keep highlights.
@export_range(0.0, 1.0, 0.01) var foam_opacity: float = 1.0:
	set(value): foam_opacity=value; emit_changed()
## Opacity of the water film inside the sprite silhouette; never fills the quad.
@export_range(0.0, 0.6, 0.01) var water_opacity: float = 0.12:
	set(value): water_opacity=value; emit_changed()
@export_color_no_alpha var water_tint: Color = Color(0.75, 0.91, 1.0):
	set(value): water_tint=value; emit_changed()
## Procedural seamless normal by default. A regular tangent-space normal can replace it.
@export var normal_texture: Texture2D = DEFAULT_WATER_NORMAL:
	set(value): normal_texture=value; emit_changed()
@export_range(0.0, 2.0, 0.01) var normal_strength: float = 0.8:
	set(value): normal_strength=value; emit_changed()
@export var normal_tiling: Vector2 = Vector2(4.0, 3.0):
	set(value): normal_tiling=value; emit_changed()
## Independent UV clock; zero freezes normals without pausing PNGs.
@export_range(0.0, 3.0, 0.01) var normal_scroll_speed: float = 0.35:
	set(value): normal_scroll_speed=value; emit_changed()
## Lower values give tighter, brighter glints; higher values soften them.
@export_range(0.03, 1.0, 0.01) var water_roughness: float = 0.14:
	set(value): water_roughness=value; emit_changed()
## 0 removes specular reflections; 1 uses a water-like specular level.
@export_range(0.0, 4.0, 0.01) var highlight_strength: float = 1.5:
	set(value): highlight_strength=value; emit_changed()

@export_group("Submersion Suppression")
## Fade starts when even the shallowest of the four hull contacts is this deep.
@export_range(0.0, 2.0, 0.01, "suffix:m") var submersion_fade_start_depth: float = 0.35:
	set(value): submersion_fade_start_depth=value; emit_changed()
## Both sheets disappear immediately at this full-hull depth, including reflections.
@export_range(0.01, 3.0, 0.01, "suffix:m") var submersion_hide_depth: float = 0.6:
	set(value): submersion_hide_depth=value; emit_changed()

@export_group("Low Speed Shape")
@export_range(0.2, 4.0, 0.05) var sheet_length_low: float = 0.85:
	set(value): sheet_length_low=value; emit_changed()
@export_range(0.1, 2.0, 0.05) var sheet_width_low: float = 0.35:
	set(value): sheet_width_low=value; emit_changed()
@export_range(0.0, 1.5, 0.01) var sheet_height_low: float = 0.15:
	set(value): sheet_height_low=value; emit_changed()

@export_group("High Speed Shape")
## Existing values remain the high-speed endpoints; spray_scale is overall size.
@export_range(0.2, 4.0, 0.05) var sheet_length: float = 1.9:
	set(value): sheet_length=value; emit_changed()
@export_range(0.1, 2.0, 0.05) var sheet_width: float = 0.85:
	set(value): sheet_width=value; emit_changed()
@export_range(0.0, 1.5, 0.01) var sheet_height: float = 0.48:
	set(value): sheet_height=value; emit_changed()

@export_group("Volume and Undulation")
## One restores a single ribbon; three gives lightweight visual thickness.
@export_range(1, 5, 1) var volume_layers: int = 3:
	set(value): volume_layers=value; emit_changed()
@export_range(0.0, 0.6, 0.005) var volume_depth: float = 0.18:
	set(value): volume_depth=value; emit_changed()
## More vertical: narrows the horizontal flare, preserving the chosen height.
@export_range(0.0, 1.0, 0.01) var volume_verticality: float = 0.65:
	set(value): volume_verticality=value; emit_changed()
@export_range(0.0, 0.3, 0.005) var undulation_strength: float = 0.06:
	set(value): undulation_strength=value; emit_changed()
@export_range(0.1, 8.0, 0.1) var undulation_frequency: float = 3.0:
	set(value): undulation_frequency=value; emit_changed()
@export_range(0.0, 3.0, 0.01) var undulation_speed: float = 0.8:
	set(value): undulation_speed=value; emit_changed()

@export_group("Layer Scale and Height Motion")
## Maximum +/- percentage around spray_scale; each ribbon has its own phase/rate.
@export_range(0.0, 50.0, 0.5) var layer_scale_variation_percent: float = 10.0:
	set(value): layer_scale_variation_percent=value; emit_changed()
## Base oscillations per second. Zero freezes the current scale motion phase.
@export_range(0.0, 3.0, 0.01) var layer_scale_variation_speed: float = 0.65:
	set(value): layer_scale_variation_speed=value; emit_changed()
## Maximum +/- percentage of the interpolated low/high-speed sheet height.
@export_range(0.0, 75.0, 0.5) var sheet_height_variation_percent: float = 15.0:
	set(value): sheet_height_variation_percent=value; emit_changed()
## Independent visual wave pulse rate. Zero freezes its current phase.
@export_range(0.0, 3.0, 0.01) var sheet_height_variation_speed: float = 0.9:
	set(value): sheet_height_variation_speed=value; emit_changed()

@export_group("Solid Occlusion")
## Depth tolerance in metres for hull/rider/terrain; not a water mask threshold.
@export_range(0.0, 0.05, 0.001) var solid_occlusion_bias: float = 0.005:
	set(value): solid_occlusion_bias=value; emit_changed()

@export_group("Hull Attachment")
## Visual vertex offset only. Node transforms always remain manually editable.
@export var attachment_slide_enabled: bool = true:
	set(value): attachment_slide_enabled=value; emit_changed()
## Metres toward the centre/stern when the nose rises.
@export_range(0.0, 2.0, 0.01) var nose_up_slide: float = 0.8:
	set(value): nose_up_slide=value; emit_changed()
## Metres toward the tip when the nose dips.
@export_range(0.0, 1.0, 0.01) var nose_down_slide: float = 0.25:
	set(value): nose_down_slide=value; emit_changed()
## Pitch angle at which the longitudinal shift reaches its full distance.
@export_range(1.0, 60.0, 0.5) var attachment_pitch_full_degrees: float = 20.0:
	set(value): attachment_pitch_full_degrees=value; emit_changed()
@export_range(0.1, 30.0, 0.1) var attachment_response: float = 12.0:
	set(value): attachment_response=value; emit_changed()
## Optional heave contribution from existing water samples; never changes height.
@export_range(0.0, 1.0, 0.01) var attachment_height_influence: float = 0.35:
	set(value): attachment_height_influence=value; emit_changed()
## Height above/below the sampled waterline for a full heave contribution.
@export_range(0.05, 2.0, 0.01) var attachment_height_full: float = 0.5:
	set(value): attachment_height_full=value; emit_changed()

@export_group("Editor Preview")
## Editor only. Runtime always reads actual vehicle state.
@export var preview_in_editor: bool = false:
	set(value): preview_in_editor=value; emit_changed()
@export_range(0.0, 50.0, 0.1) var preview_speed: float = 16.0:
	set(value): preview_speed=value; emit_changed()
@export_range(-1.0, 1.0, 0.05) var preview_steering: float = 0.0:
	set(value): preview_steering=value; emit_changed()
@export_range(-45.0, 45.0, 0.5) var preview_pitch_degrees: float = 0.0:
	set(value): preview_pitch_degrees=value; emit_changed()

@export_group("Sprite Anchor")
@export var use_custom_pivot: bool = false:
	set(value): use_custom_pivot=value; emit_changed()
@export var sprite_pivot: Vector2 = Vector2(0.5,0.0):
	set(value): sprite_pivot=value; emit_changed()
