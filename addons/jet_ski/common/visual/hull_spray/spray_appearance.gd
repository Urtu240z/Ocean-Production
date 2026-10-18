@tool
extends Resource
class_name SprayAppearance
## Same visual controls as BowSprayRoot; each new emitter has an independent profile.
const DEFAULT_DISTORTION = preload("res://addons/jet_ski/common/visual/bow_spray/bow_spray_distortion.tres")
const DEFAULT_WATER_NORMAL = preload("res://addons/jet_ski/common/visual/bow_spray/bow_spray_water_normal.tres")

@export_group("General")
## Activa la apariencia de este emisor. La emisión de juego también depende del contacto y de la velocidad; la previsualización tiene sus propios controles.
@export var enabled: bool = true:
	set(value): enabled=value; emit_changed()
## Orden de dibujo de materiales transparentes. Valores mayores se dibujan más tarde; no convierte el efecto en geometría opaca.
@export_range(-128, 127, 1) var spray_render_priority: int = 100:
	set(value): spray_render_priority=value; emit_changed()
## Velocidad horizontal mínima, en metros por segundo, para que empiece a verse el efecto durante el juego.
@export_range(0.0, 40.0, 0.1) var speed_start: float = 2.5:
	set(value): speed_start=value; emit_changed()
## Velocidad horizontal, en metros por segundo, a la que el efecto alcanza su tamaño e intensidad de alta velocidad.
@export_range(0.1, 60.0, 0.1) var speed_full: float = 16.0:
	set(value): speed_full=value; emit_changed()
## Opacidad general del efecto. Menos valor deja ver más el agua y el casco a través del sprite.
@export_range(0.0, 1.0, 0.01) var spray_opacity: float = 0.65:
	set(value): spray_opacity=value; emit_changed()
## Escala global del efecto visual, aplicada después de interpolar sus dimensiones por velocidad.
@export_range(0.1, 3.0, 0.01) var spray_scale: float = 1.0:
	set(value): spray_scale=value; emit_changed()
## Intensidad con la que el ruido de distorsión deforma las coordenadas de la textura del spray.
@export_range(0.0, 0.15, 0.001) var distortion_strength: float = 0.025:
	set(value): distortion_strength=value; emit_changed()
## Intensidad de la máscara que rompe la lámina en gotas y huecos irregulares.
@export_range(0.0, 1.0, 0.01) var breakup_strength: float = 0.7:
	set(value): breakup_strength=value; emit_changed()
## Inclinación visual máxima de la lámina según el giro. No cambia la dirección ni la inclinación física del casco.
@export_range(0.0, 0.5, 0.005) var steering_tilt_strength: float = 0.14:
	set(value): steering_tilt_strength=value; emit_changed()

@export_group("Textures and Flipbook")
## Reproduce los PNGs de Image Sequence si hay una secuencia válida; si no, utiliza el atlas de animación.
@export var use_image_sequence: bool = true:
	set(value): use_image_sequence=value; emit_changed()
## PNGs de la animación en orden de reproducción. Con la secuencia activada y válida se utiliza en lugar del atlas.
@export var image_sequence: Array[Texture2D] = []:
	set(value): image_sequence=value; emit_changed()
## Márgenes izquierdo, superior, derecho e inferior de cada PNG, como fracciones de la imagen. Permiten recortar el área útil del sprite.
@export var sequence_frame_crop: Vector4 = Vector4(0.42, 0.0, 0.0, 0.5):
	set(value): sequence_frame_crop=value; emit_changed()
## Atlas de animación RGBA, ordenado por filas desde la celda superior izquierda. Se usa cuando no hay una secuencia PNG activa.
@export var flipbook_texture: Texture2D:
	set(value): flipbook_texture=value; emit_changed()
## Máscara de rotura del spray: el blanco conserva agua y el negro abre huecos. Se combina con Breakup Strength.
@export var breakup_mask: Texture2D:
	set(value): breakup_mask=value; emit_changed()
## Ruido RG repetido que deforma los UV del spray. Se combina con Distortion Strength y su reloj de animación.
@export var distortion_texture: Texture2D = DEFAULT_DISTORTION:
	set(value): distortion_texture=value; emit_changed()
