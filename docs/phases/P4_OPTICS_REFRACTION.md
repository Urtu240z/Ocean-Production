# P4 — Water Optics / Refraction V3

## Estado

| Estructural | Runtime | Visual | Rendimiento |
| --- | --- | --- | --- |
| PASS | PASS | PASS — Eric | PASS — measured |

P4 está cerrado con `Structural: PASS`, `Runtime: PASS` y `Visual: PASS — Eric`. Eric confirmó además `Coastal/Optics decoupling: PASS`: Coastal OFF cambia las ondas y la refracción/seabed óptico sigue funcionando. El reflejo negro queda fuera de P4 y se resolverá en P5 Reflections / SSPR. No incluye underwater, caustics, sunrays ni breakers.

## Arquitectura

`Ocean.optics` selecciona una variante de `OceanClipmapSurface`.

- OFF mantiene el shader P0–P3 base: no declara ni usa `hint_screen_texture`/`hint_depth_texture`.
- ON añade la ruta P4 y sus uniforms. El cambio sólo sustituye material/shader de superficie; no reconstruye solvers FFT, Crest Foam, Surface Foam ni Coastal.
- P2 Crest Core y P3 Surface Foam/Crest Filigree permanecen después de P4 en el fragment shader. Optics no altera sus triggers, topologías ni scheduler.

## Parámetros V3 efectivos

Los defaults de `OceanOpticsProfile` coinciden con `lab/lab_main.tscn` cuando había override y con V3 activo cuando no lo había:

| Grupo | Valores |
| --- | --- |
| Body | shallow/deep/horizon/trough/crest V3; Beer–Lambert RGB `(0.35, 0.14, 0.10)`; máximo 48 m; body `0.7–26 m`; opacidad `80–1000 m` |
| Refraction | micro `0.15`, clamp `24 px`, tolerancia `0.35 m`, wave `1`, LONG/MID/SHORT `1/3/2`, fade `1–38 m` |
| Scattering | color `(0.02, 0.32, 0.42)`, strength `0.45`, shallow/deep tint `1/0.15`, shallow range `1–8 m`, turbidity `0.35` |
| Transmission | detail `7–46.5 m`, `transmission_max_lod = 5.0`, bottom visibility `5–41.1 m`, seabed match `0–22.85 m` |
| Shallow relief | Fresnel `0.58`, range `1.5–48.6 m` |

## Seabed y océano abierto

P4 consume exclusivamente datos horneados. `OceanCoastalRuntime` extrae del bake la textura RG de `BathymetryData`: R es `real_seabed_coverage` binario; G es `optical_seabed_confidence`.

La autoridad de profundidad local es:

`metrics.r` dentro del dominio × feather de borde × cobertura real R.

`coastal_field.a` no participa. La muestra de escena debe además coincidir con la altura de seabed horneada; la confianza G y los fades de bottom visibility gobiernan cuánto transmite el fondo. Si falta bake, cobertura, dominio o match, P4 usa el fallback de océano abierto: path de cámara limitado, color profundo y ningún shallow tint/fondo falso.

## Óptica y refracción

La transmisión usa `exp(-absorption_rgb * optical_path)`. En agua somera con autoridad real, el path se limita por la profundidad horneada multiplicada por `1.5`; en océano abierto conserva el path de vista. El LOD del screen sample combina fade por transmisión y turbidity.

La refracción suma pendientes LONG/MID/SHORT, aplica el clamp en píxeles y evalúa profundidad candidata. Sólo desplaza el sample si el candidato es válido, está detrás de la superficie, no cruza una discontinuidad mayor que la tolerancia dependiente de espesor y tiene confianza de borde. Si falla, mezcla a `SCREEN_UV` original: evita bleeding de foreground, siluetas duplicadas y bordes negros. El matching original/candidato mantiene la decisión de bottom visibility al refractar.

## Validation

`validation/p4_water_optics.tscn` reutiliza Environment Lab-equivalent, añade fondo sumergido y objetos de inspección, y usa el fixture Paradise autocontenido bajo `validation/p4_paradise/` para el pase shallow real. Es la ruta para revisar deep, objeto detrás, intersección, seabed y horizonte/open ocean; no introduce datos ni dependencias en el addon.

