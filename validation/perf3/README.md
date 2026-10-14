# PERF-3: por qué se encarece la IFFT mientras el hilo sigue ejecutándose

La captura anterior demuestra que el hilo permanece asignado a CPU durante casi todo el parón y localiza una parte importante del coste en la IFFT. PERF-3 añade contadores de hardware y una repetición exacta de entradas capturadas. No cambia resoluciones, espectro, parámetros del océano, fuerzas, flotabilidad, amortiguación, inercias o conducción. No introduce async ni omite ticks.

## Próxima prueba

1. Usar **Auto-Perf3.cmd** en esta carpeta y aceptar el permiso de Windows. La DLL nueva está instalada en su ruta canónica; si Godot seguía abierto durante su actualización, cerrar y volver a abrir el editor para cargarla.
2. Esperar **CAPTURA ARMADA**, dejar esa ventana abierta y ejecutar la escena del jet ski con los mismos ajustes.
3. El primer fotograma de al menos 50 ms, tras cinco segundos iniciales de marcadores del proceso, guarda Windows. Mantener el juego abierto hasta **CAPTURA GUARDADA**, para conservar el contexto posterior en el JSON.
4. Compartir **toda la carpeta indicada**, incluidos `windows.etl`, `latest.json`, `manifest.json`, `trigger.json`, `capture_profile.wprp`, `hardware_sources.txt` y los archivos **`fft_*.bin`** que aparezcan. No hace falta ejecutar la repetición mientras se juega.

El acceso utiliza el mismo capturador automático validado en PERF-2. La etiqueta de propiedad de WPR sigue siendo Perf2.Verbose.Memory; el perfil guardado identifica las medidas adicionales. La lista de contadores anunciados se conserva antes de iniciar. Si falta alguno, el acceso explica el motivo sin iniciar WPR. El perfil usa Strict=true: anunciar un contador no garantiza que se pueda programar con la configuración real del sistema. Un fallo de arranque no se presenta como una captura con esos contadores disponibles.

Si el escuchador anterior quedó abierto, `Auto-Perf3.cmd` verifica su ejecutable, PID y rutas de captura antes de pedirle que termine mediante su archivo de cancelación. No mata procesos. Si no termina o no se puede verificar su propiedad, se detiene con el motivo concreto. Los nuevos escuchadores vigilan además el proceso de control y se cierran si éste desaparece. Una sesión auxiliar huérfana `OceanProduction.Perf2.AutoTrigger` se recupera sólo con exclusión mutua y sin otro escuchador vivo; nunca se cierra WPR para recuperarla. El marcador de cancelación es distinto en cada intento y los registros anteriores se conservan. Si WPR sigue grabando el mismo perfil, volver a abrir Auto reutiliza esa captura.

Pruebas del recuperador: `validation/perf2/listener_recovery_validation.ps1`, `auto_helper_validation.ps1` y `auto_capture_listener.exe --self-test`. Las pruebas simuladas no sustituyen la comprobación de ETW con permisos de administrador de Windows.

## Qué añade Windows

### Prueba con sensores de HWiNFO

Si WPR rechaza el arranque con `0x800700AA` (recurso en uso) mientras se monitorizan sensores, usar **Auto-Perf3-Sensors.cmd** junto al registro CSV de HWiNFO. Es un modo explícito, sin solicitud de contadores PMU: mantiene las mismas palabras clave y stacks de Windows, los buffers, los marcadores del juego, el disparo por fotograma lento y los snapshots IFFT. El perfil original **Auto-Perf3.cmd** conserva sus cuatro contadores y no hace una degradación silenciosa. El manifiesto del modo de sensores indica `hardware_counter_status: not_requested`.

En el equipo de prueba, el perfil original falló con `0x800700AA` al tener HWiNFO abierto. Este dato identifica un recurso ocupado; por sí solo no demuestra qué herramienta lo reserva. El modo de sensores permite observar temperaturas y límites sin competir por esos contadores. No modifica ajustes del juego ni configura HWiNFO automáticamente.

Iniciar el CSV, abrir Auto-Perf3-Sensors, esperar CAPTURA ARMADA y ejecutar el juego. Al aparecer CAPTURA GUARDADA, detener también el CSV. Compartir la carpeta completa y el CSV. Si existe una captura iniciada con otro perfil, guardarla con Stop-Perf2 antes de cambiar; el ayudante rechaza la mezcla de perfiles.

La ejecución de WPR captura stdout/stderr y su código completo, incluso si comienza con líneas vacías en Windows PowerShell 5.1. Los fallos de arranque se conservan en `wpr_start_error.txt`; las excepciones del acceso tienen además un archivo `operation_*.error.txt`. Las preferencias de error del llamador se restauran tras ejecutar WPR.

Validación reproducible: `validation/perf2/native_error_validation.ps1` y `validation/perf3/sensor_mode_validation.ps1`, además de las pruebas anteriores. La primera usa un ejecutable ficticio real con stderr y código de salida; no inicia trazas.

Se solicitan cuatro contadores sobre cambios de contexto: `InstructionsRetiredFixed`, `UnhaltedCoreCyclesFixed`, `UnhaltedReferenceCyclesFixed` y `LLCMisses`. Permiten contrastar cantidad de instrucciones, ciclos por instrucción, ciclos reales frente a referencia y fallos de caché de último nivel. Se añaden eventos HardFaults para estudiar paginación.

