# PERF CHECKPOINT 1C-A — Production Render Shell

## Alcance

Este checkpoint añade una ruta de benchmark de producción independiente del
benchmark mínimo de `validation/ocean_benchmark.tscn`. No modifica B0-B12 ni
G0-G2, no cambia perfiles de calidad, resolución FFT, FSR, dynamic resolution
ni el comportamiento del proyecto normal.

La escena `validation/production_benchmark.tscn` instancia
`validation/p0_open_ocean.tscn` para reutilizar los valores reales de Ocean
Production: HDRI Kloofendal, Environment AGX/exposure/glow/fog/SSAO/SSIL,
CameraAttributesPhysical y la luz direccional con sombras. El único elemento
que se retira es `testisland`, que es geometría de validación y no parte del
shell de producción.

## Entrada y presets

Los presets nuevos son `Windows Production Benchmark` y `Linux Production
Benchmark`. Ambos usan el feature tag `production_benchmark`, que selecciona
`run/main_scene.production_benchmark` sin editar manualmente `project.godot`.
Los presets normales y los presets `Windows Benchmark`/`Linux Benchmark` no se
alteran.

Comandos Windows:

```powershell
& "C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64_console.exe" --headless --path "." --export-release "Windows Production Benchmark" "..\Ocean Production Production Benchmark.exe"
& ".\..\Ocean Production Production Benchmark.exe" -- --ocean-production=all --ocean-window=windowed --ocean-resolution=1920x1080
```

Para fullscreen real:

```powershell
& ".\..\Ocean Production Production Benchmark.exe" -- --ocean-production=all --ocean-window=fullscreen --ocean-resolution=1920x1080
```

Linux:

```bash
godot --headless --path . --export-release "Linux Production Benchmark" "../Ocean Production Production Benchmark.x86_64"
../Ocean\ Production\ Production\ Benchmark.x86_64 -- --ocean-production=all --ocean-window=fullscreen --ocean-resolution=1280x800
```

`--ocean-window=windowed`, `borderless` y `fullscreen` seleccionan el modo de
ventana. `--ocean-production=environment`, `production` y `underwater` permiten
repetir únicamente E, P o U durante desarrollo. El modo `all` ejecuta todo.
La resolución solicitada se valida contra ventana, viewport y render size; si no coincide,
el proceso escribe `INVALID_RESOLUTION` y no presenta la ejecución como válida.

## Matrices

### E — entorno separado

E0 no sky/HDRI, no CameraAttributes, glow off y sombras off. E1 añade el sky
HDRI real. E2 añade CameraAttributesPhysical. E3 habilita glow/post. E4
restaura las sombras de la luz real. Estas cifras sólo describen el coste del
shell; no se interpretan como delta de Ocean.

### P — producción sobre la misma escena

P0 entorno, P1 FFT off, P2 FFT LONG/MID/SHORT, P3 Coastal, P4 Crest Foam,
P5 Surface Foam, P6 Optics, P7 Reflections/SSPR, P8 Surface Detail, P9
Underwater preparado y P10 full. Los estados se aplican de forma acumulativa
y se espera el rebuild correspondiente entre casos.

### U — transición física

U0 permanece por encima. FAST conserva el cruce lineal rápido en
`U1_FAST_ENTRY` y `U3_FAST_EXIT` para detectar spikes/hitches. Después se
ejecutan `U1_SLOW_ENTRY` y `U3_SLOW_EXIT`: la cámara se acerca continuamente,
desacelera y atraviesa la misma banda diagnóstica de ±0.25 m en un objetivo de
0.85 s antes de continuar hasta el estado estable del otro lado. No hay
teleport ni cambio de superficie/query. La coordenada Y sólo controla la
trayectoria. La clasificación
ABOVE/TRANSITION/UNDERWATER procede de `signed_distance_to_surface` producido
por `ocean_waterline_camera_state.glsl`, que reutiliza las texturas LONG/MID/
SHORT y la misma inversión de chop del waterline P6. No existe una copia CPU
del cálculo de superficie.

El readback está opt-in y se limita al benchmark. En el núcleo se expone como
`Ocean.set_waterline_state_readback_enabled()` / `Ocean.get_waterline_state()`;
no participa en gating ni cambia la calidad visual. La banda de transición de
0.25 m es sólo una etiqueta diagnóstica, ampliada si los márgenes reales del
perfil lo requieren.

## Salidas

El ejecutable escribe `user://production_benchmark_results.txt`,
`user://production_benchmark_results.csv` y
`user://water_transition_frames.csv`.

El encabezado registra resolución solicitada, ventana, viewport, display,
modo, plataforma, renderer, backend, driver y GPU. Las filas incluyen GPU y
CPU median/P95/P99/max cuando el backend los proporciona; si no hay muestras se
usa `UNAVAILABLE`, sin inventar valores. También se registran FPS, primitivas,
draw calls y las muestras por frame de la transición.

## 1C-B — observaciones pendientes

Este checkpoint no decide optimizaciones. Surface Foam debe analizarse por
separado distinguiendo simulación/historial y presentación; Crest Foam debe
conservar sus dependencias de datos de cresta y de los tres cascades. No se
implementa gating final en 1C-A.

## Validation fix

La validación posterior corrigió tres problemas del primer run:

- E0-E4 retiran explícitamente el runtime `Ocean` heredado de P0 antes de
  medir. Si el shell environment-only encuentra superficie o counters de
  primitivas/draws no nulos, el caso se marca `CASE_INVALID`.
- P1 mantiene `OceanClipmapSurface` y sus niveles de clipmap, pero inicializa
  con la máscara FFT `0`; por tanto LONG/MID/SHORT están realmente OFF y la
  geometría estática sigue presente.
- Production habilita explícitamente
  `RenderingServer.viewport_set_measure_render_time(viewport_rid, true)`, la
  misma ruta usada por el benchmark B. GPU y CPU se reportan como
  `UNAVAILABLE` sólo si el backend no entrega muestras; wall-frame permanece
  separado.

Cada P/U registra `SETUP`, `STATE VERIFY` y un warmup independiente antes de
medir. Los casos que necesitan superficie validan runtime y counters, y los
casos E validan ausencia de ambos. La línea `TRANSITION` sólo agrega U1 y U3;
U0, U2 y U3 estable se reportan en ventanas independientes. Además se imprime
la duración efectiva de cada ventana de transición y los umbrales de frame
time. La CSV identifica por separado `U1_FAST_ENTRY`, `U3_FAST_EXIT`,
`U1_SLOW_ENTRY` y `U3_SLOW_EXIT`.
