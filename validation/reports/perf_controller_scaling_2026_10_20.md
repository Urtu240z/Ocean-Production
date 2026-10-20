# PERF-CONTROLLER-SCALING — 20/10/2026

**Resultado:** se integra una sola mejora adicional, pequeña y reversible, en la validación del proveedor. El controlador agregado de seis motos pasa de **5.419 a 4.836 ms/tick**, ahorro neto **0.583 ms/tick** (0.097 ms por vehículo como promedio del total). HULL sigue exclusivamente nativo. No se cambia ninguna fórmula, punto, fuerza, FFT, Jolt, shader o ajuste de conducción.

El candidato no guarda una validación por tick. **Comprueba los valores actuales en cada lectura**, incluso si cambian varias veces dentro del mismo tick.

## 1. Auditoría acotada del controlador

Código examinado: JetSkiController._integrate_forces/_perf2_integrate_forces_body; JetSkiWaterPhysicsSystem.step/_step_hull_buoyancy; entradas a NavigationSystem, DriveSystem, RiderDynamicsSystem, InputSystem, SubmarineSystem, TrickSystem y ArcadeHandlingSystem; proveedor CPU y metadatos de Ocean/OpenOceanFFT. Descubrimiento por fuente directa al no responder el grafo MCP.

Se instalaron temporalmente cronómetros entre fases del método existente, sin mover operaciones físicas. El parche íntegro está en validation/fixtures/scaling_2_diagnostic.patch y se retiró antes de medir A/B. Las capturas diagnostic1/diagnostic6 tienen 1985/1987 ticks completos. El desglose siguiente pertenece a esa cohorte **más instrumentada, anterior a la optimización**, no a los tiempos de producción del ABBA.

| Fase medida, exclusiva de las otras filas | 6 motos ms/tick | Por moto, promedio | Límite observado del grupo |
|---|---:|---:|---:|
| Preparación de consultas, con proveedor y sus hijos | 3.036 | 0.506 | ≤ 3.036 ms, antes de costes necesarios |
| step de agua, con consultas cacheadas/fuerzas | 1.956 | 0.326 | ≤ 1.956 ms, antes de costes necesarios |
| Preparación de propulsión + DriveSystem, con sus consultas | 0.568 | 0.095 | ≤ 0.568 ms, antes de costes necesarios |
| Soporte/NavigationSystem y transiciones de contacto | 0.087 | 0.014 | ≤ 0.087 ms, antes de costes necesarios |
| Begin tick de Navigation/Drive/Rider/Trick y controles | 0.068 | 0.011 | ≤ 0.068 ms, antes de costes necesarios |
| TrickSystem.update_state | 0.057 | 0.009 | ≤ 0.057 ms, antes de costes necesarios |
| Estado/actitud y SubmarineSystem antes de consultas | 0.056 | 0.009 | ≤ 0.056 ms, antes de costes necesarios |
| Configuración de física, inercia y flags por tick | 0.049 | 0.008 | ≤ 0.049 ms, antes de costes necesarios |
| InputSystem.sample_input | 0.030 | 0.005 | ≤ 0.030 ms, antes de costes necesarios |
| Factor de soporte/submarine previo a step | 0.029 | 0.005 | ≤ 0.029 ms, antes de costes necesarios |
| Guardas HULL y reinicio de estados al entrar | 0.018 | 0.003 | ≤ 0.018 ms, antes de costes necesarios |
| RiderDynamics y aplicación de trim/nose/submarine | 0.018 | 0.003 | ≤ 0.018 ms, antes de costes necesarios |
| SubmarineSystem después de contactos | 0.017 | 0.003 | ≤ 0.017 ms, antes de costes necesarios |
| ArcadeHandling (ruta desactivada en estos casos) | 0.002 | 0.000 | ≤ 0.002 ms, antes de costes necesarios |

Las filas son disjuntas entre fases del controlador, pero preparación/agua/drive **incluyen sus propias consultas y fuerzas**. No se suman otra vez validación, áreas, geometría ni otros hijos a esas filas. Navigation incluye preparación de soporte/transiciones; Drive incluye preparación del factor y consultas de propulsión, no solo una función matemática.

El wrapper y el propio registro de fases consumen un residuo medido de 0.226 ms/tick. No se atribuye íntegramente a telemetría de producción ni se propone recuperarlo como una optimización. El controlador instrumentado completo ronda 6.218 ms frente al ~5,42 ms de la cohorte sin esos relojes.

