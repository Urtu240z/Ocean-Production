# PERF-2: fotogramas lentos y Windows en la misma captura

La ampliación conserva los parámetros del océano, resoluciones FFT, fuerzas, amortiguación, inercias y conducción. Añade tiempos y contadores alrededor del código existente. Los cuerpos originales de controlador, física del agua, preparación de contactos, consultas y comprobaciones de fuente se mantienen; sus retornos pasan por un envoltorio de medición, incluidos los retornos anticipados.

## Para capturar el próximo parón

1. Ejecutar **`Auto-Perf2.cmd`** y aceptar el permiso de administrador de Windows.
2. Esperar **CAPTURA ARMADA**, dejar esa ventana abierta y ejecutar normalmente la escena del jet ski. Si PERF-2 ya estaba cargado, este cambio no requiere reiniciar Godot ni modificar la escena.
3. Al primer intervalo de fotograma de **50 ms o más**, después de **cinco segundos** desde el primer marcador recibido de ese proceso, aparece **PARON DETECTADO**. Windows se guarda automáticamente; el juego debe seguir abierto hasta **CAPTURA GUARDADA** para conservar los 32 fotogramas posteriores en el JSON.
4. Compartir **`windows.etl`, `latest.json`, `manifest.json` y `trigger.json`** de la carpeta indicada: `<proyecto>/temp/perf2-windows/capture_<fecha_hora>/`. Una ejecución de Auto guarda un parón; volver a ejecutarlo arma otra captura.

El umbral de 50 ms y el margen inicial de cinco segundos se ajustan en los argumentos de `Auto-Perf2.cmd`. Son ajustes del capturador externo, no de la física. El anillo del juego sigue conservando ventanas desde 25 ms. Auto espera hasta diez minutos; si vence el plazo o el escuchador falla, indica el motivo y deja WPR grabando para que se pueda guardar con `Stop-Perf2.cmd`.

Los accesos manuales **Start/Stop** siguen disponibles. Para una prueba manual, usar Stop al notar el parón mientras el juego sigue abierto: esperar a cerrar el juego puede sobrescribir los cambios de contexto en el buffer circular.

El capturador `auto_capture_listener.cpp` es un ejecutable separado: escucha en tiempo real únicamente `FrameBoundary` del proveedor existente, mediante un filtro de nombres de evento y una sesión ETW auxiliar de 64 KiB por buffer (4–16 buffers solicitados; Windows puede ajustar la asignación). No se recompila ni modifica la DLL del océano. El ejecutable se genera en `temp/perf2-tools/` con `build_listener.ps1`; Auto recompila si falta o el fuente es más reciente. Requiere MSVC, presente en este equipo.

Tras el disparador, se guarda Windows antes de esperar al JSON. Después se espera hasta 15 segundos por un informe del mismo PID que conserve los 65 fotogramas alrededor del disparador. Si no llega, se guarda lo disponible con una advertencia. El manifiesto indica `matched_with_context` o `unverified`; `trigger.json` identifica PID/TID, fotograma, QPC y duración. `trace_stop_requested.json` permite medir el retraso entre el marcador recibido y la solicitud de guardado. Esto no prueba por sí solo la cobertura final: hay que comprobarla por núcleo en el ETL.

El escuchador detiene únicamente la sesión auxiliar que creó. Si ya existe otra con su nombre, falla sin detenerla. Stop manual cancela el escuchador cuando desaparece el estado de la captura. No se crean tareas programadas ni servicios persistentes. La sesión auxiliar se elimina al finalizar normalmente o vencer el plazo; forzar la terminación del ejecutable puede dejarla activa.

El ayudante guarda una copia del JSON junto a la traza de la misma sesión, con PID, horas y advertencias si el informe parece antiguo. No ejecutar otra prueba antes de guardar esa pareja. `latest.json` sigue actualizándose automáticamente en `user://perf1/`, para mantener el flujo de PERF-1.

