@tool
extends Node3D
## Visual-only bow sheets. Reads existing vehicle/contact state; never samples water
## or writes to the rigid body, handling systems, or ocean.

const DEFAULT_DISTORTION = preload("res://addons/jet_ski/common/visual/bow_spray/bow_spray_distortion.tres")
const DEFAULT_WATER_NORMAL = preload("res://addons/jet_ski/common/visual/bow_spray/bow_spray_water_normal.tres")
const TEXTURE_FOLDER := "res://addons/jet_ski/common/visual/bow_spray/textures/"
const VOLUME_MESH = preload("res://addons/jet_ski/common/visual/bow_spray/bow_spray_volume_mesh.gd")

@export_category("Bow Spray")
@export_group("General")
## Activa las láminas de agua de proa. No activa ni desactiva los Splash laterales ni el Tail Jet.
@export var bow_spray_enabled: bool = true
## Orden de dibujo de materiales transparentes. Valores mayores se dibujan más tarde; no convierte el efecto en geometría opaca.
@export_range(-128, 127, 1) var spray_render_priority: int = 100
## Velocidad horizontal mínima, en metros por segundo, para que empiece a verse el efecto durante el juego.
@export_range(0.0, 40.0, 0.1) var speed_start: float = 2.5
## Velocidad horizontal, en metros por segundo, a la que el efecto alcanza su tamaño e intensidad de alta velocidad.
@export_range(0.1, 60.0, 0.1) var speed_full: float = 16.0
## Opacidad general del efecto. Menos valor deja ver más el agua y el casco a través del sprite.
@export_range(0.0, 1.0, 0.01) var spray_opacity: float = 0.65
## Escala global del efecto visual, aplicada después de interpolar sus dimensiones por velocidad.
@export_range(0.1, 3.0, 0.01) var spray_scale: float = 1.0
## Intensidad con la que el ruido de distorsión deforma las coordenadas de la textura del spray.
@export_range(0.0, 0.15, 0.001) var distortion_strength: float = 0.025
## Intensidad de la máscara que rompe la lámina en gotas y huecos irregulares.
@export_range(0.0, 1.0, 0.01) var breakup_strength: float = 0.7
## Inclinación visual máxima de la lámina según el giro. No cambia la dirección ni la inclinación física del casco.
@export_range(0.0, 0.5, 0.005) var steering_tilt_strength: float = 0.14
@export_group("Water Contact and Recovery")
## Tiempo de crecimiento tras recuperar contacto con agua, independiente de la velocidad de avance. Cero produce recuperación inmediata.
@export_range(0.0,1.0,0.01) var contact_build_seconds := 0.35
## Tamaño inicial al recuperar contacto con agua, antes de crecer durante Contact Build Seconds.
@export_range(0.0,0.5,0.01) var contact_initial_scale := 0.12
var _contact_growth := 0.0
var _contact_age := 0.0

@export_group("Textures and Flipbook")
## Reproduce los PNGs de Image Sequence si hay una secuencia válida; si no, utiliza el atlas de animación.
@export var use_image_sequence: bool = true
## PNGs de la animación en orden de reproducción. Con la secuencia activada y válida se utiliza en lugar del atlas.
@export var image_sequence: Array[Texture2D] = []
## Márgenes izquierdo, superior, derecho e inferior de cada PNG, como fracciones de la imagen. Permiten recortar el área útil del sprite.
@export var sequence_frame_crop: Vector4 = Vector4(0.42, 0.0, 0.0, 0.5)
## Atlas de animación RGBA, ordenado por filas desde la celda superior izquierda. Se usa cuando no hay una secuencia PNG activa.
@export var flipbook_texture: Texture2D
## Máscara de rotura del spray: el blanco conserva agua y el negro abre huecos. Se combina con Breakup Strength.
@export var breakup_mask: Texture2D
## Ruido RG repetido que deforma los UV del spray. Se combina con Distortion Strength y su reloj de animación.
@export var distortion_texture: Texture2D = DEFAULT_DISTORTION
## Dato antiguo reservado para gotas secundarias que aún no se generan. Se conserva para cargar escenas previas; no se muestra como ajuste.
@export_storage var droplets_atlas: Texture2D
## Número de columnas del atlas de animación. Solo interviene cuando se usa un atlas y no se detecta su cuadrícula automáticamente.
@export_range(1, 32, 1) var frames_x: int = 8
## Número de filas del atlas de animación. Solo interviene cuando se usa un atlas y no se detecta su cuadrícula automáticamente.
@export_range(1, 32, 1) var frames_y: int = 8
## Detecta filas y columnas del atlas por sus bandas de transparencia. Desactívalo para utilizar Frames X y Frames Y manualmente.
@export var auto_detect_atlas_grid: bool = true
## Número de celdas útiles de la animación. Se limita a la capacidad de la cuadrícula; uno muestra una sola imagen.
@export_range(1, 1024, 1) var flipbook_frames: int = 64
@export_group("Animation")
## Fotogramas base por segundo de la secuencia. Se multiplican por los factores de velocidad; cero pausa la fase de animación.
@export_range(0.0, 60.0, 0.1) var anim_fps: float = 20.0
## Multiplicador de la velocidad de animación cerca de Speed Start. Se mezcla progresivamente con Anim Speed High.
@export_range(0.0, 4.0, 0.01) var anim_speed_low: float = 0.8
## Multiplicador de la velocidad de animación a alta velocidad. El valor real se mezcla con Anim Speed Low según el avance.
@export_range(0.0, 4.0, 0.01) var anim_speed_high: float = 1.3
## Suavizado temporal entre imágenes: cero mezcla dos fotogramas, uno mezcla cuatro. No genera fotogramas mediante flujo óptico.
@export_range(0.0, 1.0, 0.01) var animation_smoothing: float = 0.75
## Velocidad del reloj de distorsión UV, independiente de los PNGs. Cero congela este ruido sin detener la secuencia.
@export_range(0.0, 4.0, 0.01) var distortion_speed: float = 0.35
## Invierte verticalmente la lectura de cada fotograma para adaptar la orientación de la secuencia a la lámina.
@export var flipbook_flip_y: bool = true

