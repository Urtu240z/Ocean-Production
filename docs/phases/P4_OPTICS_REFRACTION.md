# P4 — Water Optics / Refraction V3

## Estado

| Estructural | Runtime | Visual | Rendimiento |
| --- | --- | --- | --- |
| PASS | PASS | PENDING — Eric | PENDING |

P4 está listo para revisión visual; no está cerrado. No incluye reflections, underwater, caustics, sunrays, breakers ni benchmark.

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

`validation/p4_water_optics.tscn` reutiliza Environment Lab-equivalent y añade fondo sumergido, objeto bajo agua y objeto que cruza visualmente la superficie. Es la ruta para revisar deep, objeto detrás, intersección y horizonte/open ocean. Para shallow real, asignar al Ocean un `Coastal Bake` V3 horneado con `real_seabed_coverage`; la escena no simula ni fabrica bathymetry.

`validation/p4_runtime_validation.gd` ejecuta: Optics OFF→ON, Coastal OFF→ON, Crest OFF→ON, Surface OFF→ON y Wave Profile rebuild. El smoke D3D12 imprimió `P4_RUNTIME_MATRIX_PASS` sin errores de parse, compile, shader, RID ni uniform del proyecto. Las ejecuciones automatizadas deben redirigir `--log-file` cuando el entorno no puede escribir el caché global de Godot.

## Matriz para Visual Review

1. Abrir `validation/p4_water_optics.tscn` con Godot 4.7.1 Forward+ D3D12.
2. Revisar Optics OFF/ON y OFF→ON→OFF→ON: el océano sigue visible.
3. Revisar Coastal OFF/ON con un bake real: no debe aparecer fondo falso cuando está fuera de cobertura.
4. Revisar Crest OFF/ON y Surface OFF/ON: las espumas siguen opacas, posteriores a optics.
5. Ejecutar Wave Profile rebuild: no deben aparecer errores de shader, RID, uniform, NaN/Inf, halos, geometría duplicada ni bordes negros.