## Dato antiguo reservado para gotas secundarias que aún no se generan. Se conserva para cargar escenas previas; no se muestra como ajuste.
@export_storage var droplets_atlas: Texture2D:
	set(value): droplets_atlas=value; emit_changed()
## Número de columnas del atlas de animación. Solo interviene cuando se usa un atlas y no se detecta su cuadrícula automáticamente.
@export_range(1, 32, 1) var frames_x: int = 8:
	set(value): frames_x=value; emit_changed()
## Número de filas del atlas de animación. Solo interviene cuando se usa un atlas y no se detecta su cuadrícula automáticamente.
@export_range(1, 32, 1) var frames_y: int = 8:
	set(value): frames_y=value; emit_changed()
## Detecta filas y columnas del atlas por sus bandas de transparencia. Desactívalo para utilizar Frames X y Frames Y manualmente.
@export var auto_detect_atlas_grid: bool = true:
	set(value): auto_detect_atlas_grid=value; emit_changed()
## Número de celdas útiles de la animación. Se limita a la capacidad de la cuadrícula; uno muestra una sola imagen.
@export_range(1, 1024, 1) var flipbook_frames: int = 64:
	set(value): flipbook_frames=value; emit_changed()
@export_group("Animation")
## Fotogramas base por segundo de la secuencia. Se multiplican por los factores de velocidad; cero pausa la fase de animación.
@export_range(0.0, 60.0, 0.1) var anim_fps: float = 20.0:
	set(value): anim_fps=value; emit_changed()
## Multiplicador de la velocidad de animación cerca de Speed Start. Se mezcla progresivamente con Anim Speed High.
@export_range(0.0, 4.0, 0.01) var anim_speed_low: float = 0.8:
	set(value): anim_speed_low=value; emit_changed()
## Multiplicador de la velocidad de animación a alta velocidad. El valor real se mezcla con Anim Speed Low según el avance.
@export_range(0.0, 4.0, 0.01) var anim_speed_high: float = 1.3:
	set(value): anim_speed_high=value; emit_changed()
## Suavizado temporal entre imágenes: cero mezcla dos fotogramas, uno mezcla cuatro. No genera fotogramas mediante flujo óptico.
@export_range(0.0, 1.0, 0.01) var animation_smoothing: float = 0.75:
	set(value): animation_smoothing=value; emit_changed()
## Velocidad del reloj de distorsión UV, independiente de los PNGs. Cero congela este ruido sin detener la secuencia.
@export_range(0.0, 4.0, 0.01) var distortion_speed: float = 0.35:
	set(value): distortion_speed=value; emit_changed()
## Invierte verticalmente la lectura de cada fotograma para adaptar la orientación de la secuencia a la lámina.
@export var flipbook_flip_y: bool = true:
	set(value): flipbook_flip_y=value; emit_changed()

@export_group("Atlas Cleanup")
## Recupera transparencia desde el brillo de la imagen. Úsalo para atlas sobre fondo negro sin un canal alfa válido.
@export var alpha_from_luminance: bool = false:
	set(value): alpha_from_luminance=value; emit_changed()
## Umbral para descartar las zonas de alfa o luminancia demasiado débiles. Más valor elimina más fondo y también puede quitar gotas finas.
@export_range(0.0, 1.0, 0.005) var alpha_cutoff: float = 0.04:
	set(value): alpha_cutoff=value; emit_changed()
## Anchura de la transición suave del recorte de transparencia. Más valor difumina el corte del alfa.
@export_range(0.001, 0.5, 0.005) var alpha_softness: float = 0.08:
	set(value): alpha_softness=value; emit_changed()
## Multiplicador de la transparencia recuperada de la imagen. Más valor hace visibles las zonas débiles.
@export_range(0.0, 4.0, 0.05) var alpha_gain: float = 1.0:
	set(value): alpha_gain=value; emit_changed()
## Márgenes izquierdo, superior, derecho e inferior dentro de cada celda del atlas, como fracciones de la celda.
@export var frame_crop: Vector4 = Vector4.ZERO:
	set(value): frame_crop=value; emit_changed()

