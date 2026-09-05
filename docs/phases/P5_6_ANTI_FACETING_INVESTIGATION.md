# P5.6 — Investigación de geometría distante y anti-faceting

Fecha: 2026-09-05  
Rama: `investigation/p5_6-anti-faceting`  
Estado: investigación cerrada para revisión de Eric; sin promoción.

## Veredicto

| Campo | Resultado |
|---|---|
| Root Cause | NOT CONFIRMED |
| Candidate | NOT IDENTIFIED |
| Production modified | NO — solo cambios de validación en esta rama |
| Production master | UNCHANGED |
| Visual final | PENDING ERIC |

No se observó faceting triangular concluyente en las capturas neutralizadas. Tampoco se aisló una intervención que lo elimine de forma reproducible. La evidencia estructural sí confirma un riesgo de submuestreo: la banda LONG permanece activa mientras el anillo L6 usa spacing de 16 m y su longitud de onda mínima es 16 m, es decir, 1 muestra por longitud de onda; L5 empieza con 8 m de spacing y 2 muestras por longitud de onda. Esto identifica una condición plausible, no la causa demostrada del artefacto observado.

## Auditoría realizada

Se revisaron los builders y superficies de Production, el shader de superficie, perfiles de calidad/ondas/FFT/espectro, la escena `rough_validation`, el free camera y el diagnóstico de reflexión. También se revisaron Ocean Lab V3 actual y el historial solicitado.

Configuración Production vigente:

- Clipmap: 192 celdas por lado, spacing base 0.25 m, 10 niveles, horizonte 7000 m.
- Fades: SHORT 0–55 m, MID 96–280 m, LONG 768–2500 m.
- Espectro: tres FFT de resolución 256; dominios LONG/MID/SHORT de 512/137/37 m.
- Perfil rough: Hs total aproximada 2.573 m, seed 20260820; LONG min/max 16/128 m, MID 4/20 m, SHORT 0.5/5 m.
- El vertex shader aplica displacement XZ y Y de las tres bandas, ponderadas por distancia. No existe filtro espectral por LOD ni mipmap de las texturas RD de displacement/normal.
- La topología actual es regular en L0 y anillos con stitching 2:1 en niveles posteriores; diagonal fija `a,c,b` / `a,d,c`.

Tabla derivada de rings:

| LOD | Spacing | Extensión radial aproximada | Samples por λ mínima LONG |
|---:|---:|---:|---:|
| L0 | 0.25 m | 0–24 m | 64 |
| L1 | 0.5 m | 24–48 m | 32 |
| L2 | 1 m | 48–96 m | 16 |
| L3 | 2 m | 96–192 m | 8 |
| L4 | 4 m | 192–384 m | 4 |
| L5 | 8 m | 384–768 m | 2 |
| L6 | 16 m | 768–1536 m | 1 |
| L7 | 32 m | 1536–3072 m | 0.5 |

El baseline completo contiene 294,721 vértices y 574,848 triángulos. La discrepancia más fuerte está en L6, dentro del fade LONG 768–2500 m.

## Historial Ocean Lab V3

Se inspeccionaron los commits obligatorios:

- `e602e1afbfe9bdbad270311ff87ccc5b09e64c25` — implementó geomorph de transición LOD, con cuantización hacia la rejilla siguiente y metadatos por instancia.
- `e0ac3481400123dcc7e01c3c0c5ea003dab893e5` — revirtió esa implementación.

El propio documento histórico limita geomorph a suavizar transiciones y advierte que no filtra frecuencias según spacing. Además, durante la secuencia histórica hubo una corrección de coherencia entre posición muestreada y vértice desplazado (`956e870`), que luego también fue revertida (`298a5c2`). Por ello no se reutilizó geomorph como solución del artefacto interior; sigue siendo una hipótesis de transición, no un diagnóstico confirmado.

El V3 actual conserva la misma familia de topología/stitching y no tiene geomorph activo. Sus defaults de spacing/celdas/niveles coinciden con Production; sus fades difieren en SHORT.

## Experimentos de validación