No hay un cronómetro exclusivo separado para cada llamada apply_force/apply_torque ni para cada getter dentro de RiderDynamics. Están dentro de las fases indicadas; no se inventa su coste. La física completa incluye Jolt, pero no permite separar aquí el coste exclusivo de Jolt. El residuo entre medias controller/agua tampoco es un único subsistema recuperable.

## 2. Candidato respaldado por tiempo y frecuencia

En la ventana diagnóstica del proveedor, que **incluye settle**, se observaron:
- Una moto: 20.660 validaciones/tick; 0.255 ms inclusivos.
- Seis motos: 113.044 validaciones/tick; 1.120 ms inclusivos.
- Lectura completa de metadatos, hijo de validación: 0.553 ms de seis motos. El resto del validador ronda 0.566 ms **en esa misma ventana**.
- Lecturas completas totales: 120.044/tick; muestras cacheadas 78.000/tick y misses 3.229/tick. Son llamadas del proveedor, no FFTs construidas.
- Cambio de consumidor: 0.065 ms/tick agregado; no domina esta captura.

No se restan estas medias de las fases del controlador porque las ventanas no son idénticas y hay distintos padres. La frecuencia demuestra por qué tiene más potencial evitar construcción repetida de metadatos que reescribir configuración/inputs/tricks de unas centésimas.

La lectura original genera dos Dictionaries principales de metadatos; los validadores además contienen defaults {} y una clave de versión construida mediante una Array y formato de cadena. Hay acceso dinámico call/get/has_method y referencias válidas en esa ruta. No se midieron mallocs reales ni se convierte cada Variant en una supuesta asignación heap.

## 3. Cambio implementado

Ocean.matches_physics_source recibe el identificador FFT, revisión de fuente/espectro/espacio, escalas y nivel de mar esperados. Comprueba directamente disponibilidad, rebuild/debounce, flags y fuente actual. OpenOceanFFT.matches_physics_metadata comprueba la superficie y los valores escalares actuales del contrato.

CpuFftWaterProvider usa ese predicado únicamente cuando está soportado y no existe una clave de importación fallida pendiente. Cuando coincide, devuelve exactamente la misma condición final field_ready/fft/native. Cuando no coincide, ejecuta **toda la ruta anterior**, conservando mensajes, estado, limpieza de contactos e invalidación. Hosts de validación sin el método mantienen la ruta anterior.

Se eliminan en el caso coherente la consulta completa de metadatos, sus Dictionaries, la clave de versión y las conversiones que solo servían para reconstruir ese estado. No se eliminan comprobaciones de disponibilidad ni se reutiliza una respuesta antigua. La capacidad del host se detecta al configurar; **no se cachean sus valores físicos**.

Por tanto, viento/reconstrucción, espectro, reemplazo de fuente, escalas, revisión espacial y nivel de mar dentro del mismo tick provocan el mismo camino lento. QueryMode, reset y consumidores conservan sus mecanismos anteriores. La pausa/tiempo no necesita una nueva clave: el getter omitido de wave_time solo devolvía el valor, y ese campo tampoco participaba en la decisión antigua.

La reducción de operaciones por validación coherente está demostrada por el código y los tests. No se presenta un contador posterior del proveedor no medido como si lo estuviera. Las ~113 validaciones siguen existiendo; lo evitado es reconstruir su representación de diagnóstico. Las lecturas completas necesarias para sincronización/preparación siguen existiendo.

El ahorro medido también incluye la sobrecarga opcional del span PERF2 de una lectura que deja de ocurrir; no se asignan todos los milisegundos exclusivamente a Dictionaries. El microbenchmark sin journal nativo muestra asimismo ahorro.

## 4. Paridad y microbenchmark antes de ABBA

source_validation_micro.gd utiliza Ocean y OpenOceanFFT reales fuera del árbol, con metadatos controlados y referencia congelada del validador. **67 comprobaciones, cero fallos**: salida, estado, razones, field_ready, reset de contactos y nulificación de fuente. Todas las mutaciones se hacen en el mismo tick.

Escenarios: coherencia, status/rebuild/initializing/debounce, enabled/FFT, identificador y revisión, espectro, revisión espacial, escalas vertical/horizontal/nivel, NaN/infinito/escala negativa, superficie ausente, importación fallida, campo no listo y objetos ausentes. PERF-CONTACT-1 conserva además **73 comprobaciones, cero fallos**, en el entorno final sin errores de arranque.

Microbenchmark completo: 64 vueltas de calentamiento + 800 medidas por pasada; A1/B1/B2/A2 para una y seis motos, 19 validaciones por vehículo (114 para seis, próximo al promedio observado). Incluye llamadas, predicado, validaciones y bindings; no calcula FFT ni altera campos. La media de las dos pasadas de seis es ~0,831→0,224 ms, **0,607 ms menos**. Con una: ~0,142→0,032 ms. No se promete ese valor de microetapa como ahorro de controlador.

