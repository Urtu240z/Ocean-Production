# PERF-1 — análisis de la captura recibida el 14/10/2026

Fuente: `user://perf1/latest.json`, sesión `capture_1791963121_37344.json`, guardada a las 07:35:13 UTC. Se ha conservado una copia estable en `temp/perf1-analysis/latest-received.json`. Este análisis no modifica código, parámetros ni la DLL.

## Resultado

La captura identifica una subida transitoria del tiempo de construcción síncrona y acumulación de pasos físicos. No identifica todavía la causa que dispara esa subida. Las etapas se ralentizan de forma amplia, en las tres bandas; una reconfiguración o un reinicio de fase no explica los siete eventos registrados.

Se contaron 11.534 construcciones en aproximadamente 192 segundos. El archivo retiene 256 construcciones recientes y siete ventanas completas de 33 registros; tras eliminar duplicados quedan 327 construcciones. Las siete ventanas corresponden a **dos episodios**, no a siete parones independientes. No hubo ventanas descartadas ni construcciones fallidas entre los registros conservados. El anillo sobrescrito es funcionamiento normal, no pérdida de estas ventanas.

| Episodio | Construcciones >8 ms | Pico individual | Fotograma con mayor suma de agua | Pasos físicos de ese fotograma | Suma de construcción de agua |
| --- | --- | --- | --- | --- | --- |
| Secuencias 5255–5258 | 4 | 11,250 ms | 21546 | 5 | 38,431 ms |
| Secuencias 8584–8586 | 3 | 12,629 ms | 31814 | 3 | 31,545 ms |

El fotograma posterior 31815 ejecuta seis pasos y acumula 30,375 ms de construcción. El 21547 también ejecuta seis pasos. Esto muestra el coste adicional de recuperar pasos físicos atrasados después de un fotograma lento; la telemetría no demuestra cuál fue el primer trabajo que inició el atraso.

El intervalo desde el comienzo de la primera construcción hasta el final de la última del fotograma 21546 es de 87,889 ms; dentro de ese intervalo sólo 38,431 ms pertenecen a los constructores nativos. Para 31814, el intervalo es de 68,222 ms y los constructores suman 31,545 ms. **Estos intervalos no son el tiempo completo del fotograma**: faltan sus extremos y el archivo no identifica el trabajo ejecutado entre las construcciones. Los huecos tampoco equivalen automáticamente a espera del sistema operativo.

En los registros recientes aparece otra subida hasta 6,098 ms, con varios pasos por fotograma. No supera el umbral individual de 8 ms y por eso no origina una ventana nueva. No se deben interpretar las dos ventanas agrupadas como una enumeración completa de todos los tirones visuales de la sesión.

### Correlación con las capturas del perfilador aportadas después

La captura selecciona el fotograma **40210**, cuyo `Frame Time` es **63,21 ms**. El JSON conserva exactamente cuatro pasos físicos en ese fotograma, con construcciones de 5,823 / 5,881 / 5,157 / 4,918 ms. Suman **21,779 ms**, coherentes con los **21,87 ms** de `_build_backend` y cuatro llamadas que muestra el perfilador. `_build_fields` muestra 22,01 ms y el controlador de la moto 47,47 ms. Estas duraciones son inclusivas/anidadas y no se suman entre sí.

La imagen también atribuye 18,56 ms al sistema de física del agua, 11,66 ms a `integrate_cell` y 8,37 ms a `_submerged_tetra`, además de consultas y comprobaciones del proveedor. La construcción FFT explica parte del fotograma; el registro nativo no desglosa ese resto de trabajo.

**Limitación de PERF-1:** no contiene una duración total explícita por fotograma visual. Su disparador es una construcción individual >8 ms. Por tanto, un fotograma de 63,21 ms compuesto de varias construcciones inferiores a 8 ms no genera una ventana de pico. En este caso se puede correlacionar porque 40210 sigue entre los 256 registros recientes; jugando más tiempo se perdería ese contexto. Para capturar todos los parones visuales, una siguiente ampliación debe medir duración por fotograma y congelar el contexto también por ese umbral, con etapas adicionales de física/consultas. La captura no permite asignar el valor exacto del otro pico visual sin su número de fotograma.