@export_group("Atlas Cleanup")
## Recupera transparencia desde el brillo de la imagen. Úsalo para atlas sobre fondo negro sin un canal alfa válido.
@export var alpha_from_luminance: bool = false
## Umbral para descartar las zonas de alfa o luminancia demasiado débiles. Más valor elimina más fondo y también puede quitar gotas finas.
@export_range(0.0, 1.0, 0.005) var alpha_cutoff: float = 0.04
## Anchura de la transición suave del recorte de transparencia. Más valor difumina el corte del alfa.
@export_range(0.001, 0.5, 0.005) var alpha_softness: float = 0.08
## Multiplicador de la transparencia recuperada de la imagen. Más valor hace visibles las zonas débiles.
@export_range(0.0, 4.0, 0.05) var alpha_gain: float = 1.0
## Márgenes izquierdo, superior, derecho e inferior dentro de cada celda del atlas, como fracciones de la celda.
@export var frame_crop: Vector4 = Vector4.ZERO

@export_group("Soft Edges and Side View")
## Fracción de los bordes UV que se desvanece suavemente para disimular el contorno rectangular.
@export_range(0.02, 0.4, 0.01) var edge_softness: float = 0.15
## Intensidad del desvanecimiento al mirar la lámina de canto. Cero desactiva esta ocultación angular.
@export_range(0.0, 1.0, 0.01) var side_fade_strength: float = 1.0
## Ángulo desde el plano de la lámina a partir del que el desvanecimiento lateral deja ver toda su opacidad.
@export_range(1.0, 45.0, 0.5) var side_fade_angle: float = 20.0

@export_group("Spray Color")
## Color que tiñe las gotas y la espuma del sprite, combinado con su blancura, saturación y brillo.
@export_color_no_alpha var spray_tint: Color = Color(0.88, 0.96, 1.0)
## Blanqueamiento de las gotas visibles: cero conserva sus colores y uno lleva su color al blanco.
@export_range(0.0, 1.0, 0.01) var spray_whiteness: float = 0.0
## Saturación del color del sprite: cero lo deja en gris, uno conserva la original y valores mayores intensifican el color.
@export_range(0.0, 2.0, 0.01) var spray_saturation: float = 1.0
## Multiplicador del brillo del color del spray. No modifica por sí solo el reflejo especular de la película de agua.
@export_range(0.0, 4.0, 0.01) var spray_brightness: float = 1.0

@export_group("Water Appearance and Highlights")
## Añade película transparente de agua y reflejos especulares dentro de la silueta del sprite.
@export var water_appearance_enabled: bool = true
## Multiplica la opacidad de la espuma del PNG. Bajarlo permite destacar más la película de agua y sus reflejos.
@export_range(0.0, 1.0, 0.01) var foam_opacity: float = 1.0
## Opacidad de la película de agua dentro de la silueta. No rellena como agua todo el rectángulo del sprite.
@export_range(0.0, 0.6, 0.01) var water_opacity: float = 0.12
## Color de la película transparente de agua dentro de la silueta del sprite.
@export_color_no_alpha var water_tint: Color = Color(0.75, 0.91, 1.0)
## Mapa de normales de la película de agua. El recurso predeterminado es procedural; puede sustituirse por una textura de normales convencional.
@export var normal_texture: Texture2D = DEFAULT_WATER_NORMAL
## Intensidad de las normales de la película de agua. Más valor deforma más sus reflejos e iluminación.
@export_range(0.0, 2.0, 0.01) var normal_strength: float = 0.8
## Número de repeticiones de la textura de normales sobre el sprite en sus dos ejes UV.
@export var normal_tiling: Vector2 = Vector2(4.0, 3.0)
## Velocidad de desplazamiento de los UV de normales. Cero congela las normales sin detener los PNGs.
@export_range(0.0, 3.0, 0.01) var normal_scroll_speed: float = 0.35
## Rugosidad de los reflejos de agua. Valores bajos dan brillos más concentrados; valores altos los suavizan.
@export_range(0.03, 1.0, 0.01) var water_roughness: float = 0.14
## Intensidad de los reflejos especulares de la película. Cero los elimina; no sustituye al brillo del color de la espuma.
@export_range(0.0, 4.0, 0.01) var highlight_strength: float = 1.5

@export_group("Submersion Suppression")
## Profundidad del contacto menos sumergido a partir de la que empieza a ocultarse el efecto por inmersión del casco.
@export_range(0.0, 2.0, 0.01, "suffix:m") var submersion_fade_start_depth: float = 0.35
## Profundidad del contacto menos sumergido donde el efecto desaparece por inmersión completa, incluidos sus reflejos.
@export_range(0.01, 3.0, 0.01, "suffix:m") var submersion_hide_depth: float = 0.6

@export_group("Low Speed Shape")
## Longitud del efecto cerca de su velocidad mínima, antes de aplicar Spray Scale.
@export_range(0.2, 4.0, 0.05) var sheet_length_low: float = 0.85
## Anchura del efecto cerca de su velocidad mínima, antes de aplicar Spray Scale.
@export_range(0.1, 2.0, 0.05) var sheet_width_low: float = 0.35
## Altura del efecto cerca de su velocidad mínima, antes de aplicar Spray Scale.
@export_range(0.0, 1.5, 0.01) var sheet_height_low: float = 0.15

