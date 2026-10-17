# HITO 1.1.2 — Ocean Space / Physics Sync

Implementado sobre `wip/feel-soft-water`, conservando los commits anteriores y las modificaciones locales existentes. No se modifican fuerzas, amortiguación, inercias, controles, geometría, FFT visual ni shaders.

## Auditoría y transformación

`OceanSpaceContract.configure()` incrementa su revisión cuando cambia alguna escala. Los setters del océano actualizan este contrato y la superficie sin solicitar reconstrucción de FFT.

La superficie publica dominios efectivos `D_world = D_authored * Clipmap Geometry Scale`. El shader consulta `world_uv = base_world_xz / D_world + 0.5`, escala la geometría y el desplazamiento horizontal por Clipmap Geometry Scale, y la altura por Ocean Scale. Por tanto, las rejillas nativas de dominios originales deben consultarse en `q = world_xz / Clipmap Geometry Scale`. La división sigue los dominios efectivos del shader; no es una escala arbitraria de las posiciones físicas.

Para el campo de altura de CPU Lite:

- Altura mundial: `sea_level + Ocean Scale * h(q)`.
- Profundidad relativa: altura mundial menos la Y mundial del punto del casco. No se escala el casco ni el nivel del mar.
- Velocidad vertical: `Ocean Scale * vy(q) * simulation_time_scale`.
- Normal analítica: normalizar `(nx * V/H, ny, nz * V/H)`, con `V = Ocean Scale` y `H = Clipmap Geometry Scale`.
- La normal mediante cinco muestras conserva el paso de 0.40 m en coordenadas mundiales; las consultas ya incorporan H y sus diferencias de altura incorporan V. Así se evita aplicar H dos veces.

## Sincronización

`ocean.gd` publica ambas escalas y su revisión junto a la instancia FFT y la versión del espectro. El proveedor compara estos metadatos, rechaza muestras/cachés anteriores y muestra `UPDATING` hasta adoptar el nuevo contrato. Un contrato inválido produce `ERROR`.

Un cambio exclusivo de escala reutiliza las rejillas y el tiempo actuales: no copia H0, no importa el espectro ni reconstruye campos/FFT. Solo actualiza las transformaciones y limpia las cachés de contactos. La evolución normal de las rejillas por tick continúa como antes. La sincronización por instancia/espectro sigue funcionando cuando una reconstrucción reinicia la revisión local de Ocean Space.

El HUD muestra `WATER SYNC: OK / UPDATING / ERROR`, revisión del océano, versión del espectro, revisión de Ocean Space y ambas escalas usadas por la física. LEGACY y HULL_V1 consumen el mismo proveedor actualizado.

## Validación breve

Godot 4.7.1, renderer gráfico y escena real `gameplay/jet_ski_ocean.tscn`, sin benchmarks:

`Godot_v4.7.1-stable_win64_console.exe --path <repo> --script res://validation/physics/ocean_space_sync_smoke.gd`

Resultado: `OCEAN_SPACE_SMOKE: PASS | errors=0 | spectrum imports=2 | space syncs=20`, salida 0, sin errores ni advertencias.

- Ambos modos seleccionados y ejecutando su fase habitual de contactos.
- Ambas escalas recorridas por 1, 0.5 y 2, de forma independiente y en combinaciones, con tres puntos y ambas rutas de normales.
- Altura, profundidad, velocidad y normales contrastadas con las rejillas nativas actuales y los dominios realmente publicados por la superficie. Nivel del mar de 3 m para comprobar el pivote de escala.
- Muestras individuales, lotes y contactos obsoletos rechazados inmediatamente; retorno a `OK`, revisión actualizada y HUD comprobados.
- Cambios de escala sin nuevos imports ni reconstrucción de campos, incluso sincronizando dentro del mismo tick. Valores repetidos sin resincronizar cada tick.
- Una reconstrucción real por viento manteniendo V=0.5 y H=2 conserva las escalas y sincroniza la nueva instancia. Los dos imports corresponden exclusivamente al arranque y a esta reconstrucción.

## Diferencia geométrica que permanece

CPU Lite DIRECT representa un campo de altura sin invertir el desplazamiento horizontal del océano. El shader desplaza el punto base hasta `world_xz = base_world_xz + H * displacement_xz(q)`; el proveedor consulta la altura en el XZ solicitado, sin resolver ese punto base desplazado. Por ello, crestas, alturas y normales pueden diferir de la malla visual donde el choppiness es significativo. Su desplazamiento horizontal también cambia al modificar H.

Las normales físicas corresponden al campo de altura escalado de CPU Lite, no a una reproducción exacta de los pliegues ni de las normales de la superficie con choppiness. Esta limitación continúa explícita: no se añade un inversor de choppiness, otra FFT ni lectura GPU→CPU. Los modos experimentales locales existentes conservan sus consultas nativas y reciben la invalidación de caché al cambiar Ocean Space.

## Archivos del commit

- `addons/ocean/ocean.gd`: metadatos de Ocean Space publicados para física.
- `gameplay/water/cpu_fft_water_provider.gd`: sincronización de contrato y transformaciones de muestras.
- `gameplay/vehicles/common/visual/jet_ski_buoyancy_hud.gd`: revisión y escalas físicas en HUD.
- `validation/physics/ocean_space_sync_smoke.gd`: comprobación breve de la escena y cambios en ejecución.
- Este informe.
