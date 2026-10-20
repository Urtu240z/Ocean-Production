# WATER RACE — Native Performance 2 — 2026-10-20

Se recorrieron los candidatos del pipeline, fuerzas, overlays, conducción y FFT compartida. Solo se conserva una optimización de metadatos: eliminar la reflexión del Inspector al calcular la firma de los mares locales. No se ha añadido C++ nuevo. Los costes medidos no justifican una migración compleja de los núcleos numéricos individuales examinados.

Resultado: **0,231 ms por dos firmas en el microbenchmark** y **0,302 ms menos de física completa media en el A/B/B/A**. La segunda cifra es la diferencia observada de la cohorte, no una garantía de ahorro constante. Se mantiene igualdad binaria en 720 ticks con seis motos. No se suman ganancias de tareas anteriores.

## Base protegida y condiciones

- Base: `master` / `origin/master` = `88cf3ae5bca090bb34404ce362ad4a7966df2a24`. Rama creada: `codex/native-performance-2`. No merge ni push.
- Presentes los bloques anteriores: ASYNC_3_WORKERS, PERF-CONTACT-1, PERF-HULL-NATIVE-1, `a03a6fa`, `475cd5e`, `b717765` y consolidación `13c1e7c`.
- HULL V1 continúa exclusivamente en `HullBuoyancyGeometryNative`; no se tocó su geometría, fuerzas, puntos, configuración ni orden de aplicación a Jolt. Física a 60 Hz, CPU Lite 128/128/128, interpolación cúbica y AVX2 conservados.
- Había cambios locales posteriores a la integración en `validation/hull_wave_physics_playground.tscn`: activación de la segunda zona guardada y valores de animación. También apareció la eliminación de `run/max_fps=144` en `project.godot`. Se conservaron fuera de nuestros commits. El archivo SVG `.import` preexistente también se conserva.
- Escena de esta cohorte: SHA256 `df28c8f612b49683463de023f7b3879f45b1aa6c721d5ea598a8f1e70c4e9b24`. Difiere de la cohorte histórica citada en el encargo. Por tanto, los anteriores 4,836/6,047 ms y 97,919 FPS no son nuestro baseline A.
- Banco real existente: seis motos, 1920×1080, Forward+, D3D12 en **ambos** lados, `--workers=1` (enum ASYNC_3_WORKERS), sin VSync ni límite de FPS, mismas cámaras, física, recorrido, FFT y efectos. Se conserva la desactivación privada de stern mist del banco existente; no se editan efectos guardados.
- Calentamiento de 8 s, estabilización de 0,5 s por caso, seis posiciones de 3 s, recorridos X/Z de 4/14 s y salto de 3 s. Orden A1/B1/B2/A2. Solo cuatro pasadas de rendimiento.
- Todas las huellas de los archivos de producción/configuración comprobados coinciden entre pasadas salvo los dos archivos del candidato. Cada ejecución comprobó igualdad de huellas antes/después. La comparación A usa el cuerpo original exacto, mediante parche reversible de validación; ambos lados conservan PERF-CONTROLLER-SCALING.
- Lecturas puntuales de GPU de 37/38/40 °C y 2175 MHz; no hay telemetría continua de temperatura de CPU. ABBA y calentamiento reducen la deriva, pero no demuestran equivalencia térmica perfecta.

El grafo MCP y la comprobación de cobertura devolvieron `Transport closed`. La auditoría usó lectura directa de las fuentes actuales; no se atribuye cobertura exhaustiva al grafo.

## Recorrido y frecuencias actuales

`JetSkiController._integrate_forces` selecciona su contexto y prepara 12 contactos HULL más el punto de propulsión. `begin_gameplay_contacts` transforma posiciones y obtiene el lote. DIRECT genera cinco posiciones por contacto, escala XZ, llama una vez a `sample_dynamic_lite_contacts`, decodifica y crea las muestras. La historia/seams de `LocalSurfaceContactState` se publica **antes** de los overlays. Después se componen **BASE → ÁREAS → HULL WAVES → TSUNAMI → WAVE DRIFT**, se publica la caché seleccionada y HULL/propulsión leen sus muestras.