Se creó [`p5_6_geometry_lod.tscn`](../../validation/p5_6_geometry_lod.tscn) con diagnóstico temporal en [`p5_6_geometry_lod.gd`](../../validation/p5_6_geometry_lod.gd). El fixture:

- desactiva coastal, optics, reflections, crest foam, surface foam y surface detail;
- reutiliza el free camera, seed 20260820 y congela la FFT tras estabilizar;
- permite surface/unshaded/LOD-color, baseline, checkerboard, density moderate/high y atenuación XZ 100/75/50/0;
- verifica winding/degenerados y registra counts por caso.

Resultados geométricos:

| Caso | Vértices | Triángulos | Invalid | Delta triángulos |
|---|---:|---:|---:|---:|
| Baseline | 294,721 | 574,848 | 0 | 0% |
| Checkerboard | 294,721 | 574,848 | 0 | 0% |
| Density moderate (224) | 399,393 | 781,760 | 0 | +35.99% |
| Density high (256) | 519,937 | 1,020,416 | 0 | +77.51% |

Checkerboard no produjo mejora visual concluyente. Moderate/high hicieron la superficie algo más continua en algunas zonas, pero no eliminaron un patrón identificable y no permiten atribuir causalidad. El combo checkerboard+moderate fue construido y validado topológicamente, pero su captura batch no terminó; no se usa como evidencia visual positiva.

La atenuación XZ cambió la silueta y la forma de las olas, pero no eliminó de forma clara el faceting en las capturas neutralizadas. Por tanto no demuestra que la componente horizontal sea la causa.

Capturas principales:

- [`p5_6_baseline.png`](../../validation/captures/p5_6_baseline.png)
- [`p5_6_checkerboard.png`](../../validation/captures/p5_6_checkerboard.png)
- [`p5_6_density_moderate.png`](../../validation/captures/p5_6_density_moderate.png)
- [`p5_6_density_high.png`](../../validation/captures/p5_6_density_high.png)
- [`p5_6_xz_100.png`](../../validation/captures/p5_6_xz_100.png), [`p5_6_xz_75.png`](../../validation/captures/p5_6_xz_75.png), [`p5_6_xz_50.png`](../../validation/captures/p5_6_xz_50.png), [`p5_6_xz_0.png`](../../validation/captures/p5_6_xz_0.png)

## Coste y recomendación

- Checkerboard: coste de construcción CPU/startup; mismo número de triángulos; no candidato probado.
- Density moderate: aproximadamente +36% de geometría; candidato de coste razonable solo para una futura prueba controlada.
- Density high: aproximadamente +78%; no recomendar Production sin medición de GPU/CPU y plataforma objetivo.
- Geomorph: no evaluado como corrección final; solo afecta transición y no resuelve por sí mismo el submuestreo espectral.
- Band limiting por LOD: no implementado; es la línea de investigación más directamente alineada con el riesgo estructural, pero requiere definir bandas espaciales y validar continuidad temporal. No se añadió FFT ni se alteró el artefacto final.

## Limitaciones / siguiente paso de Eric

La captura automática no demostró el primer nivel visible con faceting, ni permitió separar con certeza transición de interior. Tampoco cubrió de forma concluyente wireframe/silueta, cruce temporal de cámara por todos los anillos, estabilidad de stitching durante movimiento ni una medición comparativa de frame time. La revisión visual de Eric debe decidir si el artefacto existe en el baseline y señalar distancia/LOD; solo después conviene convertir la hipótesis LONG/L6 en un cambio experimental independiente.

No se modificó ningún asset artístico por esta investigación. No se hizo commit, merge, pull ni push.

## P5.6B — aislamiento LONG por representación geométrica

La escena de validación se amplió sin tocar `H0`, FFT, perfiles de ondas, normales, `OceanQuery`, física ni sistemas de presentación. Cada `MeshInstance3D` recibe únicamente los metadatos validation-only `clipmap_level` y `clipmap_spacing_m`; el shader temporal recibe esos mismos valores como uniforms por instancia.

El filtro usa la métrica derivada de LONG:

```text
samples_per_min_wave = 16.0 / clipmap_spacing_m
weight = 1 - smoothstep(2, 8, samples_per_min_wave)
```

Así L0–L3 permanecen sin radio efectivo, L4 entra gradualmente, L5 alcanza filtrado fuerte y L6/L7 quedan en máximo; no hay un switch abrupto L5/L6. El filtro solo afecta el displacement geométrico LONG. Las normales de fragment y la textura FFT permanecen sin filtrar. En Coastal se conserva la ruta existente y el diagnóstico se ejecuta primero con Open Ocean.

Controles interactivos, sin mover la cámara:

| Tecla | Diagnóstico | LONG fetches/vértice |
|---|---|---:|
| `1` | Baseline | 1 |
| `2` | Low-pass, radio 0.5×spacing | 4 |
| `3` | Low-pass, radio 1.0×spacing | 4 |
| `4` | Strong macro-only, kernel 5-tap | 5 |
| `5` | Y-only, kernel 5-tap | 5 |
| `6` | XYZ, kernel 4-tap | 4 |
| `7` | XZ más agresivo que Y | 8 |

También están disponibles `W` wireframe, `L` LOD colors, `U` unshaded, `S` shaded, `D` Surface Detail, `R` SSPR, `SPACE` freeze y `F6–F9` para XZ 100/75/50/0%. El overlay muestra modo, cámara→plano del mar, radio de target, LOD aproximado y spacing. La cámara por defecto del fixture es `(0, 3, 80)` con pitch `-18°`; no es una reproducción confirmada del defecto de Eric.

### Checklist A/B P5.6B

1. Cámara/distancia reproducible: no confirmada automáticamente; fixture interactivo listo, default 80 m.
2. LOD del artefacto: no identificado; overlay permite situar target aproximado.
3. Spacing: visible en overlay; L6 = 16 m, L7 = 32 m.
4. Shaded/unshaded: controles `S`/`U`; pendiente de comparación en la cresta real.
5. Wireframe correlation: control `W`; pendiente de confirmación visual.
6. SSPR OFF/ON: `R`; pendiente de comparación visual.
7. Detail OFF/ON: `D`; pendiente de comparación visual; no se modifica P5.5.
8. Baseline: ejecutado; 1 fetch LONG, 294,721 vértices, 574,848 triángulos, invalid 0.
9. Low-pass 0.5×spacing: implementado temporalmente, 4 fetches; A/B visual pendiente.
10. Low-pass 1.0×spacing: implementado temporalmente, 4 fetches; A/B visual pendiente.
11. Strong macro-only: implementado temporalmente, 5 fetches; A/B visual pendiente.
12. Y-only: implementado temporalmente, 5 fetches; A/B visual pendiente.
13. XYZ: implementado temporalmente, 4 fetches; A/B visual pendiente.
14. Cambio del patrón: no evaluado concluyentemente sin la posición problemática de Eric.
15. Spectral/geometry alias: NOT CONFIRMED.
16. Samples adicionales: XZ-aggressive usa 8 fetches; no es candidato Production.
17. Seams: baseline y variantes de malla anteriores reportan invalid 0; continuidad visual entre rings pendiente.
18. Temporal stability: FFT congelada para snapshot; cruce temporal de rings pendiente.
19. Production candidate: NOT IDENTIFIED.
20. Branch/worktree: `investigation/p5_6-anti-faceting`; `master` sigue en `ba6e4f239d03b71d08969d76f7780dd02bc0c0ea`; sin commit/push/merge.

Smoke tests posteriores en GPU NVIDIA D3D12 arrancaron baseline, XYZ + wireframe/LOD y macro + Detail/SSPR con geometría válida. Permanece únicamente el warning interno de caché `shader_rd.cpp:696` causado por shaders diagnósticos creados en memoria; no aparecieron errores de uniform, RID, geometría ni NaN/Inf. La ventana interactiva no pudo dejarse en una vista de escena estable desde este entorno, por lo que el veredicto visual queda deliberadamente pendiente de Eric.