## Atribución interna

Referencia de comparación: registros retenidos con tiempo <1,8 ms y fase normal. Esta selección sirve para comparar etapas, no para calcular percentiles de toda la sesión. La mediana de las últimas 256 construcciones es 1,448 ms.

| Etapa, suma de tres bandas | Mediana de referencia | Mediana de los siete picos | Multiplicador |
| --- | --- | --- | --- |
| Avance de fase | 0,065 ms | 0,372 ms | 5,72× |
| Evolución | 0,159 ms | 0,980 ms | 6,18× |
| Empaquetado | 0,169 ms | 1,050 ms | 6,21× |
| IFFT | 1,012 ms | 7,396 ms | 7,31× |

En la construcción más lenta, secuencia 8586, las bandas tardan 4,203 / 4,169 / 4,212 ms. La IFFT suma 9,694 ms, aproximadamente el 76,8 % de los 12,629 ms totales. Configuración: 0 ms. Tiempo fuera de bandas: 0,045 ms. La mayor parte del tiempo se atribuye a las etapas de construcción; la subida no está concentrada en la publicación, el registro del contexto o una banda aislada.

## Explicaciones que no aparecen en estos eventos

- Resoluciones constantes: 128/128/128. Backend AVX2, CPU_LITE_B, comparación adicional desactivada.
- Generación del espectro constante: 1. Configuración total registrada: cero.
- Sin retrocesos ni saltos de tiempo: todos los deltas conservados son aproximadamente 0,025 s de simulación.
- Los siete picos tienen fase normal, sin reinicialización. El rebase 600 conservado en la secuencia 11401 tarda 1,612 ms en total y no produce un pico.
- Memoria lógica de cada banda constante: 4.594.128 bytes; variación registrada: cero. Esto no descarta presión de memoria o caché del proceso/sistema, pues esos recursos no se miden aquí.

Estas conclusiones se limitan a los datos conservados. Las grandes construcciones anteriores de 92,42 / 70,38 / 41,77 ms no aparecen en esta sesión; su causa no se puede inferir directamente de los episodios actuales.

## CPU del hilo y límite de la medición

Los 327 valores de tiempo de CPU son exclusivamente **0 o 15.625 µs**: 282 valores cero y 45 de 15.625 µs. Por ejemplo, una construcción de 12,629 ms tiene 15,625 ms de CPU registrados y otra de 8,337 ms tiene cero. Esta cuantización impide usar `wall_minus_thread_cpu_us` como duración fiable de desplanificación por construcción. Sumar intervalos discontinuos tampoco elimina el error de cuantización.

El contador de ciclos pasa de una mediana de referencia de 3,98 millones a 34,84 millones en el pico mayor. Es evidencia complementaria de coste asociado al hilo, pero no identifica cambios de núcleo, frecuencia, presión de caché, trabajo del kernel o competencia con otros hilos. [Microsoft documenta que el contador incluye modo usuario y kernel y advierte que no se debe convertir a tiempo transcurrido](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-querythreadcycletime).

## Próxima medición

Antes de optimizar la FFT o cambiar el calendario del agua, correlacionar una captura externa de Windows con las ventanas PERF-1: proceso 37344 en esta sesión, hilo identificado en cada registro, actividad de los demás hilos, muestras de CPU y cambios de contexto. [CPU Usage (Precise) de WPA permite distinguir ejecución, espera y tiempo listo para ejecutar](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis).

`wpr.exe` está disponible en `C:/Windows/system32/wpr.exe`; `wpa.exe` no se encontró en PATH. No se ha iniciado ningún registro externo ni instalado herramientas. Conviene incluir además el trabajo de Godot entre construcciones y el hilo de reporte PERF-1; esta captura no permite excluir su interferencia con los recursos del proceso.

El siguiente paso debe resolver si existe una ralentización de ejecución, una espera/cambio de contexto o una carga concurrente concreta. Las resoluciones, física y conducción se mantienen intactas hasta disponer de esa atribución.
