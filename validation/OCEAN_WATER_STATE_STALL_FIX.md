# Runtime water state: falsa caducidad tras un parón

## Diagnóstico confirmado

`RUNTIME WATER STATE` clasifica la cámara respecto a la superficie para activar o ahorrar efectos gráficos. No es el estado de salto, contacto o flotación del vehículo. `AIR_SAFE` significa que la cámara está suficientemente por encima del agua.

En `addons/ocean/underwater/ocean_underwater_medium.gd`, `_update_runtime_water_state()` consideraba caducada cualquier lectura solicitada hace más de 250 ms. El mismo bloque trataba datos realmente inválidos y datos viejos, forzando `TRANSITION` y escribiendo `signed_distance=INVALID` en ambos casos.

Tras un parón del hilo principal no se han renderizado nuevos fotogramas y la GPU no ha tenido oportunidad de publicar otra muestra. Una lectura perfectamente válida sobre un mar plano podía pasar a `INVALID` por tiempo de reloj, sin movimiento ni salto.

`TRANSITION` habilita el raster de waterline y el efecto completo, incluidas burbujas/rayos si están configurados; `AIR_SAFE` mantiene solo el sensor pequeño y la preparación de recursos. El cambio puede añadir trabajo gráfico al reanudar. Las llamadas de estado no modifican las fuerzas del jet ski.

## Reproducción antes de corregir

Godot 4.7.1, D3D12, escena real del jet ski. Ajustes solo en la instancia de prueba: viento 0, escala de ola 0, cámara fija a 2,20 m, vehículo congelado.

Se introdujeron tres pausas de 350 ms en el hilo principal. En las tres:

- `valid=true`, distancia 2,200 m antes y después.
- Cero fotogramas renderizados durante la pausa; mismo número de muestra.
- Antigüedad por reloj entre 356 y 358 ms.
- Se emitió `AIR_SAFE -> TRANSITION | signed_distance=INVALID`, seguido de `TRANSITION -> AIR_SAFE` al llegar nuevas muestras.

Esta reproducción demuestra que el parón puede provocar los logs, aunque el detector geométrico funcione. No prueba que el detector originase el primer parón de la sesión del usuario.

## Corrección aplicada

Solo se modificó el controlador de estados de underwater; no se modificaron FFT, shaders, física, oleaje ni readback asíncrono.

- La caducidad exige antigüedad mayor de 250 ms **y** más de cuatro fotogramas renderizados desde la consulta. Así se permite recuperar la latencia normal de la lectura asíncrona tras una pausa.
- Datos inexistentes, inválidos o sin procedencia utilizable conservan el fallback prudente a `TRANSITION`.
- Una muestra nueva al acercarse o cruzar el agua se procesa inmediatamente; no se añaden cuatro fotogramas de espera a lecturas nuevas.
- Los logs incluyen `reason=surface`, `readback_stale`, `readback_invalid` o `distance_invalid`. Una lectura vieja válida conserva su distancia en el mensaje.
- `get_runtime_feature_state()` publica `readback_valid`, `readback_age_ms` y `readback_stale`, además de la antigüedad en fotogramas.

## Validación

- `ocean_water_state_freshness_validation.gd`: PASS. Pausa sin avance de render, latencia normal, readback realmente bloqueado, datos ausentes, cruce nuevo y dato inválido real.
- `ocean_water_state_stall_probe.gd`: las mismas tres pausas con el sensor GPU real dieron **0 transiciones falsas**, frente a 3 antes.
- `ocean_underwater_visual_profile_runtime.gd`: PASS. Distancias ±0,12 m y efecto visual correctos en los tres perfiles de desplazamiento, incluidos cambios de escala en runtime.
- Conducción adicional durante 15 s sobre agua plana, cámara fija y acelerador activo: 5571 muestras; frame máximo 7,50 ms, p95 4,366 ms, cero pausas >100 ms y ninguna transición falsa durante ese tramo.

La conducción adicional no reprodujo el primer parón comunicado por el usuario. Si persiste, hace falta correlacionar su frame lento con CPU/GPU; los nuevos motivos y edades permiten distinguirlo de un dato geométrico inválido. No se ha ocultado el log ni aumentado un timeout arbitrariamente.

## Reproducción

```text
Godot_v4.7.1-stable_win64_console.exe --headless --path "<proyecto>" --script res://validation/ocean_water_state_freshness_validation.gd
Godot_v4.7.1-stable_win64_console.exe --path "<proyecto>" --rendering-driver d3d12 --script res://validation/ocean_water_state_stall_probe.gd -- --natural-run-seconds=15
```

El grafo MCP no estuvo disponible; las rutas y funciones implicadas se comprobaron directamente en el código local.
