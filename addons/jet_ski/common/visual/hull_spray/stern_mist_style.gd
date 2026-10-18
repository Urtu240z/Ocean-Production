@tool
extends Resource
class_name SternMistStyle
## Short world-space mist, separate from the nozzle jet and Ocean foam.
@export_group("General")
## Activa neblina al avanzar con contacto mojado, también sin gas. No genera niebla en reposo ni durante un salto.
@export var enabled := true:
	set(v): enabled=v; emit_changed()
## Solo emisores antiguos generados. En la escena actual, edita Amount en el nodo SternMist.
@export_range(8,1000,1) var amount := 28:
	set(v): amount=clampi(v,8,1000); emit_changed()
## Solo emisores antiguos generados. En SternMist, edita Process Material → Color/Color Ramp y el material del Draw Pass.
@export var color := Color(0.66,0.80,0.86,1):
	set(v): color=v; emit_changed()
## Solo emisores antiguos generados. En SternMist, el alfa de Color Ramp y el material del Draw Pass controlan la opacidad.
@export_range(0.0,0.8,0.01) var opacity := 0.28:
	set(v): opacity=clampf(v,0.0,0.8); emit_changed()
@export_group("Shape and Motion")
## Desplazamiento de la neblina: X lateral y Z atrás desde la tobera; Y es la altura sobre el agua o la tobera, lo que esté más alto. Solo mueve la nube, nunca el chorro.
@export var offset := Vector3(0,0.20,0.30):
	set(v): offset=v; emit_changed()
## Solo emisores antiguos: ancho de emisión. En SternMist, edita Process Material → Emission Box Extents.
@export_range(0.2,3.0,0.05,"suffix:m") var width_m := 1.25:
	set(v): width_m=clampf(v,0.2,3.0); emit_changed()
## Solo emisores antiguos: longitud de emisión. Las partículas emitidas permanecen en el mundo.
@export_range(0.2,3.0,0.05,"suffix:m") var length_m := 1.35:
	set(v): length_m=clampf(v,0.2,3.0); emit_changed()
## Conservado por compatibilidad. Edita la altura de emisión en Process Material → Emission Box Extents.
@export_range(0.1,1.5,0.05,"suffix:m") var height_m := 0.55:
	set(v): height_m=clampf(v,0.1,1.5); emit_changed()
## Solo emisores antiguos. En la escena actual, edita Lifetime en el nodo SternMist (0,5 s).
@export_range(0.15,0.9,0.01,"suffix:s") var lifetime_s := 0.5:
	set(v): lifetime_s=clampf(v,0.15,0.9); emit_changed()
## Solo emisores antiguos generados. En SternMist, edita Turbulence del Process Material y del material del Draw Pass.
@export_range(0.0,2.0,0.05) var turbulence := 1.0:
	set(v): turbulence=clampf(v,0.0,2.0); emit_changed()
@export_group("Speed Response")
## Velocidad a la que empieza la neblina. Necesita contacto real con el agua, también funciona al soltar el gas.
@export_range(0.0,60.0,0.5,"suffix:km/h") var start_speed_kmh := 6.0:
	set(v): start_speed_kmh=maxf(v,0); emit_changed()
## Velocidad a la que la neblina alcanza la intensidad elegida.
@export_range(1.0,120.0,0.5,"suffix:km/h") var full_speed_kmh := 35.0:
	set(v): full_speed_kmh=maxf(v,1); emit_changed()
@export_group("Editor Preview")
## Muestra la neblina en el editor sin gas ni contactos de físicas. Usa Preview Speed Kmh.
@export var preview_in_editor := false:
	set(v): preview_in_editor=v; emit_changed()
## Velocidad simulada, solo para la previsualización en el editor.
@export_range(0.0,120.0,1.0,"suffix:km/h") var preview_speed_kmh := 50.0:
	set(v): preview_speed_kmh=maxf(v,0); emit_changed()
