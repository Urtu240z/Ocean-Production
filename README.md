# Ocean Production

Ocean Production es el sistema de océano de producción para Godot. Requiere Godot **4.7.1** y entrega mar abierto profundo P0, Coastal Runtime P1, Crest Foam V3 Core P2 y Surface Foam V3 P3 listo para revisión visual.

## Uso rápido

1. Añade `addons/ocean/ocean.tscn` a tu escena, o crea un `Node3D` con el script `Ocean`.
2. Asigna un `Wave Profile` y un `Quality Profile`.
3. Deja `Enabled` y `Open Ocean FFT` activados para iniciar el sistema.

El addon se divide en `core` (recursos), `fft` (espectro y GPU), `surface` (clipmap) y `shaders`. La escena `validation/p0_open_ocean.tscn` contiene una configuración ROUGH funcional y reutiliza `validation/free_camera.tscn` para la inspección manual.

`validation/` es infraestructura temporal de desarrollo: puede permanecer durante toda la migración y no forma parte del addon. La free camera usa input directo, sin `InputMap` permanente, y ofrece WASD para mover, ratón para mirar, Shift para acelerar, Space para ralentizar, Q/E para subir o bajar y Esc para capturar o liberar el ratón. El benchmark, en cambio, se crea, mide, documenta y elimina en cada medición.

Disponible ahora: Open Ocean P0, Coastal Runtime P1 y Crest Foam V3 Core P2 cerrados. P3 usa un solver auxiliar J-only independiente, Direct-J topology y field persistente; está listo para revisión visual y aún no tiene benchmark.

Todavía no promovido: breakers, reflejos, underwater, caustics, sunrays, OceanQuery y sediment.

Production no contiene experimentos: los experimentos viven en Ocean Lab y sólo se promueven soluciones validadas. Una fase no está terminada hasta que su documentación operativa se actualiza en el mismo commit. `validation/` sólo se elimina cuando termina la validación global de Production y antes de preparar la distribución final; el addon final contiene únicamente `addons/ocean/`.

Consulta `docs/ARCHITECTURE.md`, `docs/CONFIGURATION.md`, `docs/IMPLEMENTATION_STATUS.md` y `docs/phases/` antes de cambiar el sistema.