Las lecturas cacheadas siguen validando metadatos vivos mediante `matches_physics_source`; no hacen interpolaciones FFT. Las firmas locales examinadas pertenecen a la sincronización/configuración de los campos compartidos, no a la lectura individual de contactos.

Medias por tick de las capturas finales de diagnóstico; los tiempos se detallan después. Las fracciones proceden de contactos adicionales condicionales y del recorrido.

| Operación | 1 moto | 6 motos | Naturaleza / observación |
|---|---:|---:|---|
| Preparación de contactos | 1 | 6 | Padre inclusivo; no sumar sus hijos |
| Contactos prefetched / clones de historia ordinarios | 13 | 78 | Administración; las copias de seams adicionales no se contaron aparte |
| Lecturas de contactos precalculados | 13 | 78 | Administración, sin nueva evaluación FFT |
| Consultas que no encuentran el siguiente contacto | 0,627 | 3,446 | Nueva consulta; principalmente callback Arcade clásico en el centro del cuerpo |
| Lotes DIRECT, incluidos adicionales | 1,627 | 9,446 | Una llamada nativa por lote |
| Muestras DIRECT construidas | 13,627 | 81,446 | Conversión/objetos |
| Posiciones consultadas en FFT principal | 68,134 | 407,228 | Cinco por muestra; hasta tres interpolaciones de banda por posición válida |
| Contactos locales, unión del slot 1 | 4,612 | 26,676 | Consultas físicas locales reales, sin duplicar por footprint |
| Posiciones nativas locales del slot 1 | 23,061 | 133,381 | Cinco por contacto local |
| Gradientes de peso de áreas | 8,279 | 48,514 | Cuatro evaluaciones de peso por gradiente; no son consultas FFT |
| Validaciones vivas del proveedor | 20,976 | 113,744 | Administración; no equivalen a evaluaciones nativas |
| Lecturas completas de estado del océano* | 2 | 7 | Administración; refresco del driver y preparación de cada consumidor |
| Cambios de consumidor* | 0 | 6 | Administración; 0,062 ms agregados con seis motos |
| Firmas de configuración local | 2 | 2 | Compartidas: un slot activo y uno preparado sin consultas |
| Construcciones de campo | principal + 2 locales | principal + 2 locales | Trabajo compartido; nueve jobs de banda, no una FFT por contacto |

\* Estas dos filas proceden de los contadores cuya ventana incluye estabilización. No se restan de cronómetros de otra ventana. Los antiguos contadores de lote que quedan sin instrumentar por la subclase se eliminan del resumen: sus ceros no significan ausencia de consultas FFT.

## Auditoría de CPU e inventario de candidatos

Los instrumentos detallados se instalaron temporalmente y se retiraron antes del A/B/B/A. Sus resultados sirven para atribución y techos de oportunidad; **no son tiempos de producción sin instrumentación**. Registrar spans por contacto aumenta especialmente los padres y las lecturas cacheadas. Por ejemplo, el controller instrumentado final alcanza 6,309 ms frente a 4,842 ms en B de rendimiento. No se utiliza esa diferencia como ganancia ni regresión.

Salvo indicación, las cifras siguientes son medias de bloques delimitados de `final_diagnostic6`, con hijos restados solo dentro de la misma ventana. Las frecuencias y los datos de una moto se conservan en el JSON adjunto. Los techos no son predicciones de ahorro.