Replay existente: referencia hull_B_binary.json frente a source_B.json y después source_clean_B.json, **720/720 hashes físicos iguales** en ambos. Se conserva el replay de consolidación hull_production, también igual. Los hashes preservan los bits físicos antes de serializar a JSON; incluyen muestras, geometría de celdas, fuerzas, torques y movimiento de seis cuerpos, áreas solapadas, respawn y cambios de configuración. No se ocultan divergencias mediante tolerancia.

## 5. Incidente de entorno y presupuesto real de pruebas

Se hicieron dos capturas diagnósticas (una/seis motos), microbenchmark y replay antes del primer ABBA. Después de source_B2 desapareció del workspace la carpeta no versionada addons/godot-rapier3d, que existía al inicio. No se realizó ninguna operación de este encargo sobre esa carpeta.

source_A2 y la pareja focalizada tail_A/tail_B registraron tres errores de arranque por la extensión ausente. Aunque el proyecto seguía configurado para Jolt, **se excluye toda esa primera cohorte de la decisión y de las tablas finales**, por no tener el mismo entorno. También se conserva la observación preliminar de p99 peor; no se ha borrado para favorecer el resultado.

Solo se retiró la referencia obsoleta de .godot/extension_list.cfg, caché generada y no versionada. No se restauró Rapier ni se cambió project.godot/Jolt. Se ejecutó una cohorte coherente clean_A1/B1/B2/A2, la única aceptada para comparar rendimiento. Esta repetición fue una reparación de validez experimental; no otra optimización ni un intento de seleccionar mejores muestras.

El runner registra antes y después huellas de proyecto, escena, extensiones, DLL y los tres archivos de metadatos. Las cuatro huellas son idénticas entre sí y dentro de cada pasada. Se conservaron todos los logs y capturas, incluidos los excluidos. No hay errores de ejecución en la cohorte aceptada. Tras ella se repitió únicamente la paridad en el entorno final y el check corto de compatibilidad.

## 6. ABBA final aceptado

Mismo escenario/recorrido/cámara/efectos, 1920×1080, D3D12, 60 Hz y ASYNC_3_WORKERS, FFT cúbica 128/128/128, HULL nativo en A y B. Escena SHA256: 1c3b2c66566ff528b0933b65b3d9d9816ee8dcc0dec2acbfd5db1781f1f5fe84. Calentamiento 8 s y ventanas existentes. Sin cambios guardados de cámara, física o ajustes de producción.

| Métrica (ms) | A: original | B: predicado en vivo | B−A |
|---|---:|---:|---:|
| Controller media | 5.419 | 4.836 | -0.583 |
| Controller p50 | 5.255 | 4.681 | -0.574 |
| Controller p95 | 6.226 | 5.628 | -0.599 |
| Controller p99 | 6.628 | 5.873 | -0.756 |
| Agua media | 1.687 | 1.235 | -0.452 |
| Geometría HULL media | 0.143 | 0.145 | 0.001 |
| Física completa media | 6.707 | 6.047 | -0.660 |
| Física completa p50 | 6.572 | 5.915 | -0.657 |
| Física completa p95 | 7.656 | 6.992 | -0.664 |
| Física completa p99 | 8.279 | 7.291 | -0.987 |
| WALL media | 10.917 | 10.212 | -0.704 |
| WALL p50 | 12.491 | 11.777 | -0.714 |
| WALL p95 | 16.861 | 16.112 | -0.749 |
| WALL p99 | 19.060 | 18.272 | -0.788 |
| GPU media | 6.997 | 6.922 | -0.075 |
| GPU p50 | 6.435 | 6.390 | -0.045 |
| GPU p95 | 10.505 | 10.389 | -0.115 |
| GPU p99 | 11.455 | 11.138 | -0.318 |
| FPS medios | 91.604 | 97.919 | 6.315 |
| FPS mínimo sostenido ~1 s | 78.649 | 83.483 | 4.834 |

| Pasada aceptada | Controller media | p95 | p99 | Física p95 | WALL p95 | FPS medios |
|---|---:|---:|---:|---:|---:|---:|
| clean_A1 | 5.445 | 6.271 | 7.007 | 7.692 | 16.966 | 91.240 |
| clean_B1 | 4.821 | 5.623 | 5.867 | 6.989 | 16.135 | 98.024 |
| clean_B2 | 4.851 | 5.636 | 5.874 | 6.992 | 16.110 | 97.814 |
| clean_A2 | 5.392 | 6.188 | 6.474 | 7.615 | 16.688 | 91.969 |