@export_group("High Speed Shape")
## Longitud del efecto a alta velocidad, antes de aplicar Spray Scale.
@export_range(0.2, 4.0, 0.05) var sheet_length: float = 1.9
## Anchura del efecto a alta velocidad, antes de aplicar Spray Scale.
@export_range(0.1, 2.0, 0.05) var sheet_width: float = 0.85
## Altura del efecto a alta velocidad, antes de aplicar Spray Scale. En el Tail Jet controla la forma, no la posición de la tobera.
@export_range(0.0, 1.5, 0.01) var sheet_height: float = 0.48

@export_group("Volume and Undulation")
## Número de capas visuales para dar espesor al spray. Más capas aumentan el volumen aparente y el trabajo de dibujo.
@export_range(1, 5, 1) var volume_layers: int = 3
## Separación entre capas que da espesor visual al spray. Depende de que Volume Layers tenga más de una capa.
@export_range(0.0, 0.6, 0.005) var volume_depth: float = 0.18
## Concentra el volumen en una forma más vertical y reduce su apertura horizontal, respetando la altura elegida.
@export_range(0.0, 1.0, 0.01) var volume_verticality: float = 0.65
## Amplitud de la ondulación de la geometría del spray. Cero deja la forma base sin este movimiento.
@export_range(0.0, 0.3, 0.005) var undulation_strength: float = 0.06
## Número de ondulaciones a lo largo de la forma del spray. Más valor introduce ondulaciones más cortas.
@export_range(0.1, 8.0, 0.1) var undulation_frequency: float = 3.0
## Velocidad de movimiento de las ondulaciones geométricas. Cero congela esta animación.
@export_range(0.0, 3.0, 0.01) var undulation_speed: float = 0.8

@export_group("Layer Scale and Height Motion")
## Variación máxima, en porcentaje, de escala de cada capa. Cada capa utiliza una fase ligeramente diferente.
@export_range(0.0, 50.0, 0.5) var layer_scale_variation_percent: float = 10.0
## Frecuencia base del cambio de escala por capas. Cero congela esta fase de movimiento.
@export_range(0.0, 3.0, 0.01) var layer_scale_variation_speed: float = 0.65
## Variación máxima de altura en porcentaje de la altura ya interpolada según la velocidad.
@export_range(0.0, 75.0, 0.5) var sheet_height_variation_percent: float = 15.0
## Velocidad de la oscilación visual de altura. Cero congela su fase sin detener otras animaciones.
@export_range(0.0, 3.0, 0.01) var sheet_height_variation_speed: float = 0.9

@export_group("Solid Occlusion")
## Tolerancia de profundidad, en metros, frente al casco, piloto y terreno. Más valor puede dejar ver el spray a través de superficies muy próximas.
@export_range(0.0, 0.05, 0.001) var solid_occlusion_bias: float = 0.005

@export_group("Hull Attachment")
## Permite desplazar longitudinalmente los vértices del efecto según el cabeceo. Desactívalo para mantener fijo el origen del chorro en su nodo.
@export var attachment_slide_enabled: bool = true
## Distancia máxima de desplazamiento hacia el centro o popa cuando se levanta la proa, con desplazamiento de anclaje activo.
@export_range(0.0, 2.0, 0.01) var nose_up_slide: float = 0.8
## Distancia máxima de desplazamiento hacia la proa cuando se inclina hacia abajo, con desplazamiento de anclaje activo.
@export_range(0.0, 1.0, 0.01) var nose_down_slide: float = 0.25
## Ángulo de cabeceo donde el desplazamiento longitudinal de anclaje alcanza su distancia máxima.
@export_range(1.0, 60.0, 0.5) var attachment_pitch_full_degrees: float = 20.0
## Rapidez con la que se suaviza el desplazamiento visual de anclaje. No mueve el nodo de la tobera o del casco.
@export_range(0.1, 30.0, 0.1) var attachment_response: float = 12.0
## Aportación de la separación vertical respecto al agua al desplazamiento longitudinal visual. No cambia la altura del nodo.
@export_range(0.0, 1.0, 0.01) var attachment_height_influence: float = 0.35
## Separación vertical respecto al agua para la aportación máxima de Attachment Height Influence.
@export_range(0.05, 2.0, 0.01) var attachment_height_full: float = 0.5

@export_group("Editor Preview")
## Activa la previsualización del efecto en el editor. Durante el juego se usa el estado real de la moto.
@export var preview_in_editor: bool = false
## Velocidad simulada, en metros por segundo, para ver y ajustar el efecto en el editor. No modifica el motor durante el juego.
@export_range(0.0, 50.0, 0.1) var preview_speed: float = 16.0
## Dirección simulada para previsualizar el efecto en el editor. Cero es centro; los extremos representan cada lado.
@export_range(-1.0, 1.0, 0.05) var preview_steering: float = 0.0
## Inclinación de proa simulada para ajustar el anclaje visual en el editor.
@export_range(-45.0, 45.0, 0.5) var preview_pitch_degrees: float = 0.0

# Keep the configuration serialized, without taking the Inspector away from
# BowSprayRoot. Each of the three sections has its own appearance and preview.
## Recurso de compatibilidad que agrupa los perfiles de Splash y Tail Jet. Edita sus secciones independientes en este mismo nodo.
@export_storage var hull_spray_settings: Resource = load("res://addons/jet_ski/common/visual/hull_spray/default_style.tres"):
	set(value):
		hull_spray_settings=value
		var extra := get_node_or_null("HullSprays")
		if extra!=null: extra.configure_settings(value)

@export_category("Splash")
@export_group("Appearance", "splash_")
## Perfil completo de los Splash laterales. Sus cambios no se aplican al Bow Spray ni al Tail Jet.
@export var splash_settings: Resource:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.splash_appearance
	set(value):
		if value==null: return
		_ensure_spray_profiles()
		if hull_spray_settings.splash_appearance==value: return
		var separate: Resource=hull_spray_settings.duplicate(false)
		separate.splash_appearance=value
		hull_spray_settings=separate
