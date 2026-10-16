# D3 — Jet Ski como addon de producción

Base: `1bfb71acc0f21f0cd968367c8033589346b2bbb4`, `wip/feel-soft-water`.
Referencia previa: `preserve/phase-d3-before-20261016`.

## Alcance

115 archivos trasladados con historial: escena, scripts, materiales, colisiones,
modelos, texturas y ocho PNG de `Splash_1`. Ubicación final: `addons/jet_ski/`.
Se preservan UIDs, opciones de importación y parámetros serializados de D2.
El addon necesita Ocean D2, con sus tipos y proveedor nativo directo.

`JetSkiController.configure_ocean(ocean)` es una función de configuración inicial:
conserva el proveedor de Ocean mediante el mecanismo D2 y configura los FX.
No interviene en cada contacto. El dispatcher de fuerzas y las consultas son
exactamente los de D2; el proveedor y todos los archivos runtime de Ocean quedan
intactos. Solo se actualiza la documentación de instalación de Ocean.

Cambios de inicialización necesarios para extraer el vehículo:

- `ProductionSetup` aplica una vez los mismos modos/flags que antes aplicaba el
  integrador de desarrollo. La inercia combinada del piloto, Water Race y modo
  angular estabilizado dejan de depender del integrador. El código de fuerzas
  permanece igual. `trick_preload_enabled=false`, antes impuesto por el integrador,
  queda serializado en el prefab; los demás valores originales se conservan.
- `WaterContactFx` pasa a ser un hijo del prefab. Espera a `vehicle.ready` para
  obtener los sistemas del padre. Sus cálculos y parámetros se mantienen.
- El HUD se traslada a `debug/` y se añade explícitamente en el integrador de
  desarrollo. No es una dependencia de la escena del vehículo ni del ejemplo.
- `JetSkiInputBindings` registra solo acciones InputMap inexistentes, al arrancar.
  Conserva nombres, teclas y deadzone de producción. Admite eventos configurables
  y respeta el InputMap del proyecto. El muestreo de inputs por tick es idéntico.

El ejemplo empaquetado conecta Ocean y Jet Ski, configura una vez CPU Lite y
espera la fuente física. No contiene cálculos esenciales del vehículo. Usa los
perfiles predeterminados de Ocean; el mar y escenario originales de desarrollo
conservan sus parámetros anteriores.

## Regresión funcional

| Comprobación | Resultado |
| --- | --- |
| Muestras D2/D3 | 4.080 comparaciones, altura/normal/velocidad/profundidad, validez y tiempos exactos |
| Reloj/campo compartido | 120 ticks, 120 construcciones, dos contextos de consulta |
| Trayectoria D2/D3 | 1.140 pasos, error cero en posición, velocidad lineal/angular y orientación |
| Maniobras | Aceleración, giro a ambos lados, frenada, reversa −1,457 m/s, lean front, submarino, caída, aterrizaje y recuperación |
| Ajustes del controlador | 177 exports iguales a la configuración efectiva D2 |
| Cámara | 23 parámetros iguales; 600 poses y siete impactos frente al oráculo, error cero |
| Uno/dos/doce vehículos | 360 ticks cada caso, 330 ticks instrumentados, 330 construcciones únicas por caso |
| Cachés por consumidor | 1/2/12 contextos distintos y 13/26/156 muestras sin alias ni posiciones de otra moto |
| Escena original | Ejecución real, flotabilidad, conducción, lean, spray, recuperación y nueve controles de cámara pasan |

El oráculo conserva el dispatcher y `_ready` de D2 y los exports serializados del
prefab anterior. Recibe exclusivamente los ajustes del integrador D2; el candidato
D3 no recibe esos ajustes desde el validador. El proveedor-oráculo omite solo la
admisión de otro singleton durante su configuración, para poder mantener un campo
independiente exclusivamente en A/B. Su código de consultas y cálculos es D2.
Producción conserva un solo proveedor/campo por Ocean.

Las primeras pruebas de caída conservaban la inclinación final del submarino y
no disparaban el umbral de FX de aterrizaje, en ambas variantes. Se conservan sus
resultados. La caída controlada horizontal sí produce el evento en ambas y pasa
la comparación exacta. No se cambió la física para satisfacer la prueba.
El primer oráculo de cámara tenía rutas antiguas: se conservó y se creó una copia
con únicamente esas rutas corregidas para el ensayo final.

## Rendimiento