El permiso de administrador permite a WPR registrar el planificador del sistema. El juego sigue ejecutándose con sus permisos normales. El ayudante comprueba que no existe otra captura WPR antes de iniciar y no usa `wpr -cancel`; para detener exige su archivo de estado y una sesión identificada como Perf2. No mezclar sesiones WPR de otras herramientas durante la captura. Si aparece un error, conservar la salida y los archivos de la sesión.

Los accesos muestran **CAPTURA ACTIVA** o **CAPTURA GUARDADA** en la ventana original. Los mensajes del proceso elevado vuelven mediante un archivo de resultado; los errores ya no desaparecen al cerrarse esa ventana. Cada intento guarda `operation_<modo>_<id>.json` en `temp/perf2-windows/`; el proceso elevado añade un `.log` si llega a ejecutarse. Si falla, compartir el resultado y el registro disponible. Cerrar la ventana tras pulsar una tecla es normal después de leer el resultado: la grabación confirmada continúa hasta ejecutar Stop.

La comprobación usa `wpr -status profiles collectors`, pues el resumen simple no contiene nombres de perfil. Start verifica el perfil después de iniciarlo y reconoce una captura propia ya activa. Un estado antiguo sin grabación se archiva con un manifiesto que indica `trace_missing`; no se inventa un ETL para ese intento. Si Windows ya no conserva la grabación, hay que realizar una prueba nueva. El modo Auto necesita mantener su consola abierta hasta que termine; cerrar la consola después de CAPTURA ACTIVA corresponde únicamente al modo manual Start.

## Qué se registra

- Disparador nativo conservado: construcción de agua >8 ms, con su contexto de construcciones.
- Disparador nuevo: **intervalo de fotograma >25 ms**, con hasta 32 fotogramas anteriores y 32 posteriores. Retiene los tiempos de etapas y las construcciones individuales de esos fotogramas, aunque ninguna supere 8 ms.
- Etapas: controlador, preparación de contactos, física del agua, integración de celdas, bucle de tetraedros, consultas por lote, validación de fuente, lectura de estado del océano, construcción nativa y escritura del informe en el hilo de reporte.
- Celdas y tetraedros: dos pares de marcas por celda. Se mide el bucle de tetraedros completo y se cuenta cuántas llamadas contiene, sin añadir una marca a cada tetraedro.
- WPR: creación de procesos/hilos, módulos, cambios de contexto, ReadyThread, muestras de CPU con pilas, DPC e interrupciones. En WPA permiten estudiar ejecución, espera y competencia por CPU.
- Marcadores ETW propios: `OceanProduction.Perf2`, GUID `a3d2398c-762f-4b16-a89c-61238e641702`, eventos `FrameBoundary` y `StageSpan`. Incluyen fotograma, tick y marcas QPC; el encabezado ETW proporciona PID y TID. Sólo se emiten cuando Windows tiene habilitado el proveedor.

Los tiempos de etapas son **inclusivos y anidados**: no sumar controlador + contactos + construcción, ni física + celdas + tetraedros. `report_save` pertenece al hilo de reporte y puede solaparse con el juego.

El intervalo de fotograma se mide entre señales `SceneTree.process_frame`: incluye la física actual y la cola de proceso/render del ciclo anterior. **No es el `Frame Time` interno exacto del perfilador de Godot.** Su función es detectar y conservar el contexto del parón; QPC y las marcas ETW permiten situar cada etapa en el tiempo real, incluso si el número que aparece en el perfilador tiene otra frontera. Las posiciones QPC de los spans GDScript son estimadas a partir de sus marcas monotónicas, calibradas en la llamada nativa.

## Límites y coste

Los anillos y las ventanas son acotados. Hay 16 ventanas de fotogramas pendientes en nativo y hasta 128 guardadas; se cuentan los descartes y cualquier construcción ausente del contexto. La ventana se completa al finalizar el contexto posterior; al cerrar demasiado pronto aparece como incompleta.