@export_group("Trajectory", "splash_")
## Ángulo de lanzamiento respecto al plano del mar. Cero es horizontal; cinco grados produce una salida lateral baja.
@export_range(0.0,20.0,0.5) var splash_elevation_degrees: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.elevation_degrees
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.elevation_degrees=value
@export_group("Impact Response", "splash_")
## Frecuencia de salpicaduras recurrentes al avanzar mojado. Cero conserva solo las respuestas a impactos.
@export_range(0.0,12.0,0.1) var splash_sustained_rate_hz: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.sustained_rate_hz
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.sustained_rate_hz=value
## Tiempo durante el que permanece visible cada splash lateral emitido. No es la duración de la estela de espuma.
@export_range(0.12,0.8,0.01) var splash_burst_lifetime: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.side_burst_lifetime
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.side_burst_lifetime=value
## Velocidad mínima de impacto contra el agua para disparar una salpicadura lateral por choque.
@export_range(0.2,6.0,0.05) var splash_impact_threshold: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.impact_threshold
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.impact_threshold=value
## Retraso máximo entre lados para romper la sincronía de las salpicaduras izquierda y derecha.
@export_range(0.02,0.3,0.01) var splash_side_delay: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.side_delay
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.side_delay=value
## Tiempo mínimo de separación entre respuestas a impactos fuertes. La emisión recurrente tiene su propia frecuencia.
@export_range(0.15,1.5,0.01) var splash_cooldown: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.cooldown
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.cooldown=value
@export_group("Editor Preview", "splash_")
## Previsualiza los Splash en el editor sin requerir gas, contacto con agua ni emisión durante el juego.
@export var splash_preview_in_editor: bool:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.splash_appearance.preview_in_editor
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.splash_appearance.preview_in_editor=value
## Velocidad simulada para previsualizar los Splash laterales en el editor, independiente del gas y del contacto real.
@export_range(0.0,50.0,0.1) var splash_preview_speed: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.splash_appearance.preview_speed
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.splash_appearance.preview_speed=value

@export_category("Tail Jet")
@export_group("Appearance", "tail_")
## Selecciona la secuencia de sprites Splash 3 o Splash 4 para el chorro de cola.
@export_enum("Splash 3", "Splash 4") var tail_variant: int:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_variant
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_variant=value
## Perfil completo del Tail Jet. Sus cambios no se aplican al Bow Spray ni a los Splash laterales.
@export var tail_settings: Resource:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_appearance
	set(value):
		if value==null: return
		_ensure_spray_profiles()
		if hull_spray_settings.tail_appearance==value: return
		var separate: Resource=hull_spray_settings.duplicate(false)
		separate.tail_appearance=value
		hull_spray_settings=separate
@export_group("Nozzle and Cone", "tail_")
## Rapidez con la que el chorro sigue el balanceo real del casco. Menos valor produce un cambio más lento y progresivo.
@export_range(0.1,20.0,0.1) var tail_turn_response: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_turn_response
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_turn_response=value
## Diámetro vertical del cono respecto a su anchura. Da volumen al chorro sin mover la tobera.
@export_range(0.15,1.5,0.01) var tail_roundness: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_roundness
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_roundness=value
## Caída vertical del extremo del cono de cola antes de aplicar Spray Scale. No baja la tobera de emisión.
@export_range(0.0,2.0,0.01) var tail_downward_curve: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_downward_curve
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_downward_curve=value
@export_group("Residual Water", "tail_")
## Duración de los restos de agua expulsados después de perder la alimentación de agua de la turbina.
@export_range(0.0,1.0,0.01) var tail_residual_seconds: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_residual_seconds
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_residual_seconds=value
## Intensidad de los borbotones residuales cuando la turbina deja de estar alimentada por agua.
@export_range(0.0,1.0,0.01) var tail_residual_strength: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_residual_strength
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_residual_strength=value
@export_group("Editor Preview", "tail_")
## Previsualiza el Tail Jet en el editor sin necesidad de gas ni contacto real. Usa su velocidad de previsualización.
@export var tail_preview_in_editor: bool:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_appearance.preview_in_editor
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_appearance.preview_in_editor=value
## Velocidad simulada para previsualizar el chorro de cola en el editor, sin necesidad de acelerar.
@export_range(0.0,50.0,0.1) var tail_preview_speed: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_appearance.preview_speed
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_appearance.preview_speed=value

@export_group("Visibility", "tail_")
## Franja poco profunda en la que el chorro aireado se desvanece bajo el agua. No cambia la posición de tu tobera. Cero recupera el recorte anterior.
@export_range(0.0,0.6,0.01,"suffix:m") var tail_surface_fade_depth_m: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_surface_fade_depth_m
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_surface_fade_depth_m=value
## Añade un núcleo de agua azul que destaca sobre la espuma blanca. Cero conserva la apariencia anterior; no cambia el color ni la animación de las gotas.
@export_range(0.0,1.0,0.01) var tail_water_core_strength: float:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.tail_water_core_strength
	set(value):
		_ensure_spray_profiles()
		hull_spray_settings.tail_water_core_strength=value
@export_category("Stern Mist")
@export_group("Appearance", "stern_mist_")
## Neblina turbulenta limitada a la popa. Controles propios de color, opacidad, tamaño, vida, turbulencia y previsualización; no modifica los otros sprays.
@export var stern_mist_settings: Resource:
	get:
		_ensure_spray_profiles()
		return hull_spray_settings.stern_mist
	set(value):
		if value==null: return
		_ensure_spray_profiles()
		if hull_spray_settings.stern_mist==value: return
		var separate: Resource=hull_spray_settings.duplicate(false)
		separate.stern_mist=value
		hull_spray_settings=separate

