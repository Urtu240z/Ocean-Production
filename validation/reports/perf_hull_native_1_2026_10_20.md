# PERF-HULL-NATIVE-1 — Geometría volumétrica HULL V1 en C++

20 de octubre de 2026 · Ocean Production · rama `codex/async-fft-lite-workers` · referencia `b47157d`.

## Decisión

**Aceptar como backend experimental opt-in. Mantener GDScript por defecto y como fallback.** El candidato conserva el algoritmo y supera el objetivo de 1 ms neto con seis motos. No se activa en presets, escenas ni ajustes de producción.

Resultado real agregado de cuatro pasadas A–B–B–A:

- Geometría completa: **2.583 → 0.142 ms/tick**; ahorro 2.440 ms.
- Controlador completo de seis motos: **7.987 → 5.419 ms/tick**; ahorro neto **2.567 ms**, incluyendo preparación, comunicación nativa y fuerzas existentes.
- FPS medios observados: **73.871 → 92.311** en esta escena y este equipo. La GPU viewport permanece prácticamente igual.
- **31.600 componentes geométricos iguales bit a bit**, 151 comprobaciones de ciclo de vida sin fallos y **945.792 valores de replay sin diferencias**. Coinciden también las **720 huellas binarias SHA256** de todos los estados físicos capturados antes de convertirlos a JSON.

La mejora de CPU aparece en ambas pasadas B y supera ampliamente la variación entre las dos A. Los percentiles de pocos procesos no garantizan una mejora universal de colas. No se amplía la tarea a otra optimización.

## 1. Confirmación de la referencia y del coste

Antes de programar se compararon los tres archivos de física con `b47157d`, el estado de PERF-CONTACT-1: eran iguales, ignorando solo CRLF/LF. En particular, `jet_ski_hull_buoyancy_v1.gd` tenía SHA256 `cbb28d9ddeddbc9318b877c9a94e9ae0d5b557404f75af11cab3fc7c5f89810e`.

El span PERF2 4 está colocado exactamente alrededor del bucle que suma `_submerged_tetra()` en `integrate_cell()`. Por ello los **2,300 ms/tick** previos corresponden al núcleo que se porta. La captura real A de esta tarea vuelve a medir **2.226 ms/tick** en ese bucle; no se usa la cifra anterior como ahorro garantizado.

Se intentó la exploración mediante el grafo y su cobertura; el servidor devolvió `Transport closed`. La auditoría usa lectura directa y búsquedas acotadas de las rutas actuales. No se afirma cobertura exhaustiva del grafo.

## 2. Celdas y algoritmo original auditado

La referencia construye la geometría **una vez**, en `configure(collision)`:

1. Toma los vértices de `ConvexPolygonShape3D` y aplica el transform local de CollisionShape3D.
2. Divide el intervalo longitudinal Z en seis estaciones de igual longitud.
3. En el punto medio de cada estación obtiene intersecciones con todos los pares de vértices que cruzan ese Z y calcula su convex hull 2D.
4. Divide la sección en las dos mitades X≤0 y X≥0.
5. Triangula cada mitad como abanico desde el vértice cero y extruye cada triángulo sobre el intervalo de la estación.
6. Cada prisma triangular usa exactamente los tres tetraedros y el orden originales. En el casco actual hay siete triángulos y **21 tetraedros por celda**, en las doce celdas.
7. Suma volumen y primer momento para el centro local; conserva área de flotación y el índice de contacto público, que agrupa las doce celdas en el mismo API de cuatro contactos.

Son **252 tetraedros por casco y 1.512 por tick para seis cascos**. El volumen de las celdas del casco actual suma **1,21580956876278 m³**. Es la cuadratura por secciones extruidas del algoritmo existente; no se sustituye por otra aproximación ni se afirma que sea el volumen exacto de toda la malla convexa.

### Datos y operaciones

