@tool
extends Resource
class_name HullSprayStyle
## Inspector entry on BowSprayRoot. Independent profiles use Bow Spray controls.
@export_group("Splash")
## Activa la generación de Splash laterales durante el juego. La previsualización del perfil se ajusta por separado.
@export var sides_enabled := true:
	set(v): sides_enabled=v; emit_changed()
## Frecuencia de salpicaduras recurrentes al avanzar con contacto mojado. Cero deja solo las respuestas a impactos.
@export_range(0.0,12.0,0.1) var sustained_rate_hz := 6.0:
	set(v): sustained_rate_hz=clampf(v,0.0,12.0); emit_changed()
## Duración visible de cada salpicadura lateral, en segundos.
@export_range(0.12,0.8,0.01) var side_burst_lifetime := 0.30:
	set(v): side_burst_lifetime=clampf(v,0.12,0.8); emit_changed()
## Velocidad mínima del impacto normal contra el agua para disparar un splash por choque.
@export_range(0.2,6.0,0.05) var impact_threshold := 0.75:
	set(v): impact_threshold=v; emit_changed()
## Separación mínima entre respuestas a impactos fuertes. No sustituye la frecuencia de emisión recurrente.
@export_range(0.15,1.5,0.01) var cooldown := 0.45:
	set(v): cooldown=v; emit_changed()
## Retraso entre las respuestas de izquierda y derecha para evitar emisiones perfectamente sincronizadas.
@export_range(0.02,0.3,0.01) var side_delay := 0.14:
	set(v): side_delay=v; emit_changed()
## Fracción de la velocidad horizontal de la moto que hereda una salpicadura al separarse del casco.
@export_range(0.0,1.0,0.05) var side_velocity_inheritance := 0.85:
	set(v): side_velocity_inheritance=v; emit_changed()
## Sideways launch angle above the sea plane; zero is horizontal.
@export_range(0.0,20.0,0.5) var elevation_degrees := 5.0:
	set(v): elevation_degrees=clampf(v,0.0,20.0); emit_changed()
## Perfil visual de los Splash laterales. Sus texturas, animación y materiales son independientes de Bow Spray y Tail Jet.
@export var splash_appearance: Resource = load("res://addons/jet_ski/common/visual/hull_spray/splash_appearance.tres"):
	set(v):
		_disconnect_profile(splash_appearance)
		splash_appearance=v
		_connect_profile(v)
		emit_changed()
@export_group("Tail Jet", "tail_")
## Activa el chorro de cola durante el juego. La previsualización del perfil puede ajustarse de forma independiente.
@export var tail_enabled := true:
	set(v): tail_enabled=v; emit_changed()
## Duración de los restos de agua expulsados después de perder la alimentación de agua de la turbina.
@export_range(0.0,1.0,0.01) var tail_residual_seconds := 0.55:
	set(v): tail_residual_seconds=clampf(v,0.0,1.0); emit_changed()
## Intensidad de los borbotones residuales cuando la turbina deja de estar alimentada por agua.
@export_range(0.0,1.0,0.01) var tail_residual_strength := 0.65:
	set(v): tail_residual_strength=clampf(v,0.0,1.0); emit_changed()
## Selecciona la secuencia de sprites Splash 3 o Splash 4 para el chorro de cola.
@export_enum("Splash 3", "Splash 4") var tail_variant := 0:
	set(v): tail_variant=clampi(v,0,1); emit_changed()
## Rapidez con la que el chorro sigue el balanceo real del casco. Menos valor produce un cambio más lento y progresivo.
@export_range(0.1,20.0,0.1) var tail_turn_response := 5.0:
	set(v): tail_turn_response=clampf(v,0.1,20.0); emit_changed()
## Diámetro vertical del cono respecto a su anchura. Da volumen al chorro sin mover la tobera.
@export_range(0.15,1.5,0.01) var tail_roundness := 0.8:
	set(v): tail_roundness=clampf(v,0.15,1.5); emit_changed()
## Caída vertical del extremo del cono de cola antes de aplicar Spray Scale. No baja la tobera de emisión.
@export_range(0.0,2.0,0.01) var tail_downward_curve := 0.45:
	set(v): tail_downward_curve=clampf(v,0.0,2.0); emit_changed()
## Perfil visual del chorro de cola, independiente de los Splash laterales y del Bow Spray.
@export var tail_appearance: Resource = load("res://addons/jet_ski/common/visual/hull_spray/tail_appearance.tres"):
	set(v):
		_disconnect_profile(tail_appearance)
		tail_appearance=v
		_connect_profile(v)
		emit_changed()

## Franja poco profunda donde el chorro aireado se desvanece bajo el agua. Cero conserva el recorte anterior. No mueve la tobera ni evita la ocultación al sumergir la moto.
@export_range(0.0,0.6,0.01,"suffix:m") var tail_surface_fade_depth_m := 0.25:
	set(v): tail_surface_fade_depth_m=clampf(v,0,0.6); emit_changed()
## Refuerza el núcleo de agua azul del chorro para distinguirlo de la espuma blanca. Conserva la silueta y el color de sus gotas.
@export_range(0.0,1.0,0.01) var tail_water_core_strength := 0.45:
	set(v): tail_water_core_strength=clampf(v,0,1); emit_changed()
@export_group("Stern Mist")
## Perfil independiente de la nube local de popa. Se puede desactivar sin cambiar Bow Spray, Splash ni Tail Jet.
@export var stern_mist: Resource = preload("res://addons/jet_ski/common/visual/hull_spray/stern_mist_style.tres"):
	set(v):
		_disconnect_profile(stern_mist)
		stern_mist=v
		_connect_profile(v)
		emit_changed()

func _init() -> void:
	_connect_profile(splash_appearance)
	_connect_profile(tail_appearance)
	_connect_profile(stern_mist)

func _connect_profile(value: Resource) -> void:
	if value!=null and not value.changed.is_connected(_profile_changed): value.changed.connect(_profile_changed)

func _disconnect_profile(value: Resource) -> void:
	if value!=null and value.changed.is_connected(_profile_changed): value.changed.disconnect(_profile_changed)

func _profile_changed() -> void:
	emit_changed()

# Compatibility for the optional quick panel and existing gate/probes.
# Inspector appearance fields are the single source of truth.
var speed_start: float:
	get: return splash_appearance.speed_start
	set(v): splash_appearance.speed_start=v
var side_opacity: float:
	get: return splash_appearance.spray_opacity
	set(v): splash_appearance.spray_opacity=v
var side_width: float:
	get: return splash_appearance.sheet_width
	set(v): splash_appearance.sheet_width=v
var side_height: float:
	get: return splash_appearance.sheet_height
	set(v): splash_appearance.sheet_height=v
var side_fps: float:
	get: return splash_appearance.anim_fps
	set(v): splash_appearance.anim_fps=v
var tail_opacity: float:
	get: return tail_appearance.spray_opacity
	set(v): tail_appearance.spray_opacity=v
var tail_length: float:
	get: return tail_appearance.sheet_length
	set(v): tail_appearance.sheet_length=v
var tail_width: float:
	get: return tail_appearance.sheet_width
	set(v): tail_appearance.sheet_width=v
var tail_height: float:
	get: return tail_appearance.sheet_height
	set(v): tail_appearance.sheet_height=v
var tail_fps: float:
	get: return tail_appearance.anim_fps
	set(v): tail_appearance.anim_fps=v
