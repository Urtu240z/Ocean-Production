# MASTER INTEGRATION + CONTACT PIPELINE 3 — 2026-10-20

**Bloque A completado y publicado. Bloque B investigado; no se conserva ninguna optimización de producción.** Las consultas Arcade no pueden sustituirse directamente por los contactos existentes. El prototipo de lectura compacta preserva la física, pero no demuestra un ahorro suficiente. No se ejecutó un ABBA gráfico adicional ni se atribuye ninguna ganancia nueva de FPS.

## Master, rama y protección del estado

El fetch confirmó `origin/master = 88cf3ae5bca090bb34404ce362ad4a7966df2a24`. Se integraron por **fast-forward** `d6940e8`, `3f0bc1a` y `ce2a343`, conservando su historial y la rama anterior.

**Push de master completado. SHA publicado: `ce2a34346aefc9e62b3bac8623f22bfcf203f9f0`.** Se verificó igualdad entre master local, `origin/master` y `git ls-remote origin refs/heads/master`. Véase también `master_integration_native_performance_2_2026_10_20.md`.

Después se creó `codex/contact-pipeline-3` desde ese mismo SHA. Todo el trabajo se hizo en el worktree externo `C:/Users/DEV/.codex/worktrees/contact-pipeline-3/Water Race Ocean Production`. No se hizo push de esta rama.

La copia original permanece en `codex/native-performance-2`. Se conservaron exactamente sus cambios pendientes, sin incorporarlos al merge:

| Archivo original | SHA256 antes y después |
|---|---|
| `project.godot` | `faf6f594c7c996088748a67dcab13c632386530528eda7884e05533aed0fc5b4` |
| `validation/hull_wave_physics_playground.tscn` | `df28c8f612b49683463de023f7b3879f45b1aa6c721d5ea598a8f1e70c4e9b24` |
| `validation/reports/async_fft_comparison_2026_10_19.svg.import` | `310aaf1df713e50d37daA2208A4df9718eac73e958fd967b7a18e2c6babfe45d` |

La eliminación local del límite de FPS, los ajustes de escena y el `.import` siguen pendientes en su árbol original. No se modificaron sus archivos ignorados. No se usaron `reset --hard`, force push ni borrado de ramas.

Validación del master integrado: importación y GDExtension correctas; **192 comprobaciones binarias en Windows y Linux**, cero fallos; smoke guardado con **Vulkan**, HULL V1 exclusivamente nativo, tres workers reales, 60 Hz, una carga de geometría, 119 lotes observados y estado/muestra finitos. No se cambió C++ ni se recompilaron bibliotecas.

DLL Windows conservada: `e22176c1d2e0ef058d4816d63b76ba353ed516ed2e8b52de7cfdfd0fbec3f0d0`. SO Linux: `3f9fb2f1cb9422dc8d2f0d82e79342f1e9561a846011b0759495e8720a9387c9`.

## Escena y método de investigación

Se tomó el **master recién publicado**, con escena SHA256 `1c3b2c66566ff528b0933b65b3d9d9816ee8dcc0dec2acbfd5db1781f1f5fe84`. No se aplicó el parche de cambios locales del usuario. Esto difiere de la cohorte de Native Performance 2; sus 0,433/0,504 ms y sus FPS no se usan como tiempos A actuales ni se restan de las nuevas medidas.

El banco real conserva seis motos, D3D12, 1920×1080, Jolt 60 Hz, HULL nativo, FFT 128/128/128 cúbica, ASYNC_3_WORKERS, áreas y efectos del fixture. El limitador se desactiva **solo en la instancia de validación** (`Engine.max_fps=0`); `project.godot` de master no se modifica. Se mantiene el footprint privado `two_state_test` y la desactivación privada de stern mist que ya utilizaba el banco.

Se separaron tres instrumentos: traza de identidad/posición, reloj ligero con acumuladores enteros publicados una vez por tick y captura adicional de contadores FFT locales. No se utiliza la traza de diccionarios para medir tiempo. Todos los hooks temporales se retiraron. El grafo MCP y cobertura devolvieron `Transport closed`; se usaron las fuentes actuales directamente, sin reclamar cobertura del grafo.

## B1 — Recorrido Arcade y causa de los misses

El callback es `JetSkiArcadeHandling._physics_process`. En modo clásico llama a `water_provider.sample_water(_vehicle.global_position, _water_sample_scratch)`. Sale antes de consultar si Arcade está desactivado, hay turn continuity, el vehículo está congelado/pausado, no tiene inmersión, está buceando o está en DEEP_SUBMERGED.