@export_group("Soft Edges and Side View")
## Fracción de los bordes UV que se desvanece suavemente para disimular el contorno rectangular.
@export_range(0.02, 0.4, 0.01) var edge_softness: float = 0.15:
	set(value): edge_softness=value; emit_changed()
## Intensidad del desvanecimiento al mirar la lámina de canto. Cero desactiva esta ocultación angular.
@export_range(0.0, 1.0, 0.01) var side_fade_strength: float = 1.0:
	set(value): side_fade_strength=value; emit_changed()
## Ángulo desde el plano de la lámina a partir del que el desvanecimiento lateral deja ver toda su opacidad.
@export_range(1.0, 45.0, 0.5) var side_fade_angle: float = 20.0:
	set(value): side_fade_angle=value; emit_changed()

@export_group("Spray Color")
## Color que tiñe las gotas y la espuma del sprite, combinado con su blancura, saturación y brillo.
@export_color_no_alpha var spray_tint: Color = Color(0.88, 0.96, 1.0):
	set(value): spray_tint=value; emit_changed()
## Blanqueamiento de las gotas visibles: cero conserva sus colores y uno lleva su color al blanco.
@export_range(0.0, 1.0, 0.01) var spray_whiteness: float = 0.0:
	set(value): spray_whiteness=value; emit_changed()
## Saturación del color del sprite: cero lo deja en gris, uno conserva la original y valores mayores intensifican el color.
@export_range(0.0, 2.0, 0.01) var spray_saturation: float = 1.0:
	set(value): spray_saturation=value; emit_changed()
## Multiplicador del brillo del color del spray. No modifica por sí solo el reflejo especular de la película de agua.
@export_range(0.0, 4.0, 0.01) var spray_brightness: float = 1.0:
	set(value): spray_brightness=value; emit_changed()

@export_group("Water Appearance and Highlights")
## Añade película transparente de agua y reflejos especulares dentro de la silueta del sprite.
@export var water_appearance_enabled: bool = true:
	set(value): water_appearance_enabled=value; emit_changed()
## Multiplica la opacidad de la espuma del PNG. Bajarlo permite destacar más la película de agua y sus reflejos.
@export_range(0.0, 1.0, 0.01) var foam_opacity: float = 1.0:
	set(value): foam_opacity=value; emit_changed()
## Opacidad de la película de agua dentro de la silueta. No rellena como agua todo el rectángulo del sprite.
@export_range(0.0, 0.6, 0.01) var water_opacity: float = 0.12:
	set(value): water_opacity=value; emit_changed()
## Color de la película transparente de agua dentro de la silueta del sprite.
@export_color_no_alpha var water_tint: Color = Color(0.75, 0.91, 1.0):
	set(value): water_tint=value; emit_changed()
## Mapa de normales de la película de agua. El recurso predeterminado es procedural; puede sustituirse por una textura de normales convencional.
@export var normal_texture: Texture2D = DEFAULT_WATER_NORMAL:
	set(value): normal_texture=value; emit_changed()
## Intensidad de las normales de la película de agua. Más valor deforma más sus reflejos e iluminación.
@export_range(0.0, 2.0, 0.01) var normal_strength: float = 0.8:
	set(value): normal_strength=value; emit_changed()
## Número de repeticiones de la textura de normales sobre el sprite en sus dos ejes UV.
@export var normal_tiling: Vector2 = Vector2(4.0, 3.0):
	set(value): normal_tiling=value; emit_changed()
## Velocidad de desplazamiento de los UV de normales. Cero congela las normales sin detener los PNGs.
@export_range(0.0, 3.0, 0.01) var normal_scroll_speed: float = 0.35:
	set(value): normal_scroll_speed=value; emit_changed()
## Rugosidad de los reflejos de agua. Valores bajos dan brillos más concentrados; valores altos los suavizan.
@export_range(0.03, 1.0, 0.01) var water_roughness: float = 0.14:
	set(value): water_roughness=value; emit_changed()
## Intensidad de los reflejos especulares de la película. Cero los elimina; no sustituye al brillo del color de la espuma.
@export_range(0.0, 4.0, 0.01) var highlight_strength: float = 1.5:
	set(value): highlight_strength=value; emit_changed()