| Datos/trabajo | Frecuencia | Tratamiento |
|---|---|---|
| Vértices de tetraedros, orden, centros locales, volúmenes, áreas e índices de contacto | Configuración del casco | Permanecen construidos por GDScript |
| Copia plana inmutable de los vértices y offsets para C++ | Una vez por generación/casco | No se reconstruye por tick |
| Transform del cuerpo, muestras de superficie/normal, validez y draft | Por tick/celda | Entradas actuales al lote |
| Plano local, profundidad máxima y clipping | Por tick/celda/tetraedro | Mismo cálculo, ahora opcionalmente C++ |
| Fuerzas, damping, drag, torques, aterrizaje, submarine, conducción y Jolt | Recorrido original | Permanecen en GDScript/Jolt |
| Transpuesta e inversa del transform | Se repetían por celda | El port conserva esas operaciones; no encadena otra optimización |
| Momento de tetraedros completamente mojados | Se recalculaba | Se conserva el mismo orden de cálculo y suma |

Para cada celda se mantiene la fórmula original: normal normalizada; normal y superficie en espacio local; plano crudo para profundidad; plano de soporte con `normal.y*draft_offset`; máximo de profundidad con denominador `max(normal.y,0.05)`. El centro usa el primer momento dividido por volumen cuando supera **1e-9** y el centro local original en caso contrario.

El clipping clasifica con **dot≤plane_d**, sin tolerancia nueva. Cero vértices mojados devuelve cero; cuatro integra el tetraedro completo; uno integra el tetraedro recortado; tres resta el tetraedro seco al completo; dos suma los mismos tres tetraedros definidos por p/q/r/s. No cambia el orden de vértices ni de sumas.

### Asignaciones de memoria

La referencia crea por tetraedro dos PackedVector3Array temporales (wet/dry) y el literal Array de cuatro vértices. Para seis motos son **3.024 contenedores packed más 1.512 literales Array por tick**, además de sus crecimientos de buffers. Siempre clasifica y añade los mismos cuatro vértices. **No había un Dictionary por tetraedro**; sí un Dictionary de resultado por celda.

Es un recuento de construcciones y append del código, **no un contador observado de malloc**: no se ha instrumentado el allocator ni se inventa el número de reallocations de Godot.

C++ usa arrays acotados en stack para wet/dry y los cuatro vértices. No hay contenedores dinámicos dentro del bucle de tetraedros. La salida PackedFloat64Array se crea por lote/casco, con 120 doubles (960 bytes); el adaptador conserva el Dictionary por celda consumido por la física. Los buffers de entrada y doce WaterSample3D de retención se reservan una vez por moto. La geometría plana ocupa 12.096 bytes por casco, antes de metadata: unos 70,9 KiB adicionales para seis copias, sin medir aquí el RAM total del proceso.

## 3. Núcleo nativo e integración

Nueva clase `HullBuoyancyGeometryNative`, registrada en la GDExtension existente e incluida explícitamente en SConstruct. No crea hilos, no accede a la escena y no consulta ni construye FFT.

- `configure_geometry(vertices, offsets, centers)` conserva una instantánea inmutable COW y los offsets/centros.
- `integrate_cells(transform, surfaces, normals, valid, draft)` procesa el lote completo.
- Cada fila devuelve: validez, volumen, centro mundial XYZ, profundidad y primer momento local XYZW.
- Los Vector3/Vector4 mantienen `real_t` de Godot, Float32 en esta build; los escalares que eran `float` GDScript mantienen double. Se reproducen explícitamente las conversiones y el orden de operaciones.
- Se usa el entorno base de compilación, sin introducir flags de menor precisión, nuevos algoritmos ni cambios de flags/dispatch AVX2. Los archivos FFT y sus trabajadores no se han modificado.

El selector interno está en cada instancia de `hull_buoyancy.geometry_backend`:

- `GeometryBackend.HULL_GEOMETRY_GDSCRIPT = 0`: predeterminado.
- `GeometryBackend.HULL_GEOMETRY_NATIVE = 1`: candidato.

La ruta nativa retiene las mismas doce muestras actuales, con las mismas llamadas al proveedor y comparación, y calcula la geometría por lote antes del bucle de fuerzas. Conserva el orden de aplicación de esas fuerzas. El resto del bucle —hidrostática, damping, drag, torques, propulsión y recuperación— sigue usando los mismos resultados y fórmulas. LEGACY_4POINT no pasa por esta ruta.