Necesita validez, normal y velocidad del agua para construir tangentes, velocidad relativa, grip lateral y damping de yaw. No utiliza directamente altura/signed depth, pero la API también los produce y su validez forma parte del contrato. Otros modos/proveedores siguen necesitando esa API completa.

Antes, `_integrate_forces` selecciona su consumidor, prepara **12 puntos HULL + propulsión**, publica el lote, consume los 12 contactos y luego propulsión. El modo clásico no solicita el centro como punto adicional. Turn continuity sí utiliza otro recorrido con el centro preparado; activar ese modo no sería una optimización equivalente de la conducción clásica.

`sample_water` comprueba la fuente y busca **el siguiente índice** de la caché lineal, no cualquier punto espacial. Cuando Arcade consulta, el cursor ya está en 13/13. La traza observó:

- **6661 consultas en 1984 ticks** del recorrido; cero coincidencias exactas con los puntos precalculados.
- Mismo tick/campo, backend, QueryMode, generación de espectro y revisiones de fuente/espacio en todas las observaciones.
- Solo **4** posiciones coincidían exactamente con el centro usado al preparar. Las otras **6657** diferían porque el banco recoloca XZ cada tick después de la integración. No se trata de una necesidad intrínseca de Arcade ni se acepta proximidad aproximada.
- En **5514** consultas el consumidor activo era el de otra moto; en 1147 era el propio. El callback clásico obtiene el proveedor compartido y **no selecciona su contexto**. El owner y centro activos se transmiten a la exclusión de estela propia de hull waves. Reasignarlos no es una optimización equivalente de la semántica actual.
- Control con movimiento libre: **436/436** consultas coinciden exactamente con el centro preparado, pero ninguna con los contactos almacenados; **351/436** siguen usando otro contexto activo. Así se distingue el efecto del banco del problema de identidad/API.
- Control Arcade desactivado: **1080 callbacks**, **cero consultas, misses, lotes o posiciones nativas adicionales**. No hay una llamada heredada al agua que eliminar en ese modo.

Frecuencia por vehículo en la traza del recorrido (puede variar con inmersión/estado):

| Vehículo | Consultas | Consultas/tick |
|---|---:|---:|
| JetSki | 1147 | 0,578 |
| AsyncFleet1 | 1212 | 0,611 |
| AsyncFleet2 | 1050 | 0,529 |
| AsyncFleet3 | 999 | 0,504 |
| AsyncFleet4 | 1115 | 0,562 |
| AsyncFleet5 | 1138 | 0,574 |

La captura ligera de costes, independiente de la traza, registró **3,361 consultas/misses por tick**, 0 hits, 3,361 lotes, 16,804 posiciones en el campo principal y 3,361 WaterSample nuevos. Son hasta seis consultas/tick, mediana tres, con una media equivalente de 0,560 por moto. Cada miss valida tres veces en los niveles existentes: 10,082 validaciones/tick. Son llamadas administrativas, no FFT nuevas.

### Costes de Arcade

Milisegundos agregados por tick para seis motos, **1985 ticks completos**. Valores observados con el reloj ligero, no una comparación limpia de FPS. Los bloques desglosados no se solapan entre sí; los padres se indican expresamente.

| Operación | Media | p50 | p95 | p99 |
|---|---:|---:|---:|---:|
| Callback excluyendo `sample_water` | 0,054157 | 0,055 | 0,079 | 0,097320 |
| Validación de fuente dentro de las consultas | 0,032381 | 0,032 | 0,057 | 0,066 |
| Preparación/escalado de posiciones extra | 0,005625 | 0,005 | 0,010 | 0,014 |
| FFT principal, tiempo interno C++ | 0,004320 | 0,004 | 0,008 | 0,011 |
| Puente principal excluyendo ese tiempo C++ | 0,005382 | 0,005 | 0,010 | 0,013 |
| Decodificación y construcción de muestra | 0,017506 | 0,017 | 0,030 | 0,034 |
| Áreas, **incluida consulta local** | 0,082449 | 0,068 | 0,234800 | 0,278160 |
| Hull waves | 0,026126 | 0,025 | 0,045 | 0,050 |
| Tsunami | 0,020666 | 0,020 | 0,036 | 0,039160 |
| Drift y metadatos | 0,005987 | 0,006 | 0,011 | 0,013 |
| Administración residual de consulta | 0,045371 | 0,044 | 0,079 | 0,087 |
| **Consulta completa, padre inclusivo** | **0,245813** | 0,225 | 0,478 | 0,565320 |
| **Callback completo, padre inclusivo** | **0,299969** | 0,287 | 0,551600 | 0,638 |

