# P1 — Coastal Runtime

## Objetivo

Consumir un Coastal Bake externo ya horneado y aplicar propagación, shoaling y warp sólo a LONG. MID y SHORT conservan P0.

## Promoción y descarte

Se promovió el contrato runtime de bake, propagación y warp. Se descartaron bakers, authoring, previews, diagnósticos, A/B, HUD, controles de Lab, Breakers, OceanQuery, foam y cualquier benchmark persistente.

## Arquitectura y ownership

`Ocean` expone `Coastal` y `Coastal Bake`. `OpenOceanFFT` posee `OceanCoastalRuntime`; éste mantiene referencias al bake válido y a las texturas `ImageTexture` construidas por sus datos. `OceanClipmapSurface` sólo recibe uniforms y no posee RIDs Coastal. OFF, cambio de bake o shutdown limpian primero la superficie y después las referencias del runtime. No hay compute Coastal ni recursos Coastal cuando está OFF.

El addon no contiene ningún mapa concreto. El fixture y bake externos usados para la revisión visual fueron temporales y se retiraron al cerrar P1.

## Uso

Con `Coastal = ON` y un bake válido, LONG usa propagación/warp dentro del área horneada. Sin bake válido, Coastal queda inactivo y P0 continúa. OFF elimina el efecto y las referencias de datos Coastal.

### SAFE TO MODIFY

`Coastal` y `Coastal Bake`.

### MODIFY WITH CARE

El contenido del Coastal Bake: altera la costa completa y debe proceder de un bake validado.

### INTERNAL / DO NOT TOUCH NORMALLY

Uniforms Coastal, formato de datos, muestreo de warp y ownership de texturas.

## Validación

Godot 4.7.1 cargó el fixture externo autorizado sin errores. La geometría temporal conservó el transform, escala, orientación y origen de su fuente; el bake permaneció sin modificar. La transición OFF→ON→OFF→ON y la retirada/restauración del bake se validaron en runtime; cierres y reaperturas no produjeron RIDs inválidos. Eric concedió el VISUAL PASS: LONG responde a la costa con shoaling y warp direccional, mientras MID y SHORT conservan P0.

## Performance

La medición se ejecutó después del VISUAL PASS mediante herramienta efímera eliminada antes del cierre. Protocolo: Godot 4.7.1 Forward+ D3D12, RTX 4070 Laptop GPU, ventana física 1920×1080, render scale 1.00, VSync OFF, `Engine.max_fps=0`, cámara fija, warm-up de 3.0 s y medición de 5.0 s. La métrica es intervalo medio de frame por reloj de pared; no es tiempo GPU.

| Métrica | P0 baseline | P1 Coastal | Delta P1 − P0 |
| --- | ---: | ---: | ---: |
| Frame interval | 1.154 ms | 1.517 ms | +0.363 ms |
| FPS | 866.6 | 659.1 | -207.5 |

Incremento de frame interval: `((1.517 / 1.154) - 1.0) * 100 = 31.46%`.

## Cierre

Fixture, geometría, bake, controles temporales y herramienta de benchmark: eliminados. No existen dependencias runtime de benchmark ni código debug/performance en el addon. P1 queda cerrado; P2 no se inicia en este cambio.