| Subsistema | ms/tick con 6 | Frecuencia / coste por moto | Trabajo reutilizable y techo | Complejidad / riesgo | Decisión |
|---|---:|---|---|---|---|
| Pesos + gradientes + composición de áreas, sin consultas locales | **0,532** | 9,446 lotes; 0,089 ms/moto equivalente | Footprints compartidos; techo de todo ese bloque 0,532 antes de entradas/salidas | Alta; precisión float32/float64, mezcla ordenada, geometría y cambios en caliente | Candidato de batching futuro; no prototipo complejo para un techo apenas superior a 0,5 |
| Hull waves, resto del wrapper tras consulta nativa | **≤0,489** | 9,446 aplicaciones; incluye publicación compartida una vez/tick | Contiene emitter/publicación y aplicación GD, sin aislamiento completo entre ambos | Alta para portar el emitter; nacimientos, propietarios y exclusión de estela propia | Conservar; no atribuir todo a composición numérica recuperable |
| Bucle de celdas HULL, excluidas matemáticas de fuerza y APIs cronometradas | **0,453** | 72 celdas; 0,076 ms/moto equivalente | Decodificación de Dictionary, validaciones y escritura de estado; incluye coste de instrumentos | Alta si se cambia representación de resultados | Problema de interfaz/estado; no reescribir geometría ni confundirlo con matemáticas |
| Validación viva de fuente | **0,349** | 113,744 llamadas; 0,058 ms/moto equivalente | Metadatos ya optimizados por b717765; techo del bloque medido | Alto si se omiten invalidaciones del mismo tick | Mantener comprobación viva; no añadir caché insegura |
| Historia/seams/publicación de contactos | **0,334** | 6 publicaciones / 78 contactos; 0,056 ms/moto | Clones de WaterSample y arrays de historia; estados de consumidor independientes | Media/alta por aliasing, reset y seams | Mantener; posible rediseño de representación con medición conjunta futura |
| DIRECT: posiciones + decodificación/WaterSample | **0,294** | 81,446 muestras; 0,049 ms/moto | 0,049 posiciones + 0,245 conversión; la FFT nativa queda fuera | Media/alta para nueva interfaz nativa completa | Primer candidato examinado y descartado: su techo es inferior a 0,5 antes del coste de interfaz |
| Firmas de mares locales | **A 0,240 → B 0,009** en micro | 2 llamadas/tick, independiente del número de motos | Eliminar reflexión conservando valores y hash exactos | Baja; esquema explícito con prueba de cobertura y fallback para clases derivadas | **Implementado** |
| DriveSystem y preparación de su grupo | **≤0,218** | 6/tick; ≤0,036 ms/moto | Incluye muestra de propulsión, validación y Godot; matemática exclusiva no aislada | Alta respecto al techo disponible | Mantener GD; no tratar los 0,218 como ahorro íntegro |
| RiderDynamicsSystem | **≤0,201** | 6/tick; ≤0,034 ms/moto | Incluye preparación y aplicación; no es matemática exclusiva | Media/alta por modos y contactos | Mantener GD; no hay núcleo con techo suficiente |
| Boundary Tsunami | **≤0,176** | 9,446 aplicaciones; ≤0,029 ms/moto equivalente | Sampler analítico, normal y propiedades; incluye obtención/avance de estado | Media; trigonometría, orden y redondeo | Sin port; techo pequeño |
| Matemática de fuerzas por celda HULL | **0,131** | 72/tick; 0,022 ms/moto | Hidrostática, damping, wave face y reducción de damping de aterrizaje | Alta en relación con el ahorro máximo | No portar; no es el coste dominante del bucle |
| Wave drift + metadatos de muestras | **≤0,064** | 81,446 muestras; ≤0,011 ms/moto | El bloque también asigna tiempo/tick; drift exclusivo no aislado | Baja/media, pero poco techo | Mantener |
| Agregación HULL + drag | **≤0,057** | 6 agregaciones y hasta 24 contactos de drag | Incluye APIs de Godot; techo superior del grupo | Media | Mantener |
| SubmarineSystem | **≤0,053 antes + ≤0,016 después** | 6 de cada/tick | Grupos distintos; sin bucle numérico pesado | Alta respecto al coste | Mantener |
| Arcade clásico | **0,504 inclusivo** | 6 callbacks/tick, fuera de controller | Contiene las consultas adicionales: 0,433 ms inclusivos medidos en otro span del mismo recorrido | Reutilizar prefetch exige demostrar misma posición/instante/consumidor | Arquitectura; no sumar callback y consultas ni eliminar consultas necesarias |

