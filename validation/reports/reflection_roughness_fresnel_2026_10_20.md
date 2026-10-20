# Base Roughness y Fresnel — 2026-10-20

Trabajo directo en master, partiendo de `44a0900d3ed252abbf083475abfd257d78c57f20`,
con árbol limpio y fetch de origin. Sin ramas, worktrees ni checkpoints nuevos.
No se cambia física, C++, configuración guardada, Optics ni fórmulas Snell/TIR.
No se regeneran ZIPs.

## Corrección

Antes, `base_roughness` sólo intervenía en el filtro de distancia y el material
seguía empezando con `water_base_roughness = 0.08`.

Ahora la variante con Reflections aplica `reflection_base_roughness` al
ROUGHNESS del material **después de Optics y antes de las mezclas de espuma**.
Esto conserva la entrada anterior de la composición Snell/TIR y permite que
la espuma siga aportando su rugosidad propia. Rango 0–1; predeterminado 0.08.
Con Reflections OFF no se inserta esa asignación y queda el material anterior.

Distance Roughness es independiente: añade rugosidad al filtro lejano, no al
material PBR. Valor inicial 0.15, equivalente al incremento anterior por defecto
`0.23 - 0.08`; Roughness Distance M conserva su intervalo existente. No se editan
presets para introducir o compensar estos nuevos valores.

## Fresnel

- **Fresnel Strength**, 0–2, inicial 1: escala la radiancia capturada SSPR/Planar.
  No apaga los brillos directos ni el entorno PBR de respaldo donde falta captura.
- **Fresnel Power**, 0.1–10, inicial 5: controla la respuesta angular relativa a
  una referencia Schlick con el F0 del SPECULAR efectivo del material. Mayor valor
  concentra el aporte hacia ángulos rasantes; menor lo extiende hacia el cenit.
- Se aplica **curva ajustada / curva de referencia**, no otra multiplicación
  por Schlick. Godot conserva su BRDF PBR y su respuesta integrada con rugosidad.
  No se promete reemplazar esa BRDF por una potencia pura. Power 5 devuelve
  directamente Strength, dando identidad exacta con los valores 1/5.
- No se modifica la confianza/alpha del RADIANCE ni la composición Optics/TIR.
  La nueva asignación de rugosidad se coloca después de ese bloque precisamente
  para conservar su entrada y su fórmula anteriores.