El residual incluye búsqueda/ramificación de miss, array de entrada de un punto, copia a scratch y contadores/retorno del proveedor. No es un cronómetro puro de búsqueda de caché. No hay hits Arcade en esta captura, por lo que no se inventa un coste de hit. No se suman los padres a los hijos.

Captura auxiliar independiente para separar FFT local: 3,337 misses/tick, 16,685 posiciones principales y **4,065 posiciones locales/tick**. El puente nativo local mide media/p50/p95/p99 **0,009234 / 0 / 0,058800 / 0,068160 ms**. El FFT principal interno mide 0,004408 ms de media en esa misma captura. La API local incluye el puente en su tiempo y no expone un cronómetro matemático interno separado.

Leer los contadores locales añade trabajo: en esa captura el padre de áreas es 0,121148 ms, el residual tras restar su puente local 0,111914 ms y la consulta completa 0,296955 ms. Ese residual **incluye la inspección de contadores**, no es una medida limpia de composición GD. No se resta el tiempo local de esa ventana al padre de la captura ligera ni se usa el instrumento auxiliar para estimar ahorro. Las dos capturas se conservan separadas en el JSON.

### Decisión Arcade

Incluir el centro en el lote no elimina información duplicada actualmente almacenada: añade una muestra nueva. En el banco casi nunca coincidiría exactamente con la posición de consulta posterior y requeriría fallback. En movimiento libre sí puede coincidir la posición, pero faltaría demostrar composición idéntica bajo el contexto que realmente utiliza el callback, cambios dentro del tick y exclusión de estela propia.

Una muestra auxiliar identificada necesitaría claves coherentes de fuente, tiempo, backend, modo, posición y overlays, además de una decisión explícita sobre el consumidor correcto. No existe aquí una muestra central precalculada equivalente que pueda compartirse directamente. No se añade caché por tick ni se altera selección de consumidor, conducción, orden de publicación o física para fabricar un hit. **No se implementa optimización Arcade.**

## B2 — Inventario de estructuras y copias

El recorrido sigue siendo FFT C++ → PackedFloat64Array → WaterSample → historia/cache → scratch HULL/Drive → buffers nativos de geometría → PackedFloat64Array → Dictionary de celda → fuerzas/Jolt.

| Frontera | Cantidad ordinaria con seis motos | Propiedad, copia y necesidad |
|---|---|---|
| Posiciones de prefetch | 6 buffers de 13 puntos | Propios del contexto; pasan a estado activo por transferencia de referencias |
| Posiciones para normal DIRECT | 6 buffers de 65 puntos, más extras | Posiciones exactas; cinco son necesarias para la normal actual |
| Salida principal FFT | 6 arrays de 391 doubles; extra de 31 doubles por miss | Contrato actual incluye tiempo y seis escalares por sondeo; no son seis construcciones FFT |
| WaterSample base | 78 objetos nuevos/tick, más extras | Campos usados por áreas, hull waves, tsunami, drift y API pública |
| Historia `last_samples` | 78 clones base/tick, más seams cuando proceda | Copia **antes** de overlays; compartir el mismo objeto contaminaría historia/recuperación |
| Caché seleccionada | Referencias a las muestras compuestas | No se reconstruye una segunda colección completa de muestras al publicarla |
| Scratch de consumo | 72 HULL y los scratch de Drive/Arcade, reutilizados | `reset` + copia conserva aislamiento; los 78 hits ordinarios escriben 8 campos al reset y 8 al copiar |
| Normal usada por HULL | Normalización y escritura en muestra scratch | HULL modifica `sample.normal`; devolver referencias mutables a la caché introduciría aliasing |
| Entrada a geometría | 6 pares de PackedVector3Array de 12 + máscaras de 12 | Reutilizados por vehículo; se escriben 24 vectores + 12 flags por vehículo; una llamada nativa por lote |
| Salida de geometría | 6 arrays de 120 doubles (960 bytes cada uno) | Ya es compacta, privada de cada vehículo; incluye volumen, centro, depth y momentos |
| Adaptador por celda | **72 Dictionary nuevos de tres campos** | Construcción seguida de 216 lecturas; era el punto aislado del prototipo |
| Geometría fija y datos de celda | 12 celdas por vehículo | Recursos configurados una vez/generación; los Dictionary de geometría fija no se crean por tick |
| Estado/HUD/debug | Arrays de cuatro contactos y métricas derivadas | Contratos públicos conservados; no se suprimen sus datos ni fuerzas para reducir escrituras |

La asignación de un PackedArray y su paso a GDExtension no equivalen automáticamente a copiar todos sus bytes: usan referencias con copy-on-write. Los contextos ya vacían sus slots tras cargarlos para evitar propietarios redundantes que provocarían COW al mutar. Los buffers de entrada a geometría ya se reutilizan.

