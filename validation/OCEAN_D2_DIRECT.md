# D2 — extracción directa de Ocean

Base: `fae3395ac5daf5009905e545a400d261828d5faf`, rama `wip/feel-soft-water`.
Arquitectura aceptada: Jet Ski depende de Ocean. No se incorpora el candidato
anterior de servicio de campos separado e integración tipada.

## Cambios

Se trasladan siete scripts de `gameplay/water/` con sus UIDs a
`addons/ocean/physics/water/`: proveedor base, muestra, proveedor CPU FFT,
proveedor GPU, historial local, deriva de superficie y captura PERF.
Se traslada sin cambios el generador VDM de breakers desde el laboratorio a
`addons/ocean/fft/`: producción lo usaba como clase global y la instalación
limpia detectó esa dependencia oculta. Se actualizan las referencias del
laboratorio y sus validadores. No se incorporan implementaciones P5.

Ocean mantiene su único proveedor. El controlador recibe y conserva su referencia
y un contexto de contactos creado durante la configuración. Los contextos no
poseen FFT, reloj, espectro ni objeto nativo. La preparación y las consultas
conservan el cálculo y el orden de D1. La integración de espuma usa la API directa
de Ocean. Los antiguos fixtures/adaptadores no se eliminan durante esta fase.

## Validación

- Comparación con fuente exacta D1: 3.840 muestras de altura, normal, velocidad y
  profundidad; 120 ticks y 120 construcciones; error cero. Trayectorias emparejadas
  durante 480 ticks: posición, velocidad lineal/angular y orientación iguales
  exactamente, aceleración, giro, frenada, caída/reentrada y lean front.
- Uno, dos y doce vehículos: 360 ticks, una construcción en cada uno de los 330
  ticks instrumentados, un objeto nativo. Contextos distintos; 13/26/156 muestras
  de contacto verificadas sin compartir objetos entre vehículos ni posiciones
  ajenas. La instrumentación es externa al proveedor de producción.
- A/A, A/B, B/A, A/B, B/A: instrumentación simétrica, 180 ticks de calentamiento
  y 900 medidos por cuerpo y ejecución. La baseline usa el proveedor y dispatcher
  D1 preservados; conserva los exports serializados del prefab. Cada ejecución
  emparejada mantiene exactamente la trayectoria y 900 construcciones por variante.
  Las FFT separadas del oráculo son exclusivamente de la prueba comparativa.
- Proyectos mínimos con copias verificadas de fuentes/assets, sin cachés de
  producción: Ocean solo y Ocean con el Jet Ski actual. Importación y ejecución
  Forward+ D3D12; DLL registrada, 720 muestras, 180 construcciones para dos
  consumidores en 180 ticks, reloj avanza, transición AIR_SAFE / UNDERWATER_SAFE /
  AIR_SAFE. El proyecto conjunto no carga `jet_ski_ocean.gd`.
- Regresión de cámara: 600 poses, 7 impactos y 23 parámetros contra el oráculo de
  Fase C, error de transformación cero. Prueba adicional de escena completa para
  conducción, lean, recuperación, controles de cámara y secuencia spray.

Tiempos agrupados de cuatro ejecuciones equilibradas (milisegundos):

| Etapa | D1 p50 / p95 / p99 | D2 p50 / p95 / p99 |
| --- | --- | --- |
| Preparación, 3.600 llamadas | 1,444 / 1,661 / 1,900 | 1,435 / 1,655 / 2,115 |
| Lotes, 4.720 llamadas | 0,185 / 0,225 / 0,249 | 0,185 / 0,222 / 0,252 |
| Integración, 3.600 callbacks | 2,448 / 2,798 / 3,111 | 2,442 / 2,778 / 3,355 |

El p99 agrupado aumenta 11,3% / 1,2% / 7,8%. La comparación A/A muestra diferencias
por orden de 38,1% / 54,3% / 41,3% en p99 y 8,1% / 9,9% / 7,0% en p95. Ambos
órdenes se conservan; no se descartan outliers. En este ensayo no se identifica
una regresión que exceda la variación de la baseline. No es una garantía del p99
en otras máquinas ni una medición Steam Deck. Los resultados y tiempos crudos
se conservan para revisar el criterio, sin optimizar FFT ni saltar ticks.

La ausencia de nuevas asignaciones **por contacto** se comprueba en fuente:
mismos métodos de consulta y muestras, sin conversión ni intermediario añadido.
El contexto se crea al configurar el vehículo y se selecciona por preparación.
No se realizó una traza de asignaciones del motor; no se afirma que el proveedor
D1 carezca de sus asignaciones originales.

## Reproducibilidad y límites

`jet_ski_water_contract_runtime.gd` permite `--mode=ocean --oracle=<D1.gd>
--controller-oracle=<dispatcher D1.gd> --result=<JSON>` y `--mode=integration`.
`ocean_direct_consumers_runtime.gd` usa `--vehicles=1|2|12` o `--bench=AA|AB|BA`,
`--fixtures=<probes externos> --result=<JSON>`. Los probes y snapshots exactos D1
se conservan con las evidencias, no dentro del addon de producción.
`ocean_clean_install_runtime.gd` se copia como `main.gd` a un proyecto vacío con
el paquete, ejecutado con `--script res://main.gd -- --result=<JSON>`; `--joint=yes`
añade el vehículo existente, sus recursos y el host de inputs histórico.

La importación headless inicial de GLSL abortó en este entorno; la importación
con RenderingDevice y la ejecución real Forward+ completaron ambas instalaciones.
No se modifica ningún shader para sortearlo.

El test textual antiguo `ocean_surface_detail_wave_time_runtime.gd` incluye una
aserción histórica de reloj en materiales/shaders que no representa el contrato
actual. D2 solo actualiza su ruta de proveedor. El reloj se valida numéricamente
contra D1 y durante las consultas compartidas; no se retocan shaders para satisfacer
esa comprobación obsoleta.

Dependencias externas del paquete: Godot 4.7.1, dispositivo Forward+ compatible y
binario Windows incluido. Sin clases de Jet Ski, autoloads, inputs, MCP ni rutas
fuera de `addons/ocean/`. Falta Linux; Steam Deck requiere compilación y validación
propias. D3 y la limpieza de ramas/worktrees permanecen pendientes de autorización.