@export_group("Submersion Suppression")
## Profundidad del contacto menos sumergido a partir de la que empieza a ocultarse el efecto por inmersión del casco.
@export_range(0.0, 2.0, 0.01, "suffix:m") var submersion_fade_start_depth: float = 0.35:
	set(value): submersion_fade_start_depth=value; emit_changed()
## Profundidad del contacto menos sumergido donde el efecto desaparece por inmersión completa, incluidos sus reflejos.
@export_range(0.01, 3.0, 0.01, "suffix:m") var submersion_hide_depth: float = 0.6:
	set(value): submersion_hide_depth=value; emit_changed()

@export_group("Low Speed Shape")
## Longitud del efecto cerca de su velocidad mínima, antes de aplicar Spray Scale.
@export_range(0.2, 4.0, 0.05) var sheet_length_low: float = 0.85:
	set(value): sheet_length_low=value; emit_changed()
## Anchura del efecto cerca de su velocidad mínima, antes de aplicar Spray Scale.
@export_range(0.1, 2.0, 0.05) var sheet_width_low: float = 0.35:
	set(value): sheet_width_low=value; emit_changed()
## Altura del efecto cerca de su velocidad mínima, antes de aplicar Spray Scale.
@export_range(0.0, 1.5, 0.01) var sheet_height_low: float = 0.15:
	set(value): sheet_height_low=value; emit_changed()

@export_group("High Speed Shape")
## Longitud del efecto a alta velocidad, antes de aplicar Spray Scale.
@export_range(0.2, 4.0, 0.05) var sheet_length: float = 1.9:
	set(value): sheet_length=value; emit_changed()
## Anchura del efecto a alta velocidad, antes de aplicar Spray Scale.
@export_range(0.1, 2.0, 0.05) var sheet_width: float = 0.85:
	set(value): sheet_width=value; emit_changed()
## Altura del efecto a alta velocidad, antes de aplicar Spray Scale. En el Tail Jet controla la forma, no la posición de la tobera.
@export_range(0.0, 1.5, 0.01) var sheet_height: float = 0.48:
	set(value): sheet_height=value; emit_changed()

@export_group("Volume and Undulation")
## Número de capas visuales para dar espesor al spray. Más capas aumentan el volumen aparente y el trabajo de dibujo.
@export_range(1, 5, 1) var volume_layers: int = 3:
	set(value): volume_layers=value; emit_changed()
## Separación entre capas que da espesor visual al spray. Depende de que Volume Layers tenga más de una capa.
@export_range(0.0, 0.6, 0.005) var volume_depth: float = 0.18:
	set(value): volume_depth=value; emit_changed()
## Concentra el volumen en una forma más vertical y reduce su apertura horizontal, respetando la altura elegida.
@export_range(0.0, 1.0, 0.01) var volume_verticality: float = 0.65:
	set(value): volume_verticality=value; emit_changed()
## Amplitud de la ondulación de la geometría del spray. Cero deja la forma base sin este movimiento.
@export_range(0.0, 0.3, 0.005) var undulation_strength: float = 0.06:
	set(value): undulation_strength=value; emit_changed()
## Número de ondulaciones a lo largo de la forma del spray. Más valor introduce ondulaciones más cortas.
@export_range(0.1, 8.0, 0.1) var undulation_frequency: float = 3.0:
	set(value): undulation_frequency=value; emit_changed()
## Velocidad de movimiento de las ondulaciones geométricas. Cero congela esta animación.
@export_range(0.0, 3.0, 0.01) var undulation_speed: float = 0.8:
	set(value): undulation_speed=value; emit_changed()

@export_group("Layer Scale and Height Motion")
## Variación máxima, en porcentaje, de escala de cada capa. Cada capa utiliza una fase ligeramente diferente.
@export_range(0.0, 50.0, 0.5) var layer_scale_variation_percent: float = 10.0:
	set(value): layer_scale_variation_percent=value; emit_changed()
## Frecuencia base del cambio de escala por capas. Cero congela esta fase de movimiento.
@export_range(0.0, 3.0, 0.01) var layer_scale_variation_speed: float = 0.65:
	set(value): layer_scale_variation_speed=value; emit_changed()