No hay conversión genérica Vector3 → Array numérico en el tramo físico ordinario: se almacenan vectores tipados. Las conversiones a arrays simples del replay pertenecen a validación. El paso WaterSample → dos buffers de vectores sí copia componentes y normaliza, porque esa es la interfaz geométrica existente.

Las fronteras de precisión importan: alturas/velocidades escalares se decodifican en doble, pero posiciones y normales Godot son Vector3 de componentes float32. Mantener doubles más allá de esas fronteras no sería automáticamente equivalente. El prototipo conserva exactamente el Vector3 construido por el adaptador anterior.

Los valores históricos 0,294/0,334/0,453 ms no se suman ni se consideran ahorro disponible. El inventario encuentra operaciones eliminables, pero su beneficio se decide con el coste completo, no con su número de objetos.

## B3 — Prototipo compacto y coste neto

Se creó un único prototipo acotado: el consumidor de fuerzas mantiene una referencia COW al **buffer nativo ya existente** y lee volumen, centro y depth directamente. El cambio efectivo es de cinco líneas añadidas/cuatro sustituidas. No añade buffers de resultados, cachés, llamadas por contacto ni estado compartido; no modifica algoritmos, puntos o fuerzas. La API `native_cell_result` permanece disponible.

El microbenchmark incluye seis consumidores, posiciones, consultas FFT reales sobre campos publicados, normales, dos áreas locales solapadas, hull waves, tsunami, drift, publicación/historia, lecturas cacheadas, empaquetado geométrico, cálculo C++ nativo, decodificación y el **paso HULL completo con cálculo y consumo ordenado de fuerzas/drag/torques**. Los campos están fijados y se construyen fuera de la ventana; la frescura de metadatos, planificación de workers e integración real de Jolt no forman parte de ese reloj. Un consumidor determinista sustituye las llamadas de aplicación a Jolt; el replay posterior sí usa Jolt real.

Se midieron 1000 iteraciones por bloque, A/B/B/A dentro del proceso, con PERF2 apagado y encendido:

| PERF2 | A1 medio | B1 medio | B2 medio | A2 medio | Diferencia de medias A−B |
|---|---:|---:|---:|---:|---:|
| Apagado | 2,864958 | 2,835481 | 2,863897 | 2,858594 | **0,012087 ms** |
| Encendido | 2,905303 | 2,813718 | 2,812105 | 2,896951 | **0,088216 ms** |

Las distribuciones media/p50/p95/p99 de cada bloque están en el JSON. Sin PERF2, B2 incluso es más lento que A2: **no hay un ahorro pequeño reproducible fuera del ruido**. Con PERF2 hay una diferencia consistente de unas centésimas, pero se evita también la instrumentación del adaptador: 72 llamadas/spans por celda. No se presenta esa diferencia como aceleración de las matemáticas de flotabilidad.

Aunque se eliminan 72 Dictionary, el resultado está muy por debajo de una oportunidad neta de 0,5 ms para rediseñar interfaces. Tampoco alcanza el criterio orientativo de 0,15–0,20 ms de una intervención focal. Exponer índices del layout privado y cambiar cobertura de métricas no compensa ese resultado. **Prototipo descartado; ahorro de producción retenido en B: 0 ms.**

No se ejecutó un ABBA gráfico: el gate de rendimiento ya falló en el micro completo. No hay nuevas cifras de controller, física completa, WALL, GPU o FPS A/B atribuibles a una optimización retenida. No se reutilizan las cifras anteriores para simular esa comparación.

## B5 — Igualdad física

- Micro: **32 pasos × seis consumidores**, cuatro configuraciones de pose repetidas, sin diferencias binarias en entradas/salidas geométricas, fuerzas ordenadas, drag y torques. Se verificó que los 32 pasos producen fuerzas no nulas y que cada consumidor ejecuta 32 lotes geométricos nativos; no es una comparación vacía de ceros.
- Mismo fixture en Linux: 32 pasos, cero diferencias A/B. No se reclama igualdad entre plataformas distintas ni rendimiento Linux con esas ventanas cortas.
- Escena real: **720 ticks con seis motos, cero hashes diferentes**. Se comparan campos FFT de prueba, tiempos, contactos publicados, historia, consumidor, altura/normal/velocidad/depth, geometría, fuerzas, drag, torques, velocidades, posición/orientación, contacto y underwater. Se incluyen los contadores de hits/misses y lotes/sondeos.
- Totales de consultas/hits/misses/inválidas: **A = B = `[57297, 56082, 1215, 0]`**. Ese replay tiene otras condiciones y no se combina con las frecuencias del banco de coste.
- Cobertura: ambos slots locales, hasta 82 paquetes hull waves, tsunami 400 ticks, drift 720, pausa, respawn, cambios de modo, viento/espectro local, escalas e invalidación. Se mantiene el orden BASE → ÁREAS → HULL WAVES → TSUNAMI → WAVE DRIFT.
- Se usa SHA256 de `var_to_bytes` dentro de Godot antes de JSON, sin tolerancias. El NAN de metadatos/historia aún no publicados se codifica antes de que JSON lo represente como null. No se ocultan diferencias físicas.

