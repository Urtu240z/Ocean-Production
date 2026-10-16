# Ocean — instalación D2

Godot 4.7.1, Forward+ y Windows x86-64. Copiar `addons/ocean/` del paquete D2
verificado a la misma ruta del proyecto destino e importar con RenderingDevice
activo. No copiar `.godot`, `temp`, `godot-cpp`, directorios de compilación ni
binarios intermedios del proyecto de desarrollo. No necesita autoloads, MCP,
inputs del vehículo, `gameplay/`, ni activar un plugin de editor.

Instanciar `res://addons/ocean/ocean.tscn`. Sus perfiles y opciones existentes
controlan el render, espuma y underwater. Para underwater, activar
`underwater_medium` y proporcionar una cámara actual y la luz direccional.

## Consultas físicas directas

Ocean es propietario de `WaterSurfaceProvider3D`, `WaterSample3D`,
`CpuFftWaterProvider` y sus tipos auxiliares. El futuro addon Jet Ski requiere
Ocean. No existe un tercer addon ni un adaptador entre cada contacto y la DLL.

Obtener una vez `ocean.get_water_provider()` y configurar **una vez por Ocean**
cuando `get_physics_source_state().status == "OK"`. La fábrica crea el proveedor
sin adelantar la configuración ni el reloj. Todos los vehículos de ese Ocean
reciben la misma referencia mediante `ski.configure_water_provider(provider)`.
La integración actual conserva 128/128/128, interpolación cúbica, backend
`CPU_LITE_B`, comparación desactivada y `set_water_race_mode(true)`.

Cada vehículo crea un `OceanWaterContactContext` al configurarse. En su callback
físico selecciona el contexto antes de preparar sus consultas y ejecuta después
las mismas consultas tipadas y por lotes de D1. Los contactos de un vehículo
forman una secuencia síncrona; no intercalar los contactos de otro consumidor
sin seleccionar su contexto. No es una API multihilo.

Los contextos contienen exclusivamente historial/cachés de contactos. El objeto
nativo, espectro, reloj, campos, sincronización y límite de una construcción por
tick permanecen en el proveedor compartido. Seleccionar el mismo contexto es un
retorno inmediato. Al cambiar de contexto se trasladan las referencias y se
vacían sus slots activos para evitar alias de PackedArray y nuevas copias COW.
Las consultas por contacto conservan sus implementaciones, scratch y resultados.
Una invalidación del espectro invalida todos los contextos mediante una época;
una recuperación del vehículo invalida solo sus contactos activos.

Los modos antiguos siguen disponibles. En `LOCAL_SURFACE`, cambiar consumidor
invalida únicamente el parche geométrico nativo compartido para reconstruirlo
con los puntos correctos; no construye otro campo FFT. D2 valida producción en
modo `DIRECT`; no cambia ni elimina Legacy/Heavy ni valida todas sus combinaciones.

## Interacciones visuales

Configurar una vez `JetSkiWaterContactFx.configure_ocean(ocean)`. Las funciones
`is_persistent_foam_enabled()`, `is_landing_ripple_enabled()` y
`submit_foam_stamp(position, velocity, strength, landing)` delegan directamente
al FFT que Ocean ya mantiene. No hay búsquedas por contacto ni un adaptador
GDScript en el camino físico.

## Binarios y alcance

El descriptor está en `physics/native/ocean_query/ocean_query_native.gdextension` y usa
`bin/ocean_query_native.windows.template_release.x86_64.dll`. No se recompiló
ni se modificó el binario ni sus llamadas nativas en D2. El código fuente nativo
se conserva; recompilar requiere el SDK `godot-cpp` compatible y SCons.

**Falta el binario Linux.** La entrada Linux del descriptor no proporciona el
`.so`: Steam Deck necesita su propia compilación y validación de rendimiento,
render y física. Las pruebas Windows no certifican Steam Deck.

Jet Ski se instala en `addons/jet_ski/` y contiene sus secuencias PNG. La
instalación conjunta histórica de D2 usó las ubicaciones anteriores del vehículo,
sin necesitar la escena de desarrollo.
La escena plana de D1 queda como fixture histórica; ya no define una promesa de
independencia del vehículo respecto a las clases de Ocean.