La lectura cacheada ligera anterior observó 0,236 ms/tick **excluyendo validación**, con ventana que incluye estabilización. El instrumento final anidado observa 0,465 ms en la ventana medida y añade trabajo de registro dentro del padre. No se presenta 0,465 como coste exclusivo limpio ni se suma a 0,236. La siguiente investigación de representación debe empezar por un instrumento de baja frecuencia que separe copia, reset y validación sin ese sesgo.

Relaciones concretas: la preparación final instrumentada de 3,101 ms contiene base, publicación y overlays; el paso de agua de 2,100 ms contiene lectura de contactos, geometría y fuerzas. No se suman padres e hijos. El `controller.drive` inicial de 0,447 ms incluía Rider y límites: al separar fronteras aparecen 0,218/0,201/0,082 ms; el pequeño descuadre corresponde a instrumentación y variación, no a costes independientes adicionales.

La geometría nativa efectiva en B1 promedió aproximadamente 0,050 ms agregados, de los cuales 0,029 ms eran tetraedros. Su wrapper instrumentado ronda 0,126 ms. No se intentó recuperar de nuevo el ahorro de PERF-HULL-NATIVE-1.

## Cambio aprobado

`OceanLocalSeaState.fingerprint_values` lee explícitamente los mismos 13 valores locales y los mismos 12 valores de cada banda en el orden anterior. `OceanWaveBandProfile.fingerprint_values` conserva también los campos legacy serializados. Se mantiene el hash original y la lectura de valores **en cada llamada**.

Se eliminan ocho construcciones de listas de propiedades del Inspector y aproximadamente 98 accesos dinámicos `get(property.name)` por tick para los dos slots canónicos. Permanecen arrays pequeños de valores y el hash. No se cachean resultados por tick, no se depende de señales nuevas y no se modifica la planificación FFT.

Las clases derivadas y bandas de otro script mantienen la ruta reflexiva anterior. La prueba recorre las propiedades reales y compara `var_to_bytes` del array completo, además del hash, para detectar campos omitidos o cambios de tipo/orden. Si se añaden campos al esquema canónico, debe actualizarse la lista explícita y pasar esta prueba.

Microbenchmark final Windows, 1000 iteraciones por bloque, dos firmas completas por iteración, orden A/B/B/A: A = 239,390/239,983 µs; B = 8,524/8,485 µs. Diferencia de medias **231,182 µs**. La sincronización compartida diagnosticada pasó aproximadamente de 0,399 a 0,237 ms; parte del trabajo de firmas del slot sin footprint ocurre fuera de esa sincronización. No son dos ganancias para sumar.

## Paridad y carga

- **192 comprobaciones binarias, cero fallos**, en Windows y Linux: valores y hash, tres semillas, cada propiedad local y de banda, viento del perfil, bandas null, perfil explícito, clases derivadas y edición del mismo tick.
- **720 ticks × seis motos, cero hashes físicos diferentes**. La comparación se hace sobre `var_to_bytes` dentro de Godot antes de JSON. Incluye geometría por celda, posición/orientación/velocidades, fuerzas, drag, torques, contactos, underwater, muestras cacheadas y base, signed depth, normal, velocidad, historial/seams, cursor de consumidor y tiempo/campo del tick. Los ticks absolutos de publicación se expresan como edad respecto al tick actual para quitar la duración no determinista del arranque.
- Cobertura real: ambos slots locales (`mask=3`), tsunami durante 400 ticks, drift durante 720, hasta 84 paquetes de hull waves; océano base, áreas solapadas, pausa/reanudación, respawn, escalas principal/local, cambio de modo LOCAL_SURFACE/DIRECT, invalidación y dos cambios locales de espectro comprobados inmediatamente.
- No se migraron DIRECT, LOCAL_SURFACE ni CONTACT_TRACKED_DISPLACED, ni sus contratos. El replay ejercita los dos primeros; no se reclama nueva cobertura determinista del solver CONTACT_TRACKED_DISPLACED.
- Las muestras base/historia pueden tener metadatos temporales NAN antes de publicación. Se incluyen en el hash binario; la conversión posterior de NAN a null en JSON no se usa para decidir paridad. No se aplicaron tolerancias ni se ocultaron diferencias físicas.
- Smoke final de la escena guardada, **Vulkan real**, sin seleccionar backend ni workers: 60 Hz, tres workers, HULL nativo activo, una carga de geometría, 119 lotes observados, estado/muestra finitos, cero fallos.

