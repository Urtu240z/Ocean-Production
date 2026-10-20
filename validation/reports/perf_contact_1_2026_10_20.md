# PERF-CONTACT-1 — Consultas y contactos del océano

20 de octubre de 2026 · rama actual `codex/async-fft-lite-workers` · referencia de código `2dfe1f6`.

## Resultado y parada

**Conservar el cambio pequeño y detenerse.** La única modificación de producción adelanta la comprobación de “comparación de backends desactivada” en `sample_comparison_water()`. Evita validar el océano para una función que va a devolver una muestra vacía. No elimina ninguna consulta física, punto de flotabilidad ni evaluación de fuerzas.

Con seis motos se eliminan **78 validaciones por tick** en ese camino. En cuatro pasadas sin contadores adicionales, el controlador reduce su media agregada de **8.705 a 8.245 ms/tick**, un ahorro observado de **0.461 ms** (unos 0.077 ms por vehículo como promedio del total).

**No hay mejora demostrada de estabilidad:** los p99 de controlador, física completa observada y frame empeoran en el agregado. No se atribuye el pequeño cambio de FPS al guard ni se intenta alcanzar 3–5 ms con más modificaciones. La estimación diagnóstica previa de 0,666 ms era instrumentada; no se presenta como ahorro real conseguido.

## 1. Auditoría del recorrido actual

Se verificaron directamente proveedor, contexto, Ocean, controlador, sistema de agua y runtime de áreas. Se intentaron primero `list_projects`, `search_graph` y `check_index_coverage`; los tres devolvieron **Transport closed**. Por eso esta auditoría se basa en lectura del código actual y búsquedas acotadas, sin afirmar cobertura exhaustiva del grafo.

El recorrido sigue siendo:

`_integrate_forces → select_consumer → prepare_water_queries → begin_gameplay_contacts → sample_water_batch → caché del consumidor → water_physics_system.step → sample_water por contacto`.

Cada `sample_water()` llama a `_is_water_source_current()` **antes** de buscar la muestra precalculada. Esa validación lee `get_physics_source_state()`, obtiene dos Dictionary de metadatos, construye una cadena de versión y comprueba fuente/espectro/espacio. Una lectura cacheada no vuelve a evaluar el campo FFT, pero sí paga esa administración.

Además, el sistema de física invoca `sample_comparison_water()` aunque la comparación esté desactivada. El orden anterior volvía a validar la fuente antes de comprobar ese interruptor. Ese es el único trabajo eliminado.

### Evidencia disponible antes del cambio

Las capturas anteriores tenían desactivado el registro nativo PERF2: `native.frames=[]`. Conservaban spans de áreas y el span externo del controlador, pero **no permitían aislar validaciones, recuperación de caché o construcción de cadenas**. No se dedujo su coste a partir del tiempo total del controlador. Se añadió una pasada diagnóstica A usando un proveedor de prueba, sin instrumentación nueva en producción.

Frecuencias observadas en esa pasada, normalizadas por 2.266 ticks incluyendo la estabilización de 0,5 s de cada caso. El promedio por moto no implica que los seis vehículos tengan idéntico recorrido local.

