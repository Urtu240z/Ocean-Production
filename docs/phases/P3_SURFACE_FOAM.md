# P3 — Surface Foam V3

Estado: **READY FOR VISUAL REVIEW**. Rendimiento: **PENDING**. La única autoridad de esta fase es el resultado efectivo ROUGH de `lab/lab_main.tscn` y `ocean_v3/`. La ruta experimental que reutilizaba Main FFT SHORT se descarta explícitamente: Production sólo usa el solver auxiliar J-only independiente.

## Arquitectura y espacios

`OceanSurfaceFoam` es el único propietario P3 y vive bajo `OpenOceanFFT`. Crea H0, ping-pong espectral, Jacobianos, field/history, Direct-J topology y MID history en el hilo de render; `OceanClipmapSurface` sólo recibe `Texture2DRD` y presenta el resultado. No hay controlador, selector de fuente, diagnóstico ni fallback histórico.

| Espacio | Recurso | Resolución/formato | Dominio |
| --- | --- | --- | --- |
| Source | auxiliar espectral J-only | 512, RGBA32F temporal / R16F J | 14.5 m |
| Topology | Direct-J, R Surface / G Crest Filigree | 512, RG16F con 10 mips | 14.5 m |
| Field | historia persistente de Surface Foam | 1024, RG16F ping-pong | 88 m |
| World | shader de superficie | coordenadas XZ | muestrea Source/Topology a 14.5 m y Field a 88 m |

La transformación es `world_xz / domain_m + 0.5`. El field no sustituye la silueta: sólo estabiliza el macro Direct-J. El update de field deperiodiza dos consultas Source dentro de 88 m; el topology continúa siendo Direct-J de 14.5 m y usa sus mips para la distancia.

## Solver, field e historia

El auxiliar genera sólo derivadas necesarias para J. Empaqueta los diagonales en un transformado complejo y hace **un IFFT auxiliar de 512²**, compuesto por 9 butterfly passes X y 9 Y (18 dispatches). Tras assemble genera J, actualiza field ping-pong con birth, persistence/advection implícita por backtrace de fuente deperiodizada, attack 0.16 s, lifetime 1.10 s, selectivity 0.28, decay/release y cadence 30 Hz.

Los valores ROUGH efectivos son: whitecap Surface 0.58, amount/source gain 8.573 (ganancia V3 2.05), evolution speed 0.59, source 14.5 m, field 88 m, threshold visual 0.11 y strength 2.52. El espectro auxiliar conserva los valores efectivos V3: profundidad 20 m, viento 10 m/s a 110°, fetch 6000 m, swell 0.779 y directional spread 0.11.

MID eligibility tiene una historia R16F ping-pong propia y consume exclusivamente el Jacobiano empaquetado en `displacement_mid.a`; con los overrides efectivos usa fold start 0.0 y end 1.0. La máscara final sólo aparece donde esa elegibilidad permite el Surface Foam.

## Topology, shaping y PBR

Cada actualización escribe Topology Direct-J y genera 9 downsample passes; R usa whitecap 0.58 y G usa whitecap Filigree 0.40. La macro usa Direct-J con factor V3 2.05 y el envelope temporal; la micro textura queda desactivada en el ROUGH efectivo. Edge shaping conserva edge strength 0.35 y width 0.14. El fade Surface efectivo es 200–600 m. PBR: color `(0.8954583, 0.9249786, 0.9149783)`, roughness 0.82 y specular 0.37.

Crest Filigree consume el canal G del mismo topology: whitecap 0.40, fresh strength 0.50, residual strength 0.62, contraste 1.0 y threshold 0.0. Sólo erosiona la máscara Crest P2 existente: no crea foam fuera de su soporte físico. Surface y Filigree no duplican recursos.

## OFF semantics e interacción

`Ocean > Systems > Surface Foam` activa o libera el módulo completo. OFF libera H0, work maps, Jacobianos, topology/mips/views, field/history, MID history, samplers, buffers, pipelines y uniform sets; no ejecuta dispatches auxiliares, topology, mipmaps ni presentación/Filigree. Crest Foam V3 Core P2 continúa activo y con su comportamiento aprobado. Alternar Surface no modifica geometría ni LONG/MID/SHORT.

Coastal P1 sigue limitado a LONG. P3 no lee ni modifica Coastal: el Surface Foam se presenta en world space sobre la geometría ya deformada y sus recursos no cambian al activar Coastal.

## Límites de modificación

- **SAFE TO MODIFY:** `Ocean.surface_foam` y documentación/escena de validación.
- **MODIFY WITH CARE:** parámetros V3 en el shader de superficie y `OceanSurfaceFoam`; exigen nueva revisión visual.
- **INTERNAL / DO NOT TOUCH NORMALLY:** layout J-only, conteo 18 butterfly, formatos, bindings, ping-pong, mip views y orden de liberación de RIDs.

No incluye breakers, wake/boat/shoreline extra, SSPR, óptica avanzada, underwater, caustics, sunrays, sediment ni OceanQuery.

## Validación manual

Abrir `res://validation/p0_open_ocean.tscn` (semilla 20260820) y alternar **Ocean → Systems → Surface Foam** en el Inspector. Revisar zonas, persistencia, advección, decay, ausencia de flicker/swimming, macro/edge, PBR, filigree, y las cuatro combinaciones Crest/Surface. Reabrir la escena y hacer OFF → ON → OFF → ON. No se ejecutó benchmark: después del Visual Pass se medirá A/B en la misma sesión.

La comprobación runtime Forward+ D3D12 se ejecutó sin errores de `RenderingDevice`, shader, RID, uniform set ni doble liberación. Cubrió Surface OFF → ON → OFF → ON y Crest/Surface `(ON, ON)`, `(ON, OFF)`, `(OFF, ON)` y `(OFF, OFF)`. La revisión visual manual y el benchmark siguen pendientes.
