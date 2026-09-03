# Estado de implementación

| Sistema | Estado | Estructural | Runtime | Visual | Rendimiento |
| --- | --- | --- | --- | --- | --- |
| Open Ocean | Production P0 — closed | PASS | PASS | PASS — Eric | P0 BASELINE RECORDED |
| Coastal | Production P1 — closed | PASS | PASS | PASS — Eric | P1 RECORDED |
| Crest Foam | Production P2 V3 Core — closed | PASS | PASS | PASS — Eric | P2 RECORDED |
| Surface Foam + Crest Filigree | Production P3 — ready for visual review | PASS | PASS — Forward+ D3D12 lifecycle | PENDING — Eric | PENDING |
| Breakers | Not promoted | - | - | - | - |
| Reflections | Not promoted | - | - | - | - |
| Underwater | Not promoted | - | - | - | - |
| Caustics | Not promoted | - | - | - | - |
| Sunrays | Not promoted | - | - | - | - |
| OceanQuery Native | Not promoted | - | - | - | - |
| Sediment | LAB ONLY | - | - | - | - |

El VISUAL PASS de Open Ocean P0 fue concedido manualmente por Eric. Un estado de rendimiento exige una medición real.

## Baseline de rendimiento P0

Medición temporal ejecutada el 2026-09-03 sobre `validation/p0_open_ocean.tscn`. La herramienta de benchmark se retiró al terminar la medición; la infraestructura de inspección manual de `validation/` permanece disponible para las fases siguientes.

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

El ms registrado es el intervalo medio de frame por reloj de pared; no es un tiempo GPU. Este es el baseline de comparación obligatorio para P1 y fases posteriores. El benchmark es efímero; la free camera y otras herramientas reutilizables de inspección pertenecen temporalmente a `validation/`.

## Resultado de rendimiento P1

Medición temporal ejecutada el 2026-09-03 después del VISUAL PASS de Eric. Mismo protocolo P0: Godot 4.7.1 Forward+ D3D12; ventana física 1920x1080; render scale 1.00; VSync OFF; `Engine.max_fps=0`; cámara fija; warm-up 3.0 s; medición 5.0 s.

| Métrica | P0 baseline | P1 Coastal | Delta P1 − P0 |
| --- | ---: | ---: | ---: |
| Intervalo de frame | 1.154 ms | 1.517 ms | +0.363 ms |
| FPS | 866.6 | 659.1 | -207.5 |
| Incremento de intervalo | — | 31.46% | +31.46 pp |

El coste se expresa por intervalo de frame: `((P1_ms / P0_ms) - 1.0) * 100`. La herramienta de benchmark, el fixture temporal y el bake temporal se retiraron al cerrar la medición. La infraestructura reutilizable de validación puede permanecer en `validation/`; no quedan dependencias runtime de benchmark ni código debug/performance en el addon.

## Resultado de rendimiento P2

Medición temporal oficial ejecutada el 2026-09-03 con el mismo protocolo P0/P1: 1920x1080, render scale 1.00, VSync OFF, `Engine.max_fps=0`, cámara fija, warmup 3.0 s y medición 5.0 s.

| Fase | Average frame ms | Average FPS |
| --- | ---: | ---: |
| P0 Open Ocean | 1.154 | 866.6 |
| P1 + Coastal | 1.517 | 659.1 |
| P2 + Crest Foam | 1.253 | 798.2 |

Resultado: `OCEAN PERF | P2 UNCAPPED | avg 1.253 ms | 798.2 FPS | 1920x1080 | scale 1.00`.

P1 y P2 no son comparables como delta marginal: P1 llevaba workload Coastal; P2 se midió en `validation/p0_open_ocean.tscn` sin Coastal bake. Los dos resultados son válidos para sus respectivas escenas, pero no existe un delta directo de Crest Foam frente a P1.

### INDICATIVE CROSS-RUN COMPARISON

P2 Open Ocean + Crest Core frente a P0 Open Ocean: `+0.099 ms`, aproximadamente `+8.58 %` de frame interval. Es una referencia acumulada, no un benchmark A/B ni coste marginal oficial: no se midieron ON/OFF en la misma sesión y la métrica es wall-clock, sensible a ruido de sistema, temperatura y scheduling.

Desde P3 el coste marginal oficial exige misma escena, sesión, cámara y estado, midiendo pares cercanos OFF/ON. Fórmulas: `delta_ms = ON_ms - OFF_ms`; `delta_percent = ((ON_ms / OFF_ms) - 1.0) * 100`.

P3 debe recibir Visual PASS antes de cualquier benchmark A/B. No se ha registrado un resultado de rendimiento P3.
