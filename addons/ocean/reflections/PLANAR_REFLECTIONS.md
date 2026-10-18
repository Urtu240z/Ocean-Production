# Reflejos planares del océano

En el Inspector: **Ocean → Reflection Profile → Reflection Method → Reflection Mode → Planar**. Mantener **Reflections** activado en Ocean. Screen Space conserva el método existente y sigue siendo el valor predeterminado de los recursos ya guardados.

La cámara planar refleja la escena sobre `Ocean.sea_level`, por lo que las montañas pueden seguir reflejándose aunque salgan de la pantalla principal. Comparte el mundo y no duplica la simulación. El shader proyecta la captura sobre el plano medio y añade la distorsión de las normales del oleaje. Respeta la iluminación especular, la espuma, la exposición y la gradación existentes; mirar verticalmente al agua produce reflejos más débiles por Fresnel.

## Ajustes

- **Planar Resolution Scale**: 0.5 por defecto; mitad de ancho y alto, un cuarto de los píxeles. La segunda vista vuelve a dibujar geometría y sombras: el coste no se reduce proporcionalmente a los píxeles. No hay medición de rendimiento representativa de una carrera completa todavía.
- **Planar Cull Mask**: capas de objetos que aparecen en la captura, además de la máscara de la cámara principal. Permite excluir efectos costosos y geometría submarina.
- **Screen Space Weight**, **Distortion Strength**, **Edge Fade**, **Radiance Exposure EV** y **Radiance Saturation** se comparten entre ambos métodos. Para una comparación inicial, duplicar el recurso actual y cambiar solo Reflection Mode. Un Edge Fade alto desvanece los bordes de la captura.

El cambio de método funciona en ejecución sin reconstruir el FFT. Al desactivar Reflections, la captura se detiene. Bajo el plano medio del mar se usa el entorno como fallback; la captura planar se reanuda al salir.

## Límites de esta implementación

- Reserva temporalmente la **capa de renderizado 20 para las mallas del océano**. La cámara principal la ve y la cámara reflejada la excluye, evitando autorreflejos y lectura/escritura simultánea de la textura. No usar esa capa para montañas u otros objetos que deban reflejarse. Se restauran las capas al desactivar o desmontar el sistema.
- No implementa un plano de recorte oblicuo para todos los materiales de la escena. Geometría submarina y terrenos que cruzan la superficie pueden aparecer u ocluir objetos en la captura; usar la máscara de capas y comprobar la costa. No sustituye una solución de recorte universal para escenas arbitrarias.
- Refleja el plano medio, no cada cresta del FFT. Las olas distorsionan la imagen; oleaje fuerte, espuma y bordes de pantalla reducen su contribución. No captura información fuera del campo de visión de la segunda cámara.
- La textura planar se filtra linealmente, sin la cadena de mipmaps del SSPR. No hay desenfoque planar específico de rugosidad.
- Captura la cámara activa del viewport principal. Otras vistas simultáneas necesitarían capturas propias.

## Validación

`validation/ocean_planar_reflection_runtime.gd` comprueba con renderizado real un marcador HDR que está fuera del frustum principal: aparece en la textura reflejada y en la posición prevista sobre el agua. También comprueba cambio SSR/Planar, cambio de variante Optics, resolución, desactivación/reactivación, inmersión, restauración de capas y reflexión con nivel del mar distinto de cero y cámara inclinada. Capturas: `temp/planar_validation/`.

Verificado el 18 de octubre de 2026 con Godot 4.7.1, Forward+, D3D12 y RTX 4070 Laptop: `PLANAR_SURFACE_PASS` (2486 píxeles del marcador sobre el agua), `PLANAR_OFFSCREEN_PASS` (captura 400 × 225 para ventana 800 × 450) y `PLANAR_LIFECYCLE_PASS`, salida 0. La regresión existente `p5_reflections_runtime_validation.gd` también pasa con 40 cambios de variante Optics (`P5_VARIANT_BINDING_PASS`). No se han validado otros renderizadores ni visores simultáneos.

Referencias de API: [Camera3D](https://docs.godotengine.org/en/stable/classes/class_camera3d.html), [SubViewport y Viewports](https://docs.godotengine.org/en/stable/tutorials/rendering/viewports.html), [ViewportTexture HDR lineal](https://docs.godotengine.org/en/stable/classes/class_viewporttexture.html).
