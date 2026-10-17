# Hito 1.1 — Sincronización visual y física

Base: `wip/feel-soft-water`, conservando `91aee79`.

## Auditoría y corrección

`Ocean._request_rebuild` agrupa cambios de authoring durante 0.15 s.
`_rebuild_if_ready` conserva el reloj, retira OpenOceanFFT y construye una
instancia nueva. La publicación sólo ocurre tras inicializarla; sus recursos
visuales terminan de publicarse en el hilo de render.

La resincronización parcial anterior sólo se consultaba al preparar contactos.
Al faltar una instancia válida podía dejar `field_ready` y las muestras
precargadas disponibles. Otras consultas conservaban acceso al nodo retirado.

Además, `build_dynamic_physics_lite` reutiliza coeficientes cuando la resolución
y el filtro no cambian. Importar H0 nuevo mediante `set_production_spectrum`
no invalidaba esa caché: los metadatos coincidían, pero las alturas seguían
representando el mar anterior. La transición a agua plana detectó este fallo.

La corrección añade:

- Estado público ligero del océano: disponibilidad, revisión de reconstrucción,
  identidad de OpenOceanFFT, versión espectral y reloj. No copia H0 por tick.
- Invalidación inmediata al solicitar o comenzar una reconstrucción. El
  proveedor suelta la referencia FFT y bloquea campos y cachés de contacto.
- Importación CPU Lite sólo al cambiar instancia, revisión o versión. Se usa
  `native.clear()` una vez por cambio para retirar también los coeficientes
  Lite; después se importa H0 y se construye el campo con el reloj vigente.
- Ninguna muestra individual, por lotes o precargada es utilizable hasta
  recuperar una fuente publicada y un campo válido. Un fallo de importación
  mantiene ERROR y no vuelve a copiar ese mismo espectro cada tick.
- HUD: `WATER SYNC: OK / UPDATING / ERROR`, revisión del océano y versión del
  espectro usado por la física. El mismo proveedor sirve a ambos modos.

No se modifican OpenOceanFFT, shaders, choppiness, casco, fuerzas,
amortiguación ni conducción. Los cambios pendientes ajenos al hito se conservan.

## Validación breve

Godot 4.7.1, escena `gameplay/jet_ski_ocean.tscn`, renderer habitual.
Tres reconstrucciones durante la partida:

| Cambio | Flotabilidad | Viento | Resultado físico |
| --- | --- | --- | --- |
| Wind Speed → 23 m/s | LEGACY_4POINT | 23 m/s | Olas actualizadas |
| Swell → 0, Wave Height Scale → 0 | HULL_BUOYANCY_V1 | 1 m/s | Diferencia de alturas 0 m |
| Swell → 0.8, Wave Height Scale → 1 | HULL_BUOYANCY_V1 | 23 m/s | Recuperación de las olas |

Comprobado: UPDATING inmediato, rechazo de muestras antiguas, referencia
retirada liberada sin acceso posterior, identidad y H0 actuales coincidentes,
continuidad y coincidencia del reloj, una importación por reconstrucción,
cambio de versión sin reemplazar la instancia y ausencia de importaciones
extra con estado estable o al volver a LEGACY_4POINT. Indicador HUD comprobado.

`WATER_SYNC_SMOKE: PASS | errors=0 | imports=5`

Cinco importaciones: inicial, tres reconstrucciones y una comprobación de
versión mediante cambio exclusivo de metadatos en la escena de validación.
Sin errores de escena, scripts ni ejecución. No se ejecutan benchmarks.

Repetir con:
`--path <Ocean-Production> --script res://validation/physics/water_sync_smoke.gd`

No se inicia el siguiente hito.
