# Ocean Production — PERF CHECKPOINT 1

Fecha: 2026-09-09. Auditoría estática del checkout actual, contaje
determinista de geometría y revisión del benchmark existente. No se han
cambiado valores visuales ni se ha hecho commit/push.

## Estado y limitaciones

El checkout ya tenía cambios sin commit antes de esta auditoría en:

- addons/ocean/underwater/ocean_underwater_medium.gd
- validation/fft_cascade_gate.gd
- validation/p0_open_ocean.tscn
- validation/profiles/rough_validation.tres
- varios ficheros nuevos de validación/importación

La herramienta de codebase-memory indicada por AGENTS.md no estaba expuesta en
esta sesión; se hizo el fallback dirigido a rg, lectura de fuentes y análisis
binario del GLB. Godot 4.7/4.7.1 console termina con signal 11 al crear la
ventana/render device, por lo que no se presentan FPS como si fueran medidos.
El chequeo editorial headless termina con exit code 0.

## 1. Arquitectura relevante

    Ocean
     ├─ OpenOceanFFT
     │   ├─ 0..3 OceanGPUStockhamFFT (LONG/MID/SHORT o neutral)
     │   ├─ Texture2DRD displacement/normal/crest por banda
     │   ├─ OceanClipmapSurface (10 MeshInstance3D por defecto)
     │   ├─ OceanSurfaceFoam opcional
     │   └─ OceanSSPR opcional como CompositorEffect
     └─ OceanUnderwaterMedium opcional como CompositorEffect POST_TRANSPARENT

Archivos clave:

- addons/ocean/ocean.gd:304-333: ciclo de vida público.
- addons/ocean/fft/open_ocean_fft.gd:52-127: H0, solvers, texturas y superficie.
- addons/ocean/fft/open_ocean_fft.gd:418-433: actualización por frame.
- addons/ocean/fft/gpu_stockham_fft.gd:48-72,96-123: recursos y dispatch.
- addons/ocean/surface/ocean_clipmap_surface.gd:392-423: niveles de mesh.

## 2. Primitive count de P0

El perfil efectivo es cells_per_side=192, level_count=10,
base_spacing_m=0.25, en addons/ocean/core/ocean_quality_profile.gd:11-28.
El builder está en addons/ocean/surface/ocean_clipmap_mesh_builder.gd:5-39.

| nivel | vértices | triángulos | stitch |
|---:|---:|---:|---:|
| 0 | 37.249 | 73.728 | 0 |
| 1–9, cada uno | 28.608 | 55.680 | 1.152 |
| total | 294.721 | 574.848 | 10.368 |

El GLB actual validation/testisland.glb contiene una malla, una superficie y
625.281 triángulos; no contiene nodos mesh duplicados. La DirectionalLight
mantiene sombras activas en validation/p0_open_ocean.tscn:201-211, mientras el
océano desactiva cast shadow en
addons/ocean/surface/ocean_clipmap_surface.gd:416-421.

La explicación casi exacta de los ~3,7M es:

    clipmap main                         574.848
    isla main                            625.281
    isla en 4 cascadas de shadow pass  2.501.124
                                         ---------
    total teórico                      3.701.253

Por tanto el contador no son 3,7M de triángulos propios del océano. El
desglose esperado es 10 draws del clipmap + 1 de isla en color + 4 de isla en
sombras, antes de pases auxiliares del renderer.

La escena actual no es un P0 mínimo: contiene isla, sombras, Optics,
Reflections, Surface Detail, Underwater y un compositor SSPR explícito en
validation/p0_open_ocean.tscn:74-86,213-244.

## 3. Base FFT

OceanWaveProfile.build_fft_configs() fija resolution=256 para las tres bandas y
dominios [512, 137, 37] en addons/ocean/core/ocean_wave_profile.gd:80-105.

Por cascada 256²:

- 1 dispatch de evolución.
- 16 Stockham: 2 ejes × 8 stages.
- 1 assemble de displacement + normal.
- 18 dispatches base por cascada y frame.
- FULL: 54 dispatches base por frame; ALL OFF: 0 dispatches de solver.

Crest añade 2 dispatches por cascada cada vez que vence su scheduler de 30 Hz
(gpu_stockham_fft.gd:157-185). La memoria de texturas base aproximada por
cascada es 8,5 MiB: H0 1 + seis ping-pong 6 + displacement 1 + normal 0,5.
Las tres bandas son aproximadamente 25,5 MiB, sin overhead de allocator.

## 4. LONG / MID / SHORT

La superficie mantiene siempre los tres bindings y samplea displacement/normal
de las tres bandas en addons/ocean/shaders/ocean_surface.gdshader:201-244.
Una cascada OFF no crea H0/solver y publica una textura neutral 1×1
(open_ocean_fft.gd:71-111,436-488), pero el shader común sigue haciendo el
sample de ese binding.

| estado | solvers | dispatch base | resultado |
|---|---:|---:|---|
| ALL OFF | 0 | 0 | superficie + samples neutrales |
| LONG ONLY | 1 | 18/frame | LONG real |
| LONG+MID | 2 | 36/frame | LONG+MID reales |
| FULL | 3 | 54/frame | tres bandas reales |

