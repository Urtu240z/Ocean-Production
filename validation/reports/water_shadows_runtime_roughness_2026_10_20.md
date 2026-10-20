# Sombras del mar y Roughness en Hull Foam — 2026-10-20

## Corrección de Roughness

`hull_wave_physics_playground` carga `validation/profiles/p0_reflection_profile.tres`
con Base Roughness 1. El valor no se perdía: Hull Foam reconstruía las variantes
desde `foam2d/references/original/ocean_surface.gdshader.source`, anterior al
marcador que aplica Roughness al material. El uniform estaba enlazado, pero no
participaba en la asignación de ROUGHNESS. La prueba inicial de uniforms, por sí
sola, no detectaba este fallo.

La composición añade el marcador a las fuentes antiguas antes de expandir
Optics. Conserva el orden Optics/TIR → rugosidad del agua → espuma y mantiene
las fuentes de referencia intactas. No cambia el perfil guardado del usuario.
Antes de corregirlo fallaron seis comprobaciones del shader activo; después
pasan, y las capturas de agua con Roughness 0 y 1 son diferentes.

## Sombras

`Ocean → Surface → Cast Shadows` controla la proyección de toda la superficie,
con actualización en editor y juego. Está activado para comparar en P0, escena
que hereda Hull Wave Physics Playground. El addon conserva el valor OFF por
defecto. Con OFF, el tsunami puede seguir proyectando su cresta mediante
`BoundaryTsunami → Rendering → Cast Shadows` (ON por defecto).

Un material de profundidad comparte los buffers y transformaciones del clipmap;
solo dibuja en mapas de sombras. Incluye deformación FFT, áreas, tsunami y la
fuente de vértices de Hull Foam. En modo tsunami descarta agua plana y valle.
En modo mar proyecta toda la superficie, también sobre objetos sumergidos.
Se reutilizan las mismas instancias para ambos modos. Se ocultan cuando no
queda ningún modo activo. Requiere luces con sombras y distancia suficiente.
No se ha medido el coste GPU ni se promete una mejora de rendimiento.

## Comprobaciones

Godot 4.7.1, Forward+, D3D12, Windows:

- `production_reflection_state_runtime.gd`, escena real de Hull: salida 0.
  Perfil guardado 1; valores 0/0.08/0.25/0.5/1 conservados; Reflections OFF/ON,
  variantes Optics y cambio SSPR/Planar; asignación presente en shader activo;
  efecto en imagen y fuente de sombras con deformación Hull Foam.
- `tsunami_shadow_runtime.gd`: salida 0. Diez casters comparten mallas;
  99 352 píxeles del receptor oscurecidos por la cresta y 268 464 por el mar.
  Activación/desactivación en vivo, fin del evento, sin asignación antes del
  evento y muestras/buffer físico del tsunami exactamente iguales.
- `tsunami_render_check.gd`: salida 0, error CPU 0 m y alineación de waterline
  0.00000381469727 m.
- TestAddons, `release_smoke.gd --complete`: salida 0 tras sincronizar el addon.
- `tsunami_boundary_check.gd`: cuatro fallos `inside radius ignores altitude`.
  Repetidos exactamente usando el controlador de HEAD anterior a estos cambios.
  No se modifica la lógica física para arreglar un fallo ajeno a esta tarea.
- La escena Hull emite un aviso preexistente de UID de `default_style.tres` y
  resuelve correctamente por ruta. No hay errores de shader en las pruebas.

Capturas y logs: `temp/tsunami_shadow/`. Comparativas principales:
`hull_no_foam_1_before_fix.png`,
`hull_wave_physics_playground_no_foam_roughness_0.png`,
`hull_wave_physics_playground_no_foam_roughness_1.png`,
`wave_without_shadow.png`, `wave_with_shadow.png` y
`hull_wave_physics_playground_shadow_false.png` / `shadow_true.png`.

Los nueve archivos del addon se sincronizan con TestAddons tras confirmar que
su contenido anterior coincide exactamente con HEAD. Los ZIP no se regeneran.
No se toca C++, bibliotecas nativas, parámetros físicos ni los cambios locales
del usuario en Hull Wave Physics Playground o su perfil de reflejos.
