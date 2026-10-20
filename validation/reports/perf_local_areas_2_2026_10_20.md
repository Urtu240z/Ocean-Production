# PERF-LOCAL-AREAS-2 — 20/10/2026

**Decisión:** conservar el compositor actual. Se descarta el traslado nativo en la fase de diseño, antes de implementar otro algoritmo. El coste observado de pesos + gradiente + composición es **0.3702 ms/tick con seis motos**. Incluso eliminarlo entero no alcanza el objetivo orientativo de 0,5 ms, y un lote tendría preparación y comunicación propias. No se promete ese límite como ahorro realizable.

La tarea continúa en el bloque C con el coste mayor medido de validación de la fuente. No se cambia calidad, pesos, blending, FFT ni orden de overlays.

## Código y recorrido actual

Examinados directamente ocean_wave_area_runtime.gd (synchronize/_synchronize/_update_layout/_apply/weight/weight_gradient/compose), ocean_local_fft_state.gd (sample/_sample/consume_physics_tick), cpu_fft_water_provider.gd (sample_water_batch) y OceanQueryNative::sample_dynamic_lite_local_sea_batch(). El grafo MCP no respondió (Transport closed); no se atribuye al grafo cobertura exhaustiva.

- La disposición mantiene inversas/forma/blend/meta por entrada. Referencias de nodos y valores de transforms/shapes se comprueban una vez por tick; el layout se reconstruye cuando cambia su fingerprint/invalidation.
- synchronize comparte dos estados potenciales por slot. Configure/advance y la construcción de campos FFT no se duplican por moto. En esta escena hay mar principal y un slot local activo; los campos se consultan después de construirse.
- _apply calcula un peso por entrada y posición. La unión de posiciones por slot ya evita consultar dos veces el mismo contacto cuando lo cubren dos áreas del mismo slot. Cada entrada conserva su peso/gradiente y prioridad de mezcla; no se puede eliminar otra entrada solo porque comparte mar.
- weight_gradient conserva cuatro evaluaciones de weight desplazadas ±0,1 m. La composición secuencial actual incluye el gradiente de transición y redondeos Vector2/Vector4 de Godot.
- El sampler nativo genera cinco posiciones por contacto (centro y cuatro vecinos), usa la misma inversión por vecino y devuelve altura/derivadas/velocidad. Consulta los campos actuales; no crea un espectro por contacto.
- La muestra se compone con áreas antes de hull waves, tsunami y wave drift, en ese orden. compose() es otra API que consulta el mar por entrada; el gameplay por lotes examinado utiliza _apply(), no se ha confundido su frecuencia con compose().
- Fuera de áreas también se reconstruye la normal desde pendientes. Un retorno anticipado podría cambiar sus bits aunque el peso sea cero: no se introduce.

## Medición focalizada después de consolidar HULL

Una captura con una moto y otra con seis; mismos fixtures/escena de PERF-HULL-NATIVE-1, 1080p D3D12, ASYNC_3_WORKERS, 60 Hz, calentamiento 8 s y las ventanas existentes. No ABBA de consolidación ni de compositor.

Hay 1985 y 1987 ticks con uno/seis controladores completos. Se conservan 9/9 filas de borde o sin controlador completo en las capturas; el desglose usa solo ventanas completas y cuenta ceros cuando una etapa no se ejecutó. Datos y percentiles: [resultados](perf_scaling_2_results_2026_10_20.json).

| Operación exclusiva | 1 moto, ms/tick | 6 motos, ms/tick | 6: p50 | p95 | p99 |
|---|---:|---:|---:|---:|---:|
| Pesos y mapeo a slots | 0.0289 | 0.1318 | 0.1290 | 0.1640 | 0.2060 |
| Gradiente (hijo de composición) | 0.0155 | 0.0893 | 0.0000 | 0.2830 | 0.3496 |
| Composición excluyendo gradiente | 0.0283 | 0.1491 | 0.1040 | 0.2690 | 0.3271 |
| Despacho local excluyendo sample() | 0.0057 | 0.0255 | 0.0090 | 0.0737 | 0.0850 |
| sample() excluyendo llamada nativa | 0.0075 | 0.0259 | 0.0000 | 0.0900 | 0.1060 |
| Consulta nativa local existente | 0.0367 | 0.1950 | 0.0000 | 0.6320 | 0.7181 |
| Wrapper, reloj y registro de las subetapas | 0.0101 | 0.0495 | 0.0480 | 0.0690 | 0.0890 |

