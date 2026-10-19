# Auditoría: FFT física Lite asíncrona

Base: `081dd40`, Ocean Production, Godot 4.7.1, Jolt, D3D12. Trabajo experimental; `SYNC_BASELINE` sigue siendo el valor predeterminado.

## Ruta anterior y uso real del pool

`OceanQueryNative::build_dynamic_physics_lite` configura tres campos y recorre las bandas secuencialmente. Cada `DynamicOceanPhysicsField::build_lite` ejecuta, en este orden, `prepare_`, `transform_pair_(0)`, `transform_pair_(1)` y `finish_build_`. Cambiar `set_dynamic_worker_count` no paralelizaba esa ruta.

El `PersistentFftPool` anterior se usaba en `build_all_outputs_`: una tanda de hasta tres preparaciones, una barrera, otra de hasta dieciocho transformaciones y otra barrera. La ruta completa y `DynamicOceanAsyncPublisher` utilizan esa infraestructura. Ese publicador permite campos atrasados y coalescing con tolerancias temporales: se conserva para su API anterior y no se utiliza para el nuevo contrato Lite.

La ruta AVX2 de Lite ya existía. No se ha introducido otra FFT, biblioteca, resolución ni representación numérica.

## División del trabajo

El nuevo `DynamicOceanLiteAsync` envía tres trabajos persistentes por estado al mismo pool. Cada trabajo ejecuta **toda una banda Lite**, conservando el orden interno anterior. Océano principal y dos estados locales producen nueve trabajos potenciales.

No existen nuevos hilos productores. Las colas de la FFT completa y de Lite comparten los mismos trabajadores. Las reservas de modo fijan el tamaño total del pool en tres o cuatro; una llamada posterior a `set_dynamic_worker_count(6)` no puede saltarse ese límite. Dos reservas incompatibles se rechazan. Cambiar de tamaño drena y termina los trabajadores anteriores antes de crear sus sustitutos. La última reserva restaura el tamaño previo.

`admission_mutex_` serializa envíos, cambios de tamaño y las tandas síncronas del pool. Las tareas nunca envían otras tareas. También se corrige la notificación de la barrera antigua: se notifica mientras sigue retenido su mutex, evitando acceder a una condición de stack que el llamador ya pudiera destruir.

## Memoria mutable y lectores

| Datos | Propietario / protección |
|---|---|
| H0, lattice y coeficientes Lite | Copia privada por banda; se configuran sin trabajos pendientes |
| Fase, rotor, contador de rebase | Un builder persistente por banda |
| Espectros, scratch y perfiles | Solo el trabajo de esa banda |
| Checkpoint de fase | Cuatro arrays double y estado escalar; se reservan antes de trabajar |
| Campos publicados | Tres slots por estado, retenidos por `shared_ptr<const LiteSnapshot>` |
| Estado de cola y barrera | Mutex y contador de tres trabajos pendientes |
| Telemetría del pool | Contadores atómicos independientes de la matemática |

La publicación intercambia los dos campos complejos ya calculados y los arrays de evolución necesarios para el oráculo. Los snapshots no reciben otra IFFT ni conversiones de precisión. Las consultas nativas conservan una referencia al snapshot durante todo el batch. Un slot solo se reutiliza cuando no queda ningún lector ni publicador reteniéndolo. Si los tres slots están retenidos, se aplica backpressure y se mide la espera.

Los métodos de control/configuración conservan el contrato de un propietario en el hilo de física/Godot. Las pruebas concurrentes verifican lectores de snapshots inmutables; no convierten en concurrentes las APIs heredadas de configuración, cachés de contacto o parches locales.

El probe PERF-3 mutable no se comparte con los trabajos nuevos. Sus perfiles por banda se publican junto al campo completo.

## Tick, predicción y recuperación

La clave compara exactamente `tick`, `time`, `spectrum_version` y `resource_generation`. No se redondea el tiempo ni se utiliza una tolerancia para admitir otro tick.

