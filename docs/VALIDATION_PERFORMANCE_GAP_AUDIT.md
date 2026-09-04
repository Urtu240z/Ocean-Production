# Auditoría del gap de rendimiento de validation

Fecha: **2026-09-04**

Esta auditoría mide cuánto del aumento histórico entre P2 y el benchmark P3
OFF procede del cambio de workload de `validation`. No modifica el coste
marginal oficial de P3 (`Surface OFF` vs `Surface ON`, **+0.602 ms**).

## Protocolo

- Ejecutable efectivo: Godot `4.7.stable.official.5b4e0cb0f`.
- Renderer: Forward+ D3D12.
- Hardware: Intel Core i7-13650HX; NVIDIA GeForce RTX 4070 Laptop GPU,
  driver 610.62, 8188 MiB.
- Escena: `res://validation/p0_open_ocean.tscn`.
- Resolución real: 1920x1080.
- Render scale: 1.00.
- VSync: OFF.
- `Engine.max_fps`: 0.
- Cámara fija: `FreeCamera`, posición `(0, 8, 16)`, transform y FOV 70° sin
  input ni movimiento; far 8000.
- Ocean fijo: seed `20260820`, `rough_validation.tres`, Significant Wave
  Height `2.573`, Crest Foam ON, Surface Foam OFF, Coastal OFF.
- Warmup: 3 s por estado.
- Measurement: 5 s por estado.
- Métrica: intervalo medio de frame por reloj de pared entre callbacks de
  frame, medido con `Time.get_ticks_usec`; no es GPU time.

La herramienta temporal mantuvo vivo el mismo Ocean, FFT, cámara y escena. La
única variable del A/B primario fue el stack de `Environment`/lighting,
incluidos los `CameraAttributes` que forman parte del postprocesado del estado.

### Estado A — P2-light

Reconstruido desde `validation/p0_open_ocean.tscn` del commit histórico
`f88438f`, sin aproximar valores: background Color
`Color(0.04, 0.1, 0.16, 1)`, ambient source 3, ambient color
`Color(0.35, 0.48, 0.6, 1)`, ambient energy `0.8`, tonemap mode `2`, sin Sky,
CameraAttributes ni postprocesado adicional. La DirectionalLight usa el
transform histórico, energy `2.0`, shadows ON y los valores por defecto
históricos para las propiedades de sombra omitidas.

### Estado B — current reference

Tomado de la escena actual: HDRI Kloofendal 4K, PanoramaSky energy `3.0`,
radiance size `4`, sky ambient contribution `0.15`, reflected source Sky,
AgX (`exposure 0.5`, white `2.0`, contrast `1.12`), SSAO, SSIL, Glow, Fog,
adjustment y CameraAttributesPhysical con auto exposure. La luz actual conserva
su transform, energy `3.611`, angular distance `0.5`, shadows, blur `2.5`,
splits `0.05 / 0.15 / 0.4`, blend splits y max distance `2500`.

## A/B primario

Orden balanceado: A1, B1, B2, A2, A3, B3, B4, A4, A5, B5.

| Run | P2-light A | Current environment B |
| --- | ---: | ---: |
| 1 | 1.303 ms / 767.6 FPS | 2.570 ms / 389.2 FPS |
| 2 | 1.308 ms / 764.3 FPS | 2.595 ms / 385.3 FPS |
| 3 | 1.294 ms / 772.5 FPS | 2.661 ms / 375.7 FPS |
| 4 | 1.327 ms / 753.6 FPS | 2.685 ms / 372.5 FPS |
| 5 | 1.347 ms / 742.2 FPS | 2.806 ms / 356.4 FPS |
| **Promedio** | **1.316 ms / 760.0 FPS** | **2.663 ms / 375.5 FPS** |

Spread aproximado entre runs: A `0.053 ms`; B `0.236 ms`.

| Cálculo | Resultado |
| --- | ---: |
| Environment delta `B_avg - A_avg` | **+1.348 ms** |
| Environment delta porcentual | **+102.42 %** |
| Historical gap `2.619 - 1.253` | **+1.366 ms** |
| Fraction explained `1.348 / 1.366` | **98.7 %** |
| Unexplained remainder | **0.018 ms** |

## Ablation del Environment B

Cada fila es una medición aislada contra B0. Las diferencias no son aditivas y
no deben sumarse para inferir un coste total.

| Block | Average ms | FPS derivado | Delta vs B0 |
| --- | ---: | ---: | ---: |
| B0 Current full environment | 2.808 | 356.1 | 0.000 ms |
| B1 SSAO + SSIL OFF | 2.416 | 413.9 | -0.392 ms |
| B2 Glow OFF | 2.525 | 396.0 | -0.283 ms |
| B3 Fog OFF | 2.721 | 367.6 | -0.087 ms |
| B4 Auto Exposure OFF | 2.352 | 425.2 | -0.456 ms |
| B5 Shadows OFF | 2.513 | 398.0 | -0.295 ms |
| B6 Simplified Shadows | 2.678 | 373.5 | -0.130 ms |
| B7 HDRI / IBL OFF | 2.618 | 382.0 | -0.190 ms |

La mayor reducción individual observada fue Auto Exposure OFF (`-0.456 ms`),
seguida de SSAO+SSIL OFF (`-0.392 ms`), Shadows OFF (`-0.295 ms`) y Glow OFF
(`-0.283 ms`). Es una clasificación indicativa de ablation individual, no una
descomposición aditiva.

## Controles, teardown y limpieza

Durante toda la sesión se confirmó por runtime:

```text
Surface Foam OFF | module_null=true | Coastal OFF | Crest ON
```

No aparecieron errores de shader, compilación de shader durante los runs,
invalid RID, invalid uniform set, Texture2DRD stale ni double free durante la
medición. La salida temporal sí mostró avisos de fugas de RIDs de
`DirectionalLight` al cerrar, después de mutar repetidamente la luz para los
estados A/B y ablations. Se trata del teardown de la herramienta temporal; no
se produjo en el smoke test limpio de Production posterior a su eliminación,
que terminó con exit code 0.

El benchmark temporal, escena, script, `.uid` y nodo fueron eliminados. La
escena `validation/p0_open_ocean.tscn`, `project.godot`, el addon y los
shaders no fueron modificados permanentemente.

## Conclusión

**SÍ: el cambio de Environment/lighting explica aproximadamente el 98.7 % de
los +1.366 ms históricos; quedan 0.018 ms sin explicar dentro de esta
medición.**

Esta auditoría no cambia ni sustituye el benchmark marginal oficial de P3.
No se inició P4.