Cinco ejecuciones: A/A, A/B, B/A, A/B y B/A. 180 ticks de calentamiento y 900
medidos por cuerpo. Mismos inputs y tiempo inicial de olas. Instrumentación
simétrica, tiempos individuales conservados, sin escritura en callbacks físicos.
El render de HUD opcional se iguala entre variantes dentro de la prueba.

| Etapa | D2 p50 / p95 / p99 (ms) | D3 p50 / p95 / p99 (ms) | Llamadas por variante en A/B agrupado |
| --- | --- | --- | --- |
| `prepare_water_queries` | 1,457 / 1,678 / 1,979 | 1,454 / 1,667 / 1,950 | 3.600 |
| Consultas por lotes | 0,188 / 0,227 / 0,257 | 0,187 / 0,227 / 0,261 | 4.720 |
| `_integrate_forces` | 2,473 / 2,806 / 3,200 | 2,468 / 2,807 / 3,369 | 3.600 |

El p99 cambia −1,47%, +1,56% y +5,28%. La diferencia por orden observada en A/A
es 44,49%, 58,44% y 30,50% en p99; en p95, 10,20%, 12,56% y 7,66%.
No se identifica una regresión superior a la variación A/A. No se descarta ningún
outlier ni se afirma una mejora de rendimiento. Cada variante construye 900 campos
durante los 900 ticks medidos. Las trayectorias A/B permanecen exactamente iguales.

No se introducen nuevas asignaciones por contacto: se verifica en fuente el
dispatcher exacto D2, el proveedor inalterado y los métodos de inputs sin cambios.
Los nuevos recursos, bindings y conexiones se inicializan una vez. No se realizó
una traza de asignaciones del motor; esta afirmación se limita a los cambios D3.

## Instalación independiente

El proyecto temporal se crea **descomprimiendo los dos ZIP distribuidos** en una
carpeta vacía y copiando el `project.godot.example` distribuido como
`project.godot`: ejemplo como escena principal, Forward+ D3D12, Jolt e
interpolación física activada, los mismos ajustes públicos que producción.
No se copian cachés, autoloads, MCP, recursos del
laboratorio, `gameplay/`, validadores ni configuración privada de producción.

Importación y ejecución real Windows sin errores ni avisos de UID inválido.
Prueba externa sobre el ejemplo instalado:

- DLL registrada; V1 normal, flags de producción e inercia combinada correctos.
- Inputs se instalan desde cero; un binding personalizado y acciones existentes
  del proyecto se conservan; recuperación con la tecla T confirmada.
- Conducción, lean, salto, dos aterrizajes, partículas, spray con ocho PNG y cámara.
- Nueve controles de cámara correctos, sin HUD de depuración ni integrador cargado.
- AIR_SAFE → UNDERWATER_SAFE → AIR_SAFE con lectura de waterline válida.
- Cero fallos del campo físico, clases globales y UIDs únicos, sin rutas de recurso
  externas a ambos addons (excepto las rutas regenerables de `.godot` en `.import`).

El proyecto mínimo se conserva con las evidencias. El paquete Jet Ski contiene
126 archivos, con manifiesto SHA-256 y tamaño exacto por archivo.
Cada entrada se verifica leyendo de nuevo el ZIP; la prueba limpia usa ese ZIP.

## Repetir las pruebas y límites

Validadores versionados, fuera de ambos addons:

- `jet_ski_addon_regression.gd`: `--fixtures=<D3 oracle directory> --result=<JSON>`.
- `jet_ski_addon_benchmark.gd`: `--vehicles=1|2|12` o `--bench=AA|AB|BA`,
  `--fixtures=<D3 timing probes> --result=<JSON>`.
- `jet_ski_camera_rig_runtime.gd`: oráculo de cámara preservado, con rutas de D3.
- El probe externo `clean_probe.gd` comprueba el ejemplo del proyecto limpio.

Legacy/Heavy permanecen; sus combinaciones experimentales no se auditan de nuevo
en esta extracción. Las acciones InputMap siguen compartidas como en D2: no se
implementa control multijugador por vehículo. El código del antiguo fixture plano
permanece fuera del addon y no condiciona su arquitectura.

**Linux/Steam Deck pendientes:** falta el binario Linux de Ocean y su validación
específica. No se trasladan experimentos P5 ni se limpian ramas, worktrees o
evidencias. La limpieza final queda pendiente de autorización.
