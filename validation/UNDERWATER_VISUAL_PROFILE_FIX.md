# Transición underwater y perfil visual del mar

## Causa

El mar visible aplica `visual_horizontal_displacement_scale` por cascada.
La escena del jet ski usa `PHYSICS_ALIGNED` con multiplicadores `(0, 0, 1)`:
long y mid conservan su altura, pero no desplazan la superficie en horizontal.
El waterline rasterizado y el sensor de cámara seguían usando el desplazamiento
horizontal completo. Por eso podían detectar otra altura de ola en las mismas
coordenadas y mantener aire cuando la cámara ya estaba bajo la superficie visible.

Además, la firma de publicación solo comparaba texturas/Coastal/Breakers: cambios
de escalas, dominios o fades con los mismos RIDs podían dejar parámetros antiguos.

## Corrección

- `open_ocean_fft.gd`: publica los multiplicadores visuales existentes en el
  paquete que entrega a underwater. No cambia generación FFT ni forma del mar.
- `ocean_underwater_medium.gd`: republica al cambiar multiplicadores, escalas,
  dominios o fades, aunque no cambien las texturas.
- `ocean_underwater_medium_effect.gd`: transmite un vec4 adicional al raster y
  al sensor (416 y 288 bytes respectivamente).
- `ocean_waterline_raster.glsl` y `ocean_waterline_camera_state.glsl`: aplican
  los mismos multiplicadores XZ por cascada que el shader visible. La altura
  de cada cascada se conserva.

Los márgenes de entrada/salida siguen en 0.05 m. No se desplaza artificialmente
la línea de agua ni se cambian fuerzas, flotabilidad o parámetros del bow spray.

## Verificación en Godot 4.7.1 / Forward+ D3D12

`ocean_underwater_visual_profile_parity.gd`: PASS. Ejecuta el shader de cámara
real en una RenderingDevice local sobre una ola conocida con 2 m de chop.
Verifica altura con error inferior a 5 mm y clasificación correcta a ±10 cm,
con perfiles aligned, full y custom. Verifica tamaño de los dos paquetes,
compilación de ambos shaders y republicación al cambiar parámetros.

`ocean_underwater_visual_profile_runtime.gd`: PASS. Instancia la escena real
del jet ski y usa una copia del perfil con máscara de depuración. Con tiempo de
ola congelado solo para la prueba, cambia el perfil en ejecución y cruza la
superficie a ±0.12 m. Los seis cruces arrojan distancias de ±0.1199999 m y el
render cambia correctamente entre aire y agua. También verifica la actualización
de Ocean Scale y Clipmap Geometry Scale sin reemplazar texturas FFT.

Las pruebas crean sus propios recursos/escenas y no guardan cambios de inspector.
Reiniciar una partida anterior para cargar los nuevos buffers y shaders.
