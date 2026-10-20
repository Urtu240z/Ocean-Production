# Diagnóstico temporal de FPS — Ocean Production, 081dd40

Fecha: 19 de octubre de 2026. Diagnóstico realizado; **no se ha aplicado ninguna optimización**.

Las caídas tienen tres contribuciones distintas: dibujo del agua, construcción CPU de los estados locales y picos de transparencia del **Stern Mist** al desplazarse. Planar no está activo en la escena guardada. No hay evidencia de una multiplicación de sincronizaciones o construcciones por contacto.

## Procedencia y límites

- Código medido: `081dd40fd8fcefb585a634c09652ec8bd72fafed`, en la copia aislada `codex/local-sea-performance`. Su único cambio de producción durante la medición es un enlace opcional de tres líneas al temporizador existente del controlador, sin modificar consultas ni fuerzas.
- Escena: instantánea de `validation/hull_wave_physics_playground.tscn` guardada actualmente por el usuario. SHA-256: `5d567d441ef48973d8ac49812b2348b6f457865db7b90f1559bc7deaf2b603f3`.
- **El commit por sí solo contiene una sola área.** La segunda área y sus valores actuales son cambios locales posteriores. Para reproducir la escena de dos áreas se usó esa instantánea con el código de `081dd40`; no se sustituyó la escena original ni se incorporaron las correcciones locales pendientes de tsunami/caustics/waterline a esa copia.
- Godot 4.7.1, D3D12 Forward+, RTX 4070 Laptop GPU. Prueba principal: viewport medido de **1920×1080**, VSync desactivado, límite guardado de 144 FPS, física a 60 Hz. Ninguna resolución FFT se ha reducido: campos CPU **128/128/128** y configuración GPU original.
- El usuario juega incrustado en Godot. Se midió el **contenido de la escena real en una única instancia**, sin editor abierto. 1920×1080 es un tamaño de diagnóstico explícito, no una resolución confirmada del panel incrustado. El coste adicional del editor y la presentación incrustada **no están medidos**. No se atribuye a este diagnóstico una reproducción exacta de ese anfitrión.

## Método

Prueba principal: 16.520 fotogramas y 10.576 ticks registrados, dos pasadas con orden inverso, 20 s de calentamiento global, 2,5 s de asentamiento por caso y 4 s medidos por posición/cámara. Recorridos adicionales de 14 y 26 s, a 20 m/s.

El controlador de diagnóstico fija únicamente la trayectoria horizontal. Conserva movimiento vertical, velocidad vertical, orientación y respuesta a las olas de la moto; no cambia su implementación física. La cámara mantiene una orientación mundial estable o gira sobre su propio eje, separadamente del desplazamiento. Se mide una trayectoria de planeo controlada, no una reproducción exacta de acelerador y dirección de una sesión manual.

Posiciones X/Z, en metros:

| Caso | X | Z | Acción |
|---|---:|---:|---|
| Exterior | 260 | −63 | Quieto / giro de cámara |
| Interior slot 0 | 35 | −100 | Quieto / giro de cámara |
| Feather slot 0 | 120 | −63 | Quieto / giro de cámara |
| Solapamiento | −5 | −310 | Quieto / giro de cámara |
| Interior slot 1 | −5 | −435 | Quieto / giro de cámara |
| Feather slot 1 | 120 | −435 | Quieto / giro de cámara |
| Recorrido X | 210 → −70 | −140 | Cámara sin giro |
| Recorrido Z | 35 | 90 → −430 | Cámara sin giro |

Se conservan los feather de 145,5 y 108,3 m y la influencia 0,6 del segundo estado. Aunque las cajas están separadas, sus zonas suavizadas sí se solapan. Los recorridos no cruzan el radio de 500 m guardado para el tsunami.

Un control inicial estaba sobre la rampa de Z≈−67,6. La captura mostró que ocultaba el agua. **Ese punto y los recorridos iniciales con altura/actitud forzadas se excluyeron de los resultados principales.** Sus archivos quedan como controles auxiliares, no como prueba de que un mar tranquilo cueste menos.

### Interpretación de tiempos