La suma de estas medias exclusivas da apply(): **0.1327 / 0.6661 ms**. El grupo de wrapper incluye el coste de registrar estas mismas subetapas y no se interpreta como trabajo eliminable del compositor.

synchronize() es un padre compartido: **0.4314 / 0.4219 ms**, no se añade otra vez a los hijos del controlador. Los ~0,65/1,50 ms antiguos no describen la captura actual. El apply sin estos relojes de subetapa medido en PERF-HULL-NATIVE-1 era ~0,55 ms; no se presenta la diferencia con 0,666 ms como regresión del compositor, cuyo código final no cambia.

## Frecuencias observadas

| Operación | 1 moto/tick | 6 motos/tick | Naturaleza |
|---|---:|---:|---|
| apply() | 1.561 | 9.430 | padre inclusivo, más de un lote por moto |
| Posiciones de entrada / pesos centrales (una entrada activa) | 13.561 | 81.430 | peso/mapa administrativo y espacial |
| Gradientes por contacto/área afectado | 4.588 | 26.735 | cuatro pesos, necesarios en transición |
| slot1.sample() | 0.485 | 2.798 | consulta compartida por slot, no FFT por moto |
| Contactos locales únicos | 4.588 | 26.735 | incluye unión de áreas del mismo slot |
| Posiciones nativas locales | 22.940 | 133.674 | cinco por contacto local |
| Sincronización | 1.000 | 1.000 | compartida |

Son promedios del recorrido, que atraviesa zonas sin influencia. No se convierten llamadas GDScript en un supuesto número de FFTs. El slot0 no tuvo consultas locales en esta captura; el replay separado sí garantiza solapamiento de los dos slots.

## Diseño evaluado, descarte y paridad

Un lote nativo de pesos/gradientes seguido de composición podría reutilizar la tabla de entradas y las consultas por slot existentes. No debe compartir estado mutable entre consumidores ni retrasar un tick de Jolt. Unir también los samplers exigiría preservar su publicación/consume/invalidación y el orden de mezcla.

El ahorro máximo de la parte concreta a trasladar está acotado por los 0,370 ms observados, **antes** del empaquetado. El resto incluye consultas FFT necesarias y administración del sampler. No se crea un prototipo que ya incumple el objetivo temporal antes de considerar sus costes. Por esa razón B3/microbenchmark A/B y B4/ABBA del compositor no se ejecutan; el candidato se descarta en diseño. No se declara paridad de un compositor nuevo inexistente.

El archivo de producción ocean_wave_area_runtime.gd termina exactamente con el contenido previo a esta tarea. Los relojes temporales se retiraron; solo se conserva el parche diagnóstico en validation/fixtures/scaling_2_diagnostic.patch. El replay gráfico de consolidación conserva 720 hashes previos y cubre áreas/solapamiento/respawn/cambios en caliente; no se presenta como una nueva prueba específica de áreas rotadas porque no hubo sustitución matemática que validar.

Ahorro integrado del bloque B: **0 ms**. Los FPS de las capturas instrumentadas están en los datos; no hay un antes/después de compositor ni ganancia de FPS atribuible.

## Reproducción, commits y límites

Aplicar temporalmente el parche diagnóstico, ejecutar run_scaling_2_case.ps1 -Boats 1 -Label diagnostic1 y después seis; revertir el parche antes de cualquier benchmark. El runner exige los relojes para este modo. analyze_scaling_2.py reconstruye tablas desde las capturas. Los relojes de gradiente/registro distorsionan algo el coste: son un diagnóstico separado, nunca la cohorte de rendimiento.

Este informe y el fixture de relojes constituyen el commit del bloque B. Los archivos comunes de análisis se añaden en el bloque C. Capturas locales temp/scaling_2/, sin mezclar FPS de escenas distintas. No se han probado pantalla partida, red o Steam Deck; estas cifras son del portátil indicado. No hay temperaturas de CPU por núcleo; la instrumentación no justifica precisión submicrosegundo.

Siguiente coste: validaciones administrativas de fuente (~1,12 ms/tick de seis motos, ventana del proveedor que incluye settle); ver perf_controller_scaling_2026_10_20.md.
