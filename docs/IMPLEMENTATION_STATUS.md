# Estado de implementación

| Sistema | Estado | Estructural | Runtime | Visual | Rendimiento |
| --- | --- | --- | --- | --- | --- |
| Open Ocean | Production P0 — closed | PASS | PASS | PASS — Eric | P0 BASELINE RECORDED |
| Coastal | Not promoted | - | - | - | - |
| Crest Foam | Not promoted | - | - | - | - |
| Surface Foam | Not promoted | - | - | - | - |
| Breakers | Not promoted | - | - | - | - |
| Reflections | Not promoted | - | - | - | - |
| Underwater | Not promoted | - | - | - | - |
| Caustics | Not promoted | - | - | - | - |
| Sunrays | Not promoted | - | - | - | - |
| OceanQuery Native | Not promoted | - | - | - | - |
| Sediment | LAB ONLY | - | - | - | - |

El VISUAL PASS de Open Ocean P0 fue concedido manualmente por Eric. Un estado de rendimiento exige una medición real.

## Baseline de rendimiento P0

Medición temporal ejecutada el 2026-09-03 sobre `validation/p0_open_ocean.tscn`, antes de retirar completamente la herramienta de medición del proyecto.

| Campo | Valor |
| --- | --- |
| Hardware | Intel i7-13650HX; RTX 4070 Laptop GPU |
| Motor / renderer | Godot 4.7.1; Forward+; D3D12 |
| Cámara | Fija; sin movimiento ni input |
| Resolución | 1920x1080 |
| Render scale | 1.00 |
| Warmup / medición | 3.0 s / 5.0 s |
| Protocolo | VSync OFF; `Engine.max_fps=0`; sin cambios persistentes |
| Resultado oficial | 1.154 ms por intervalo medio de frame; 866.6 FPS |

El ms registrado es el intervalo medio de frame por reloj de pared; no es un tiempo GPU. Este es el baseline de comparación obligatorio para P1 y fases posteriores. La infraestructura de benchmark fue temporal y ya no existe en Production.
