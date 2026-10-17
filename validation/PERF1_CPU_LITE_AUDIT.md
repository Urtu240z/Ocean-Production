# PERF-1 — captura de picos CPU Lite

Auditoría sobre `wip/feel-soft-water`, base local `6c38e347102e3b337918d58bd3bf656d181ccc7c`. Se conservan los cambios locales anteriores. Esta entrega añade observación, sin cambiar resoluciones, parámetros, consultas, conducción ni calendario de construcción del agua.

## Comparación previa con el código público

Referencia descargada: `origin/wip/phys-cpu-lite`, commit `b304e8fcff782cbd58f0bfc9e7660948bdc4b1bd`. `origin/master` no contiene la implementación CPU Lite y no sirve como referencia de estas funciones.

| Función antes de PERF-1 | Comparación |
| --- | --- |
| `advance_phase_` | Idéntica a la rama pública CPU Lite. |
| `get_dynamic_lite_profile` | Idéntica; PERF-1 conserva su formato y semántica. |
| `configure_lite` | Diferencia local: argumento y filtro por longitud de onda física mínima. Conservado. |
| `build_dynamic_physics_lite` | Diferencias locales: invalidación del parche de contacto y seguimiento de la longitud de onda mínima para reconfigurar. Conservadas. |

La implementación existente mide `update_us` **después** de configurar las tres bandas. Por tanto, ese valor no permite atribuir un pico del constructor a configuración o a FFT. PERF-1 toma además el tiempo desde la entrada hasta la salida del método, incluidas validaciones, configuración y casos fallidos.

Las capturas anteriores atribuyen 92,42 / 70,38 / 41,77 ms al constructor CPU dentro de fotogramas de 176,32 / 130,15 / 98,69 ms. No permiten identificar por sí solas la etapa interna responsable ni demostrar desplanificación. No se ha reproducido aún un pico de esa magnitud con esta instrumentación; no se propone una optimización sin esa evidencia.

## Registro

`OceanQueryNative` mantiene un anillo fijo de 2048 construcciones. Cada construcción superior a **8000 µs** congela hasta 16 construcciones anteriores y conserva 16 posteriores. Un tick puede contener construcción principal y comparación; ambas quedan separadas con `is_comparison`. Se admiten 32 ventanas nativas pendientes; el desbordamiento se cuenta explícitamente.

Cada registro incluye fotogramas de proceso y renderizado, tick físico, generación del espectro, backend seleccionado y construido, comparación activada, resolución real por banda, AVX2/escalar, duración completa, configuración y su motivo, evolución, fases, empaquetado, FFT por filas/transposiciones, publicación y memoria de los campos antes/después. `outside_bands_us` sólo se calcula para CPU Lite, cuyas bandas se ejecutan en serie. En FULL_CPU sus tiempos se solapan entre trabajadores.

Los reinicios de fase se distinguen por primera construcción/reset, retroceso, salto superior a 0,25 s y rebase periódico de 600 avances. `rewind_reset` permite reconocer el reset explícito del wrapper, aunque la banda vea después una primera fase. Se registran delta, contador previo/posterior, reconstrucción de rotor y tiempos de inicialización/rebase.

Un contador adicional recoge los callbacks físicos reales por fotograma de proceso, independientemente de las construcciones o comparaciones. El último fotograma del registro puede estar incompleto. Los IDs de renderizado sirven para correlacionar la presentación, pero no sustituyen al fotograma de proceso para contar pasos físicos.

En Windows se usan `GetThreadTimes` y `QueryThreadCycleTime`. Un exceso de tiempo transcurrido frente a CPU del hilo sugiere espera/desplanificación, con la limitación de cuantización de `GetThreadTimes`. En FULL_CPU no se suman los relojes de los trabajadores; su diferencia no prueba desplanificación. La memoria registrada es almacenamiento lógico de los campos, no working set ni un rastreo completo de asignaciones del proceso.

El productor nativo no reserva memoria, imprime ni escribe archivos por construcción. Usa un mutex durante copias acotadas. La conversión a diccionarios, JSON y escritura se ejecuta cada dos segundos en un hilo de reporte de prioridad baja. **El agua sigue siendo síncrona**. Para reducir el coste de exportación se guardan las últimas 256 construcciones, además de las ventanas de picos; el anillo nativo conserva 2048. El informe retiene 128 ventanas y cuenta las descartadas. La salida usa archivo temporal y renombrado; al cerrar normalmente la escena se hace un último vaciado. Un cierre forzado puede perder los últimos dos segundos.

## Uso y archivo que compartir

Es necesario **cerrar y volver a abrir Godot una vez**: el editor abierto puede seguir usando la DLL anterior cargada en memoria. La DLL compilada de PERF-1 ya está instalada en la ruta canónica. Los binarios son artefactos locales ignorados por Git; para reproducir, ejecutar `build_windows_release.bat` con MSVC y SCons. `output_base` en SConstruct permite compilar una biblioteca alternativa para validación sin sobrescribir una biblioteca cargada.

Ejecutar la escena del jet ski como siempre. No hay que activar un perfilador ni modificar parámetros. Cuando ocurra el parón, continuar al menos un segundo para completar el contexto posterior, detener normalmente y compartir:

`C:/Users/DEV/AppData/Roaming/Godot/app_userdata/Ocean Production/perf1/latest.json`

Equivalente dentro de Godot: `user://perf1/latest.json`. También se conserva un archivo `capture_<timestamp>_<pid>.json` por sesión, cuyo nombre aparece en `session_path`. Antes de ejecutar otra sesión, guardar/enviar el correspondiente archivo: `latest.json` identifica la última sesión que escribió un informe.

## Validación

- Compilación Release x64 y carga con Godot 4.7.1.
- Fixture nativo: 604 construcciones de tres bandas a 128, primera fase, recurrencia, rebase 600, salto 0,30 s y retroceso. Mismo SHA-256 de muestras con la DLL anterior y la instrumentada: `7720b58c99d1e7acd41034560c45acd395f11cac665b98efb8e0818a89c22c9c`. Desactivar captura tampoco cambia la muestra comprobada.
- Buffer: contexto de 33 registros, conservación tras sobrescribir el anillo, desbordamiento explícito, entrega única de ventanas completas y captura desactivada. Espera aislada de 20 ms: tiempo de pared mayor de 8 ms con CPU del hilo 0 µs en la prueba Windows.
- JSON automático leído y validado; agrupación de tres pasos por fotograma en el fixture.
- Escena real `gameplay/jet_ski_ocean.tscn` cargada sin modificar. Validación final: 240 fotogramas de proceso, 83 físicos, un nodo `Perf1Capture`; informe con 48 construcciones, CPU_LITE_B, 128/128/128 y comparación desactivada. Contador observado de hasta tres pasos físicos por fotograma. El mayor constructor fue 5,061 ms, por debajo del umbral; no sustituye a una captura del próximo parón.

Reproducir las pruebas con `validation/perf1_native_validation.gd`, `validation/perf1_scene_validation.gd` y `validation/perf1_ring_validation.cpp`. Los resultados generados permanecen fuera del commit. La escena requiere un renderer con RenderingDevice; la prueba nativa admite modo headless.