var horizontal_speed: float = 0.0
var speed_factor: float = 0.0
var contact_factor: float = 0.0
var submersion_visibility: float = 1.0
var detected_atlas_grid: Vector2i = Vector2i.ZERO
var sequence_frame_count: int:
	get:
		return _sequence_textures.size()
var effective_anim_fps: float = 0.0
var effective_sheet_dimensions: Vector3 = Vector3.ZERO
var effective_height_multiplier: float = 1.0
var _visual_speed: float = 0.0
var _visual_contact: float = 0.0
var _visual_steering: float = 0.0
var _animation_time: float = 0.0
var _frame_position: float = 0.0
var _volume_time: float = 0.0
var _normal_time: float = 0.0
var _layer_scale_time: float = 0.0
var _height_variation_time: float = 0.0
var _volume_mesh: ArrayMesh
var _mesh_layer_count: int = -1
var _vehicle: JetSkiController
var _materials: Array[ShaderMaterial] = []
var _sheets: Array[MeshInstance3D] = []
var _scene_light_tint := Vector3.ONE
var _scene_tint_refresh := 0.0
var _attachment_offsets: Array[Vector3] = []
var _layout_texture: Texture2D
var _layout_auto: bool = false
var _sequence_configuration: Array[Texture2D] = []
var _sequence_textures: Array[Texture2D] = []

func _ensure_spray_profiles() -> void:
	if hull_spray_settings==null: hull_spray_settings=load("res://addons/jet_ski/common/visual/hull_spray/default_style.tres")
	var defaults := {"tail_turn_response":5.0,"tail_roundness":0.8,"tail_downward_curve":0.45,
		"sustained_rate_hz":6.0,"side_burst_lifetime":0.30,"tail_residual_seconds":0.55,"tail_residual_strength":0.65,
		"tail_surface_fade_depth_m":0.25,"tail_water_core_strength":0.45}
	for key in defaults:
		if hull_spray_settings.get(key)==null:
			hull_spray_settings.set(key,defaults[key])
	if hull_spray_settings.get("splash_appearance")==null:
		hull_spray_settings.set("splash_appearance",load("res://addons/jet_ski/common/visual/hull_spray/splash_appearance.tres"))
	if hull_spray_settings.get("tail_appearance")==null:
		hull_spray_settings.set("tail_appearance",load("res://addons/jet_ski/common/visual/hull_spray/tail_appearance.tres"))
	if hull_spray_settings.get("stern_mist")==null:
		hull_spray_settings.set("stern_mist",load("res://addons/jet_ski/common/visual/hull_spray/stern_mist_style.tres"))


func _ready() -> void:
	_load_default_assets()
	_vehicle = _find_vehicle() if not Engine.is_editor_hint() else null
	for side_name in ["BowSprayLeft", "BowSprayRight"]:
		var sheet := get_node(side_name) as MeshInstance3D
		# Per-side, per-vehicle materials prevent speed/phase leaking between instances.
		var material := sheet.material_override.duplicate() as ShaderMaterial
		sheet.material_override = material
		# Large shader bounds must not move transparent sorting away from the bow.
		sheet.sorting_use_aabb_center = false
		# Vertex shader curves/expands the grid beyond its original flat AABB.
		sheet.custom_aabb = AABB(Vector3(-12.0, -12.0, -2.0), Vector3(24.0, 24.0, 22.0))
		_sheets.append(sheet)
		_attachment_offsets.append(Vector3.ZERO)
		_materials.append(material)
	_materials[0].set_shader_parameter("side_sign", -1.0)
	_materials[0].set_shader_parameter("phase_offset", 0.0)
	_materials[0].set_shader_parameter("frame_phase", 0.0)
	_materials[1].set_shader_parameter("side_sign", 1.0)
	_materials[1].set_shader_parameter("phase_offset", 0.37)
	_materials[1].set_shader_parameter("frame_phase", 1.5)
	_apply_materials()
	_set_sheet_visibility(false)
	if not Engine.is_editor_hint() and _vehicle == null:
		push_warning("BowSprayRoot must be inside a JetSkiController hierarchy.")
		set_process(false)