Las seis funciones originales `integrate_cell`, `_cross_section`, `_half_section`, `_tetra_moment`, `_plane_intersection` y `_submerged_tetra` se conservan literalmente como referencia.

Cada moto posee objeto nativo, buffers, resultados y contadores propios. `configure()` incrementa la generación y retira el objeto previo; tras reconstruir el casco se sube la geometría nueva una sola vez. Respawn sin cambio de casco reutiliza la geometría. Se mantiene el contrato de reconstrucción existente mediante `configure_hull_buoyancy/configure`; no se añade un watcher que cambie la física al editar directamente recursos.

Si falta la clase o se rechaza el resultado, se usa GDScript y aumenta el contador visible de fallback. Si ya se habían leído las muestras, el fallback usa esas muestras actuales: no repite las consultas ni recupera geometría antigua.

## 4. Paridad geométrica aislada

El fixture usa exactamente el casco guardado y añade casos de seco, parcial, sumergido, roll, pitch pronunciado, inversión, normales inclinadas, 180 poses deterministas aleatorias, planos de clipping con variaciones de draft hasta ±1e-12, barrido rápido de entrada y tetraedros casi degenerados o de volumen cero.

Comparación directa de bytes de los componentes Float64 que transportan volumen, primer momento, centro y profundidad:

| Comprobación | Resultado |
|---|---:|
| Componentes comparados | 31.600 |
| Diferencias bit a bit | 0 |
| Máximo error absoluto/relativo entre GDScript y C++ | 0 / 0 |
| Componentes NaN/Inf | 0 |
| Volúmenes de celdas completamente sumergidas frente a la configuración original | 0 diferencias bit a bit |

En el control de volúmenes complementarios, la referencia ya acumula un residual de redondeo de hasta **4,4703483581543e-8 m³**, relativo máximo **3,55777181020853e-7**. C++ reproduce **exactamente el mismo residual**. No se esconde con una tolerancia ni se cambia el algoritmo para corregirlo.

El fixture aislado no calcula fuerzas ni simula velocidad de entrada: barre posiciones (0,1 m por paso, equivalente a 6 m/s a 60 Hz). La entrada/salto y el aterrizaje físicos se comprueban después en el replay.

## 5. Microbenchmark completo y criterio de continuación

Dentro de Godot, geometría y muestras idénticas, 800 lotes medidos por pasada más 48 de calentamiento. Orden A1–B1–B2–A2 para uno y seis cascos. Sin PRINT por iteración.

A ejecuta `integrate_cell`; B incluye preparación de arrays desde WaterSample3D, llamada GDExtension, bucle nativo, lectura del resultado, reconstrucción del Dictionary de celda y escritura de volúmenes/centros/profundidades consumidos por la física. La preparación constante del casco queda fuera en ambos; no se compara solo el bucle C++ con toda la ruta GDScript.

| Cascos | Pasada | Media ms | p50 ms | p95 ms | p99 ms |
|---|---|---|---|---|---|
| 1 | A1 | 0.432 | 0.391 | 0.668 | 1.129 |
| 1 | B1 | 0.024 | 0.020 | 0.037 | 0.049 |
| 1 | B2 | 0.022 | 0.020 | 0.029 | 0.036 |
| 1 | A2 | 0.468 | 0.396 | 0.809 | 1.459 |
| 6 | A1 | 2.910 | 2.587 | 5.544 | 6.777 |
| 6 | B1 | 0.136 | 0.113 | 0.236 | 0.373 |
| 6 | B2 | 0.193 | 0.204 | 0.388 | 0.424 |
| 6 | A2 | 2.731 | 2.409 | 4.808 | 6.802 |

Promedio de las dos medias por variante:

| Cascos | GDScript ms/tick | Nativo ms/tick | Ahorro neto ms/tick | Ahorro medio por casco |
|---|---|---|---|---|
| 1 | 0.450 | 0.023 | 0.428 | 0.428 |
| 6 | 2.820 | 0.165 | 2.656 | 0.443 |

