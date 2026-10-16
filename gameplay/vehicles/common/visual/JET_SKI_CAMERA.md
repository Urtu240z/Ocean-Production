# Cámara autónoma del jet ski

La escena `jet_ski_01.tscn` incluye `CameraRig/Camera3D` y el adaptador opcional
`CameraRig/Controls`. El rig se vincula a su padre `JetSkiController`, sigue su
transformación interpolada y lee la telemetría de agua/contactos ya calculada.
Se conecta a `hard_landing` y `reset_completed` del propio vehículo.

Los ajustes están en el inspector de `CameraRig`: distancia, altura, punto de
mira, FOV, suavizado, alejamiento por velocidad, vibración e impactos. La escena
del vehículo conserva los overrides de producción: alejamiento 2 m, impacto
0,6 m y recuperación 0,9500000000000001 s. Los presets CLOSE/MEDIUM/FAR y los
defaults de los helpers se conservan.

El nodo es `top_level` y actualiza la cámara en coordenadas globales para evitar
heredar por segunda vez los movimientos del casco. Conserva la actualización
durante pausa y la interpolación física desactivada de la cámara. Los helpers
de rumbo, vibración e impactos siguen siendo los originales.

## Controles y HUD

`Controls.controls_enabled` permite desactivar las teclas sin desactivar el
seguimiento ni los efectos. El adaptador atiende únicamente a la cámara actual:

- `C`: siguiente preset.
- `+`/`-` y teclado numérico: distancia en pasos de 0,25 m.
- Rueda: distancia en pasos de 0,25 m.
- `PgUp`/`PgDn`: altura en pasos de 0,15 m.

La API del rig ofrece `adjust_distance`, `adjust_height`, `cycle_preset` y
`get_preset_name`; `settings_changed(action)` permite que un HUD externo muestre
feedback. El seguimiento funciona con `Controls` desactivado y sin un HUD.

`jet_ski_ocean.gd` conserva su alias `camera` y un adaptador **no exportado** de
`follow_camera` para los validadores de desarrollo existentes. Los valores
efectivos pertenecen al rig. El integrador solo muestra feedback; tampoco
coordina sacudidas o impactos.

## Escena mínima y validación

Una escena anfitriona configura el proveedor de agua y el InputMap general de
conducción que requiere el vehículo. La cámara no necesita nodos de la escena
de desarrollo ni una implementación concreta de Ocean.

```text
godot --headless --path <proyecto> --script res://validation/jet_ski_camera_rig_runtime.gd
```

La prueba instancia un vehículo con otro nombre, proveedor plano y sin el
integrador. Comprueba seguimiento, FOV, inmersión, saltos simulados, impactos,
aterrizajes, recuperación, controles y pausa. Opcionalmente, `--oracle=<script>`
y `--baseline=<JSON>` comparan 600 pasos con el código preservado anterior al
refactor. Las poses y telemetría sintéticas solo existen en esa prueba.