func _process(delta: float) -> void:
	_update_scene_light_tint(delta)
	var steering := 0.0
	var airborne := false
	if Engine.is_editor_hint():
		submersion_visibility = 1.0
		# Preview never writes node transforms, including when toggled off.
		_update_hull_attachment(delta, deg_to_rad(preview_pitch_degrees) if preview_in_editor else 0.0, null, false)
		horizontal_speed = preview_speed if preview_in_editor else 0.0
		contact_factor = 1.0 if preview_in_editor else 0.0
		_contact_growth = 1.0 if preview_in_editor else 0.0
		steering = preview_steering
	elif is_instance_valid(_vehicle) and _vehicle.water_physics_system != null:
		var velocity := _vehicle.linear_velocity
		horizontal_speed = Vector2(velocity.x, velocity.z).length()
		steering = clampf(_vehicle.steering_input, -1.0, 1.0)
		var water := _vehicle.water_physics_system
		airborne = water.contact_is_airborne
		_update_submersion_visibility(water, airborne)
		var forward := -_vehicle.global_transform.basis.z.normalized()
		var pitch := asin(clampf(forward.y, -1.0, 1.0))
		_update_hull_attachment(delta, pitch, water, airborne)
		contact_factor = 1.0 if water.contact_is_wet and not airborne else 0.0
		if contact_factor > 0.0:
			# Reduce bow spray when only the stern is wet, using already sampled data.
			var front_wet := 0
			var depths := water.point_depths
			var valid := water.point_sample_valid
			for index in mini(2, mini(depths.size(), valid.size())):
				if valid[index] and depths[index] >= water.MEANINGFUL_WET_DEPTH_M:
					front_wet += 1
			contact_factor *= float(front_wet) / 2.0
		contact_factor *= submersion_visibility
		if contact_factor>0.001 and not airborne:
			_contact_age+=delta
			_contact_growth=smoothstep(0.0,maxf(contact_build_seconds,0.001),_contact_age)
		else:
			_contact_age=0.0
			_contact_growth=0.0
	else:
		submersion_visibility = 1.0
		horizontal_speed = 0.0
		contact_factor = 0.0
		_contact_growth = 0.0
		_contact_age = 0.0

	# A non-increasing inspector range remains safe and deterministic.
	var full_speed := maxf(speed_full, speed_start + 0.01)
	speed_factor = smoothstep(speed_start, full_speed, horizontal_speed)
	var blend := 1.0 - exp(-delta * 12.0)
	_visual_speed = lerpf(_visual_speed, speed_factor, blend)
	_visual_steering = lerpf(_visual_steering, steering, blend)
	_visual_contact = lerpf(_visual_contact, contact_factor, blend)
	# Suppression must not lag behind a dive. Fade back in normally on resurfacing.
	_visual_contact = minf(_visual_contact, submersion_visibility)
	if airborne or contact_factor<=0.0:
		_visual_contact = 0.0
	if not bow_spray_enabled:
		_visual_speed = 0.0
		_visual_contact = 0.0
	# Integrate the frame rate, rather than multiplying all elapsed time by FPS.
	# Changing FPS or accelerating cannot suddenly move to another frame phase.
	effective_anim_fps = maxf(anim_fps, 0.0) * lerpf(anim_speed_low, anim_speed_high, _visual_speed)
	_frame_position += delta * effective_anim_fps
	_volume_time += delta * maxf(undulation_speed, 0.0)
	_animation_time += delta * maxf(distortion_speed, 0.0) * lerpf(0.8, 1.3, _visual_speed)
	_normal_time += delta * maxf(normal_scroll_speed, 0.0) * lerpf(0.8, 1.3, _visual_speed)
	var motion_weight := _shape_motion_weight()
	# Separate integrated clocks: editing a rate never jumps phase, and neither
	# movement depends on PNG FPS or the existing lateral undulation clock.
	_layer_scale_time += delta * maxf(layer_scale_variation_speed, 0.0) * motion_weight
	_height_variation_time += delta * maxf(sheet_height_variation_speed, 0.0) * motion_weight
	_apply_materials()
	_set_sheet_visibility(bow_spray_enabled and not airborne and _visual_speed * _visual_contact * _contact_growth * spray_opacity > 0.001)


func _update_scene_light_tint(delta: float) -> void:
	if Engine.is_editor_hint():
		_scene_light_tint = Vector3.ONE
		return
	_scene_tint_refresh -= delta
	if _scene_tint_refresh > 0.0:
		return
	_scene_tint_refresh = 0.12
	if is_instance_valid(_vehicle) and is_instance_valid(_vehicle.ocean):
		_scene_light_tint = _vehicle.ocean.get_scene_lighting_tint()
	else:
		_scene_light_tint = Vector3.ONE


func _update_submersion_visibility(water: JetSkiWaterPhysicsSystem, airborne: bool) -> void:
	if airborne or not water.contact_is_wet:
		submersion_visibility = 1.0
		return
	var depths := water.point_depths
	var valid := water.point_sample_valid
	# Normal floating and a single immersed bow/stern are not full submersion.
	# With incomplete data, retain the last result so hidden spray cannot flash on.
	if depths.size() < 4 or valid.size() < 4:
		return
	var shallowest := INF
	for index in 4:
		if not valid[index] or not is_finite(depths[index]):
			return
		shallowest = minf(shallowest, depths[index])
	var start := maxf(submersion_fade_start_depth, 0.0)
	var full := maxf(submersion_hide_depth, start + 0.01)
	submersion_visibility = 1.0 - smoothstep(start, full, shallowest)


func _load_default_assets() -> void:
	# Optional files: exported assignments take precedence; no broken resource refs.
	if flipbook_texture == null:
		flipbook_texture = _load_optional_texture("bow_spray_flipbook.png")
	if breakup_mask == null:
		breakup_mask = _load_optional_texture("foam_breakup_mask.png")
	if distortion_texture == null or distortion_texture == DEFAULT_DISTORTION:
		var noise := _load_optional_texture("distortion_noise.png")
		if noise != null:
			distortion_texture = noise
	if droplets_atlas == null:
		droplets_atlas = _load_optional_texture("droplets_atlas.png")


func _load_optional_texture(filename: String) -> Texture2D:
	var path := TEXTURE_FOLDER + filename
	return load(path) as Texture2D if ResourceLoader.exists(path, "Texture2D") else null


func _find_vehicle() -> JetSkiController:
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is JetSkiController:
			return ancestor as JetSkiController
		ancestor = ancestor.get_parent()
	return null