La conversión a JSON y la escritura siguen ejecutándose en el hilo de reporte de prioridad baja. WPR usa modo circular en memoria (128 MiB para el sistema y 8 MiB para los marcadores), y guarda el ETL al detenerlo. El horizonte temporal depende del volumen de eventos; guardar pronto tras el parón evita sobrescribirlo. Registrar pilas y cambios de contexto añade coste de observación: hay que valorarlo al analizar la captura.

`perf2_stage_measurements_enabled` en el proveedor permite desactivar las marcas de etapas para una comparación diagnóstica; no cambia fuerzas ni consultas. El disparador de fotograma sigue activo. `frame_hitch_threshold_ms` en el nodo de captura ajusta exclusivamente el umbral de diagnóstico.

WPA no se encontró en PATH y no se ha instalado. El registro se puede obtener con WPR ya disponible; el análisis puede hacerse después con Windows Performance Analyzer. El reporte por sí solo no decide si el hilo ejecutaba o esperaba: esa decisión corresponde a la traza de Windows.

## Validación realizada

- Extensión x64 Release compilada y cargada en Godot 4.7.1; escena del jet ski cargada sin modificar.
- Agua: las 604 construcciones del fixture PERF-1 mantienen SHA-256 `7720b58c99d1e7acd41034560c45acd395f11cac665b98efb8e0818a89c22c9c`.
- Flotabilidad: 144 casos de celdas coinciden con el código anterior a PERF-2; SHA-256 `9f4a127425bddceae7292922d1fcb5e78fbc238db7dce05b2faf0acaeee14e3e`.
- Anillo: un fotograma de 63,21 ms con cuatro construcciones de 5,5 ms dispara y conserva una ventana completa de 65 fotogramas; verificados retornos tardíos de etapas, sobrescritura y desbordamiento.
- Guardado automático: fixture aislado con espera de 63 ms; ventana completa y cero construcciones ausentes, verificadas leyendo el JSON final.
- Perfil WPR aceptado con `windows_capture.ps1 -Mode Validate`, incluyendo CSwitch/ReadyThread y el GUID de marcadores.
- Corrección de accesos: probados con Windows PowerShell 5.1; flujo Start/Stop, generación del paquete, estado antiguo, fallo nativo y protección de otra grabación mediante WPR simulado. Verificado además que el lanzador conserva y muestra un error real de falta de permisos. Esta prueba simulada no valida una traza real del kernel.
- Capturador automático compilado con MSVC x64 Release, sin advertencias; probado el umbral, margen inicial, PID independiente y timestamps inválidos. Reproduciendo el ETL real del usuario, TDH lee los campos del marcador y dispara en el fotograma 14018, 55,334 ms, PID 57116. La reproducción de un ETL no requiere iniciar otra grabación.
- Flujo Auto probado en PowerShell 5.1 con WPR y escuchador simulados: guarda Windows antes de esperar contexto, confirma PID/fotograma, rechaza contexto incompleto o con huecos y conserva el diagnóstico de errores. `auto_helper_validation.ps1` no genera una traza Windows real.
- El ETL real recibido del usuario se ha analizado; su cobertura circular era insuficiente en los núcleos que ejecutaban los parones. **La nueva captura automática en tiempo real necesita la prueba del usuario con elevación:** este proceso no tiene token de administrador. El ejecutable devuelve correctamente el error 5 en ese caso. No se han tocado ajustes de energía, afinidad, prioridades del juego o conducción.

Pruebas reproducibles: `validation.gd`, `automatic_frame_capture.gd`, `frame_ring_validation.cpp` y los fixtures PERF-1. La espera deliberada sólo existe en los archivos de validación, nunca en el juego.

Referencias oficiales: [análisis de CPU y estados de hilo](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis), [perfiles WPR y modo circular](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/authoring-recording-profiles), [SystemProvider y pilas de cambios de contexto](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/systemprovider).

Escuchador: [StartTrace y alcance de las sesiones](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-starttracew), [EnableTraceEx2 y filtros](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-enabletraceex2), [lectura TDH de propiedades](https://learn.microsoft.com/en-us/windows/win32/api/tdh/nf-tdh-tdhgetproperty).
