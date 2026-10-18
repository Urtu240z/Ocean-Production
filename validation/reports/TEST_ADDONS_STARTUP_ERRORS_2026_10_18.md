# Errores de arranque de Test Addons

Proyecto inspeccionado: `C:/Users/DEV/Documents/test-addons`. Godot 4.7.1, Forward+, D3D12, RTX 4070 Laptop. Se han leído la escena `Level_1.tscn`, la configuración del proyecto, los addons instalados y el registro actual y anterior en `C:/Users/DEV/AppData/Roaming/Godot/app_userdata/Test Addons/logs/`.

En la primera fase no se detuvo la partida del usuario ni se guardaron escenas o cambiaron ajustes de Test Addons. La conexión MCP disponible no correspondía a una instancia accesible de este proyecto. El servicio de grafo estaba desconectado y se comprobó el código directamente; posteriormente volvió a estar disponible. La continuación y el cambio aplicado se detallan al final.

## Tres errores rojos: una cadena de creación de textura fallida

Los registros repiten la misma secuencia de la captura:

1. `Too many mipmaps requested ... (4294967295), maximum allowed: (1)`.
2. `Attempted to name invalid ID: 0`.
3. `Condition "p_named_texture.texture.is_null()" is true` en `RenderSceneBuffersRD::update_sizes`.

El segundo y tercer mensaje son consecuencia de la textura que no se pudo crear. El valor 4294967295 corresponde a -1 convertido a entero sin signo de 32 bits; no es una cantidad solicitada de forma intencionada por el usuario.

Se ha reproducido **la secuencia exacta de los tres mensajes** en un proyecto mínimo separado, usando la misma versión de Godot y D3D12, sin Ocean, Jet Ski, Terrain3D ni otros addons. Una superficie con `hint_screen_texture, filter_linear_mipmap` activa los buffers de desenfoque. Se pasa de una imagen interna de 128×128 a 1×1 mediante un viewport de 2×2 con escala 3D 0,25. Un CompositorEffect de diagnóstico confirma `internal_size=(1,1)`.

Control: manteniendo un viewport mínimo de 8×8 con la misma escala 0,25, el tamaño interno mínimo es 2×2 y desaparecen los tres errores. Ambas pruebas finalizan con código 0; la variante insegura registra los errores, la segura no. No son benchmarks y no se ha cargado una segunda copia de la escena del usuario.