Con seis cascos se observan **2.656 ms netos** de ahorro; supera 1 ms incluso comparando las medianas más desfavorables de estas pasadas. Por ello se continuó a la integración. Es una medición aislada, no una predicción de FPS.

## 6. Replay de 720 ticks y seis consumidores

Se reutiliza el replay de PERF-CONTACT-1, con su mismo recorrido, áreas, muestras, cambios de escala/modo, pausa y respawn. A/B solo seleccionan el backend geométrico. PERF-CONTACT-1 permanece activo en ambos.

La captura añade volúmenes, centros numéricos y profundidad por celda. Además genera SHA256 de `var_to_bytes` de todo el estado físico de cada tick **antes de serializar JSON**. Solo separa los contadores del backend; se conservan en bruto. No se omite ningún valor físico, arranque ni NaN de estado desconocido.

- **945.792 valores sin diferencias.**
- **720/720 huellas binarias físicas iguales**, evitando que el formato decimal pueda ocultar redondeos.
- Alturas/posiciones del agua, normales, velocidades, signed depth, fuerzas, drag por punto, torques, orientación, posición y velocidades del cuerpo coinciden.
- Coinciden flags de contacto, underwater, aterrizaje, recuperación y el estado tras respawn.
- Cobertura por pesos: 121 ticks de océano base, 462 de un área y 137 de solapamiento.
- Cada moto nativa registra 719 lotes evaluados, **una subida de geometría y cero fallbacks**.
- Los contactos aún sin evaluar de los ticks 0 y 240 (arranque/respawn) son iguales en ambos y permanecen incluidos; no hay pérdida adicional de contactos.

Las capturas preliminares con centros como Vector3 textual se conservaron pero no se usan como prueba final de precisión. Después se guardaron centroides numéricos completos y, finalmente, las huellas binarias. Estos replays no son pasadas de FPS.

Las **151 comprobaciones de ciclo de vida** verifican repetición sin resubir geometría, cambio de casco, rechazo de una forma que no es ConvexPolygonShape3D (igual que la referencia), restauración de geometría y rechazo de un lote simulado con fallback visible. No sustituyen el replay: este último utiliza el backend real y registra cero fallbacks.

## 7. Comparación real mínima A–B–B–A

Cuatro ejecuciones completadas sin errores de ejecución, seis motos, ASYNC_3_WORKERS, FFT 128/128/128 cúbica, Jolt a 60 Hz, D3D12, 1920×1080. Misma escena, cámara, efectos, recorrido y áreas en A/B.

Calentamiento 8 s y estabilización 0,5 s por caso; seis posiciones mantenidas 2 s, cruce X 4 s, cruce Z 14 s y salto/aterrizaje 3 s. Stern Mist permanece desactivado mediante las mismas copias privadas en ambos controles. No se guardan cambios en recursos.

SHA256 de escena, igual antes/después y en las cuatro pasadas: `1c3b2c66566ff528b0933b65b3d9d9816ee8dcc0dec2acbfd5db1781f1f5fe84`. Es la escena actual usada por PERF-CONTACT-1, no la del antiguo informe de 27 pasadas. El fixture existente añade una huella slot 1 en memoria; las huellas guardadas están inactivas. El replay de paridad prueba aparte las dos áreas solapadas.

Todos los tiempos siguientes son ms/tick agregado de seis motos, salvo WALL/GPU que son por frame. Las duraciones son **inclusivas según su nivel**; no se suman controlador + agua + celdas + tetraedros.

| Métrica | A media | B media | A p50 | B p50 | A p95 | B p95 | A p99 | B p99 |
|---|---|---|---|---|---|---|---|---|
| Bucle de tetraedros | 2.226 | 0.030 | 2.185 | 0.029 | 2.933 | 0.044 | 3.056 | 0.049 |
| Geometría completa de celdas | 2.583 | 0.142 | 2.541 | 0.140 | 3.299 | 0.167 | 3.436 | 0.205 |
| Sistema de física de agua | 4.389 | 1.701 | 4.348 | 1.685 | 5.266 | 1.874 | 5.438 | 2.248 |
| controller.integrate agregado | 7.987 | 5.419 | 8.002 | 5.271 | 8.910 | 6.212 | 9.208 | 7.041 |
| Física completa observada | 9.232 | 6.695 | 9.256 | 6.571 | 10.375 | 7.664 | 10.763 | 9.086 |
| Frame WALL | 13.537 | 10.833 | 14.851 | 12.477 | 17.489 | 16.736 | 20.827 | 18.867 |
| GPU viewport | 6.925 | 6.924 | 6.343 | 6.367 | 10.458 | 10.390 | 11.185 | 11.128 |