| Operación anterior | Por moto/tick | Seis motos/tick | Naturaleza | Coste observado del total | Eliminable aquí |
|---|---:|---:|---|---|---|
| Preparar contactos | 1 | 6 | Administración + consultas reales | 2.727 ms, inclusivo | No se cambia |
| Validación completa de fuente | 31.749 | 190.491 | Administración | 1.784 ms, incluye lectura de fuente | Solo las 78 de comparación inactiva |
| Leer metadatos de Ocean | ≈32.749 + parte compartida | 197.491 | Administración; sin FFT/readback | 0.837 ms, hijo de validación/refresh | Reducción del mismo camino inactivo |
| Formar cadena fft/revisión/espectro | Como la validación | ≈190.491 | Administración/Variant/String | No aislado | Se evita en las 78 llamadas retiradas |
| Comparación desactivada | 13 | 78 | Devuelve muestra vacía; cero consulta física | 0.666 ms de validación, instrumentado | Sí |
| `sample_water()` total | 13.525 | 81.149 | Lecturas cacheadas + misses | No se interpreta como nº de evaluaciones nativas | No se reduce |
| Contactos encontrados en caché | 13 | 78 | Reset/copia de muestra; sin FFT | 0.280 ms excluyendo validación | Se mantiene idéntico |
| Contactos no encontrados en esa caché | 0.525 | 3.149 | Disparan un lote adicional real | Incluido en batch; no aislado por miss | No se cambia |
| Lotes de consulta base, incluidos adicionales | 1.525 | 9.149 | Evaluación real de campos ya construidos | Base nativa: 0.094 ms | No se cambia |
| Contactos base enviados a esos lotes | 13.525 | 81.149 | Entradas físicas, no lecturas de caché | Con normales Water Race: cinco posiciones nativas por contacto | No se reduce |
| `sample_water_batch()` total | 1.525 | 9.149 | Validación, consulta, conversión y overlays | 2.768 ms inclusivos | No se cambia |
| Cambio de consumidor | 1 | 6 | Mueve referencias y estado de caché | 0.061 ms | No se cambia |

Los 13 accesos observados por vehículo incluyen lecturas auxiliares; no se confunden con los doce puntos HULL V1 ni con doce FFT. La preparación de espectro añade seis lecturas de fuente y el driver compartido otra: de ahí que las lecturas de fuente superen a las validaciones aproximadamente en siete por tick.

Los contexts existentes conservan posiciones, arrays de muestras, cursor, historial y epochs de reset/modo. El proveedor mueve esas referencias al cambiar de consumidor, evitando una copia general de arrays. La muestra final se copia a un scratch mediante `_copy_sample`. No se han cambiado esas asignaciones ni las allocations de lotes. Los costes individuales de Dictionary, Variant, String y copia no tienen cronómetros separados; no se les asignan cifras inventadas.

La observación LEGACY frente a HULL V1 queda **sin causa demostrada**: menos puntos no prueban menos lotes, misses, posiciones nativas o overlays. No se ha cambiado ni comparado su modo físico en esta tarea.

## 2. Por qué no se introduce una caché de validación por tick

Los mecanismos actuales no garantizan una invalidación inmediata y completa de todos los cambios:

- Viento/espectro y reconstrucción tienen `physics_source_invalidated`; QueryMode y reset ya disponen de epochs.
- Los setters de Ocean Scale y Clipmap Scale actualizan directamente el FFT y su revisión espacial; no emiten aquella señal de invalidación.
- El runtime de áreas observa algunos recursos, pero documenta que transform, disabled y asignación de shape de sus hijos requieren polling. Su sincronización habitual es por tick.
- La clave completa de la fuente tampoco constituye una versión de todos los overlays, parámetros del proveedor, tiempo y estados de consumidor.

Usar solo `Engine.get_physics_frames()`, o un epoch que no cubra esos caminos, permitiría reutilizar una validación tras una modificación dentro del mismo tick. **No se hace.** Tampoco se añade una red nueva de señales/setters para justificar una caché más extensa.

El guard implementado no reutiliza validaciones. Las lecturas reales, incluidas las cacheadas, conservan exactamente la validación anterior. Cuando la comparación está activada, su recorrido y sus consultas también permanecen iguales.

Una comparación desactivada deja de provocar incidentalmente una invalidación de metadatos por sí sola; no devuelve agua. La siguiente consulta real o consulta explícita de estado sigue validando e invalidando antes de poder servir un contacto. Ese orden se comprueba expresamente en la prueba de mismo tick.

## 3. Comparativa A/B mínima

**Solo cuatro pasadas de rendimiento: A1 → B1 → B2 → A2.** A es una subclase de prueba que conserva literalmente el método anterior; B utiliza el proveedor de producción con el guard cambiado. El resto del proveedor y la física son comunes.