Surface Foam depende de MID (open_ocean_fft.gd:284-307). Coastal depende de
LONG para deformar la ola (open_ocean_fft.gd:173-191). Optics puede mantener
el bake Coastal vivo para la autoridad de seabed aunque Coastal waves esté OFF
(ocean.gd:486-489), así que ambas mediciones no son completamente ortogonales.

## 5. Sistemas OFF

| sistema | clasificación | evidencia |
|---|---|---|
| Open Ocean FFT | A | ocean.gd:126-140 hace shutdown del owner, superficie y solvers. |
| Cascada | B | No hay H0/solver/dispatch; quedan draws y samples neutrales. |
| Coastal OFF sin Optics | A | Limpia runtime y deja coastal_enabled=false; no tiene compute propio. |
| Crest Foam | B/C | Libera RIDs/dispatches, pero republish de wrappers cada frame (open_ocean_fft.gd:425,498-503). |
| Surface Foam | A | Libera solver/wrappers y la rama shader queda inactiva (open_ocean_fft.gd:284-332, shader:253-256). |
| Optics | A | Variante base sin screen/depth hints ni compositor/compute propio. |
| Reflections vía Ocean | A | El owner elimina efecto, targets y variante SSPR (open_ocean_fft.gd:376-398). |
| Surface Detail | A | Variante sin inyección de uniforms/muestras de detail. |
| Underwater Medium | A | Retira el efecto y libera RIDs (ocean_underwater_medium.gd:251-273). |
| Sunrays con Medium ON | B/D | Rama dentro del compute P6; no hay dispatch propio, pero el pase P6 sigue. |
| Bubbles con Medium ON | A/B | Se liberan volumen/pipeline Bubble; permanece el compute base P6. |

### Hallazgo SSPR de la escena actual

validation/p0_open_ocean.tscn:74-86 adjunta directamente un OceanSSPREffect con
enabled=true al compositor de la cámara. No lo crea ni lo controla OceanSSPR;
su _active comienza en true (addons/ocean/reflections/ocean_sspr_effect.gd:
52-66,110-148). Puede despachar SSPR aunque Ocean.reflections=false, y con
reflections ON puede duplicar el efecto gestionado por OpenOceanFFT.

A 1920×1080 y escala 0,25, una instancia hace 3 dispatches principales y 8
downsample: 11 dispatches/frame. Es un coste residual innecesario, categoría C,
y una dependencia escena/addon, categoría D. No se parchea en este checkpoint.

## 6. Trabajo redundante sospechoso

1. SSPR de cámara en P0: posible efecto huérfano/duplicado.
2. Crest reescribe Texture2DRD.texture_rd_rid cada frame aun estando OFF o
   estable.
3. Surface Foam reescribe tres wrappers cada frame tras publicar
   (open_ocean_fft.gd:426-433).
4. Underwater Medium llama cada frame a _push_sunray_state() y _push_state()
   aunque el perfil no cambie (ocean_underwater_medium.gd:97-105).
5. P6 hace un camera-state dispatch 1×1, rasteriza los 10 niveles y hace el
   compute de pantalla completa por frame (ocean_underwater_medium_effect.gd:
   484-616).
6. Surface Foam hace 32 dispatches por job: evolve + 18 IFFT + assemble + field
   + topology + 9 mips + MID history, a 30 Hz (ocean_surface_foam.gd:141-219).

## 7. Escalabilidad de resolución

El solver acepta power-of-two mediante OceanFftConfig.is_valid() y
fft_stage_count() (addons/ocean/core/ocean_fft_config.gd:32-46), y usa la
resolución para texturas, grupos y stages (gpu_stockham_fft.gd:59-72,96-120).
El límite actual no es el solver: OceanWaveProfile fuerza 256 para todas.

Internamente no se presupone igualdad de resolución entre cascadas. Deben
revisarse antes de exponerlo: OpenOceanFFT._mid_resolution y Surface Foam,
Crest por banda, fades/aliasing de superficie y sampling de Optics/P6.

Para orientación de coste, N=128 implica 16 dispatches base con grupos 16×16;
N=64 implica 14 dispatches con grupos 8×8. Son capacidades técnicas del
backend, no valores artísticos aprobados para activar ahora.

## 8. Update rate independiente

Hoy OpenOceanFFT._process() despacha todo solver no nulo cada frame
(open_ocean_fft.gd:418-424). Un divisor futuro de bajo riesgo puede saltar el
dispatch completo y conservar displacement/normal anteriores.

Riesgos: stepping de SHORT, sincronización Crest/displacement, normals y
Jacobian con el mismo frame lógico, Surface Foam leyendo MID stale, Coastal
dependiendo de LONG, y cualquier physics/query futura leyendo datos antiguos.
Interpolation requeriría doble salida y coordinación de normal/foam, hoy
inexistente. Es viable como snapshot scheduler, no como cambio trivial.

