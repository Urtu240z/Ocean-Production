# P5.5 — Surface Detail V3

## Autoridad y alcance

La autoridad es la implementación activa `ocean_v3` del Legacy Lab, auditada en
`ocean_v3.gd`, `ocean_v3.tscn`, `rendering/ocean_clipmap_surface.gd`,
`rendering/shaders/ocean_surface.gdshader`, `rendering/surface_detail/` y
`lab/lab_main.tscn`. P5.5 es fragment shading: no modifica FFT, displacement,
geometría, OceanQuery, Coastal, Crest Foam, Surface Foam ni el algoritmo SSPR.

Los recursos V3 promovidos, autocontenidos bajo el addon, son
`surface_normal_a.tres`, `surface_normal_b.tres` y `surface_warp_noise.tres`.
Son `NoiseTexture2D` procedurales: A/B son normales seamless 3D con
`as_normal_map`; el warp es seamless 256². No hay rutas Lab ni assets externos.

## Valores activos V3

`lab_main.tscn` sobrescribe `wave_follow = 1.0`, tamaños A/B `34.15 m` y
`2.4 m`, strength `1.18`, warp `14.5 m` y strength `1.15`. Los valores no
sobrescritos heredan V3: direcciones `(0.82, 0.57)` / `(-0.46, 0.89)`, speeds
`0.24` / `-0.17`, fade `180–800 m`, far strength `0.18` y calidad `2`.

## Sampling y espacios

El carrier es mundo y clipmap-independent:
`mix(final_displaced_world_xz, ocean_base_xz, wave_follow)`. La variante P5.5
publica la posición final desde vertex únicamente para ese carrier; no desplaza
ningún vértice adicional. El reloj `ocean_time_s` conserva la evolución V3 sin
acoplar semánticamente el detalle al sistema Coastal.

En calidad 2 el shader hace una muestra de warp y dos de normal. El warp usa la
trayectoria V3 `(0.31, -0.95) * time * 0.035`; A usa `carrier + warp` y B
`carrier - warp * 0.57`. Las direcciones se normalizan con los fallbacks V3.
Las normales se decodifican de `[0,1]` a `[-1,1]` y se componen exactamente con
pesos XY/Z `0.58/0.42`, piso Z `0.08`, normalización, fade a distancia y
conversión de slope world XZ a view space. La normal final de Godot sigue siendo
`NORMAL` en view space.

## Integración

La normal FFT LONG/MID/SHORT conserva autoridad física/macro. P5.5 se añade sólo
a su normal visual para PBR/Fresnel. P4 reutiliza el mismo `surface_detail_offset_view`
en la normal de refracción, con `refraction_micro_normal_strength`; no añade
screen/depth reads. P5 conserva de forma intencionada la normal macro FFT para
la distorsión/ray de SSPR, igual que V3: el detalle mejora el PBR subyacente pero
no cambia Project/Resolve/Temporal, targets ni history de SSPR.

P2/P3 siguen siendo autoridad de máscara, color, roughness y specular. Production
no posee los buffers de micro-normal de foam del shader V3 monolítico; por eso
P5.5 no inventa ni promueve una nueva ruta de foam. Sus máscaras y solvers quedan
inalterados y el detalle se compone antes de sus mezclas PBR aprobadas.

## Runtime, variantes y perfiles

`OceanSurfaceDetailProfile` es un Resource tipado con defaults válidos, incluidos
los tres assets. `null` usa un perfil Production nuevo; el Inspector sólo acepta
instancias del tipo, no el script `.gd`. `changed` se conecta una vez desde
`Ocean`, se desconecta al reemplazar el perfil y actualiza uniforms en caliente,
sin rebuild FFT ni recreación SSPR.

Las variantes son Base/Optics/SSPR/Optics+SSPR multiplicadas por Detail OFF/ON.
OFF usa literalmente el shader P5 previo, sin uniforms, varyings ni muestras de
detalle. ON inyecta las declaraciones y funciones V3. Cambiar el perfil no cambia
variante; cambiar el toggle lo hace de forma idempotente y reaplica perfiles,
Coastal y la textura SSPR publicada.

`validation/p5_5_surface_detail.tscn` reutiliza P5, P0, la free camera, el HDRI
y la seed `20260820`; prepara la revisión con Optics, SSPR y objetos de reflexión.

## Configuración

Authoring: `wave_follow`, tamaños A/B y `normal_strength`. Advanced:
direcciones/speeds de flow, tamaño/fuerza de warp, fades y fuerza lejana. Internal:
quality, pesos de mezcla, factor `0.57`, trayectoria del warp, conversión de
slope, claves de variante e inyecciones P4/P5. Es seguro modificar el perfil y
las texturas del addon; carrier, flow, warp, composición y markers requieren
validación nueva.

## Estado

Structural y runtime D3D12 se validan antes de revisión humana. La aprobación
visual, el examen de movimiento y cualquier benchmark marginal P5.5 permanecen
pendientes de Eric. Posibles experimentos post-parity: RNM/whiteout o warp FFT,
únicamente mediante A/B separado después de esa aprobación.
