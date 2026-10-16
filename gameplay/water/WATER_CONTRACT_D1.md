# Contrato de agua — D1

Estado anterior: `6ad2dcc9ec2cdc43af305f2f6fb60411f5419491`, preservado por
`preserve/phase-d1-water-before-20261016`. Esta fase mantiene las carpetas existentes.

## Contrato obligatorio

`WaterSurfaceProvider3D` y `WaterSample3D` no dependen de Ocean ni de Jet Ski.

| Entrada / resultado | Semántica |
| --- | --- |
| `prepare_water_queries(transform, local_points, extra_points, physics_delta_s)` | Una preparación por consumidor, justo antes de evaluar fuerzas. Mantiene los hooks anteriores de CPU y GPU. |
| `sample_water(world_position, scratch)` | Posición de superficie, normal, velocidad y profundidad firmada coherentes. Puede reutilizar un resultado. |
| `sample_propulsion_water(world_position, scratch)` | Conserva la consulta específica del propulsor; el proveedor GPU mantiene su interpolación de contactos traseros. |
| `sample_surface_batch(world_positions)` | Un resultado por punto, en el mismo orden. Fuente no disponible: resultados inválidos. Sin selección de backend en el contrato común. |
| `sample_height(world_position)` | Altura de una muestra válida; `NAN` si no hay muestra válida. |
| `valid` | Los campos se pueden usar juntos. No se deduce de un temporizador. |
| `signed_depth` | Positivo dentro del agua; cero en la superficie. No supone distancia vertical para geometría arbitraria. |
| `sample_time_seconds` | Tiempo de simulación del campo consultado, no reloj de pared. `NAN` indica tiempo desconocido. |
| `sample_physics_tick` | Tick de publicación del campo, o `-1` si es desconocido. No introduce caducidad. |

Las muestras inválidas reutilizadas borran también el tiempo y tick anteriores.
Los proveedores antiguos pueden devolver tiempo desconocido sin perder su validez.
Las capacidades de diagnóstico, comparación, invalidación y registro existentes
siguen siendo opcionales; no se han eliminado modos ni cambiado sus cálculos.

## Reloj y construcción compartida

El integrador crea **un** `PhysicalWater` y suministra su ruta al vehículo.
Otros consumidores deben reutilizar ese mismo proveedor, no crear uno por vehículo.
`prepare_water_queries` termina en el prefetch CPU anterior, con idénticos puntos,
orden, delta y momento de ejecución. `OpenOceanFFT.advance_physics_wave_time`
continúa siendo el reloj autoritativo, protegido por tick. `last_build_tick`
conserva la protección de una construcción nativa por tick del proveedor compartido.
Las consultas individuales y por lotes no construyen FFT ni avanzan el reloj.

En CPU, la muestra publica `current_field_time` y `last_build_tick`.
En el proveedor GPU conservado, publica `spectrum_time` y `field_tick` del paquete
recibido; no cambia sus reglas preexistentes de aceptación. El proveedor plano
publica tiempo físico de la escena y velocidad configurada, sin simular FFT.

## Efectos opcionales del medio

Los efectos de contacto del vehículo ya no buscan `open_ocean_fft` ni mencionan
`OpenOceanFFT`. Reciben opcionalmente un `WaterInteractionSink3D` mediante
`set_water_interaction_sink`. Sus partículas funcionan sin ese endpoint.

`gameplay/integration/ocean_jet_ski_interaction_sink.gd` conecta las solicitudes de
espuma y aterrizaje con la instancia Ocean suministrada por el integrador. Mantiene
los argumentos y permisos anteriores y vuelve a resolver el FFT tras una
reconstrucción de Ocean. No consulta agua ni construye campos. Ocean no importa
clases, escenas o rutas del vehículo.

## Propiedad y mapa pendiente para D2 / D3