Condiciones: seis motos, ASYNC_3_WORKERS, 128/128/128 cúbico, Jolt, D3D12, 1920×1080, 60 Hz, mismas cámaras, efectos y recorrido del banco existente. Stern Mist se mantiene apagado de la misma forma privada que en aquel banco. Calentamiento 8 s, estabilización 0,5 s por caso, seis posiciones de 2 s, cruce X 4 s, cruce Z 14 s y salto/aterrizaje 3 s. No se modifican escenas guardadas ni presets.

La escena actual tiene SHA256 `1c3b2c66566ff528b0933b65b3d9d9816ee8dcc0dec2acbfd5db1781f1f5fe84`, igual en las cuatro pasadas y después de las pruebas. **Difiere de la escena del informe anterior**, por lo que no se comparan sus FPS directamente con 49,904. Las huellas guardadas actuales están inactivas: el fixture existente `two_state_test` añade una huella slot 1 en memoria, y esa es la única activa del A/B de hoy. El solapamiento de dos áreas se prueba aparte en paridad.

Orden ABBA y calentamiento reducen sesgos de orden, pero no se ha registrado temperatura/frecuencia efectiva por núcleo ni throttling en estas cuatro ejecuciones. No se garantiza igualdad térmica ni se atribuye el ruido a una causa concreta.

### Tabla de decisión

Operaciones: diagnóstico separado, por tick. Tiempos de controlador/física/frame/FPS: solo las cuatro pasadas sin contadores adicionales.

| Métrica | Antes A | Después B | Diferencia B−A |
|---|---:|---:|---:|
| Validaciones/tick | 190.491 | 112.568 | -77.923 llamadas |
| Comparaciones inactivas que validan/tick | 78.000 | 0.000 | -78.000 llamadas |
| Lecturas de fuente/tick | 197.491 | 119.568 | -77.923 llamadas |
| Contactos cacheados/tick | 78.000 | 78.000 | +0.000 lecturas |
| Misses de contactos/tick | 3.149 | 3.172 | +0.023 misses |
| Lotes nativos base/tick | 9.149 | 9.172 | +0.023 lotes |
| Tiempo nativo base, diagnóstico | 0.094 | 0.096 | +0.002 ms |
| Controller media | 8.705 | 8.245 | -0.461 ms |
| Controller p50 | 8.697 | 8.170 | -0.527 ms |
| Controller p95 | 9.655 | 9.404 | -0.251 ms |
| Controller p99 | 10.388 | 10.705 | +0.317 ms |
| Física completa observada p50 | 9.966 | 9.520 | -0.446 ms |
| Física completa observada p95 | 11.134 | 10.950 | -0.184 ms |
| Física completa observada p99 | 11.883 | 12.324 | +0.441 ms |
| WALL p50 | 15.842 | 15.508 | -0.334 ms |
| WALL p95 | 18.083 | 18.484 | +0.401 ms |
| WALL p99 | 26.747 | 28.522 | +1.774 ms |
| FPS medios | 65.513 | 67.405 | +1.892 FPS |
| Mínimo sostenido ~1 s | 48.563 | 38.843 | -9.720 FPS |
| GPU viewport p95 | 10.389 | 10.784 | +0.394 ms |

La reducción exacta del camino inactivo es 78 validaciones/tick. El total diagnóstico baja 77,923 porque el número de consultas auxiliares difiere ligeramente entre ventanas basadas en tiempo real. Eso también explica que los lotes base no sean numéricamente idénticos por tick entre esas ventanas; **no se ha eliminado ningún lote nativo**. El replay a ticks fijos sí conserva exactamente las salidas físicas.

La validación completa instrumentada pasa de 1.784 a 1.171 ms/tick. La recuperación de caché excluyendo validación pasa de 0.280 a 0.283 ms. Son diagnósticos con wrappers y clocks; su diferencia no sustituye al ahorro real de 0.461 ms observado sin ellos. B diagnóstico añade además spans de subsistemas; su controller total no es un A/B comparable.

| Pasada | Controller media ms | Controller p99 ms | WALL p95 ms | WALL p99 ms |
|---|---:|---:|---:|---:|
| A1 | 8.686 | 9.910 | 17.842 | 22.673 |
| B1 | 8.299 | 11.458 | 18.683 | 29.985 |
| B2 | 8.190 | 9.839 | 18.118 | 21.711 |
| A2 | 8.725 | 10.654 | 18.360 | 27.550 |