**Ahorro neto de controlador: 0.583 ms/tick**. Ambas B son inferiores a ambas A. El ahorro de agua es 0.452 ms; no se suma a su padre. El resto de diferencias temporales no se atribuye a otra optimización.

FPS 91.604→97.919 es una observación de esta cohorte, no una promesa. La GPU media también varía -0.075 ms pese a no haber cambio de render. No se adjudica al predicado una mejora de GPU. No se agregan los 2,567 ms históricos de HULL de otra cohorte para anunciar un ahorro combinado no medido.

## 7. Cronómetros y límites

Física completa es el máximo tick físico completo por iteración render de EngineProfiler; se conservan número de pasos y subconjunto de un paso. No es una reconstrucción de todos los ticks individuales en frames con varios pasos. Las filas de borde sin muestra se contabilizan en datos, no se rellenan ni se eliminan sin explicación.

Medias/p50/p95/p99 se calculan sobre muestras agrupadas; no se restan percentiles entre cronómetros. WALL, física y GPU no se suman. El máximo WALL de A es 62.153 ms, frente a 26.400 en B; ese evento tampoco se ha recortado.

Cero tick/tiempo/resolución FFT incorrectos, campos inválidos, recuperaciones o fallos en el ABBA aceptado. Se conserva el coste de los dos slots físicos especulativos del driver, incluso donde uno no recibe consultas de áreas; no se modifica el trabajo FFT.

La alternancia y las huellas no demuestran igualdad térmica perfecta: no se registraron temperaturas/frecuencias por núcleo ni throttling. La paridad corresponde a Windows x86_64/Godot 4.7.1 a13da4feb. No se midieron dos cámaras de pantalla partida, autoridad online, IA ni Steam Deck.

## 8. Priorización siguiente, sin nueva reescritura

El mayor grupo restante medido sigue siendo preparación de consultas (3,036 ms/tick en el diagnóstico anterior, incluyendo sus hijos), seguido de agua. **3,036 ms es un límite superior del grupo en aquella captura, no una promesa recuperable ni un coste exclusivo de una función numérica.**

Un siguiente diagnóstico acotado debería separar en la misma ventana preparación/decodificación de queries, publicación de contactos y overlays del proveedor; solo entonces decidir un lote C++ de conversión. Su trabajo matemático y las consultas nativas deben permanecer. Pasar el controlador entero a C++ o eliminar validaciones por tick exigiría más riesgo y no se ejecuta aquí. Los grupos de configuración/input/tricks, de 0,03–0,07 ms agregados, no justifican esa reescritura.

La sincronización de áreas (~0,422 ms) es compartida, no por moto. Los slots FFT sin consultas tienen trabajo de fondo medido, pero sus esperas actuales son prácticamente nulas: no se convierten sus tiempos de trabajadores en milisegundos recuperables del hilo principal. GPU y Jolt se mantienen separados; no hay evidencia aquí para reescribir Jolt.

## 9. Archivos, commits y estado local

- Producción: cpu_fft_water_provider.gd, ocean.gd y open_ocean_fft.gd; predicados de metadatos, sin matemáticas de FFT.
- Referencia solo en validation/fixtures/source_validation_reference_provider.gd.
- Fixtures existentes ampliados con una selección de referencia exclusivamente de validación. No hay selector geométrico GDScript en gameplay.
- source_validation_micro.gd, analyze_scaling_2.py y run_scaling_2_case.ps1 reproducen paridad, diagnóstico y comparación.
- [Datos completos, capturas excluidas e integridad](perf_scaling_2_results_2026_10_20.json).
- Bloque A: a03a6fa. Bloque B: 475cd5e. Bloque C: el commit que incorpora este informe y el predicado.
- Se conservaron los cambios locales previos de escenas, proyecto, tsunami, shaders, efectos y el sink diagnóstico del proveedor fuera de nuestros commits. La desaparición externa de Rapier se registra, no se atribuye a una limpieza propia.
- El sink diagnóstico local previo es necesario para reproducir algunas columnas desde un checkout limpio; el predicado de producción no depende de él.
- Revertir el commit C restaura la validación anterior; revertir A recupera el estado experimental de HULL. No se hizo push.

**Parada:** HULL nativo consolidado; áreas conservadas tras acotar su ahorro; una mejora de metadatos integrada con paridad y 0.583 ms netos medidos. No se encadena otra optimización.