| Propietario | Archivos actuales | Pendiente de empaquetado |
| --- | --- | --- |
| Contrato neutral | `gameplay/water/water_surface_provider_3d.gd`, `water_sample_3d.gd`, `water_interaction_sink_3d.gd` | Establecer una única ubicación de distribución del contrato y sus UID; evitar registrar dos copias de las mismas clases globales. |
| Ocean / integración concreta | `addons/ocean/**`; `gameplay/water/cpu_fft_water_provider.gd`, `gpu_heightfield_water.gd`, `local_surface_contact_state.gd`, `wave_surface_drift.gd`, `perf1_capture.gd` | Reubicar proveedor y auxiliares de campos junto con Ocean o su puente opcional, conservando descriptor, DLL y reloj. Ocean base sigue sin depender de clases del vehículo. |
| Jet Ski | `gameplay/vehicles/**` | Reubicar escenas, sistemas, cámara y VFX como una unidad. Resolver rutas actuales de assets y secuencia `Splash_1/`. No hay referencias directas a Ocean en los scripts/escenas/shaders del vehículo. |
| Integración opcional | `gameplay/integration/ocean_jet_ski_interaction_sink.gd`, composición de `gameplay/jet_ski_ocean.gd` | Distribuir el puente por separado. El integrador actual aún configura Ocean/CPU, entradas, HUD y herramientas de desarrollo. Los efectos de contacto adicionales aún se instancian desde este host; el bow spray y la cámara ya pertenecen al vehículo. |
| Prueba independiente | `gameplay/water/flat_water_provider_3d.gd`, `validation/jet_ski_flat_water.*` | Fixture mínima sin Ocean. Las entradas de conducción siguen siendo responsabilidad del host, como antes. |

Los modos experimentales de superficie desplazada conservan sus historiales
internos y una preparación activa por proveedor. D1 comprueba múltiples
consumidores secuenciales en el modo DIRECT de producción. Antes de ofrecer varios
vehículos simultáneos con modos experimentales hay que separar sus contextos de
historial, manteniendo compartido el constructor FFT. No se ha rediseñado ese
comportamiento experimental en esta fase.

## Validación reproducible

Desde Godot 4.7.1, con el proyecto actual:

```text
Godot --headless --path <proyecto> --script res://validation/jet_ski_water_contract_runtime.gd -- --mode=flat --result=<flat.json>
Godot --path <proyecto> --script res://validation/jet_ski_water_contract_runtime.gd -- --mode=integration --result=<integration.json>
Godot --path <proyecto> --script res://validation/jet_ski_water_contract_runtime.gd -- --mode=ocean --oracle=<legacy_cpu_fft_water_provider.gd> --controller-oracle=<legacy_controller_force_dispatch.gd> --result=<parity.json>
```

El informe externo D1 conserva los scripts de extracción del oráculo, fuentes
anteriores, resultados JSON y registros. El oráculo de proveedor solo cambia su
ruta de preload para usar también el auxiliar anterior. El segundo oráculo hereda
del controlador y reemplaza exclusivamente su función de despacho de fuerzas por
el cuerpo exacto anterior; conserva los exports serializados del prefab.
Los dos campos nativos del test son exclusivamente para comparar versiones.
La escena de producción mantiene un solo proveedor y campo compartido.

Se han comprobado 3.840 pares de muestras sin diferencia, 120 construcciones para
120 ticks con dos consumidores, y 480 ticks de trayectoria de dos cuerpos con
las mismas entradas sin diferencia en posición, base ni velocidades.
La prueba plana recorre 600 ticks con flotabilidad, conducción, spray y cámara.
La escena completa y el test de cámara de Fase C cubren controles, impactos,
aterrizaje y recuperación. La prueba de integración verifica entrada al agua,
deriva y transiciones `AIR_SAFE -> UNDERWATER_SAFE -> AIR_SAFE`.

La comparación de trayectoria está acotada a las fases y entradas registradas;
no afirma equivalencia exhaustiva de todos los modos experimentales/Legacy/Heavy.
No cambian calidad, parámetros, fuerzas, cámara, shaders, DLL ni código FFT.