| Resultado | A GDScript | B Nativo | Diferencia B−A |
|---|---|---|---|
| FPS medios | 73.871 | 92.311 | +18.441 |
| Mínimo sostenido ~1 s | 61.158 | 69.418 | +8.260 |
| Máximo WALL ms | 27.126 | 28.526 | +1.400 |
| Máximo de física observada ms | 16.533 | 13.735 | -2.798 |

### Reproducibilidad por ejecución

| Pasada | Geometría media | Agua media | Controller media | Controller p99 | WALL p95 | WALL p99 | FPS medios |
|---|---|---|---|---|---|---|---|
| A1 | 2.585 | 4.385 | 7.949 | 9.093 | 17.443 | 20.874 | 74.435 |
| B1 | 0.143 | 1.719 | 5.478 | 7.766 | 17.016 | 19.037 | 91.427 |
| B2 | 0.141 | 1.682 | 5.361 | 6.345 | 16.416 | 18.585 | 93.195 |
| A2 | 2.580 | 4.392 | 8.025 | 9.307 | 17.533 | 20.718 | 73.306 |

El ahorro real medio de controlador es **2.567 ms/tick** para seis motos, aproximadamente **0.428 ms por vehículo** como promedio del total. A 60 Hz equivale a unos **154.045 ms de tiempo CPU por segundo** de esa carga; no es utilización total de la máquina.

La reducción medida de geometría (2.440 ms) explica la mayor parte del cambio. No se atribuye el resto de la diferencia entre cronómetros a otra optimización. La GPU media es 6.925 frente a 6.924 ms, coherente con conservar el trabajo de render.

## 8. Qué incluyen los relojes y límites de la conclusión

- GDScript tetraedros es el span original PERF2 4. Nativo usa un reloj opcional `steady_clock` alrededor del mismo bucle por celda, agregado por tick. No se presenta ese tiempo interno como el coste completo.
- Geometría nativa incluye empaquetado, normal/validez de entrada, comunicación, escritura del resultado y decodificación a Dictionaries. La retención de muestras del proveedor se mide en física de agua/controlador, junto con el resto de la ruta. La tabla no oculta ese coste: el ahorro neto principal procede del controlador completo.
- En GDScript, parte del primer tratamiento de normal está fuera de `integrate_cell`; en B está dentro del empaquetado. La comparación de la subetapa resulta conservadora para B. Las fuerzas siguen recibiendo exactamente la misma normal y el normalizado geométrico posterior.
- Geometría está dentro de agua, y agua dentro de controlador. Tetraedros están dentro de geometría. No se suman duraciones inclusivas. Los perfiles de trabajadores FFT tampoco se agregan al hilo de física.
- Física completa procede de EngineProfiler: **máximo tick físico completo por frame renderizado**, incluyendo Jolt. Hubo dos iteraciones de dos pasos en A y tres en B; máximo dos en ambos. Las otras iteraciones medidas tienen un paso. Se conservan el número de pasos y el subconjunto de un paso en JSON; no se reconstruye una distribución individual inexistente.
- Se contabilizan 18 ticks de borde sin muestra completa en A y 13 en B. No se rellenan ni se eliminan silenciosamente.
- Los percentiles se calculan sobre muestras agrupadas; FPS medio = frames/tiempo WALL. El mínimo sostenido usa bloques consecutivos de aproximadamente un segundo dentro de cada caso.
- Los máximos no mejoran uniformemente: B tiene un frame de 28,526 ms frente a 27,126 ms en A. Con dos procesos por variante no se interpreta un evento extremo ni una diferencia de p99 como garantía general de estabilidad. La evidencia sólida aquí es la reducción grande y repetida del coste medio y de geometría, sin divergencia física.
- Se alterna ABBA y se conserva calentamiento/configuración. No se registraron temperaturas/frecuencias por núcleo ni throttling en esta cohorte; no se afirma igualdad térmica perfecta.
- La bit-identidad se ha demostrado en esta build Windows x86_64/Godot 4.7.1 `a13da4feb`. Otros compiladores o builds de precisión necesitan ejecutar los fixtures; no se generaliza sin prueba.

