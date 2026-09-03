# Ocean — auditoría de promoción P0

## Alcance entregado

P0 contiene sólo mar abierto profundo con las bandas `LONG`, `MID` y `SHORT`.
Cada una usa el mismo perfil ROUGH documentado en `P0_BASELINE_ROUGH.md`: JONSWAP/Hasselmann, semilla derivada de la semilla raíz, resolución FFT 256 y dominios 512 m, 137 m y 37 m respectivamente.

El flujo estructural es:

`Ocean` → `OpenOceanFFT` → tres `OceanGPUStockhamFFT` → `OceanClipmapSurface`.

El apagado desconecta primero los `Texture2DRD` publicados, después libera los recursos de cada solver en el hilo de render y, por último, libera la superficie. Desactivar `enabled` u `open_ocean_fft` llama a ese apagado; no deja simulación ni recursos GPU activos.

## Archivos promovidos y motivo

| Producción | Referencia en Lab | Motivo P0 |
| --- | --- | --- |
| `ocean.gd` y `.tscn` | `ocean_v3.gd` | API pública `Ocean`, autoría e inspector P0. |
| `core/ocean_fft_config.gd`, `ocean_wave_band.gd`, `ocean_wave_profile.gd` | `core/open_ocean_fft_config.gd` y los valores activos de `lab_main.tscn` | Recursos mínimos para conservar las tres bandas ROUGH sin exponer configuración de espuma o costa. |
| `core/ocean_quality_profile.gd` | `core/ocean_quality_settings.gd` | Un perfil concreto y útil para la malla clipmap. |
| `fft/jonswap_hasselmann_spectrum.gd` | `core/tessendorf_spectrum.gd` y `open_ocean_fft_module.gd` | Construcción de H0 JONSWAP/Hasselmann y derivación determinista de semillas. |
| `fft/gpu_stockham_fft.gd` | `rendering/fft/gpu_stockham_fft.gd` | Solver FFT Stockham reducido a desplazamiento, normal y Jacobiano. |
| `fft/open_ocean_fft.gd` | `open_ocean_fft_module.gd` | Orquestación directa de LONG/MID/SHORT y ciclo de vida de GPU. |
| `surface/ocean_clipmap_mesh_builder.gd` | `rendering/ocean_clipmap_mesh_builder.gd` | Centro, anillos y stitches 2:1 conservados; no se genera malla por fotograma. |
| `surface/ocean_clipmap_surface.gd` y `shaders/ocean_surface.gdshader` | `rendering/ocean_clipmap_surface.gd` y `rendering/shaders/ocean_surface.gdshader` | Presentación básica de tres bandas, color profundo y vista de normales. |
| `shaders/fft/*.glsl` | pipeline FFT de `rendering/fft/gpu_stockham_fft.gd` | Evolución espectral, Stockham IFFT y ensamblaje de mapas sin canales de espuma. |
| `validation/p0_open_ocean.tscn` | escena activa ROUGH de Lab | Escena aislada para abrir y ejecutar P0. |

Los ficheros `.uid` y `.import` asociados son metadatos generados por Godot para las mismas piezas anteriores; no introducen sistemas adicionales.

## Comparación estructural

| Aspecto | Lab ROUGH | Producción P0 |
| --- | --- | --- |
| Bandas de mar abierto | LONG, MID, SHORT, más variantes posteriores | LONG, MID, SHORT exclusivamente |
| Espectro y FFT | JONSWAP/Hasselmann, FFT GPU | JONSWAP/Hasselmann, FFT GPU Stockham |
| Presentación | clipmap y módulos posteriores | clipmap mínimo con stitches 2:1 |
| Diagnóstico | conjunto amplio de laboratorios | sólo `Normals` y overlay opcional |
| Ciclo de vida | módulos de Lab | propietario único que libera sus tres solvers |

## Exclusiones verificadas

No hay dependencias de runtime de Coastal, foam, breakers, SSPR, underwater, caustics, sunrays, sediment, OceanQuery, benchmarks ni experimentos. No se promovieron `LONG_COASTAL` ni `LONG_REMAINDER`.

Los términos de esta lista sólo pueden aparecer en esta documentación o en un comentario descriptivo; no forman parte del runtime P0.

## Validación técnica realizada

- Godot 4.7.1 abre el proyecto en modo editor sin errores del proyecto.
- La escena principal `validation/p0_open_ocean.tscn` se inicia dos veces seguidas en modo headless sin errores ni caídas.
- La escena tiene los tres recursos de banda activos y el perfil ROUGH documentado.
- Se comprobó el ciclo de arranque/cierre y la liberación de los recursos publicados por las tres bandas.
- Eric concedió VISUAL PASS manual a P0. P1 puede comenzar después de cerrar y sincronizar este checkpoint.