func _update_hull_attachment(delta: float, pitch: float,
		water: JetSkiWaterPhysicsSystem, airborne: bool) -> void:
	# Tool-script hot reload may keep the sheets but initialize this new buffer.
	if _attachment_offsets.size() != _sheets.size():
		_attachment_offsets.resize(_sheets.size())
	var pitch_factor := clampf(pitch / deg_to_rad(maxf(attachment_pitch_full_degrees, 1.0)), -1.0, 1.0)
	var aft_local := Vector3.BACK
	if is_instance_valid(_vehicle):
		# Supports a rotated/offset visual parent: slide along the actual hull axis.
		aft_local = global_transform.basis.inverse() * _vehicle.global_transform.basis.z.normalized()
	for index in _sheets.size():
		# Read the current editable transform; no cached position can undo a drag.
		var anchor := _sheets[index].position
		var factor := pitch_factor
		if water != null and not airborne and water.contact_is_wet and attachment_height_influence > 0.0:
			var surfaces := water.point_water_surface_positions
			var valid := water.point_sample_valid
			if index < surfaces.size() and index < valid.size() and valid[index] and surfaces[index].is_finite():
				var height_above_water := to_global(anchor).y - surfaces[index].y
				factor += clampf(height_above_water / maxf(attachment_height_full, 0.05), -1.0, 1.0) * attachment_height_influence
		factor = clampf(factor, -1.0, 1.0)
		var shift := factor * (nose_up_slide if factor >= 0.0 else nose_down_slide)
		var target := aft_local * shift
		# Keep the optional pitch/heave slide in a separate visual offset. The node
		# itself follows the hull and can be moved/rotated/scaled at any time.
		_attachment_offsets[index] = _attachment_offsets[index].lerp(target, 1.0 - exp(-delta * attachment_response)) if attachment_slide_enabled else Vector3.ZERO


func _apply_materials() -> void:
	var layer_count := clampi(volume_layers, 1, 5)
	var expected_vertices: int = layer_count * (VOLUME_MESH.LONG_STEPS + 1) * (VOLUME_MESH.CROSS_STEPS + 1)
	if _mesh_layer_count != layer_count or _volume_mesh == null or _volume_mesh.surface_get_array_len(0) != expected_vertices:
		_volume_mesh = VOLUME_MESH.build(layer_count)
		_mesh_layer_count = layer_count
		for sheet in _sheets:
			sheet.mesh = _volume_mesh
	if image_sequence != _sequence_configuration:
		_sequence_configuration = image_sequence.duplicate()
		_sequence_textures.clear()
		for texture in image_sequence:
			if texture != null:
				_sequence_textures.append(texture)
	var sequence_active := use_image_sequence and not _sequence_textures.is_empty()
	if flipbook_texture != _layout_texture or auto_detect_atlas_grid != _layout_auto:
		_layout_texture = flipbook_texture
		_layout_auto = auto_detect_atlas_grid
		detected_atlas_grid = _detect_atlas_grid() if auto_detect_atlas_grid else Vector2i.ZERO
	var grid := Vector2(maxi(frames_x, 1), maxi(frames_y, 1))
	if auto_detect_atlas_grid and detected_atlas_grid.x > 1 and detected_atlas_grid.y > 1:
		grid = Vector2(detected_atlas_grid)
	effective_sheet_dimensions = Vector3(sheet_length_low, sheet_width_low, sheet_height_low).lerp(
		Vector3(sheet_length, sheet_width, sheet_height), _visual_speed)
	if not Engine.is_editor_hint():
		effective_sheet_dimensions*=lerpf(contact_initial_scale,1.0,_contact_growth)
	var motion_weight := _shape_motion_weight()
	# Two smooth frequencies avoid a perfectly repetitive up/down breathing cycle.
	var height_wave := sin(_height_variation_time * TAU) * 0.7 + sin(_height_variation_time * TAU * 0.63 + 1.7) * 0.3
	effective_height_multiplier = 1.0 + clampf(sheet_height_variation_percent, 0.0, 75.0) * 0.01 * motion_weight * height_wave
	var atlas_count := clampi(flipbook_frames, 1, int(grid.x * grid.y))
	if _attachment_offsets.size() != _sheets.size():
		_attachment_offsets.resize(_sheets.size())
	for index in _materials.size():
		var material := _materials[index]
		# Convert the hull-axis offset into the manually rotated/scaled sheet space.
		material.set_shader_parameter("attachment_offset", _sheets[index].basis.inverse() * _attachment_offsets[index])
		material.render_priority = spray_render_priority
		material.set_shader_parameter("solid_occlusion_bias", solid_occlusion_bias)
		material.set_shader_parameter("volume_layers", layer_count)
		material.set_shader_parameter("volume_depth", volume_depth)
		material.set_shader_parameter("volume_verticality", volume_verticality)
		material.set_shader_parameter("undulation_strength", undulation_strength)
		material.set_shader_parameter("undulation_frequency", undulation_frequency)
		material.set_shader_parameter("undulation_speed", undulation_speed)
		material.set_shader_parameter("volume_time", _volume_time)
		material.set_shader_parameter("has_image_sequence", sequence_active)
		material.set_shader_parameter("sequence_frame_crop", sequence_frame_crop)
		if sequence_active:
			_set_sequence_frame(material)
		else:
			material.set_shader_parameter("sequence_texture", null)
			material.set_shader_parameter("sequence_next_texture", null)
			material.set_shader_parameter("sequence_previous_texture", null)
			material.set_shader_parameter("sequence_following_texture", null)
		material.set_shader_parameter("animation_time", _animation_time)
		material.set_shader_parameter("frame_position", fposmod(_frame_position, float(atlas_count)))
		material.set_shader_parameter("animation_smoothing", animation_smoothing)
		material.set_shader_parameter("speed_factor", _visual_speed)
		material.set_shader_parameter("contact_factor", _visual_contact * _contact_growth)
		material.set_shader_parameter("steering", _visual_steering)
		material.set_shader_parameter("spray_opacity", spray_opacity)
		material.set_shader_parameter("spray_scale", spray_scale)
		var layer_scales := _layer_scale_multipliers(layer_count, index, motion_weight)
		material.set_shader_parameter("layer_scale_factors", Vector4(layer_scales[0], layer_scales[1], layer_scales[2], layer_scales[3]))
		material.set_shader_parameter("layer_scale_factor_5", layer_scales[4])
		material.set_shader_parameter("distortion_strength", distortion_strength)
		material.set_shader_parameter("breakup_strength", breakup_strength)
		material.set_shader_parameter("alpha_from_luminance", alpha_from_luminance)
		material.set_shader_parameter("alpha_cutoff", alpha_cutoff)
		material.set_shader_parameter("alpha_softness", alpha_softness)
		material.set_shader_parameter("alpha_gain", alpha_gain)
		material.set_shader_parameter("edge_softness", edge_softness)
		material.set_shader_parameter("side_fade_strength", side_fade_strength)
		material.set_shader_parameter("side_fade_angle", deg_to_rad(side_fade_angle))
		material.set_shader_parameter("frame_crop", frame_crop)
		material.set_shader_parameter("flipbook_flip_y", flipbook_flip_y)
		material.set_shader_parameter("steering_tilt_strength", steering_tilt_strength)
		material.set_shader_parameter("sheet_length", effective_sheet_dimensions.x)
		material.set_shader_parameter("sheet_width", effective_sheet_dimensions.y)
		material.set_shader_parameter("sheet_height", effective_sheet_dimensions.z * effective_height_multiplier)
		material.set_shader_parameter("spray_color", spray_tint)
		material.set_shader_parameter("scene_light_tint", _scene_light_tint)
		material.set_shader_parameter("spray_whiteness", spray_whiteness)
		material.set_shader_parameter("spray_saturation", spray_saturation)
		material.set_shader_parameter("spray_brightness", spray_brightness)
		material.set_shader_parameter("water_appearance_enabled", water_appearance_enabled)
		material.set_shader_parameter("foam_opacity", foam_opacity)
		material.set_shader_parameter("water_opacity", water_opacity)
		material.set_shader_parameter("water_tint", water_tint)
		material.set_shader_parameter("normal_texture", normal_texture)
		material.set_shader_parameter("has_normal_texture", normal_texture != null)
		material.set_shader_parameter("normal_strength", normal_strength)
		material.set_shader_parameter("normal_tiling", normal_tiling)
		material.set_shader_parameter("normal_time", _normal_time)
		material.set_shader_parameter("water_roughness", water_roughness)
		material.set_shader_parameter("highlight_strength", highlight_strength)
		material.set_shader_parameter("has_flipbook", flipbook_texture != null)
		material.set_shader_parameter("has_breakup_mask", breakup_mask != null)
		material.set_shader_parameter("has_distortion", distortion_texture != null)
		material.set_shader_parameter("flipbook_texture", flipbook_texture)
		material.set_shader_parameter("breakup_mask", breakup_mask)
		material.set_shader_parameter("distortion_texture", distortion_texture)
		material.set_shader_parameter("flipbook_grid", grid)
		material.set_shader_parameter("flipbook_frames", clampi(flipbook_frames, 1, int(grid.x * grid.y)))
		material.set_shader_parameter("flipbook_fps", anim_fps)