`validation/p4_runtime_validation.gd` ejecuta: Optics OFF→ON, Coastal OFF→ON, Crest OFF→ON, Surface OFF→ON y Wave Profile rebuild. El smoke D3D12 imprimió `P4_RUNTIME_MATRIX_PASS` sin errores de parse, compile, shader, RID ni uniform del proyecto. Las ejecuciones automatizadas deben redirigir `--log-file` cuando el entorno no puede escribir el caché global de Godot.

## Matriz para Visual Review

1. Abrir `validation/p4_water_optics.tscn` con Godot 4.7.1 Forward+ D3D12.
2. Revisar Optics OFF/ON y OFF→ON→OFF→ON: el océano sigue visible.
3. Revisar Coastal OFF/ON con un bake real: no debe aparecer fondo falso cuando está fuera de cobertura.
4. Revisar Crest OFF/ON y Surface OFF/ON: las espumas siguen opacas, posteriores a optics.
5. Ejecutar Wave Profile rebuild: no deben aparecer errores de shader, RID, uniform, NaN/Inf, halos, geometría duplicada ni bordes negros.

## PERFORMANCE

Benchmark marginal P4 ejecutado el 2026-09-04 en entorno ligero tipo P2, con la
misma escena `res://validation/p0_open_ocean.tscn`, sesión, cámara, seed, Wave
Profile, Quality Profile y estado Ocean. La única diferencia fue `Optics OFF`
frente a `Optics ON`; Crest Foam y Surface Foam permanecieron ON y Coastal OFF.
No se usó el HDRI Kloofendal ni el workload pesado de la escena visual.

| Campo | Valor |
| --- | --- |
| Ejecutable / renderer | Godot `4.7.stable.official.5b4e0cb0f`; Forward+ D3D12 |
| Hardware | Intel Core i7-13650HX; NVIDIA GeForce RTX 4070 Laptop GPU, driver 610.62, 8188 MiB |
| Resolución / render scale | 1920x1080 real / 1.00 |
| VSync / frame cap | OFF / `Engine.max_fps=0` |
| Cámara | `FreeCamera` fija en `(0, 8, 16)`, transform original, FOV 70°, far 8000; sin input |
| Ocean | seed `20260820`, `rough_validation.tres`, Hs `2.573`, Crest ON, Surface ON, Coastal OFF |
| Warmup / measurement | 3 s / 5 s por estado |
| Métrica | Intervalo medio de frame por reloj de pared entre callbacks, mediante `Time.get_ticks_usec`; no es GPU time |

### Runs OFF/ON

| Run | Optics OFF | Optics ON |
| --- | ---: | ---: |
| 1 | 1.585 ms / 631.0 FPS | 2.022 ms / 494.5 FPS |
| 2 | 1.596 ms / 626.7 FPS | 2.045 ms / 489.0 FPS |
| 3 | 1.598 ms / 626.0 FPS | 2.094 ms / 477.5 FPS |
| **Promedio** | **1.593 ms / 627.7 FPS** | **2.054 ms / 486.9 FPS** |

Spread aproximado: OFF `0.013 ms`; ON `0.072 ms`.

| Resultado | Valor |
| --- | ---: |
| Delta absoluto `ON - OFF` | **+0.461 ms** |
| Delta porcentual `((ON / OFF) - 1) * 100` | **+28.92 %** |

Antes de medir se confirmó por runtime la variante efectiva:

```text
OFF=base:true | OFF=screen_depth:false | ON=dynamic:true | ON=screen_depth:true
```

Optics OFF usa el shader base sin `hint_screen_texture` ni `hint_depth_texture`;
Optics ON usa la variante dinámica con ambos recursos. La métrica registra
únicamente el coste observado de la variante P4 bajo este protocolo; no se
interpretan los FPS como coste GPU.

La herramienta benchmark fue temporal y se eliminó antes del cierre. Durante
su salida apareció un aviso de fuga de un RID de luz al cerrar tras cambiar
temporalmente el estado de iluminación; no hubo errores de shader, variante,
RID inválido, uniform inválido ni double free durante la medición. El smoke
test limpio posterior de Production terminó con exit code 0.