`consume_dynamic_lite` espera una construcción completa con esa clave. Si la predicción llega tarde, espera su barrera. Si no corresponde al tiempo solicitado, termina la tarea anterior, restaura su checkpoint y construye el mismo tick solicitado en el pool. No publica resultados parciales, no devuelve silenciosamente el tick anterior y no calcula una segunda FFT concurrente sobre los mismos buffers. Se registran misses, recuperaciones, invalidaciones, fallos, tiempo bloqueado y espera de buffers.

El driver prepara los estados independientemente de las posiciones de las motos. Si un recurso local está configurado pero su zona está inactiva, prepara una instancia exclusivamente CPU: no crea solvers, texturas, geometría o efectos GPU.

Los relojes existentes siguen siendo autoritativos. Para anticipar el océano principal se utiliza `physics_wave_time_step`, el paso exacto que publicó el FFT original. Esto evita sustituir el paso float del controlador por un delta double parecido. Los estados locales usan la misma expresión temporal y los mismos multiplicadores que su ruta anterior.

Pausa, cambios de velocidad y rewind invalidan la predicción cuando cambia la clave. Cambios de espectro/recurso, limpieza y shutdown esperan los trabajos pendientes antes de retirar los builders. Los lectores conservan sus snapshots antiguos sin que el escritor los sobrescriba. El publicador FFT completo anterior no se puede iniciar simultáneamente en la misma instancia experimental Lite.

Al reemplazar la instancia nativa del proveedor se retiran primero todas sus reservas y las de sus estados locales, incluso si el capturador de diagnóstico todavía conserva el objeto anterior. Un estado local recién configurado hereda el modo efectivo del nativo principal. Al retirar un modo se invalidan también los metadatos de caché local. Un fallo real de snapshot local se registra y propaga como muestra inválida; no se transforma silenciosamente en mar base sin la contribución local.

## AVX2 y compilación

La decisión sigue siendo `OceanQueryCore::avx2_supported()`. En Windows se comprueban CPUID, AVX, OSXSAVE, XCR0 para XMM/YMM y AVX2. Se conserva la comprobación existente de AVX2/FMA del compilador en la ruta GCC/Clang. No se añade AVX-512 ni afinidad de CPU.

Todos los modos llaman el mismo `prepare_`. Fase, evolución e IFFT utilizan los kernels AVX2 existentes cuando el dispatch lo permite. **El packing Lite sigue siendo escalar**: no entra en `prepare_physics_spectra_avx2`, que pertenece al campo completo. No se atribuye vectorización a esa etapa. La TU FFT AVX2 conserva `/arch:AVX2` en MSVC y `-mavx2 -mfma -ffp-contract=off` en la configuración Linux existente. Las TUs base siguen sin `/arch:AVX2`. No se cambia FMA, contracción ni flags de precisión. Solo la nueva TU de coordinación habilita desenredo de excepciones para completar la barrera ante fallos.

El build nativo aislado compila las TUs base sin `/arch:AVX2` y las dos TUs SIMD con esa opción. La prueba scalar es un control privado del ejecutable de validación; no modifica el backend por defecto del proyecto.

## Evidencia de validación