## 9. Benchmark actual vs. solicitado

La infraestructura existente es reutilizable pero no define todavía este
checkpoint:

- validation/ocean_benchmark.gd:118-168 mide ALL_OFF/LONG/LONG+MID/FULL y
  después una cadena que comienza en BASE con las tres FFT activas.
- Construye otro mundo en validation/ocean_benchmark.gd:60-115, no la escena P0.
- Calcula medianas, pero imprime deltas con gpu_mean
  (validation/ocean_benchmark.gd:247-261).
- No captura primitives/draw calls del workload P0.
- project.godot:20-24 fija 1920×1080; no hay ejecución 1280×800. Render scale
  0,85/0,70 no sustituye cambiar la ventana.

La auditoría histórica de docs/VALIDATION_PERFORMANCE_GAP_AUDIT.md usó frame
wall-clock, no median GPU, y no se usa como resultado de este checkpoint.

## 10. Matriz propuesta

Reutilizar el benchmark existente con un mundo P0 controlado, mismo seed,
cámara y estado en cada gate, warmup 3 s + medida 5 s, median GPU/CPU, p95 GPU,
FPS derivado, primitives/draws si existen y validación de lifecycle.

| gate | definición acumulativa |
|---|---|
| P0 FLOOR | cámara + environment + luz + isla; Ocean ausente |
| P1 STATIC_SURFACE | Ocean/superficie con mask ALL_OFF |
| P2 LONG_ONLY | P1 + LONG |
| P3 LONG_MID | P2 + MID |
| P4 LONG_MID_SHORT | P3 + SHORT |
| P5 + COASTAL | P4 + Coastal waves, Optics OFF |
| P6 + CREST FOAM | P5 + Crest |
| P7 + SURFACE FOAM | P6 + Surface Foam |
| P8 + OPTICS | P7 + Optics; declarar si el bake está presente |
| P9 + REFLECTIONS | P8 + un único SSPR |
| P10 + SURFACE DETAIL | P9 + Detail |

Underwater debe ser una rama emparejada: repetir P10 con cámara underwater
como P10_U, luego P11 Medium y P12 Bubbles+Sunrays. Así no se atribuye el
cambio de cámara al módulo. Ejecutar 1920×1080 y 1280×800; no confundir
resolution scaling con resolución de ventana.

## 11. OceanQualityProfile futuro

El recurso ya existe, pero hoy sólo controla clipmap
(addons/ocean/core/ocean_quality_profile.gd:1-52). La ampliación futura debería
ser un recurso central pasado desde el juego:

    fft: enabled por cascada, resolution por cascada, update_divisor por cascada
    geometry: cells_per_side, level_count, spacing, fades
    coastal, crest_foam, surface_foam, optics, reflections, surface_detail
    underwater: medium, bubbles, sunrays

Los módulos recibirían subconfiguraciones tipadas; el addon no conocería Steam
Deck ni una escena concreta. La resolución validaría power-of-two y el divisor
sería positivo. El perfil debe publicar el estado efectivo para diagnóstico.

## 12. Quick wins y arquitectura recomendada

Propuestas seguras aún no aplicadas:

1. Confirmar y eliminar la autoridad duplicada de SSPR en P0.
2. Añadir contadores de dispatch/lifecycle al benchmark, sin cambiar shaders.
3. Evitar republish de wrappers si el RID no cambió.
4. Usar median GPU/CPU para deltas y guardar metadata de resolución.
5. Separar isla color y shadow passes en la captura de geometría.

Arquitectónicamente, mantener un único owner de cada compositor, estados
requested/runtime_active/resources_ready/dispatch_count, y un scheduler por
cascada sólo después de fijar la semántica temporal.

## 13. Ahora vs. PERF CHECKPOINT 2

### Ahora

1. Confirmar la autoridad única de SSPR en P0.
2. Congelar una escena benchmark limpia y separada de la referencia visual.
3. Instrumentar dispatches, lifecycle, primitives y draw calls.
4. Ejecutar runtime en una máquina con RenderDevice funcional y guardar
   medianas/p95/configuración.
5. Repetir la auditoría OFF después de instrumentar.

### Checkpoint 2

- escoger resoluciones por cascada con datos;
- implementar y validar update divisor;
- introducir OceanQualityProfile central si la matriz lo justifica;
- decidir si separar variantes de Sunrays/Medium;
- optimizar geometría sólo después de confirmar el impacto real de sombras.

## Conclusión

La separación de ownership es razonable: la mayoría de los sistemas OFF libera
recursos y evita sus dispatches. Todavía no puede afirmarse que la arquitectura
escala correctamente porque la escena P0 contiene un SSPR fuera del owner, la
matriz existente no coincide con los gates pedidos y falta la medición GPU
reproducible.

Los ~3,7M no parecen desperdicio del clipmap: quedan explicados casi
exactamente por la isla en color y cuatro sombras, más 574.848 triángulos del
océano. El siguiente paso correcto es instrumentar y medir la base limpia, no
bajar calidad ni cambiar la apariencia PC.
