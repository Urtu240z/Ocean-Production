# P2 — Crest Foam

## Objetivo

Promover únicamente la ruta ganadora de Crest Foam: espuma directa de cresta, sin simulación ni estado persistente. LONG determina el soporte; MID aporta variación de densidad; SHORT no puede activarla por sí solo.

## Procedencia y ruta promovida

La implementación procede de la ruta directa final aprobada de Legacy. Conserva sus rangos de altura, pendiente, detalle MID, distancia, borde/core, densidad mínima, fuerza y mezcla PBR. Se descartaron las variantes históricas de triggering discontinuo, A/B, vistas debug, laboratorios visuales, benchmarks y cualquier ruta de Surface Foam.

## Arquitectura y flujo

`Ocean` expone únicamente `Crest Foam`. `OpenOceanFFT` reenvía el estado a `OceanClipmapSurface`; la superficie activa una rama del shader existente. En vertex, altura y pendiente LONG forman el trigger físico. MID calcula sólo detalle de densidad; el suelo de densidad evita que MID corte por completo una cresta LONG. SHORT no entra ni en trigger ni en modulación. En fragment, el trigger interpolado recibe shaping edge/core y antialiasing por derivadas antes de mezclar color, roughness y specular de espuma.

No hay recursos propios: no se crean texturas, RIDs, compute, dispatches, targets, history ni nodos. OFF elimina el trabajo específico separable de Crest Foam; los tres solvers FFT requeridos por el océano continúan sin duplicarse.

## Coastal

Crest Foam usa el muestreo LONG que ya aplica Coastal cuando está activo. No requiere bake ni estado Coastal, y funciona con Coastal OFF, con Coastal ON sin bake válido y con Coastal ON más bake válido.

## Uso

`Crest Foam = ON` aplica espuma en crestas con soporte LONG. `OFF` omite trigger, modulación y mezcla PBR de espuma sin alterar desplazamiento, normales ni movimiento de las olas.

### SAFE TO MODIFY

El booleano `Crest Foam`.

### MODIFY WITH CARE

Los valores internos aprobados de Crest Foam: cambian cobertura, continuidad y aspecto PBR.

### INTERNAL / DO NOT TOUCH NORMALLY

Trigger LONG, suelo de densidad MID, shaping edge/core y antialiasing de la máscara.

## Limitaciones

P2 no incluye Surface Foam, espuma de shoreline, wakes, barcos, breakers ni persistencia temporal. La revisión visual debe comprobar continuidad de crestas, estabilidad por distancia y que SHORT no active espuma por sí solo.

## Validación

Godot 4.7.1 carga la escena de validación sin errores. Se validó Crest Foam OFF→ON→OFF→ON y Coastal ON/OFF combinado con Crest Foam ON/OFF sin RIDs inválidos, double free ni errores de RenderingDevice. La escena reutiliza la infraestructura de free camera de `validation/` aportada por otro agente y no modificada por P2.

VISUAL PASS: PENDING ERIC.

## Performance y commit

P1 es el baseline actual: 1.517 ms y 659.1 FPS. P2 performance permanece PENDING hasta VISUAL PASS; no se ejecutó benchmark. Commit y push permanecen PENDING.
