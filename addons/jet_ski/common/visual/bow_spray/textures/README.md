# Assets de bow spray

Copias sin modificar de las imágenes suministradas desde el root del proyecto:

- `bow_spray_flipbook.png`: atlas principal 1254×1254 RGBA, 8 columnas / 7 filas
  detectadas; grid manual editable inicialmente 8×8.
- `foam_breakup_mask.png`: máscara de ruptura, blanco conserva / negro recorta.
- `distortion_noise.png`: ruido RG o gris repetible, tratado como datos lineales.
- `droplets_atlas.png`: reservado para una fase posterior; V1 no lo emite.

El controlador los carga al abrir la escena o iniciar el juego si los slots del
inspector no tienen un asset asignado. También se pueden arrastrar archivos con
otro nombre a los campos correspondientes de `BowSprayRoot`.

La escena asigna explícitamente los cuatro recursos. Las imágenes originales
del root se conservan. El alpha del atlas principal tiene fondo residual;
la limpieza se hace en el shader, sin editar el PNG. Sin atlas, sigue
funcionando la previsualización procedural de la primera versión.