No se modificó C++, por lo que no se recompilaron ni publicaron bibliotecas. Se comprobó la carga en ambas plataformas y que permanecen las bibliotecas finales de la integración:

| Biblioteca | SHA256 |
|---|---|
| Windows DLL | `e22176c1d2e0ef058d4816d63b76ba353ed516ed2e8b52de7cfdfd0fbec3f0d0` |
| Linux SO | `3f9fb2f1cb9422dc8d2f0d82e79342f1e9561a846011b0759495e8720a9387c9` |

## Comparativa A/B/B/A sin instrumentos detallados

Tiempos en ms. Physics es el tick completo de EngineProfiler, incluido Jolt: máximo de los pasos de cada iteración de render, con número de pasos conservado. Solo hubo una observación con varios pasos en cada grupo; la distribución de iteraciones de un solo tick coincide prácticamente (media A/B 6,215/5,913 ms). No se confunde el monitor histórico de máximo a un segundo con esta distribución.

| Métrica | A actual | B final | B − A |
|---|---:|---:|---:|
| Controller medio agregado | 5,004 | 4,842 | −0,162 |
| Controller p50 | 4,766 | 4,600 | −0,166 |
| Controller p95 | 5,891 | 5,775 | −0,115 |
| Controller p99 | 6,088 | 6,075 | −0,013 |
| Física completa media | 6,215 | 5,913 | **−0,302** |
| Física completa p50 | 6,027 | 5,717 | −0,311 |
| Física completa p95 | 7,158 | 6,905 | −0,253 |
| Física completa p99 | 7,440 | 7,278 | −0,162 |
| Frame WALL medio | 10,787 | 10,333 | −0,455 |
| WALL p50 | 12,101 | 11,873 | −0,228 |
| WALL p95 | 17,181 | 16,539 | −0,642 |
| WALL p99 | 19,351 | 18,753 | −0,598 |
| GPU viewport media | 7,438 | 7,340 | −0,098 |
| FPS medios | 92,700 | 96,779 | +4,079 observados |
| FPS mínimo sostenido, ventanas de 1 s | 74,136 | 77,285 | +3,149 observados |

Por ejecución, física media: A1 6,233; B1 5,948; B2 5,879; A2 6,198. FPS: 89,499 / 96,723 / 96,835 / 95,901. La diferencia entre A1 y A2 en FPS evidencia ruido/condiciones de escena; **no se atribuyen cuatro FPS al cambio**. La mejora pequeña de CPU tiene apoyo en el microbenchmark y en ambas pasadas B; la GPU y las colas/render también varían. El controller p99 apenas cambia.

La preparación total y sus subetapas solo están desglosadas en las capturas instrumentadas; no hay una medida A/B limpia e independiente de cada hijo en estas cuatro pasadas. No se inventa un ahorro por overlay/publicación ni se añade instrumentación pesada a posteriori para atribuir la diferencia global.

## FFT compartida y siguiente límite

Los tres trabajadores están activos en producción y en todas las capturas. Se generan los campos principal y dos locales incluso cuando el slot 0 no recibe consultas; el slot 1 sí recibe contactos. Se conserva la especulación para el tick siguiente, sus checkpoints, recuperación e invalidación.