Ambas medias B son inferiores a ambas A; las colas oscilan. Dos procesos por variante no proporcionan una estimación sólida de eventos raros. Los frames y ticks consecutivos no se consideran miles de experimentos independientes.

### Relaciones de cronómetros y límites

- `controller.integrate` es el span externo agregado de las seis motos. Incluye preparación, física de agua y el resto del controlador; no equivale a IA.
- `prepare` contiene el lote precalculado; `sample_water_batch` también cuenta lotes adicionales fuera de preparación. No se restan esos dos totales como si todas sus llamadas coincidieran.
- Validación contiene lectura de fuente; batch contiene consultas nativas, conversiones y composición. No se suman esos cronómetros inclusivos.
- Tiempo nativo base es el contador devuelto por el sampler, no todo el tiempo del wrapper ni una construcción FFT. El sampler local slot 1 registra aparte 0,187 ms/tick en B diagnóstico; base 0,096 ms/tick. Son consultas a campos publicados, no los trabajos async de construcción.
- Física completa usa el `EngineProfiler` del banco: **máximo tick completo por iteración renderizada**, incluyendo Jolt. En iteraciones de varios pasos no se dispone de cada duración individual. El JSON conserva también el subconjunto de un paso.
- Quedan 18 ticks de borde sin muestra completa en A y 19 en B, contados por el analizador; no se rellenan. Los máximos y tamaños muestrales están en JSON.
- A registra 11 misses async y B 28, con espera correcta del mismo tick; cero ticks/tiempos/resoluciones incorrectos, campos inválidos, recuperaciones, invalidaciones o fallos en las ventanas medidas. No se modificó el planificador async ni se presenta ese incremento como una mejora.

## 4. Equivalencia y seguridad

**73 comprobaciones de mismo tick, sin fallos.** Comparan bytes de las muestras, incluidos los NaN de metadatos inválidos: caché válida, reconstrucción/viento, espectro, fuente, revisión, escala vertical/horizontal, revisión espacial, sea level, escala inválida, fuente ausente y campo fallido. Cubren comparación activada/desactivada y lectura real inmediatamente después de una comparación inactiva con fuente modificada.

**Replay de 720 ticks y seis consumidores: 686.160 valores, cero diferencias.** Incluye altura/posición de superficie, normales, velocidad del agua, signed depth, posiciones de contactos, fuerzas, drag por punto, torques registrados y momentos, velocidades/orientación del cuerpo, flags de contacto y underwater. No se elimina ninguna fila ni se aplica tolerancia.

Cobertura comprobada por pesos de áreas: 121 ticks solo océano base, 462 con un área y 137 con solapamiento. También pausa/cambio de tiempo en ticks 120/132, escalas en 180/420, reset/respawn en 240, QueryMode en 480/540 e invalidación de contactos en 600. Las dos áreas se añaden exclusivamente en memoria al fixture de paridad.

En tick 240, justo después del respawn que reinicia los diagnósticos, los seis cuerpos tienen contactos todavía sin evaluar. Es igual en ambos controles y se conserva en la comparación; todos los demás ticks posteriores al arranque tienen contactos válidos. El arranque también se compara completo. Un replay limpio adicional de la escena con una sola área compara 684.720 valores, igualmente sin diferencias.

Se conservan localmente los primeros replays `contact_A/contact_B`: coincidían, pero forzar `configure()` completo en tick 600 produjo en ambos el guard previo de “más de un field build por tick”. **No se usan como validación aceptada y no se arregla ese problema ajeno al guard.** Los replays aceptados no tienen errores de ejecución. Esta tarea no demuestra que una reconfiguración completa en mitad de la fase física esté soportada; mantiene el mecanismo anterior.

No se cambia HULL V1, LEGACY, fuerzas, damping, puntos, espectro, precisión, AVX2, FFT async, shaders ni render. No hay una caché nueva que pueda ocultar cambios de área/fuente dentro del tick.

