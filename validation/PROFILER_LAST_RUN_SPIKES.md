# Picos de la última captura conservada en el editor

Se inspeccionaron los paneles Profiler y Visual Profiler de Sesión 1 sin iniciar el juego, vaciar los paneles ni cambiar el código de producción. Se leyeron las tablas del editor al seleccionar fotogramas del historial y se copiaron las gráficas. Al terminar se restauraron ambos selectores al fotograma 36854, que tenían al empezar.

Rango del selector CPU: 33255–36854. Rango visual: 33254–36854. Son identificadores de fotograma; por sí solos no indican minutos transcurridos. El barrido CSV recoge los valores visibles para cada posición del selector, no una exportación del buffer interno del motor.

## Tres picos principales

| Fotograma seleccionado | Frame Time CPU | `_integrate_forces` | `_build_backend` CPU agua | Llamadas a física | GPU Render Viewports |
|---:|---:|---:|---:|---:|---:|
| 34301 | 176,32 ms | 136,09 ms | 92,42 ms | 4 | 2,13 ms |
| 35223 | 130,15 ms | 101,57 ms | 70,38 ms | 8 | 2,36 ms |
| 35337 | 98,69 ms | 59,63 ms | 41,77 ms | 2 | 2,36 ms |

Hay otro pico menor en el selector 33795: Frame Time 55,89 ms, `_build_backend` 24,28 ms, 3 llamadas a física y GPU Render Viewports 2,19 ms.

Los tiempos de funciones son los que presenta el perfilador y están anidados. No deben sumarse padre e hijos. El desglose Script Functions agregado tampoco debe interpretarse como tiempo exclusivo del fotograma.

## Ruta caliente identificada

```text
JetSkiController._integrate_forces
  -> CpuFftWaterProvider.begin_gameplay_contacts
     -> _build_fields
        -> _build_backend
           -> native.build_dynamic_physics_lite / build_dynamic_physics_fields
```

`gameplay/vehicles/common/core/jet_ski_controller.gd:835–842` llama al proveedor desde la integración de fuerzas. `gameplay/water/cpu_fft_water_provider.gd:724–727` construye el campo cuando cambia el tick físico; `832–870` mide y valida la construcción; `872–875` ejecuta directamente el backend nativo. El camino es síncrono: la integración espera su resultado.

El guard existente limita las construcciones a una por tick físico. Las 4/8/2 llamadas registradas no prueban duplicación dentro del mismo tick: son compatibles con pasos físicos acumulados para recuperar tiempo y pueden amplificar un retraso inicial.

En el pico 34301, OceanUnderwaterMedium._process registró 1,27 ms y OceanUnderwaterMediumEffect._render_callback 0,69 ms. Su coste no domina el desglose de ese pico.

En el barrido del perfilador visual, el máximo de GPU Render Viewports fue 2,49 ms (selector 35224). El máximo de CPU Render Viewports fue 10,54 ms (selector 35223). El perfilador visual muestra gráficos CPU y GPU separados; los valores GPU no explican los fotogramas CPU de 99–176 ms.

## Conclusión y límite

La captura identifica dónde se concentra el coste: construcción del agua física en CPU dentro de la integración del vehículo, junto con varias llamadas físicas en las muestras lentas. Permite dirigir la siguiente investigación al backend nativo y su planificación, evitando cambiar a ciegas shaders o flotación.

Todavía no demuestra por qué el backend se vuelve más lento puntualmente. Los tiempos pueden incluir trabajo, espera y desplanificación del hilo; hace falta instrumentación más fina para distinguir cálculos, asignaciones, sincronización o carga externa. No se hicieron optimizaciones de producción durante esta inspección.

## Copias conservadas

- `profiler_last_run_cpu.csv`: barrido del selector de CPU.
- `profiler_last_run_visual.csv`: CPU/GPU Render Viewports del selector visual.
- `profiler_last_run_peak_details.json`: tablas y funciones de los picos.
- `profiler_saved_cpu_graph.png`, `profiler_saved_gpu_graph.png`: texturas de las gráficas conservadas.

El grafo se usó para localizar la ruta y comprobar llamadas. Su cobertura tenía metadatos cambiados y una limitación en la línea 719 del proveedor; esa línea y los rangos implicados se leyeron directamente del código local.
