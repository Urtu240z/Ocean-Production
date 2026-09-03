# P0 — Open Ocean

## Objetivo y promoción

Promover mar abierto profundo mínimo: JONSWAP/Hasselmann, FFT GPU Stockham, LONG/MID/SHORT, clipmap y escena de validación. Se tomaron los valores ROUGH activos de Lab, documentados en `../P0_BASELINE_ROUGH.md`.

Se descartaron deliberadamente Coastal, LONG_COASTAL, LONG_REMAINDER, espuma, breakers, óptica avanzada, SSPR, underwater, caustics, sunrays, sediment, OceanQuery, infraestructura permanente de benchmarks y experimentos.

## Arquitectura, flujo y archivos

`Ocean` crea `OpenOceanFFT`; éste convierte el perfil en tres configuraciones, genera H0, crea tres solvers y publica sus desplazamientos/normales a `OceanClipmapSurface`. Los compute shaders evolucionan el espectro, ejecutan Stockham IFFT y ensamblan mapas. La superficie construye sus mallas de clipmap una vez y las actualiza visualmente con la cámara.

Archivos: `ocean.gd` (API y lifecycle), `core/*` (perfiles/configuración), `fft/*` (H0 y solvers), `surface/*` (malla/superficie), `shaders/*` (compute y material), y `validation/p0_open_ocean.tscn` (validación). El detalle de responsabilidades está en `../ARCHITECTURE.md`.

H0 se mantiene en CPU hasta la carga. Cada solver posee sus RIDs, buffers, pipelines, uniform sets y texturas. El orquestador posee los wrappers `Texture2DRD`; en shutdown los desconecta antes de liberar los RIDs del solver. No hay recursos GPU compartidos fuera de esa publicación.

## Qué puedo tocar

### SAFE TO MODIFY

`Significant Wave Height`, `Wind Speed`, `Wind Direction`, `Swell`, `Sea Level`, `Enabled`, `Open Ocean FFT`, `Debug View` y `Performance Overlay`.

### MODIFY WITH CARE

Bandas del Wave Profile y los valores de clipmap/fade del Quality Profile. Cambian imagen, calidad o coste y requieren reconstrucción o reinicio.

### INTERNAL / DO NOT TOUCH NORMALLY

Resolución FFT, dominios canónicos, ping-pong Stockham, bindings del shader, formatos de textura, ownership de RIDs y código de shutdown.

## Checkbox ON/OFF

Con `Enabled` u `Open Ocean FFT` en OFF, el propietario llama a shutdown, desatacha las texturas publicadas y libera los tres solvers GPU. Con ambos en ON, vuelve a crear las configuraciones, H0, RIDs y clipmap. No existe un modo oculto que conserve recursos.

## Dependencias y limitaciones

Depende de Godot 4.7.1, RenderingDevice y Forward Plus. P0 sólo soporta las tres bandas de mar abierto y no incluye consulta física del océano ni infraestructura permanente de medición. No hay aprobación visual todavía.

## Validación

Godot 4.7.1 abre el proyecto sin errores del proyecto; `validation/p0_open_ocean.tscn` arrancó y cerró dos veces seguidas sin errores; las tres bandas están activas; no hay dependencia de runtime de Lab; y el baseline temporal P0 quedó registrado en `../IMPLEMENTATION_STATUS.md`.

## Commit de fase

El commit de introducción se registra en este mismo checkpoint después de actualizar esta documentación.