Contrato del motor: [RADIANCE, Godot 4.7](https://docs.godotengine.org/en/4.7/tutorials/shaders/shader_reference/spatial_shader.html#fragment-built-ins).
El ajuste modifica radiancia antes de la iluminación PBR. No añade pasadas de render.

## Validación

Godot 4.7.1, Windows x86_64, Forward+, D3D12, RTX 4070 Laptop.

| Prueba | Resultado |
|---|---|
| Base 0.00 / 0.08 / 0.25 / 0.50 / 1.00 | PASS: 80 combinaciones SSPR/Planar × Kawase OFF/ON × espuma OFF/ON × Optics OFF/ON |
| Fresnel cenital/oblicuo/rasante | PASS: 216 casos, Power 2/5/8 y Strength 0/1/2, ambos métodos, Kawase OFF/ON y ambos estados iniciales de espuma |
| Cambios en caliente | PASS: 414 señales Resource.changed y bindings comprobados; mismos setters que usa el Inspector; incluye cambios de método y variantes Optics |
| Aspecto neutro | PASS: imágenes nuevas y fragmento anterior iguales píxel a píxel, en SSPR y Planar, con/sin espuma |
| Reflections OFF | PASS: imágenes iguales píxel a píxel pese a valores no neutros; shader sin modificaciones funcionales |
| Rugosidad material real | PASS GPU: emisión diagnóstica de ROUGHNESS distingue bases 0 y 1 |
| Rugosidad de espuma | PASS GPU: cobertura forzada completa conserva la misma imagen con rugosidad propia 0.77 para bases 0 y 1 |
| Preset anterior | PASS: recurso serializado existente hereda Strength 1, Power 5 y Distance Roughness 0.15 |
| Regresión de variantes | `P5_VARIANT_BINDING_PASS`, 40 cambios de Optics |
| Planar | `PLANAR_SURFACE_PASS`, `PLANAR_OFFSCREEN_PASS`, `PLANAR_LIFECYCLE_PASS` |
| Kawase | `KAWASE_GPU_PASS`, bypass y preservación de radiancia HDR |
| TestAddons | Importación y smoke de la demo completos, salida 0 y sin errores |
| Exportación TestAddons | PCK v4, 622 entradas verificadas, descriptor/DLL correctos; ejecutable arranca 300 frames sin errores |

Las ejecuciones finales listadas terminan con salida 0 y sin errores de shader,
parseo, ejecución o fugas reportadas. Se revisaron capturas de rugosidad y Fresnel.
La ruta del editor también conecta `reflection_profile.changed` con el refresco
del material de preview. No se afirma haber arrastrado manualmente sliders con
automatización de interfaz; se ejercitan sus setters/señales y render reales.

La comparación neutra usa el fragmento del Git anterior, no una fórmula recreada.
El diagnóstico de espuma fuerza cobertura completa para evitar una comprobación
vacía sin espuma visible. Todas las configuraciones de la fixture son en memoria;
las escenas y parámetros guardados de producción permanecen intactos.

### Incidencia anterior fuera de este cambio

Conmutar repetidamente el interruptor global **Crest Foam** produjo avisos
`Attempted to free invalid ID` en `_publish_crest_textures`. Se reprodujo en el
OceanOnly del release anterior, sin estos cambios: cuatro avisos en el probe.
No se atribuyen a Roughness/Fresnel ni se ocultan como pruebas pasadas.

La matriz final arranca una vez con espuma OFF y otra con espuma ON, sin
reasignar sus recursos FFT en caliente. Sus 80 combinaciones y 216 casos angulares
no generan esos errores. Los controles Roughness/Fresnel sí se cambian en caliente.
El ciclo de liberación de recursos de Crest Foam queda **pendiente**, fuera de
esta corrección; no se modificó para ampliar el alcance de la tarea.

## Capturas y reproducción

Capturas y resultados locales:
`C:/Users/ehort/Documents/GODOT PROJECTS/Water Race Ocean Production/temp/reflection_fix/`.

- `foam_off/` y `foam_on/`: `results.json`, comparaciones de los cinco valores,
  ángulos y potencias, imágenes neutras contra el original y diagnósticos GPU.
- `roughness_m1_k1_0.00.png` / `roughness_m1_k1_1.00.png` en `foam_off/`:
  comparación de rugosidad Planar con Kawase y Planar Roughness Blur activos.
- `fresnel_m1_k1_oblique_p2.png` / `fresnel_m1_k1_oblique_p8.png` en `foam_off/`:
  comparación angular manteniendo Strength 1.
- `baseline_foam.*.log`: reproducción independiente del aviso anterior.
- Los logs `matrix_foam_*`, `p5_reflections_runtime_validation`,
  `ocean_planar_reflection_runtime`, `ocean_reflection_kawase_runtime`,
  `testaddons_*`, `export*` contienen la evidencia final.
- `export_audit.json` y `export_windows/` corresponden únicamente a una
  comprobación de exportación, no a nuevos ZIPs del addon.

Para repetir, guardar primero el blob
`44a0900:addons/ocean/surface/ocean_clipmap_surface.gd` como
`temp/reflection_fix/baseline_clipmap.gd.txt`. Ejecutar
`validation/reflection_roughness_fresnel_runtime.gd` con render Forward+ una vez
sin argumentos y otra con `-- --foam-on`. El resto son las regresiones existentes.

Planar no tiene mipmaps. **Kawase ON y Planar Roughness Blur ON** permiten el
desenfoque dependiente de rugosidad. Kawase solo proporciona desenfoque uniforme;
sin Kawase la captura permanece nítida aunque cambie el material PBR.

## Production y TestAddons

Se sincronizan únicamente el perfil, el shader base, OceanClipmapSurface y la
documentación de reflejos con:

`C:/Users/ehort/Documents/GODOT PROJECTS/WaterRace_Addons_Release_2026-10-20/TestAddons/`.

Se comprobó que esos cuatro archivos de TestAddons coincidían con el release
anterior antes de copiarlos, para preservar posibles cambios locales.
Los tres ZIP, sus hashes y el manifiesto original del release permanecen intactos:
ese manifiesto describe los ZIP originales, no la copia TestAddons parcheada.
No se toca OceanOnly, salvo ejecutarlo como referencia del fallo anterior.

El grafo MCP no estuvo disponible; se verificaron las rutas y fuentes directamente.
El commit de cierre usa el mensaje solicitado y se publica directamente en master.
