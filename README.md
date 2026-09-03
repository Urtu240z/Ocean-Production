# Ocean Production

Ocean Production es el sistema de océano de producción para Godot. Requiere Godot **4.7.1** y entrega mar abierto profundo P0 con Coastal Runtime P1: LONG, MID y SHORT, con adaptación Coastal aplicada únicamente a LONG cuando se proporciona un bake externo válido.

## Uso rápido

1. Añade `addons/ocean/ocean.tscn` a tu escena, o crea un `Node3D` con el script `Ocean`.
2. Asigna un `Wave Profile` y un `Quality Profile`.
3. Deja `Enabled` y `Open Ocean FFT` activados para iniciar el sistema.

El addon se divide en `core` (recursos), `fft` (espectro y GPU), `surface` (clipmap) y `shaders`. La escena `validation/p0_open_ocean.tscn` contiene una configuración ROUGH funcional.

Disponible ahora: Open Ocean P0 y Coastal Runtime P1 cerrado (bake externo, modificación sólo de LONG).

Todavía no promovido: espuma, breakers, reflejos, underwater, caustics, sunrays, OceanQuery y sediment.

Production no contiene experimentos: los experimentos viven en Ocean Lab y sólo se promueven soluciones validadas. Una fase no está terminada hasta que su documentación operativa se actualiza en el mismo commit.

Consulta `docs/ARCHITECTURE.md`, `docs/CONFIGURATION.md`, `docs/IMPLEMENTATION_STATUS.md` y `docs/phases/` antes de cambiar el sistema.