## 5. Siguiente intervención: coste medido, sin implementarla aquí

En B diagnóstico, la física de agua suma 5,067 ms/tick, **inclusivos**. La integración de celdas suma 2,671 ms y contiene el bucle de tetraedros, 2,300 ms. Por tanto:

| Zona medida | Seis motos ms/tick | Promedio por vehículo | Relación |
|---|---:|---:|---|
| Bucle de tetraedros | 2,300 | 0,383 | Hoja exclusiva instrumentada |
| Resto de integración de celdas | 0,371 | 0,062 | Celdas menos tetraedros |
| Física de agua fuera de celdas | 2,396 | 0,399 | Residuo: incluye lecturas y otros hijos; no es un único coste exclusivo |

El bucle de tetraedros es la **mayor hoja exclusiva desglosada** en esta captura: 72 celdas y 1.512 tetraedros por tick para seis motos. Es trabajo por vehículo, no una FFT compartida ni GPU. El residuo de física de agua aún necesita más desglose para clasificarlo; no se afirma que toda esa zona sea recuperable.

Las capturas **ya existentes** de la escena anterior muestran crecimiento de composición de áreas: `apply` pasa de 0,2985 ms con una moto a 1,5047 ms con seis, inclusivos. Sus hijos `slot0.sample + slot1.sample` pasan de 0,1509 a 0,7514 ms; el resto de `apply` pasa aproximadamente de 0,1476 a 0,7533 ms. En cambio, `synchronize` compartido permanece próximo: 0,6571 frente a 0,6465 ms. Esa evidencia distingue trabajo repetido por vehículo de preparación compartida, pero no se mezcla con los FPS del A/B actual.

Una siguiente tarea tendría que estudiar primero esas zonas medidas y su coste exclusivo por vehículo, preservando los mismos resultados. **No se cambia ahora la integración volumétrica ni se promete recuperar 3–5 ms**: 2,300 ms es todo el coste observado del bucle, no un ahorro disponible demostrado. No se encadena ninguna optimización.

## 6. Archivos, reproducción y estado local

- [Resultados y hashes de las capturas](perf_contact_1_results_2026_10_20.json).
- Cambio de producción + prueba de mismo tick: `a9cba73`.
- Fixtures A/B, replay y analizadores: `8f77896`. Reutilizan los dos bancos existentes mediante un hook de creación de escena; no cambian sus cálculos.
- Prueba focal: `validation/physics/perf_contact_same_tick_test.gd`.
- Rendimiento: `run_perf_contact_case.ps1 -Variant A -Label A1`; después B1, B2 y A2. `-Diagnostic` se ejecuta aparte y nunca se mezcla con los tiempos de rendimiento.
- Paridad: `run_perf_contact_case.ps1 -Variant A -Label contact_A_overlap -Replay`, después B; `compare_perf_contact.py` compara todos los valores. `analyze_perf_contact.py` procesa A1/B1/B2/A2 y los diagnósticos.
- Capturas locales: `temp/async_fft/perf_contact_1/` y `temp/async_fft/deterministic/contact_*.json`; fuera del repositorio. La etiqueta `native_base_positions` del primer diagnóstico A se normaliza a `native_base_contacts` en el analizador: aquel contador era de contactos, no de posiciones nativas.
- La DLL conserva SHA256 `9abda232bcbfce2c630e030f6307b9f3fcc746d37dc358da8bf0a6189e1d31fb`; no se ha recompilado ni cambiado C++.
- Se mantiene la rama y se dejan fuera de los commits los cambios locales del usuario, incluidas sus tres líneas de sink diagnóstico del proveedor. Las columnas de controlador del banco usan ese sink ya existente.
- `project.godot` también figura modificado localmente (ausencia del ajuste de driver); se deja pendiente, sin incorporarlo ni revertirlo. El A/B fuerza D3D12 mediante argumentos y verifica ese backend. No se modifica el selector físico predeterminado ni se hace push.

**Parada:** ahorro pequeño, mantenible y verificable en un único guard. Sin mejora demostrada de p99; sin otra optimización en esta entrega.