func _shape_motion_weight() -> float:
	# Smoothly remove shape pulsation at rest/dry contact and strongly reduce in air.
	return smoothstep(0.0, 0.1, _visual_speed) * clampf(_visual_contact, 0.0, 1.0) if bow_spray_enabled else 0.0


func _layer_scale_multipliers(layer_count: int, side: int, motion_weight: float) -> PackedFloat32Array:
	var scales := PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 1.0])
	var amplitude := clampf(layer_scale_variation_percent, 0.0, 50.0) * 0.01 * motion_weight
	for layer in layer_count:
		var phase := float(layer) * 2.094395 + float(side) * 1.17
		var rate := 0.88 + float(layer) * 0.12 + float(side) * 0.07
		var wave := sin(_layer_scale_time * TAU * rate + phase) * 0.7
		wave += sin(_layer_scale_time * TAU * (rate * 1.31) + phase + 1.3) * 0.3
		scales[layer] = 1.0 + amplitude * wave
	return scales


func _set_sequence_frame(material: ShaderMaterial) -> void:
	var phase: float = material.get_shader_parameter("frame_phase")
	var frame := fposmod(_frame_position + phase, float(_sequence_textures.size()))
	var current := int(floor(frame))
	var previous := (current + _sequence_textures.size() - 1) % _sequence_textures.size()
	var next := (current + 1) % _sequence_textures.size()
	var following := (current + 2) % _sequence_textures.size()
	material.set_shader_parameter("sequence_previous_texture", _sequence_textures[previous])
	material.set_shader_parameter("sequence_texture", _sequence_textures[current])
	material.set_shader_parameter("sequence_next_texture", _sequence_textures[next])
	material.set_shader_parameter("sequence_following_texture", _sequence_textures[following])
	material.set_shader_parameter("sequence_blend", frame - float(current))


func _detect_atlas_grid() -> Vector2i:
	if flipbook_texture == null:
		return Vector2i.ZERO
	var image := flipbook_texture.get_image()
	if image == null or image.is_empty():
		return Vector2i.ZERO
	# Small in-memory analysis only; original pixels/files are preserved.
	if image.is_compressed() and image.decompress() != OK:
		return Vector2i.ZERO
	image.resize(160, 160, Image.INTERPOLATE_NEAREST)
	var columns := PackedInt32Array()
	var rows := PackedInt32Array()
	columns.resize(160)
	rows.resize(160)
	for y in 160:
		for x in 160:
			if image.get_pixel(x, y).a > 0.75:
				columns[x] += 1
				rows[y] += 1
	return Vector2i(_count_alpha_bands(columns), _count_alpha_bands(rows))


func _count_alpha_bands(projection: PackedInt32Array) -> int:
	var peak := 0
	for value in projection:
		peak = maxi(peak, value)
	var threshold := float(peak) * 0.12
	var count := 0
	var run := 0
	for value in projection:
		if float(value) > threshold:
			run += 1
		else:
			if run >= 2:
				count += 1
			run = 0
	if run >= 2:
		count += 1
	return count if count <= 32 else 0


func _set_sheet_visibility(show_spray: bool) -> void:
	for sheet in _sheets:
		sheet.visible = show_spray