## Variación máxima de altura en porcentaje de la altura ya interpolada según la velocidad.
@export_range(0.0, 75.0, 0.5) var sheet_height_variation_percent: float = 15.0:
	set(value): sheet_height_variation_percent=value; emit_changed()
## Velocidad de la oscilación visual de altura. Cero congela su fase sin detener otras animaciones.
@export_range(0.0, 3.0, 0.01) var sheet_height_variation_speed: float = 0.9:
	set(value): sheet_height_variation_speed=value; emit_changed()

@export_group("Solid Occlusion")
## Tolerancia de profundidad, en metros, frente al casco, piloto y terreno. Más valor puede dejar ver el spray a través de superficies muy próximas.
@export_range(0.0, 0.05, 0.001) var solid_occlusion_bias: float = 0.005:
	set(value): solid_occlusion_bias=value; emit_changed()

@export_group("Hull Attachment")
## Permite desplazar longitudinalmente los vértices del efecto según el cabeceo. Desactívalo para mantener fijo el origen del chorro en su nodo.
@export var attachment_slide_enabled: bool = true:
	set(value): attachment_slide_enabled=value; emit_changed()
## Distancia máxima de desplazamiento hacia el centro o popa cuando se levanta la proa, con desplazamiento de anclaje activo.
@export_range(0.0, 2.0, 0.01) var nose_up_slide: float = 0.8:
	set(value): nose_up_slide=value; emit_changed()
## Distancia máxima de desplazamiento hacia la proa cuando se inclina hacia abajo, con desplazamiento de anclaje activo.
@export_range(0.0, 1.0, 0.01) var nose_down_slide: float = 0.25:
	set(value): nose_down_slide=value; emit_changed()
## Ángulo de cabeceo donde el desplazamiento longitudinal de anclaje alcanza su distancia máxima.
@export_range(1.0, 60.0, 0.5) var attachment_pitch_full_degrees: float = 20.0:
	set(value): attachment_pitch_full_degrees=value; emit_changed()
## Rapidez con la que se suaviza el desplazamiento visual de anclaje. No mueve el nodo de la tobera o del casco.
@export_range(0.1, 30.0, 0.1) var attachment_response: float = 12.0:
	set(value): attachment_response=value; emit_changed()
## Aportación de la separación vertical respecto al agua al desplazamiento longitudinal visual. No cambia la altura del nodo.
@export_range(0.0, 1.0, 0.01) var attachment_height_influence: float = 0.35:
	set(value): attachment_height_influence=value; emit_changed()
## Separación vertical respecto al agua para la aportación máxima de Attachment Height Influence.
@export_range(0.05, 2.0, 0.01) var attachment_height_full: float = 0.5:
	set(value): attachment_height_full=value; emit_changed()

@export_group("Editor Preview")
## Activa la previsualización del efecto en el editor. Durante el juego se usa el estado real de la moto.
@export var preview_in_editor: bool = false:
	set(value): preview_in_editor=value; emit_changed()
## Velocidad simulada, en metros por segundo, para ver y ajustar el efecto en el editor. No modifica el motor durante el juego.
@export_range(0.0, 50.0, 0.1) var preview_speed: float = 16.0:
	set(value): preview_speed=value; emit_changed()
## Dirección simulada para previsualizar el efecto en el editor. Cero es centro; los extremos representan cada lado.
@export_range(-1.0, 1.0, 0.05) var preview_steering: float = 0.0:
	set(value): preview_steering=value; emit_changed()
## Inclinación de proa simulada para ajustar el anclaje visual en el editor.
@export_range(-45.0, 45.0, 0.5) var preview_pitch_degrees: float = 0.0:
	set(value): preview_pitch_degrees=value; emit_changed()

@export_group("Sprite Anchor")
## Usa el punto de anclaje UV elegido manualmente en lugar del calculado para la secuencia.
@export var use_custom_pivot: bool = false:
	set(value): use_custom_pivot=value; emit_changed()
## Punto UV del sprite que coincide con el emisor. X recorre el ancho; Y recorre la altura de la imagen.
@export var sprite_pivot: Vector2 = Vector2(0.5,0.0):
	set(value): sprite_pivot=value; emit_changed()