En B, medias de wall de construcción por estado: principal 0,670 ms, local 0 1,207 ms, local 1 1,711 ms. **Se solapan en los trabajadores y no se suman a la física del hilo principal.** El pool registra pico de tres trabajadores, aproximadamente 42 031 jobs en 4689 ticks observados; solo trabajan los tres índices previstos. Las esperas p50/p95/p99 son cero en los tres estados. Máximos observados B: principal 0,325 ms y local 1 0,469 ms, aislados; espera media de cada uno inferior a 0,00011 ms. Hubo dos misses de agenda en B1 y dos en A2, con consumo correcto, sin fallos, muestras inválidas ni ticks/tiempos/resoluciones incorrectos. Los huecos de borde de EngineProfiler se conservan por separado en el JSON.

No se midió ancho de banda de memoria ni contención con contadores de hardware. La evidencia disponible no muestra espera sostenida que justifique cambiar el scheduler o apagar campos. Ninguna consulta del tick tiene latencia añadida.

El mayor bloque numérico GD separado que crece con las motos es la composición/footprints de áreas, con techo observado de 0,532 ms. El bookkeeping de contactos/celdas y las representaciones WaterSample/Dictionary también cuestan más que la matemática de fuerzas aislada. Para buscar varios milisegundos haría falta demostrar una oportunidad conjunta de interfaz y datos, con empaquetado/decodificación incluido; portar solo las fórmulas de fuerzas no lo demuestra. Las consultas Arcade adicionales deben medirse por instante y posición antes de intentar compartir prefetch. El tiempo de GPU, 7,340 ms de viewport, requiere análisis separado del CPU: no se suma a 5,913 ms de física.

Se detiene aquí tras evaluar todos los grupos: no hay una segunda oportunidad clara que justifique una migración compleja por el ahorro neto disponible. No se promete recuperar 3–5 ms ni se encadena otra optimización para mejorar los FPS observados.

## Evidencia, reproducción y commits

- `native_performance_2_checks_2026_10_20.json`: resultados, frecuencias, distribuciones, huellas, cobertura, smoke y SHA256 de capturas. Capturas brutas locales en `temp/native_performance_2/`; replays en `temp/async_fft/deterministic/np2_replay_A.json` y `np2_replay_B.json`.
- `local_fingerprint_parity.gd`: prueba de esquema/valores y micro completo con entrada/salida real. `native_performance_2_replay.gd`: replay físico ampliado. `native_performance_2_smoke.gd`: arranque guardado sin overrides.
- `native_performance_2_fingerprint.patch`: se invierte para A y se reaplica para B. `native_performance_2_diagnostic.patch`: solo para capturas de diagnóstico; debe retirarse antes del benchmark y del uso normal. Ninguno queda aplicado como selector de producción.
- `native_performance_2_local_state.patch`: copia de los cambios locales de escena/proyecto usados por la cohorte, para poder reconstruir sus condiciones sin convertirlos en cambios de producción de esta tarea. Aplicarlo únicamente en un checkout compatible tras `git apply --check`; en este workspace esos cambios ya están presentes.
- Banco: `run_native_performance_2_case.ps1 -Benchmark -Boats 6 -Select all -Seconds 3 -Label <etiqueta>`, secuencia A1/B1/B2/A2. Replay: el mismo runner con `-Replay`. Resumen reproducible: `python -B validation/physics/analyze_native_performance_2.py`.
- La captura exploratoria `detailed_diagnostic6` contenía solo el exterior; no se utiliza para cobertura global ni se mezcla con rendimiento. Las capturas completas y la comparación limpia son las identificadas arriba.
- Commit de producción y paridad: **`d6940e8`**, `Avoid inspector reflection in live local-sea spectrum fingerprints`.
- Commit de instrumentos/replay: **`3f0bc1a`**, `Add current-cohort water pipeline inventory and six-rider parity fixtures`.
- Este informe y su JSON se guardan en un commit documental separado. Permanecen pendientes únicamente los cambios locales del usuario en escena/proyecto y el `.svg.import` preexistente. `master` y `origin/master` siguen en `88cf3ae`; **no se ha hecho push**.
