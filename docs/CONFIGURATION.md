# Configuración de Production

Los valores de referencia P0 están en `P0_BASELINE_ROUGH.md`. Cambiar un campo de Sea State reconstruye las tres bandas cuando el juego está activo.

## AUTHORING

| Parámetro | Unidad / default | Efecto y recomendación |
| --- | --- | --- |
| `Enabled` | booleano / `true` | Enciende o apaga completamente P0. Runtime: sí; al apagar libera recursos GPU y al encender reconstruye. |
| `Open Ocean FFT` | booleano / `true` | Habilita el único sistema de océano actual. Runtime: sí; mismo ciclo completo que `Enabled`. |
| `Coastal` | booleano / `false` | Activa el consumidor Coastal sólo si existe un `Coastal Bake` válido. Runtime: sí; OFF elimina las referencias y vuelve al flujo P0. |
| `Coastal Bake` | Resource / vacío | Datos externos ya horneados: bathymetry, propagación y warp. Puede cambiarse en runtime; un bake inválido deja Coastal inactivo de forma segura. |
| `Crest Foam` | booleano / `true` | Activa Crest V3 Core aprobado en P2. Runtime: sí; OFF libera acumuladores y bindings Crest, omite sus dispatches y su mezcla, sin cambiar geometría ni FFT base. |
| `Surface Foam` | booleano / `true` | Activa P3 completo: auxiliar J-only, Direct-J topology, field/history, MID history, render y Crest Filigree. Runtime: sí; OFF libera todos los RIDs exclusivos y deja Crest Core P2 activo. |
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

Crest Foam no expone parámetros artísticos en el nodo principal. Sus valores internos siguen el preset ROUGH efectivo V3: compresión Jacobiana por LONG/MID/SHORT, whitecap 0.62/0.66/0.68, amount 1.60/0.42/0.22, decay 4.50, pesos 1.00/0.65/0.10, breakup 0.45 a 14 m, edge 0.32 y fade 0–5000 m. Cambiarlos altera persistencia, cobertura y material.

Surface Foam P3 conserva los valores ROUGH efectivos V3 internamente: source 512 / 14.5 m, topology 512 RG16F con mips, field 1024 RG16F / 88 m y 30 Hz. No exponer ni cambiar layout, formatos, source J-only ni bindings sin nueva validación visual.

## INTERNAL / NO TOCAR NORMALMENTE

`OceanFftConfig` se genera desde el perfil. No cambiar manualmente resolución FFT (256), dominio de cada banda (512/137/37 m), layout ping-pong, índices de bindings, formatos de textura, H0 ni los shaders de compute. Crest añade snapshots de desplazamiento y acumuladores RG16F por solver cuando está activo; su ownership y liberación pertenecen al solver. Estos parámetros afectan compatibilidad GPU, estabilidad o propiedad de RIDs y requieren una validación estructural nueva.