La implementación del motor calcula los mipmaps del buffer y resta uno al crear el segundo buffer. Con el tamaño mínimo aparece el desbordamiento, seguido de la asignación de nombre y la consulta de tamaños a un RID inválido. Fuente primaria: [Godot, RenderSceneBuffersRD::allocate_blur_textures y create_texture_from_format](https://github.com/godotengine/godot/blob/master/servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.cpp).

### Qué está y qué no está confirmado en Test Addons

Confirmado: misma secuencia, versión y backend; el océano usa la lectura de pantalla; el Environment de Level_1 también tiene el SSR integrado de Godot activado; el editor usa ejecución embebida (`embed_size_mode=2`). Esa exportación del addon solo contiene `ocean_sspr.gd`, `ocean_sspr_effect.gd` y sus shaders: no contiene Planar ni Kawase.

**No se ha medido todavía el tamaño interno transitorio de la ejecución real de Level_1**. El arranque/redimensionado de la ventana embebida es el candidato principal, pero no queda probado solo por reproducir el mismo fallo en 1×1. La prueba siguiente es comparar el arranque de Level_1 en ventana independiente y embebida, registrando el tamaño interno en los primeros fotogramas. No se atribuye el problema a Planar ni se presenta como corregido en el proyecto real.

El remedio debe evitar solicitar buffers de desenfoque/mipmaps con una imagen interna de 1×1. Un tamaño mínimo de ventana puede servir como workaround si se confirma el origen embebido; no se ha impuesto ese cambio de interfaz al proyecto. Un simple `return` dentro del callback de Ocean no garantiza corregirlo: el motor puede preparar esos buffers antes de ejecutar el callback, y otros materiales/SSR integrado también pueden pedirlos.

Reproductor local: `temp/mip_startup_probe/`. Ejecutar su `probe.gd` sin argumentos para el control seguro, o añadir `-- --unsafe` para el caso 1×1. La carpeta es temporal y no forma parte de la exportación del addon.

## Dos avisos amarillos de Terrain3D

### Método de interpolación obsoleto

`instance_reset_physics_interpolation() is deprecated` corresponde a la API antigua de RenderingServer empleada por Terrain3D. Está documentado por sus mantenedores: [Terrain3D #934](https://github.com/TokisanGames/Terrain3D/issues/934) y [explicación del cambio de Godot](https://github.com/godotengine/godot-docs/issues/11119). No equivale a que los resets normales de `Node3D.reset_physics_interpolation()` del vehículo sean incorrectos. No se han eliminado esos resets ni sustituido DLLs durante una ejecución activa.

Acción: revisar una versión/binario de Terrain3D compatible con esta versión de Godot y su corrección de esta llamada obsoleta. Ocultar las advertencias globalmente no corrige la incompatibilidad.

### Assets sin archivo propio

`free_editor_textures requires Assets be saved to a file` coincide directamente con la escena: `Terrain3DAssets_3bv4q` está declarado como subrecurso dentro de `Level_1.tscn`, y Terrain3D lo referencia mediante `SubResource`.

Acción preferente: guardar el recurso Assets de Terrain3D en un archivo externo `.tres` y conservar la referencia desde Terrain3D. Alternativa: desactivar `free_editor_textures`, aceptando que no se liberen esas texturas del editor. No se ha guardado automáticamente `Level_1.tscn`, porque la captura muestra una escena con cambios sin guardar.

## Hallazgo adicional

El registro contiene también `BasisUniversal cannot unpack level 4`, fuera de los cinco mensajes mostrados. Requiere investigar por separado la textura/importación comprimida que lo produce; no se le atribuye la cadena de errores de RenderSceneBuffersRD sin evidencia adicional.

## Continuación: ejecución real y protección aplicada

Se ejecutó `Level_1.tscn` completo a 960×540 durante 120 fotogramas, con un medidor de RenderSceneBuffersRD. Resultado: código 0, tamaño interno 960×540 y ninguno de los tres errores rojos. Los avisos de Terrain3D y el mensaje de BasisUniversal permanecen.

Se probó también el arranque desde un editor separado con ejecución embebida. Para no guardar ni alterar la escena original se utilizó una copia temporal sin su UID original y con un script de diagnóstico heredado del host. Tamaños medidos: 922×731 y 922×656; ninguno fue 1×1 y no apareció la cadena de mipmaps. **El modo embebido por sí solo no ha reproducido el fallo del usuario; el disparador original sigue sin aislarse.** Los errores de cierre de esa sesión de editor automatizado se distinguen del registro del juego y no se usan como evidencia de errores de Level_1.

Se ha añadido `addons/jet_ski/common/visual/jet_ski_render_size_guard.gd` y conectado al host `addons/jet_ski/examples/ocean_jet_ski_demo.gd`, tanto en Production como en la copia instalada de Test Addons. Solo pausa el render 3D del viewport si su tamaño interno estimado baja de 16 píxeles en algún eje; la interfaz y la simulación siguen funcionando. Se reanuda automáticamente cuando el área vuelve a ser válida. Vigila redimensionados y cambios de escala 3D; respeta un `disable_3d` que ya estuviera activado y desconecta sus señales al salir. No cambia la resolución, el método de escalado, SSR, materiales ni recursos de la escena.

Verificación GPU del caso que reproduce el fallo:

- Sin protección: viewport de 2×2 y escala 0,25 → callback con imagen 1×1 → los tres mensajes exactos de la captura.
- Con protección: pausa 3D antes de dibujar ese tamaño, cero errores y reanudación al recuperar tamaño válido.
- `validation/render_size_guard_runtime.gd`: código 0, dos pausas y dos reanudaciones (redimensionado y cambio de escala), `failures=[]`; el callback GPU nunca recibe 1×1. También comprueba que se respeta un `disable_3d` previo.
- Level_1 completo tras aplicar el cambio: código 0, 120 fotogramas a 960×540, sin errores rojos de mipmaps.

Es una **mitigación comprobada del mecanismo reproducido**, no la prueba de que cualquier error futuro de textura quede resuelto. Si reaparece en el arranque habitual, hay que capturar el tamaño interno y el viewport concreto que lo origina; podría ser otra vista que no dependa de este host.

Solo se instalaron el helper nuevo y el cambio del script host en Test Addons. Se conserva una copia exacta del host anterior en `temp/test_addons_original_demo.gd` de Production. `Level_1.tscn` y `project.godot` no se han guardado ni alterado para aplicar la protección. Los avisos de Terrain3D siguen pendientes de las acciones específicas indicadas arriba; no se han silenciado globalmente ni cambiado DLLs.