Para observar ambas rutas, el recorder de validación captura ahora el resultado de lote además del getter de Dictionary. El candidato se aplicó **temporalmente solo al worktree de prueba** durante B del replay y se revirtió después. El diff final de `addons/` respecto a master es vacío. Los ensayos iniciales de preparación con errores de fixture se descartaron; la configuración final de campos utiliza `configure_physics_only`, y todos los resultados aceptados carecen de errores de ejecución.

## Decisiones, límites y siguiente intervención

| Oportunidad | Resultado y decisión |
|---|---|
| Reutilizar contactos actuales para Arcade | No contienen el centro; coincidencias/contexto/composición requeridos no se cumplen. No implementar |
| Prefetch central o muestra auxiliar | Posible contrato futuro, pero no una sustitución equivalente demostrada en el banco ni con la identidad actual. No añadir caché |
| Eliminar consulta con Arcade desactivado | Ya es cero; no hay trabajo que recuperar |
| Corregir consumidor de Arcade clásico | Debe definirse como cambio funcional de ownership de hull waves, con validación propia; no esconderlo como optimización equivalente |
| Consumir resultado geométrico compacto | Paridad demostrada; beneficio 0,012 ms sin PERF2 compatible con ruido y 0,088 ms con instrumentación. Retirado |
| Evitar clones de historia / devolver caché mutable | Copias defensivas necesarias en las fronteras actuales; HULL y overlays mutan muestras. No introducir aliasing |
| Portar todo el proveedor/overlays a otro contrato | No hay ventaja neta demostrada de al menos 0,5 ms. No ampliar el prototipo ni modificar matemáticas |

Dentro de las consultas adicionales, el bloque más costoso observado es áreas, seguido de administración/validación; la evaluación principal FFT es pequeña y ya nativa. El techo de **toda** la consulta extra ligera es aproximadamente 0,246 ms, no varios milisegundos recuperables. Parte de él produce información nueva y parte protege composición/validez. No se promete recuperarlo entero.

La siguiente intervención lógica es definir explícitamente la identidad del consumidor que debería usar Arcade clásico y comprobar las condiciones de una muestra central, separando esa corrección funcional de una optimización. Si se pretende una reducción mayor, hace falta otra evidencia exclusiva que la sustente; esta prueba desautoriza convertir el antiguo bookkeeping de 0,453 ms en una promesa de ahorro de estructuras. No se cambia el scheduler Async ni se atribuyen mejoras de frame/GPU sin un A/B limpio.

## Evidencia y commits

- `contact_pipeline_3_checks_2026_10_20.json`: frecuencias, todas las distribuciones, ventanas separadas, validación, condiciones y hashes de capturas.
- Capturas brutas: `temp/contact_pipeline_3/`; replays `temp/async_fft/deterministic/cp3_replay_A.json` y `cp3_replay_B.json`.
- `contact_pipeline_3_arcade_diagnostic.patch`: aplicar solo para `-Kind trace/cost` y retirar después. El runner rechaza su presencia en replay/benchmark.
- `contact_pipeline_3_compact_candidate.patch`: reproducción temporal del candidato de replay; **no está aplicado**.
- `contact_pipeline_3_compact_micro.gd`: micro completo de la frontera examinada; el candidato aislado vive solo en `validation/fixtures/`.
- Resumen reproducible: `python -B validation/physics/analyze_contact_pipeline_3.py`. El runner conserva huellas antes/después y rechaza errores. No hay selector de producción A/B.
- Commits de B: `f759022` publicación de master; `6488ac5` trazas/replay/costes; `eeac635` prototipo aislado; `e4f647d` separación local y guards. El informe/JSON y sus últimas comprobaciones se guardan en un commit documental final.

Estado final: master publicado en `ce2a34346aefc9e62b3bac8623f22bfcf203f9f0`; rama B separada, con evidencia y sin cambios de producción, **sin push**. La rama anterior y todos los cambios locales originales están conservados. No se trabajó en Gold City, pantalla partida, IA o multijugador.
