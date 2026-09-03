# Configuración de Production

Los valores de referencia P0 están en `P0_BASELINE_ROUGH.md`. Cambiar un campo de Sea State reconstruye las tres bandas cuando el juego está activo.

## AUTHORING

| Parámetro | Unidad / default | Efecto y recomendación |
| --- | --- | --- |
| `Enabled` | booleano / `true` | Enciende o apaga completamente P0. Runtime: sí; al apagar libera recursos GPU y al encender reconstruye. |
| `Open Ocean FFT` | booleano / `true` | Habilita el único sistema de océano actual. Runtime: sí; mismo ciclo completo que `Enabled`. |
| `Coastal` | booleano / `false` | Activa el consumidor Coastal sólo si existe un `Coastal Bake` válido. Runtime: sí; OFF elimina las referencias y vuelve al flujo P0. |
| `Coastal Bake` | Resource / vacío | Datos externos ya horneados: bathymetry, propagación y warp. Puede cambiarse en runtime; un bake inválido deja Coastal inactivo de forma segura. |
| `Sea Level` | m / `0` | Altura de la superficie y clipmap. Runtime: sí; reconstruye. |
| `Significant Wave Height` | m / `2.574` | Escala proporcionalmente Hs de LONG/MID/SHORT. Runtime: sí; reconstruye. Usar valores positivos. |
| `Wind Speed` | m/s / `18` | Velocidad de viento común de las tres bandas. Runtime: sí; reconstruye. |
| `Wind Direction` | grados / `5.71` | Rota las tres direcciones conservando su separación relativa. Runtime: sí; reconstruye. |
| `Swell` | 0–1 / `0.80` | Escala el swell relativo de las bandas. Runtime: sí; reconstruye. |
| `Performance Overlay` | booleano / `false` | Muestra una etiqueta diagnóstica. No reconstruye ni mide rendimiento. |
| `Debug View` | Off/Normals / Off | Alterna vista de normales. Runtime: sí; no reconstruye. |

## ADVANCED

`OceanWaveProfile` permite ajustar por banda Hs, choppiness, dirección, spread, fetch, swell y límites de longitud de onda. Afectan espectro y aspecto; reconstruyen al volver a inicializar. Mantener bandas no solapadas y Hs moderado.

`OceanQualityProfile` controla `cells_per_side` (192), `base_spacing_m` (0.25 m), `level_count` (10) y los fades. Más celdas o niveles aumenta geometría y coste; los fades cambian la contribución visual de cada banda. Ajustar en tiempo de edición y reiniciar la escena.

Los datos internos de un Coastal Bake no deben editarse en Production: se hornean fuera del addon y se consumen tal cual.

## INTERNAL / NO TOCAR NORMALMENTE

`OceanFftConfig` se genera desde el perfil. No cambiar manualmente resolución FFT (256), dominio de cada banda (512/137/37 m), layout ping-pong, índices de bindings, formatos de textura, H0 ni los shaders de compute. Estos parámetros afectan compatibilidad GPU, estabilidad o propiedad de RIDs y requieren una validación estructural nueva.