La relación entre ciclos reales y de referencia debe interpretarse según las capacidades y semántica del procesador, CPU lógico y tramo de ejecución. No equivale por sí sola a una lectura de MHz durante cada mariposa de la FFT. Tampoco se puede repartir exactamente un contador de un tramo largo entre varios spans sin fronteras de medida suficientes. Las limitaciones del planificador, migraciones, interrupciones y granularidad se conservarán en el análisis. Este cambio programa contadores de observación; no cambia plan de energía, afinidad ni prioridad del juego.

## Captura nativa y repetición

Cada par IFFT registra el identificador del CPU lógico y MXCSR antes/después. Sólo se **lee** MXCSR: no se borran flags ni se modifican rounding, FTZ o DAZ. Los bits de excepción son persistentes; una excepción ya marcada antes no permite contar cuántas veces ocurrió durante ese cálculo.

La captura binaria se limita a **una IFFT lenta por banda por instancia nativa**, con resolución máxima 128. No modifica la resolución: para una mayor, la matriz no se captura. Requiere AVX2, telemetría habilitada, `fft_probe_enabled` y un proveedor ETW activo. Se evita capturar durante las primeras 120 construcciones observadas por la sonda; ese contador es independiente del rebase de fases. La prueba aislada dispone de un override explícito sin ETW y umbral cero.

Mientras una banda aún no ha capturado, se copia su entrada a un buffer fijo antes de cada IFFT. Cuando una IFFT individual supera 1.500 microsegundos se conserva entrada, salida transpuesta, tablas exactas, frame/tick, CPU, MXCSR y tiempos. Después la banda deja de copiar. **El snapshot identifica esa IFFT concreta y puede preceder al fotograma que dispara Windows**: no debe presentarse como la matriz del disparador si sus números no coinciden.

Los buffers de entrada/salida se reservan en el objeto de diagnóstico, unos 1,5 MiB para las tres bandas más tablas. No hay asignación ni escritura a disco en el productor de matrices. La lectura de los resultados utiliza publicación acquire/release y matrices inmutables. El hilo de informes exporta cada matriz una sola vez, escribe el `.bin` y añade su nombre al JSON. El ayudante copia esos binarios desde la carpeta original del juego incluso cuando ha congelado el JSON en otra carpeta.

La copia cambia la carga de memoria y puede alterar la caché. Se registra `probe_input_copy_us` por par; el tiempo completo de construcción incluye ese coste. En dos calibraciones de 200 ensayos alternando copia activada/desactivada, con espectro y tiempo idénticos, las medianas fueron 1.309→1.395 y 1.147→1.202 microsegundos por construcción. En la última, las copias sumaron 67 microsegundos de mediana y 104 de p95. Es una calibración, no un límite máximo ni una prueba de ausencia de efecto. Se puede desactivar `fft_probe_enabled` en el controlador de informes para contrastar sin copias, conservando los contadores de Windows.

El programa **fft_replay** se compila separado con la misma función AVX2 y utiliza las tablas y entradas binarias capturadas. Repite las filas, la transposición de bloques de 16 y las columnas en el mismo orden. Exige salida idéntica bit a bit en el modo original. También informa de componentes subnormales, presión de caché de 32 MiB y un experimento FTZ/DAZ que modifica exclusivamente el proceso de repetición, nunca el juego.

Cada modo hace 32 calentamientos. Las medidas excluyen la copia de entrada y el pase de presión de caché. La copia calienta parte de la caché, por lo que no se garantiza una caché completamente fría. Los modos se miden secuencialmente, sin afinidad o prioridad forzada; diferencias temporales no demuestran causalidad. La identidad numérica y las medidas de rendimiento son comprobaciones diferentes.

## Validación

- DLL x64 Release compilada e instalada. Las 604 construcciones conservan el SHA-256 `7720b58c99d1e7acd41034560c45acd395f11cac665b98efb8e0818a89c22c9c`; el guardado automático del JSON sigue funcionando.
- 144 casos de flotabilidad conservan el SHA-256 `9f4a127425bddceae7292922d1fcb5e78fbc238db7dce05b2faf0acaeee14e3e`. La escena real del jet ski carga: 240 fotogramas y un controlador de informes detectado.
- Tres snapshots del fixture se repiten 100 veces por modo: salida original idéntica bit a bit, cero error absoluto. En estos datos sintéticos no hay componentes subnormales; esto no descarta su presencia en el juego real.
- Pruebas de paquete: copia de binarios después de congelar el JSON, rechazo de nombres con rutas y rechazo de contadores ausentes. Los accesos Start/Stop/Auto anteriores siguen pasando sus pruebas simuladas con PowerShell 5.1.
- Windows acepta el nuevo XML con `-profiledetails` y anuncia los cuatro contadores en `-pmcsources`. **La programación efectiva de PMU en una sesión real necesita la prueba con elevación de Windows**: el proceso del agente no tiene ese token. No se afirma que se haya ejecutado ya esa captura.

Pruebas reproducibles: `snapshot_validation.gd`, `probe_cost_validation.gd`, `bundle_validation.ps1` y las validaciones PERF-1/PERF-2. `build_replay.ps1` genera `temp/perf3-tools/fft_replay.exe`. Para repetir un archivo después de cerrar el juego: `fft_replay.exe entrada.bin informe.json 200`.

Formato binario v1, little endian y 64 bits: cabecera `Perf3FftHeader` de 96 bytes, bit_reverse de N uint32, twiddles real/imag de N-1 doubles, duplicados de 2(N-1) doubles, 32 offsets uint64, N² complejos de entrada y N² complejos de salida transpuesta. El lector valida tamaños, resolución, índices y estado de coma flotante antes de ejecutar.

Referencia primaria: [contadores PMU sobre eventos ETW, límites y Strict](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/recording-pmu-events).