- Prueba nativa de 1.060 ticks por modo y backend, nueve bandas, pausa, rewind, salto temporal, cambio de velocidad y nueve rebases de fase por ejecución.
- Igualdad binaria dentro del mismo backend: 4.277.952 valores de altura, normales cúbicas, velocidad y desplazamiento, además de comparaciones completas de los campos empaquetados altura/velocidad.
- Lectura concurrente de un snapshot antiguo durante las construcciones; lease válido después del shutdown; rollback a baseline y bloqueo de cambios de límite incompatibles.
- Ocupación máxima observada de tres y cuatro tareas respectivamente; todos los trabajadores ejecutan tareas, incluido el cuarto.
- Control scalar/AVX2: 59.965.440 componentes; máximo de la norma del error complejo `1.0347183290953907e-13`. Es una comparación de los dos backends existentes, no una diferencia entre los modos de trabajadores.
- Integración con H0 de los recursos locales reales: **81.120 valores double de consulta iguales**, inversión desplazada y normales/velocidades locales iguales, sustitución H0 en caliente conservando fase, herencia del límite efectivo y retiro completo de las reservas al reconfigurar.
- Replay real de 720 ticks con 1, 4 y 6 motos: **1.042.554 valores comparados entre baseline y los dos modos async, sin diferencias**. Incluye posiciones, orientación, velocidades, vectores de fuerza de flotabilidad total y por punto, profundidades, normales, drag, velocidad del agua y estados mojado/soportado/aire/aterrizaje/submarino. La repetición síncrona adicional también coincide: 521.277 valores de control.
- El replay recorre ambos estados, feather y solapamiento, movimientos rápidos, salto/aterrizaje, hull waves físicas y el sampler de tsunami de producción. Los snapshots solicitados siguen siendo completos y no se cambia la física del controlador.

La igualdad estricta nativa corresponde a **la misma secuencia de tiempos y construcciones**. La baseline real calcula estados locales bajo demanda; precalcularlos cada tick cambia su historia de recurrencia durante los intervalos sin consultas. El control específico de distinta historia compara 147.840 valores: error double máximo inferior a `8e-12` y **11 diferencias en componentes convertidos a Float32**. No se afirma identidad binaria universal entre historias distintas. Esto no cambia H0, la FFT ni su precisión; el replay de fuerzas y trayectoria anterior no muestra diferencias en sus salidas físicas.

En la primera fila del replay todavía no hubo evaluación de fuerzas y los cuatro contactos de cada moto tienen `sample_valid=false`. La baseline conserva el campo preparado a tiempo 0; async ya preparó tiempo 0,025. Ese metadato de preparación sin consumo se conserva y se informa por separado. Se comparan todos los valores de los cuerpos también en esa fila y no se omite ninguna diferencia de reloj posterior.

## Instrumentación de física completa

El monitor `TIME_PHYSICS_PROCESS` de esta versión publica un máximo acumulado por segundo. No se utiliza para calcular percentiles de ticks. El banco registra el callback oficial `EngineProfiler._tick`, que recibe el máximo **completo** de los ticks físicos de cada iteración renderizada, e incluye su número de pasos. Cuando hay un paso, la muestra es un tick exacto; cuando hay varios, se conserva y etiqueta el máximo, sin inventar tiempos individuales. El temporizador de callbacks Node se entrega aparte y no sustituye al ciclo físico con Jolt. Véanse [el código exacto del motor](https://github.com/godotengine/godot/blob/a13da4feb/main/main.cpp) y [EngineProfiler](https://docs.godotengine.org/en/stable/classes/class_engineprofiler.html#class-engineprofiler-private-method-tick).

Los resultados de FPS, física completa, GPU, percentiles y la recomendación se entregan en el informe de mediciones. No se deduce una mejora de rendimiento a partir de estas pruebas de paridad.

## Alcance protegido

Sin cambios a presets, escenas guardadas, semillas, espectros, direcciones, choppiness, resoluciones 128/128/128, inversión, interpolación cúbica, normales, velocidades, controlador de jetski, shaders ni geometría del mar. Stern Mist solo se apaga en las instancias del banco, igual en todos los controles. La segunda zona de la escena de pruebas se instancia en memoria para probar solapamiento; no se guarda.

La auditoría utiliza evidencia dirigida del grafo (Tier 2) y lectura directa de las rutas afectadas. El índice inicial notificó metadatos cambiados y rangos parciales en el header nativo y el proveedor; esas fuentes se inspeccionaron directamente. La cobertura del grafo es una señal de apoyo, no una demostración de exhaustividad del repositorio.
