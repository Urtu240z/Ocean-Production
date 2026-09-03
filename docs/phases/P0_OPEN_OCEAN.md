# P0 — Open Ocean

## Objetivo y promoción

Promover mar abierto profundo mínimo: JONSWAP/Hasselmann, FFT GPU Stockham, LONG/MID/SHORT, clipmap y escena de validación. Se tomaron los valores ROUGH activos de Lab, documentados en `../P0_BASELINE_ROUGH.md`.

Se descartaron deliberadamente Coastal, LONG_COASTAL, LONG_REMAINDER, espuma, breakers, óptica avanzada, SSPR, underwater, caustics, sunrays, sediment, OceanQuery, infraestructura permanente de benchmarks y experimentos.

## Arquitectura, flujo y archivos

`Ocean` crea `OpenOceanFFT`; éste convierte el perfil en tres configuraciones, genera H0, crea tres solvers y publica sus desplazamientos/normales a `OceanClipmapSurface`. Los compute shaders evolucionan el espectro, ejecutan Stockham IFFT y ensamblan mapas. La superficie construye sus mallas de clipmap una vez y las actualiza visualmente con la cámara.

Archivos: `ocean.gd` (API y lifecycle), `core/*` (perfiles/configuración), `fft/*` (H0 y solvers), `surface/*` (malla/superficie), `shaders/*` (compute y material), y `validation/p0_open_ocean.tscn` (validación). La cámara reutilizable está en `validation/free_camera.tscn`; no pertenece al addon. El detalle de responsabilidades está en `../ARCHITECTURE.md`.

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

Depende de Godot 4.7.1, RenderingDevice y Forward Plus. P0 sólo soporta las tres bandas de mar abierto y no incluye consulta física del océano ni infraestructura permanente de medición. Eric concedió VISUAL PASS manual.

## Validación

Godot 4.7.1 abre el proyecto sin errores del proyecto; `validation/p0_open_ocean.tscn` arrancó y cerró dos veces seguidas sin errores; las tres bandas están activas; no hay dependencia de runtime de Lab; `git diff --check` pasó; y Eric concedió VISUAL PASS manual.

## PERFORMANCE

Baseline oficial P0, medido el 2026-09-03 en `validation/p0_open_ocean.tscn`. La herramienta de benchmark usada fue temporal y se eliminó después de documentar la medición; la free camera de validación permanece para las fases posteriores.

| Campo | Valor |
| --- | --- |
| Hardware | Intel i7-13650HX; RTX 4070 Laptop GPU |
| Resolución | 1920x1080 real de ventana durante la medición |
| Render scale | 1.00 real del viewport 3D |
| Renderer | Godot 4.7.1; Forward+; D3D12 |
| VSync | OFF |
| FPS cap | `Engine.max_fps=0` |
| Métrica | Intervalo medio de frame por reloj de pared; no es GPU ms |
| Average frame ms | 1.154 ms |
| Average FPS | 866.6 FPS |
| Resultado | P0 OPEN OCEAN — 1920x1080, render scale 1.00, VSync OFF |

Este baseline se usa para P1 y fases posteriores: `delta ms = fase_ms - 1.154`, `delta FPS = fase_fps - 866.6` e incremento porcentual de intervalo `((fase_ms / 1.154) - 1.0) * 100`. La herramienta fue temporal y ya se eliminó.

## Commit de fase

El cierre P0 contiene runtime, infraestructura reutilizable de validación, baseline y documentación. El benchmark no permanece; `validation/` se eliminará únicamente al finalizar la validación global de Production.
