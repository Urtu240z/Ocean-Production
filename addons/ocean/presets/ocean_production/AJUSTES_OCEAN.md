# Valores efectivos de Ocean Production

Origen: `gameplay/jet_ski_ocean.tscn` → `Production/Ocean`, una vez preparado el juego.

Los perfiles `.tres` contienen los mismos valores guardados e incrustados de producción.
También hay ajustes del nodo que no pertenecen a esos perfiles. Para conservarlos todos,
instancia `ocean_production.tscn`, o reproduce la tabla siguiente en tu Ocean existente.

| Propiedad del nodo | Valor de producción |
| --- | --- |
| `breaker_detector_capture_arm_serial` | `0` |
| `breaker_detector_capture_release_serial` | `0` |
| `breaker_detector_debug_mode` | `0` |
| `breaker_detector_probe_enabled` | `false` |
| `breaker_detector_probe_reset_serial` | `0` |
| `breaker_detector_probe_xz` | `Vector2(0, 0)` |
| `breakers` | `false` |
| `caustics` | `true` |
| `clipmap_geometry_scale` | `1.0` |
| `coastal` | `false` |
| `crest_foam` | `true` |
| `debug_view` | `0` |
| `editor_preview` | `true` |
| `enable_spindrift` | `false` |
| `enabled` | `true` |
| `freeze_spindrift_visuals` | `false` |
| `local_breaker_refinement_debug` | `false` |
| `local_breaker_refinement_enabled` | `false` |
| `long_band_scale` | `1.03` |
| `long_enabled` | `true` |
| `long_wave_spacing` | `1.55` |
| `mid_band_scale` | `1.36` |
| `mid_enabled` | `true` |
| `mid_fill_amount` | `1.0` |
| `ocean_scale` | `1.0` |
| `open_ocean_fft` | `true` |
| `optics` | `true` |
| `performance_overlay` | `false` |
| `preview_time` | `0.0` |
| `reflections` | `true` |
| `sea_level` | `0.0` |
| `sea_state_mode` | `0` |
| `short_band_scale` | `2.0` |
| `short_enabled` | `true` |
| `significant_wave_height_m` | `2.574` |
| `simulation_seed` | `20260820` |
| `spindrift_debug_mode` | `5` |
| `surface_detail` | `true` |
| `surface_foam` | `true` |
| `swell` | `0.8` |
| `underwater_bubbles` | `true` |
| `underwater_medium` | `true` |
| `underwater_sunrays` | `true` |
| `visual_water_profile` | `1` |
| `wave_height_scale` | `1.16` |
| `wave_speed_multiplier` | `1.5` |
| `wind_direction_degrees` | `210.0` |
| `wind_speed_mps` | `35.0` |

## Recursos independientes

- `breaker_profile.tres`
- `caustics_profile.tres`
- `crest_foam_profile.tres`
- `lighting_environment.tres`
- `optics_profile.tres`
- `quality_profile.tres`
- `reflection_profile.tres`
- `spindrift_profile.tres`
- `surface_detail_profile.tres`
- `surface_foam_profile.tres`
- `underwater_bubble_profile.tres`
- `underwater_medium_profile.tres`
- `underwater_sunray_profile.tres`
- `wave_profile.tres`

## Iluminación y costa

`lighting_environment.tres` y `lighting_reference.tscn` conservan el entorno/HDR y el sol
originales como referencia opcional. Tu Sky3D y tu iluminación pueden producir otra imagen
aunque los valores de Ocean sean iguales. Asigna a Ocean el sol que utilices en tu nivel.

La escena del jet ski desactiva `coastal` y `breakers` al arrancar; el preset conserva ese
estado efectivo. El perfil de breakers se entrega igualmente. El bake costero antiguo es
específico de la isla original y depende de clases antiguas de validación: se conserva
aparte en `resource_exports/ocean_production_legacy/coastal_reference.zip`, con rutas y
hashes verificados. No es necesario para este preset ni se activa en el otro mapa.

`visual_water_profile = 1` conserva el perfil PHYSICS_ALIGNED que el integrador original
aplica en runtime. Se ha expuesto ese selector para poder guardarlo en una escena portable,
sin cambiar el valor predeterminado del addon ni los cálculos FFT.
