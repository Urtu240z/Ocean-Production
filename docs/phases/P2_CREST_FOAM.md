# P2 — Crest V3 Core

## Objetivo y autoridad

P2 promueve el núcleo final Crest Foam V3 Core del Ocean V3 activo: `lab/lab_main.tscn`, preset ROUGH efectivo y `ocean_v3/`. No utiliza la ruta height+slope ni la interpretación V4. Eric concedió el pase visual manual de P2.

## Señal física persistente

Cada cascada conserva un acumulador temporal RG16F con canales fresh y residual. El compute recibe la Jacobiana actual, el desplazamiento anterior y el estado anterior:

```
source_i = max(0, whitecap_i - Jacobian_i)
fresh_i  -> source_i * cascade_weight
residual_i = decay(residual_i) + deposit(fresh_i) + advection
```

Los valores ROUGH efectivos son:

| Cascada | Whitecap | Amount | Decay | Weight |
| --- | ---: | ---: | ---: | ---: |
| LONG | 0.62 | 1.60 | 4.50 | 1.00 |
| MID | 0.66 | 0.42 | 4.50 | 0.65 |
| SHORT | 0.68 | 0.22 | 4.50 | 0.10 |

La presentación visible usa residual porque el preset efectivo fija `foam_fresh_strength = 0.0`.

## Composición y material

LONG es la señal principal. MID aporta `MID * 0.35 * 0.55`; SHORT aporta `SHORT * 0.35 * 0.30`; se combinan mediante unión complementaria. Después se aplica `smoothstep(0, 1, raw)`, `pow(..., 1 / 1.19)`, intensidad 0.96, breakup procedural V3 (fuerza 0.45, tamaño 14 m, edge 0.32) y fade 0–5000 m.

El material residual usa el color HDR efectivo V3, roughness 0.88 y specular 0.18. El export huérfano V3 `foam_roughness = 0.27` no se promueve porque no alimenta el shader aprobado.

## Recursos y ownership

Cuando Crest está activo, cada `OceanGPUStockhamFFT` posee y libera su snapshot RG16F de desplazamiento, dos acumuladores RG16F ping-pong, sampler, uniform sets, shader y pipeline Crest. `OpenOceanFFT` sólo publica el RID actual mediante `Texture2DRD`; `OceanClipmapSurface` consume esas tres texturas y el recurso procedural `crest_breakup_noise.tres` sin crear RIDs Crest.

`Crest Foam = OFF` libera los recursos Crest por solver y omite sus dispatches y mezcla de superficie. No altera desplazamiento, normales, mallas ni las FFT base de P0.

## Coastal y límite P3

La promoción conserva la integración Coastal de P1 sin reabrirla ni introducir el split LONG_COASTAL + LONG_REMAINDER de V3. La señal aprobada concentra espuma en crestas, conserva persistencia/advección, aplica breakup y fade lejano correctamente.

P2 no incluye Surface Foam mask/field, FFT auxiliar, topología Direct-J, historia MID, render o eligibility de Surface Foam. Crest Filigree queda explícitamente pendiente para P3 porque depende de Direct-J / Surface Foam topology.

## Validación y estado

Godot 4.7.1 abre y ejecuta Production limpiamente. La escena de revisión `validation/p0_open_ocean.tscn` fija `simulation_seed = 20260820` para acercar el patrón a V3 sin cambiar el default del addon. Se validó `Crest Foam OFF -> ON -> OFF -> ON` sin errores de shader, RenderingDevice, RIDs inválidos ni double free. Crest OFF no modifica geometría ni movimiento. Los archivos `validation/free_camera.gd` y `validation/free_camera.tscn` compartidos no fueron modificados.

Structural: PASS.
Runtime: PASS.
Visual: PASS — Eric.

## PERFORMANCE

Medición temporal oficial ejecutada el 2026-09-03 sobre `validation/p0_open_ocean.tscn` con Crest Foam ON. El benchmark se eliminó antes del commit.

| Campo | Valor |
| --- | --- |
| Hardware | Intel Core i7-13650HX; NVIDIA GeForce RTX 4070 Laptop GPU, driver 610.62, 8188 MiB |
| Godot / renderer | Godot 4.7.stable; Forward+; D3D12 |
| Resolución | 1920x1080 real de ventana |
| Render scale | 1.00 real del viewport 3D |
| VSync | OFF |
| FPS cap | OFF; `Engine.max_fps=0` |
| Cámara | `FreeCamera` congelada para la medición; `current=true`, posición `(0, 8, 16)`, orientación fija por el transform de la escena, FOV 70°, far 8000; sin movimiento ni input |
| Warmup | 3.0 s |
| Measurement | 5.0 s |
| Métrica | Intervalo medio de frame por reloj de pared entre callbacks de `_process`, usando `Time.get_ticks_usec`; no es GPU ms |

| Fase | Average frame ms | Average FPS |
| --- | ---: | ---: |
| P0 Open Ocean | 1.154 | 866.6 |
| P1 + Coastal | 1.517 | 659.1 |
| P2 + Crest Foam | 1.253 | 798.2 |

Resultado: `OCEAN PERF | P2 UNCAPPED | avg 1.253 ms | 798.2 FPS | 1920x1080 | scale 1.00`.

P1 y P2 no son comparables como delta marginal: P1 se midió con workload Coastal y P2 en `validation/p0_open_ocean.tscn`, sin Coastal bake activo. Por tanto no existe un dato válido de “Crest Foam frente a P1” ni se interpreta P2 como una aceleración.

### INDICATIVE CROSS-RUN COMPARISON

Como referencia acumulada —no benchmark A/B— P2 Open Ocean + Crest Core frente a P0 Open Ocean da aproximadamente `+0.099 ms` y `+8.58 %` de frame interval. No es un coste marginal oficial: no hubo OFF/ON en la misma sesión, y esta métrica wall-clock a estos FPS incorpora ruido de sistema, temperatura y scheduling.

Desde P3, el coste marginal oficial se mide en la misma escena, sesión, cámara y estado: `delta_ms = ON_ms - OFF_ms` y `delta_percent = ((ON_ms / OFF_ms) - 1.0) * 100`.

## P3 pendiente

Crest Filigree: PENDING P3 porque depende de Direct-J / Surface Foam topology.
