# Estado de implementación

| Sistema | Estado | Estructural | Runtime | Visual | Rendimiento |
| --- | --- | --- | --- | --- | --- |
| Open Ocean | Production P0 — closed | PASS | PASS | PASS — Eric | P0 BASELINE RECORDED |
| Coastal | Production P1 — closed | PASS | PASS | PASS — Eric | P1 RECORDED |
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

## Resultado de rendimiento P1

Medición temporal ejecutada el 2026-09-03 después del VISUAL PASS de Eric. Mismo protocolo P0: Godot 4.7.1 Forward+ D3D12; ventana física 1920x1080; render scale 1.00; VSync OFF; `Engine.max_fps=0`; cámara fija; warm-up 3.0 s; medición 5.0 s.

| Métrica | P0 baseline | P1 Coastal | Delta P1 − P0 |
| --- | ---: | ---: | ---: |
| Intervalo de frame | 1.154 ms | 1.517 ms | +0.363 ms |
| FPS | 866.6 | 659.1 | -207.5 |
| Incremento de intervalo | — | 31.46% | +31.46 pp |

El coste se expresa por intervalo de frame: `((P1_ms / P0_ms) - 1.0) * 100`. La herramienta de benchmark, fixture temporal, bake temporal y controles de validación se retiraron antes del commit; no quedan dependencias runtime de benchmark ni código debug/performance en el addon.