## 9. Contadores, errores y alcance protegido

En las cuatro pasadas: cero ticks FFT incorrectos, tiempos/resoluciones incorrectos, campos inválidos, recuperaciones o fallos. Los misses async son dos en A y uno en B, resueltos por espera del mismo tick; el planificador no se ha cambiado.

En B hay **seis subidas de geometría en total**, una por moto durante la preparación, sin nuevas subidas por tick y con cero fallbacks. Los avisos de división entera, parámetro que oculta `position` y UID foam2d resuelto por ruta están conservados en logs; no hay errores de ejecución en las pasadas aceptadas.

Un primer intento A1 acabó por un error de tipo del recorder **antes de arrancar la escena**. Se conserva bajo `real/setup_failure`, se corrigió y no cuenta como pasada medida. No se han quitado muestras lentas de las cuatro ejecuciones válidas.

Sin modificaciones a navegación, controlador, LEGACY_4POINT, parámetros físicos, FFT async, número de workers, resolución, espectro, AVX2, shaders, efectos, Jolt o escenas guardadas. La optimización PERF-CONTACT-1 permanece y sus tres líneas locales previas de sink diagnóstico siguen fuera de nuestros commits; el banco utiliza ese sink para sus spans. Se necesita ese soporte diagnóstico local para reproducir esas columnas desde un checkout limpio; el backend geométrico no depende de él.

## 10. Archivos, commits y rollback

- [Datos, perfiles, paridad e índice SHA256 de capturas](perf_hull_native_1_results_2026_10_20.json).
- Núcleo: `addons/ocean/physics/native/ocean_query/src/hull_buoyancy_geometry_native.h/.cpp`; registro en `register_types.cpp` y lista explícita de SConstruct.
- Adaptador/selector: `jet_ski_hull_buoyancy_v1.gd`; conexión exclusiva a HULL V1 en `jet_ski_water_physics_system.gd`.
- `build_hull_native.ps1`: compilación con copia local de la DLL anterior.
- `hull_native_isolated.gd -- --benchmark=true --iterations=800`: paridad y coste completo de uno/seis cascos.
- `hull_native_lifecycle.gd`: invalidación/reconstrucción/fallback.
- `run_hull_native_case.ps1 -Variant A -Label hull_A_binary -Replay`, después B, y `compare_hull_native.py`: replay con hashes.
- `run_hull_native_case.ps1` con A1/B1/B2/A2 y `analyze_hull_native.py`: comparación real.
- Capturas: `temp/hull_native_1/` y `temp/async_fft/deterministic/hull_*.json`, locales y fuera del repositorio.
- DLL final SHA256: `e22176c1d2e0ef058d4816d63b76ba353ed516ed2e8b52de7cfdfd0fbec3f0d0`.
- Commits separados: `4804bb3` prototipo/fixture aislado; `590d71b` integración con fallback y DLL; `746989e` ciclo de vida/replay/A-B; `e1f2e7b` huellas binarias finales.
- Rollback operativo: `hull_buoyancy.geometry_backend = 0`. Para retirar el código completo, revertir los commits del encargo en orden inverso y usar/recompilar su DLL correspondiente.

Se conserva `codex/async-fft-lite-workers`, sin checkout de master ni push. Los cambios locales previos de escenas, proyecto, tsunami, shaders, efectos y diagnóstico se mantienen pendientes y fuera de los commits de esta tarea. No se ha activado el selector nativo en producción.

**Parada:** candidato geométrico experimental validado, ahorro CPU neto medido y mismo comportamiento en el replay. No se encadena ninguna optimización adicional.
