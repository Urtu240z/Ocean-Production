# P2 — Crest V3 Core

## Objetivo y autoridad

P2 promueve el núcleo de Crest Foam del Ocean V3 activo: `lab/lab_main.tscn`, preset ROUGH efectivo y `ocean_v3/`. No utiliza la ruta height+slope ni la interpretación V4. El resultado pendiente de revisión es Crest V3 antes del Crest Filigree que depende de la topología Direct-J de Surface Foam.

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

La primera promoción prioriza paridad Crest en open ocean. Usa la mejor Jacobiana disponible del LONG Coastal actual, sin reabrir P1 ni introducir el split LONG_COASTAL + LONG_REMAINDER de V3. Por ello la paridad exacta cerca de costa queda por comprobar tras la revisión visual; no se modifica P1 sin autorización.

P2 no incluye Surface Foam mask/field, FFT auxiliar, topología Direct-J, historia MID, render o eligibility de Surface Foam. En particular, Crest Filigree dependiente de esa topología queda explícitamente pendiente para P3. El Crest final V3 no se declara todavía exacto.

## Validación y estado

Godot 4.7.1 abre y ejecuta Production limpiamente. La escena de revisión `validation/p0_open_ocean.tscn` fija temporalmente `simulation_seed = 20260820` para acercar el patrón a V3 sin cambiar el default del addon. En una instancia efímera de esa escena se validó `Crest Foam OFF -> ON -> OFF -> ON` sin errores de RenderingDevice, RIDs inválidos ni double free. Los archivos de free camera compartidos no fueron modificados.

VISUAL PASS: PENDING ERIC.

P1 es el baseline actual: 1.517 ms y 659.1 FPS. P2 performance permanece PENDING hasta VISUAL PASS; no se ejecutó benchmark. Commit y push permanecen PENDING.
