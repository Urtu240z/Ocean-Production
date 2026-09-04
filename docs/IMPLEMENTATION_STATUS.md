# Estado de implementación

| Sistema | Estado | Estructural | Runtime | Visual | Rendimiento |
| --- | --- | --- | --- | --- | --- |
| Open Ocean | Production P0 — closed | PASS | PASS | PASS — Eric | P0 BASELINE RECORDED |
| Coastal | Production P1 — closed | PASS | PASS | PASS — Eric | P1 RECORDED |
| Crest Foam | Production P2 V3 Core — closed | PASS | PASS | PASS — Eric | P2 RECORDED |
| Surface Foam + Crest Filigree | Production P3 — closed | PASS | PASS | PASS — Eric | P3 MARGINAL RECORDED |
| Water Optics / Refraction | Production P4 — closed | PASS | PASS | PASS — Eric | PASS — measured |
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

## Resultado de rendimiento P3

Benchmark marginal oficial ejecutado el 2026-09-04 en la misma sesión/escena/cámara/seed/estado, con Crest Foam ON en ambos estados, Coastal OFF, 1920x1080, render scale 1.00, VSync OFF, `Engine.max_fps=0`, warmup 3.0 s y medición 5.0 s por estado. La métrica es wall-clock frame interval entre callbacks de frame, no GPU time.

| Run | Surface Foam OFF | Surface Foam ON |
| --- | ---: | ---: |
| 1 | 2.527 ms / 395.7 FPS | 3.193 ms / 313.2 FPS |
| 2 | 2.754 ms / 363.1 FPS | 3.181 ms / 314.4 FPS |
| 3 | 2.575 ms / 388.3 FPS | 3.291 ms / 303.9 FPS |
| Promedio | 2.619 ms / 381.8 FPS | 3.221 ms / 310.4 FPS |

| Delta P3 ON − OFF | Valor |
| --- | ---: |
| Delta absoluto de frame interval | +0.602 ms |
| Delta FPS | -71.4 FPS |
| Incremento porcentual de frame interval | +23.00 % |
| Spread aproximado | OFF 0.227 ms; ON 0.110 ms |

P0/P1/P2 históricos no se usan para calcular este coste. El benchmark fue efímero y se eliminó; `validation/free_camera.gd`, `validation/free_camera.tscn`, `validation/profiles/` y `validation/environment/` permanecen.

## Auditoría del gap de validation

Una auditoría temporal A/B del workload de `validation` midió el mismo Ocean con Surface Foam OFF en ambos estados: P2-light `1.316 ms` frente al Environment actual `2.663 ms`, delta `+1.348 ms`. Esto explica `98.7 %` del gap histórico de `+1.366 ms` y deja `0.018 ms` sin explicar. Las ablations individuales señalaron como mayores reducciones Auto Exposure OFF (`-0.456 ms`), SSAO+SSIL OFF (`-0.392 ms`), Shadows OFF (`-0.295 ms`) y Glow OFF (`-0.283 ms`); no son aditivas. Detalle y teardown documentados en [`VALIDATION_PERFORMANCE_GAP_AUDIT.md`](VALIDATION_PERFORMANCE_GAP_AUDIT.md). Esta auditoría no modifica el coste marginal oficial P3 de `+0.602 ms`.

## Resultado de rendimiento P4

Benchmark marginal oficial ejecutado el 2026-09-04 en entorno ligero tipo P2, con la misma escena/sesión/cámara/seed/estado, Crest Foam ON, Surface Foam ON y Coastal OFF. Optics OFF promedió `1.593 ms / 627.7 FPS`; Optics ON `2.054 ms / 486.9 FPS`; delta `+0.461 ms` y `+28.92 %` de intervalo medio. La métrica es wall-clock frame interval, no GPU time. La variante base OFF no contiene screen/depth hints y la variante ON sí los contiene. Detalle de runs, spread y condiciones en [`docs/phases/P4_OPTICS_REFRACTION.md`](phases/P4_OPTICS_REFRACTION.md). El benchmark fue efímero y no modifica el coste oficial P3 de `+0.602 ms`.
# P5 — Reflections / SSPR

Structural and runtime validation are implemented. Visual review and performance
assessment remain pending.
