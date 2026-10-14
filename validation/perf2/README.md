# PERF-2: fotogramas lentos y Windows en la misma captura

La ampliación conserva los parámetros del océano, resoluciones FFT, fuerzas, amortiguación, inercias y conducción. Añade tiempos y contadores alrededor del código existente. Los cuerpos originales de controlador, física del agua, preparación de contactos, consultas y comprobaciones de fuente se mantienen; sus retornos pasan por un envoltorio de medición, incluidos los retornos anticipados.

## Para capturar el próximo parón

1. Cerrar y volver a abrir Godot para cargar la DLL nueva; está instalada en su ruta canónica. No hace falta modificar la escena.
2. Ejecutar `Start-Perf2.cmd` en esta carpeta y aceptar la solicitud de administrador de Windows. Después ejecutar normalmente la escena del jet ski.
3. Tras un parón, continuar al menos dos segundos y detener normalmente el juego, para que el JSON termine de guardarse. Ejecutar `Stop-Perf2.cmd` poco después.
4. Compartir **`windows.etl`, `latest.json` y `manifest.json`** de la carpeta que indica el ayudante: `<proyecto>/temp/perf2-windows/capture_<fecha_hora>/`.

El ayudante guarda una copia del JSON junto a la traza de la misma sesión, con PID, horas y advertencias si el informe parece antiguo. No ejecutar otra prueba antes de guardar esa pareja. `latest.json` sigue actualizándose automáticamente en `user://perf1/`, para mantener el flujo de PERF-1.

El permiso de administrador permite a WPR registrar el planificador del sistema. El juego sigue ejecutándose con sus permisos normales. El ayudante comprueba que no existe otra captura WPR antes de iniciar y no usa `wpr -cancel`; para detener exige su archivo de estado y una sesión identificada como Perf2. No mezclar sesiones WPR de otras herramientas durante la captura. Si aparece un error, conservar la salida y los archivos de la sesión.

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
- **La captura real de CPU Usage (Precise) no se ha ejecutado:** este proceso no tiene token de administrador. Los accesos solicitan elevación al iniciar/guardar. No se ha iniciado una sesión WPR ni tocado ajustes de energía, afinidad, prioridades del juego o conducción.

Pruebas reproducibles: `validation.gd`, `automatic_frame_capture.gd`, `frame_ring_validation.cpp` y los fixtures PERF-1. La espera deliberada sólo existe en los archivos de validación, nunca en el juego.

Referencias oficiales: [análisis de CPU y estados de hilo](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis), [perfiles WPR y modo circular](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/authoring-recording-profiles), [SystemProvider y pilas de cambios de contexto](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/systemprovider).