- **WALL:** intervalo entre límites `process_frame`; contiene la física actual y la cola de proceso/render del fotograma anterior. FPS es fotogramas / tiempo transcurrido, no el inverso de la mediana de WALL.
- **CPU física:** span existente de `_integrate_forces`, agregado por tick y frame; aparte, ventana de callbacks de física entre `physics_frame` y un nodo de prioridad final. Esta última no incluye todo PhysicsServer. No se presenta como duración total del tick.
- `TIME_PROCESS` y `TIME_PHYSICS_PROCESS` se conservan como monitores distintos. Son máximos publicados por el motor aproximadamente cada segundo; repetir su lectura en cada frame no crea mediciones nuevas. **TIME_PROCESS no es física.** Véase la [implementación del bucle principal de Godot](https://github.com/godotengine/godot/blob/master/main/main.cpp).
- `controller.integrate`, `get_runtime`, `synchronize`, `apply`, `sample` y construcción de campos son spans inclusivos anidados. **No se suman.** CPU y GPU tampoco se suman para predecir FPS.
- GPU: timestamps de los FFT locales, tiempo medido del viewport y etapas del renderer. Un marcador por frame enlaza el frame RD completado con su process frame y tick originales. Las etapas GPU usan la diferencia al siguiente timestamp, como el [perfilador del renderer](https://github.com/godotengine/godot/blob/master/servers/rendering/rendering_server_default.cpp).
- El CSV distingue CPU del frame actual y GPU/proceso del draw anterior. La clasificación underwater usa el estado realmente publicado por el manager, conservando el readback asíncrono original; no fuerza una lectura síncrona.
- No se añadieron cronómetros por contacto. Serialización, capturas y extracción del historial nativo se realizan fuera de las ventanas medidas.

## Tres responsables medidos

| Responsable | Coste observado | Aislamiento / evidencia |
|---|---|---|
| **Stern Mist: transparencia durante el movimiento** | En recorrido Z, pasada transparente p95 **14,55–17,32 ms** con todo activo; **5,94 ms** ocultando únicamente los dos Stern Mist | El control conserva agua, FFT, emisiones y física; solo impide su dibujo. Diferencia de p95: **8,60–11,37 ms**, no un cronómetro exclusivo del shader de niebla |
| **Dibujo del agua visible** | Quieto: p50 **3,16 ms** en slot 0, **5,48 ms** en solapamiento y **5,57 ms** en slot 1 | Ocultando únicamente la superficie, la pasada transparente quieta queda en **0,004 ms**. El resto de productores y underwater siguen activos |
| **Campos CPU locales** | Un slot: **1,19–1,21 ms/tick**; solapamiento: **2,38 ms/tick**, p95 **2,71–3,19 ms** para la suma de ambas construcciones | Una construcción real por slot afectado y tick; ninguna fuera de influencia. Conserva las tres bandas 128/128/128 y la consulta original |

Estas filas combinan costes de GPU/frame y CPU/tick. **No son tres sumandos de una misma duración.** Las diferencias entre cuantiles de controles independientes no representan un tiempo exclusivo exacto ni una ganancia prometida.

### Stern Mist: comprobación independiente

Los valores realmente encontrados son **250 partículas por emisor**, dos emisores, lifetime **0,65 s**, `fixed_fps=0`, coordenadas de mundo. No se asumieron 1.000 partículas ni se cambiaron esos valores.

| Recorrido Z | FPS | GPU viewport p50 / p95 | Transparencias p50 / p95 |
|---|---:|---:|---:|
| Todo activo, pasada 0 | 69,44 | 10,19 / 17,77 ms | 7,20 / 14,55 ms |
| Todo activo, pasada 1 | 66,88 | 9,93 / 20,90 ms | 6,41 / 17,32 ms |
| Solo Stern Mist oculto | 93,02 | 7,41 / 9,35 ms | 4,36 / 5,94 ms |
| Todo BowSprayRoot oculto | 98,19 | 6,19 / 8,24 ms | 3,10 / 5,20 ms |
| Solo agua oculta | 95,12 | 3,52 / 15,07 ms | 0,22 / 11,84 ms |

El control sin agua todavía tiene picos grandes. El control sin los dos Mist elimina gran parte de esos picos. Ocultar todo el conjunto de spray mejora algo más: **la niebla explica la mayor parte del exceso, no necesariamente todo el VFX**. Los controles no son fases idénticas píxel a píxel; no se restan sus FPS para calcular una aceleración.

El shader de Stern Mist declara `depth_test_disabled` y calcula ruido, máscara y relieve antes de producir el alpha final. Esto es evidencia de código compatible con coste de fragmentos superpuestos; **el número exacto de capas de overdraw no se ha medido con contadores de hardware**.

## FPS y posición / cámara

Primera pasada de la prueba principal; segunda pasada resumida por FPS. WALL y GPU son tiempos independientes.

| Caso | FPS, pasadas 0 / 1 | WALL p50 / p95, pasada 0 | GPU viewport p50 / p95, pasada 0 |
|---|---:|---:|---:|
| Exterior, sin giro | 116,35 / 124,34 | 9,24 / 12,97 ms | 6,58 / 7,00 ms |
| Interior 0, sin giro | 106,41 / 109,89 | 10,40 / 14,10 ms | 6,37 / 6,57 ms |
| Interior 0, giro | 109,62 / 112,87 | 10,46 / 13,85 ms | 5,90 / 6,54 ms |
| Feather 0, sin giro | 104,33 / 109,12 | 10,55 / 14,56 ms | 6,69 / 7,06 ms |
| Solapamiento, sin giro | 86,90 / 87,48 | 12,00 / 17,96 ms | 8,70 / 9,21 ms |
| Solapamiento, giro | 93,23 / 90,40 | 11,85 / 17,14 ms | 7,58 / 8,62 ms |
| Interior 1, sin giro | 96,95 / 97,12 | 10,39 / 16,37 ms | 8,54 / 9,34 ms |
| Interior 1, giro | 95,15 / 98,83 | 10,50 / 17,23 ms | 8,40 / 10,33 ms |
| Feather 1, sin giro | 101,00 / 99,13 | 10,31 / 15,38 ms | 7,71 / 8,15 ms |
| Recorrido X | 106,11 / 104,48 | 10,75 / 14,10 ms | 6,20 / 6,87 ms |
| Recorrido Z, prueba prolongada | 69,44 / 66,88 | 15,14 / 22,29 ms | 10,19 / 17,77 ms |

Se reproduce la banda de ~100–110 y la caída a ~87 en solapamiento. El recorrido prolongado a 72 km/h es un caso de estrés más severo que el rango comunicado por el usuario. Girar la cámara no equivale a mover la moto: cambia la cobertura del agua y los VFX visibles aunque los contactos estén en la misma zona.

## Contadores y correlación temporal

| Posición quieta | Contactos afectados slot 0 / 1 | Builds/tick slot 0 / 1 | Campos CPU p50 / p95 | Query nativa local p50 |
|---|---:|---:|---:|---:|
| Exterior | 0 / 0 | 0 / 0 | 0 / 0 ms | 0 ms |
| Interior 0 | 14 / 0 | 1 / 0 | 1,189 / 1,393 ms | 0,121 ms |
| Solapamiento | 14 / 14 | 1 / 1 | 2,381 / 2,705 ms | 0,225 ms |
| Interior 1 | 0 / 13–14 | 0 / 1 | 1,209 / 1,403 ms | 0,115 ms |

`synchronize` alcanza como máximo **una llamada por tick** en estos controles. En el solapamiento cuesta ~0,75 ms/tick p50. `apply` cuesta ~2,89 ms/tick p50, **incluyendo** campos, consultas y composición. El controlador completo cuesta ~8,52 ms/tick p50 en ese caso, **incluyendo** esas operaciones; no es un coste adicional de 8,52 ms.

En la primera parada de solapamiento, frames sin build local tienen WALL p50/p95 **4,82 / 5,29 ms**; frames con dos builds tienen **12,64 / 18,10 ms**. Esa diferencia también contiene el resto del tick físico y el pipeline de render: no se atribuyen sus 7,82 ms completos al FFT.

En ambos recorridos Z, agrupando por GPU transparente del draw anterior y conservando los contadores del frame:

| GPU transparente previa | Frames | WALL p50 / p95 | Controlador CPU p50 | Builds locales p50 |
|---|---:|---:|---:|---:|
| <4 ms | 592 | 12,05 / 16,94 ms | 7,38 ms | 1 |
| 4–8 ms | 1.273 | 12,56 / 17,81 ms | 6,91 ms | 1 |
| ≥12 ms | 1.163 | 18,08 / 29,01 ms | 7,67 ms | 1 |

La caída prolongada se correlaciona con transparencias altas, sin un aumento equivalente de construcciones ni del controlador CPU. Los controles de Mist y spray aportan la intervención independiente que falta en una simple correlación de FPS.

### Composición local, otros costes y descartes

El control de fragmento conserva geometría, FFT y física, pero sustituye únicamente la composición de normales locales por la normal base **en un shader privado en memoria**. Secuencia y cámara iguales para ambos controles:

| Caso | Transparente completa p50 | Control sin composición local p50 | Diferencia de medianas |
|---|---:|---:|---:|
| Solapamiento, sin giro | 4,962 ms | 4,489 ms | 0,473 ms |
| Solapamiento, giro | 3,906 ms | 3,453 ms | 0,453 ms |
| Interior 1, sin giro | 5,485 ms | 5,222 ms | 0,262 ms |
| Interior 1, giro | 5,330 ms | 4,998 ms | 0,332 ms |

Es el coste incremental del control sobre la pasada real, **no un timestamp exclusivo de `wave_areas_compose()`**: cambian las normales resultantes y puede cambiar trabajo posterior. La composición local es medible, pero estos datos no explican por sí solos los picos de 12–17 ms.

- FFT GPU locales: ~0,29–0,32 ms por slot y despacho, ambos activos también fuera de las áreas. Se registran por separado del viewport; su coste no presenta el salto espacial de los campos CPU.
- Underwater post-transparente: ~0,039–0,043 ms en `AIR_SAFE`; ~0,27–0,34 ms en `TRANSITION`. En los escasos frames `UNDERWATER_SAFE` del recorrido aparece ~1,80 ms. No explica las transparencias ≥12 ms que también aparecen en `AIR_SAFE`.
- Foam2D compute: ~0,02–0,03 ms; HullWaves compute del recorrido: ~0,055 ms p50 y ~0,13 ms p95. Esos productores medidos no explican el pico completo de la pasada transparente. Esto no mide por separado cada operación de espuma dentro del material de agua.
- **Planar: 0 capturas y 0 ms atribuibles**; no hay instancia activa. El perfil guardado es `SCREEN_SPACE`. No se activó Planar para fabricar una comparación. El enlace opcional para registrar CPU/capturas queda disponible si posteriormente se selecciona ese método.

## Propuesta de optimización, todavía sin aplicar

1. **Stern Mist primero para los picos en movimiento.** Reordenar el shader para descartar fragmentos cuyo alpha sea exactamente cero antes del relieve/iluminación costosos; usar primero los factores independientes del ruido cuando permiten demostrar cero. Mantener las 250+250 partículas, tamaño, lifetime, rampas, normal map y soft-depth actuales. No activar depth test ni introducir umbrales de alpha sin una prueba visual de paridad. Después medir cobertura/overdraw con un capturador GPU para identificar el resto del coste de spray.
2. **Agua para el coste sostenido.** Perfilar bloques del material real y ensayar eliminación de cálculos redundantes / selección conservadora por regiones de pantalla. Conservar las muestras y el orden de composición de los slots, la derivada de feather y las pendientes desplazadas. Un prepass de profundidad sería un experimento separado que necesita comprobar transparencia, refacción, estela y underwater; no se da por equivalente ni por más rápido.
3. **Campos CPU para el solapamiento.** Ensayar construcción nativa en batch o paralela de los dos estados independientes, con la misma hora de simulación y una barrera antes de consultar. Mantener 128/128/128, la misma inversión horizontal y las cinco posiciones de pendiente. No sustituir por normales FFT directas ni mover la fase temporal para ocultar el coste.

Antes de aceptar cualquiera: repetir esta matriz y comparar HEIGHT, NORMAL, VY, signed_depth, feather, solapamiento, grandes chop, cámara submarina y estela. No se promete una ganancia antes de implementar y validar esas propuestas. El FFT exterior, la física del jetski, Planar, tsunami y los presets quedan fuera de los cambios de comportamiento.

## Archivos y reproducción

- `validation/real_scene_temporal_profile.gd`: registrador y controles opt-in; `--mode=full` es el modo normal del diagnóstico.
- `validation/real_scene_profile_end.gd`: límites finales de callbacks.
- `validation/real_scene_profile_analyze.py`: distribuciones, etapas GPU y CSV con las relaciones frame/tick explícitas.
- `validation/reports/real_scene_fps_081dd40_summary.json`: resumen numérico de la prueba principal.
- `temp/real_scene_profile/commit081_buoyant1920.json` y `commit081_buoyant1920_timeline.csv`: captura principal completa y línea temporal; `scene_snapshot.tscn` conserva la escena medida. Datos temporales locales, excluidos de Git.
- Controles: JSON `commit081_buoyant_water_control`, `commit081_buoyant_travel_water_control`, `commit081_buoyant_travel_spray_control`, `commit081_buoyant_travel_mist_control`, `commit081_buoyant_fragment_control` y `commit081_buoyant_components_full`, en esa carpeta temporal.

Ejemplo, desde una copia de `081dd40` con el registrador, el enlace de diagnóstico y la instantánea:

```text
Godot_v4.7.1-stable_win64_console.exe --path . --gpu-profile --script res://validation/real_scene_temporal_profile.gd -- --scene=res://temp/real_scene_profile/scene_snapshot.tscn --resolution=1920x1080 --warmup=20 --seconds=4 --repeats=2 --label=repeat
```

Los controles que ocultan dibujo o sustituyen normales solo existen dentro del registrador y terminan al cerrar su instancia. No son optimizaciones aplicadas al juego. La instrumentación de producción queda desactivada por defecto. La escena original conserva el SHA-256 indicado; no se guardó ningún preset ni se cambió la rama o el commit del proyecto principal.
