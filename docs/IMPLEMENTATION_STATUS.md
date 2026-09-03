# Estado de implementación

| Sistema | Estado | Estructural | Visual | Rendimiento |
| --- | --- | --- | --- | --- |
| Open Ocean | Production P0 | PASS | PENDING ERIC | P0 BASELINE RECORDED |
| Coastal | Not promoted | - | - | - |
| Crest Foam | Not promoted | - | - | - |
| Surface Foam | Not promoted | - | - | - |
| Breakers | Not promoted | - | - | - |
| Reflections | Not promoted | - | - | - |
| Underwater | Not promoted | - | - | - |
| Caustics | Not promoted | - | - | - |
| Sunrays | Not promoted | - | - | - |
| OceanQuery Native | Not promoted | - | - | - |
| Sediment | LAB ONLY | - | - | - |

`PASS` visual sólo puede concederlo Eric. Un estado de rendimiento exige una medición real.

## Baseline de rendimiento P0

Medición temporal ejecutada el 2026-09-03 sobre `validation/p0_open_ocean.tscn`, antes de retirar completamente la herramienta de medición del proyecto.

| Campo | Valor |
| --- | --- |
| Hardware | Intel Core i7-13650HX; NVIDIA GeForce RTX 4070 Laptop GPU, driver 610.62, 8188 MiB |
| Motor / renderer | Godot 4.7.stable; Forward+; D3D12 |
| Cámara | Fija; sin movimiento ni input |
| Resolución | 1920x1080 |
| Render scale | 1.00 |
| Warmup / medición | 3.0 s / 5.0 s |
| Estado efectivo previo | VSync ON; `Engine.max_fps=0`; sin cap de escena; sin setting permanente de cap en `project.godot` |
| Configuración temporal | VSync OFF; `Engine.max_fps=0`; ventana runtime 1920x1080; sin cambios persistentes |
| Resultado uncapped | `OCEAN PERF | P0 UNCAPPED | avg 1.154 ms | 866.6 FPS | 1920x1080 | scale 1.00` |

El ms registrado es el intervalo medio de frame por reloj de pared entre callbacks de frame; no es un tiempo GPU. La ejecución anterior (`6.060 ms / 165.0 FPS`) queda excluida del baseline por VSync activo. No se declara comparación ni mejora frente a Legacy porque no existe una medición equivalente bajo las mismas condiciones.
