# Bow spray de proa — primera versión visual

Integrado en `JetSki/BowSprayRoot`, con `BowSprayLeft` y `BowSprayRight`.
Las superficies subdivididas se curvan en el shader y salen de los laterales de la
proa (Z local negativo), extendiéndose hacia atrás (+Z). No tienen colisión,
no proyectan sombras y no escriben profundidad.

## Ocultación por sólidos y volumen visual

Se ha eliminado el overlay ciego: el shader compara la profundidad del spray
con la copia de profundidad **opaca anterior a las transparencias**. La moto,
un rider con materiales opacos y el escenario ocultan automáticamente el spray
si están delante; no hay listas de objetos ni capas especiales para cada uno.
Se mantiene prioridad 100 para componer después del océano con Optics/refracción,
que usa el paso de lectura de pantalla. La profundidad que el mar escribe
después no tapa el spray. El shader del océano, el FFT y la física no se modifican.

Esta separación usa el pipeline de transparencias: un objeto transparente que
no aparece en la profundidad opaca no puede servir de oclusor en esta copia.
Igualmente, una variante de mar completamente opaca sin Optics sí aparecería
en ella. El comportamiento probado corresponde al mar con Optics de este
proyecto y a la vista del editor. `solid_occlusion_bias` es una tolerancia en
metros (inicial 0.005), no una máscara para clasificar objetos.

Cada lado conserva su nodo y su anclaje, pero ahora tiene tres ribbons de
malla con separaciones y fases distintas. Es grosor visual, no simulación de
un fluido volumétrico. La opacidad por ribbon se compensa para que tres capas
no tripliquen la densidad en los solapamientos.

- `volume_layers`: 1–5, inicialmente 3; geometría compartida entre ambos lados.
- `volume_depth`: grosor del abanico (0.18 m inicialmente).
- `volume_verticality`: 0 conserva la apertura horizontal, 1 lo vuelve más vertical.
- `undulation_strength`: amplitud de ondas laterales (0.06 m inicialmente).
- `undulation_frequency`: número de ondas a lo largo de la superficie.
- `undulation_speed`: velocidad de ondas; 0 congela su fase sin parar los PNGs.

El grosor y la ondulación desaparecen en el borde del anclaje, por lo que el
origen no se despega del casco. Para recuperar la lámina anterior: una capa,
verticalidad 0 y amplitud 0. Se mantienen los extremos de tamaño por velocidad.

## Bordes suaves desde el lateral

Las láminas se desvanecen al mirarlas de canto, usando normales suaves de la
superficie ya curvada y ondulada. Se ha aumentado la subdivisión a 32×12 por
capa para suavizar la silueta. El recorte alpha tiene una transición mínima de
un píxel para reducir líneas duras incluso con `alpha_softness` muy pequeño.

- `edge_softness`: difuminado de los márgenes UV (inicial 0.15).
- `side_fade_strength`: 1 desvanece las superficies vistas de canto; 0 lo desactiva.
- `side_fade_angle`: ángulo desde el plano de la lámina al que recupera toda
  su opacidad (20° inicialmente); subirlo suaviza más una vista lateral.

Los controles están en **Soft Edges / Side View** de `BowSprayRoot`. El efecto
reduce densidad cerca del canto; sigue siendo volumen visual hecho de mallas.
Las caras vistas de frente y de detrás conservan su densidad.
Referencia: [normales y dirección de vista en shaders espaciales](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html).

## Variación de escala por hoja y altura tipo oleaje

En **Layer Scale / Height Motion** de `BowSprayRoot`:

- `layer_scale_variation_percent`: variación máxima ±% alrededor de `spray_scale`
  para cada hoja (inicial 10%). Con escala 0.89 y 10%, el rango permitido es
  0.801–0.979. Cada una de las 1–5 hojas tiene fase y ritmo distintos; también
  hay diferencia entre izquierda y derecha.
- `layer_scale_variation_speed`: ritmo base de la variación (inicial 0.65 ciclos/s).
- `sheet_height_variation_percent`: variación máxima ±% de la altura que resulta
  de interpolar `sheet_height_low` y `sheet_height` (inicial 15%). Afecta también
  las velocidades intermedias. Las alturas guardadas en el inspector no cambian.
- `sheet_height_variation_speed`: ritmo independiente de esa variación de altura
  (inicial 0.9 ciclos/s).

Se combinan ondas suaves de dos frecuencias para evitar un pulso perfectamente
regular. La altura comparte un pulso entre ambos lados, como respuesta visual
al oleaje, mientras las escalas de las hojas varían independientemente. Es un
movimiento visual; no añade muestreos del océano ni modifica fuerzas físicas.

La amplitud entra suavemente al aparecer el spray y baja con contacto seco o
en el aire. Los relojes se ralentizan al desvanecerse. Los porcentajes son
límites máximos mientras hay spray y contacto completo con el agua.
Los dos efectos se multiplican: la escala modifica largo, ancho y alto de cada
hoja; el porcentaje de altura añade una variación solo a su altura.

Poner un porcentaje a **0** elimina esa variación. Poner su velocidad a **0**
congela su fase actual. Cambiar la velocidad no provoca saltos de fase. Los
relojes son independientes de `anim_fps`, del ruido UV y de la ondulación lateral.
El origen de emisión permanece fijo: no se escriben posiciones, rotaciones ni
escalas de los nodos que colocas manualmente.

Referencias del pipeline: [lectura de pantalla](https://docs.godotengine.org/en/stable/tutorials/shaders/screen-reading_shaders.html)
y [reconstrucción de profundidad](https://docs.godotengine.org/en/stable/tutorials/shaders/advanced_postprocessing.html).

## Secuencia Splash_1 activa

El bow spray usa ahora los ocho PNG originales de `res://addons/jet_ski/common/visual/bow_spray/sequences/Splash_1/001.png`
hasta `008.png`, en ese orden y en bucle. Cada PNG es un fotograma completo:
no se corta con el grid del atlas. Se mezclan hasta cuatro fotogramas con
alpha correcto y suavizado temporal, incluyendo la transición 008→001. Cada lado mantiene
una fase distinta. Se conservan el anclaje al casco, las posiciones editadas,
el recorrido según pitch y altura, y la prioridad de dibujado delante del mar.

- `use_image_sequence`: activa esta fuente; desactivarlo recupera el atlas anterior.
- `image_sequence`: lista ordenada de los ocho archivos; permite reemplazar o añadir frames.
- `anim_fps`: velocidad de reproducción. Se conserva el ajuste existente de la escena del jet ski.
- `anim_speed_low` / `anim_speed_high`: multiplicadores de reproducción según
  velocidad horizontal, entre `speed_start` y `speed_full`.
- `animation_smoothing`: 0 mezcla dos PNG, 1 usa una mezcla temporal cúbica de
  cuatro. Valor inicial 0.75. Suaviza cambios, pero no reconstruye trayectorias
  de gotas ni genera nuevos fotogramas mediante optical flow.
- `distortion_speed`: reloj independiente del ruido UV; 0 congela el ruido.
- `sequence_frame_crop`: márgenes izquierda/arriba/derecha/abajo; inicialmente
  `(0.42, 0, 0, 0.5)`. Quita el espacio transparente a la izquierda y usa la mitad
  superior del abanico para colocar el punto de emisión en el borde del casco.
  Es recorte UV en el shader, no una modificación de los PNG.

Las imágenes tienen alpha transparente limpio. La instancia base usa
`alpha_from_luminance = false`, `alpha_cutoff = 0.01`, `alpha_softness = 0.03`
y `alpha_gain = 1`. La máscara y la distorsión anteriores siguen modulando
el resultado. Los archivos de `Splash_1` se referencian directamente y no se editan.
Con una secuencia vacía se recupera el atlas como respaldo.

## Qué mueve cada control

`anim_fps` avanza por los PNG de `Splash_1`, no controla los FPS del juego ni
deforma por sí mismo las mallas. A 0 se pausa la fase actual del PNG; el ruido
UV y el anclaje al casco pueden seguir moviéndose. Para parar también el ruido,
poner `distortion_speed = 0` (o `distortion_strength = 0` para quitar el efecto).

La tasa efectiva es `anim_fps × lerp(anim_speed_low, anim_speed_high, velocidad)`.
Con los valores iniciales 0.8/1.3 y `anim_fps = 3`, recorre 2.4 PNG/s a baja
velocidad y 3.9 PNG/s a máxima. Con 30 recorre 24–39 PNG/s: solo ocho imágenes
se repiten en 0.33–0.21 segundos. Esa repetición rápida puede seguir pareciendo
nerviosa aunque haya interpolación. Para un movimiento suave empezar con
`anim_fps` entre 4 y 8, `animation_smoothing = 0.75–1` y
`distortion_speed = 0.2–0.4`; subir FPS acelera los PNG y subir `distortion_speed`
acelera el movimiento UV. El reloj de fotogramas integra la tasa nueva, para
evitar saltos de fase al cambiar FPS o acelerar la moto.

## Forma entre poca y mucha velocidad

`sheet_length_low`, `sheet_width_low`, `sheet_height_low` definen la forma a
baja velocidad. Los campos existentes `sheet_length`, `sheet_width`,
`sheet_height` son los extremos de máxima velocidad y conservan tus ajustes.
Las tres dimensiones pasan suavemente entre ambos extremos usando la
velocidad real. `spray_scale` multiplica todo el tamaño; ya no hay un segundo
factor de escala oculto en el shader. Los puntos de anclaje siguen en el casco.

## Color sin editar los PNG

- `spray_tint`: tinte general.
- `spray_whiteness`: 0 conserva el color; 1 deja blancas las gotas visibles.
- `spray_saturation`: 0 quita el color azul, 1 conserva la saturación original.
- `spray_brightness`: 1 mantiene brillo, menos oscurece y más aclara.

Para spray blanco: `spray_whiteness = 1`, tinte blanco y brillo alrededor de
1. Para conservar algo de azul: blancura 0.5–0.8 y saturación 0.3–0.6. Estos
controles cambian RGB; `spray_opacity` y `alpha_gain` siguen controlando alpha.

## Agua transparente, normales y brillos

En **Transparent Water / Highlights** de `BowSprayRoot`:

- `water_appearance_enabled`: ON activa película de agua y reflejos; OFF muestra
  solo espuma iluminada, conservando la opacidad general.
- `foam_opacity`: multiplica la densidad blanca del PNG. Inicial 1 para conservar
  tu ajuste; bajar a 0.2–0.35 deja ver más agua y brillos.
- `water_opacity`: opacidad de la película de agua dentro de la silueta del PNG.
  Inicial 0.12; un punto de partida para el aspecto de agua es 0.12–0.18.
- `water_tint`: tinte ligero de esa película, independiente del color de espuma.
- `normal_texture`: normal tangent-space; inicialmente la textura procedural
  `bow_spray_water_normal.tres`. Es ruido seamless convertido a normal por Godot,
  con mipmaps. Se puede sustituir por una normal de agua o espuma.
- `normal_strength`: amplitud del relieve visual (0 lo elimina; inicial 0.8).
- `normal_tiling`: repeticiones del ruido sobre la hoja, inicialmente `(4, 3)`.
- `normal_scroll_speed`: velocidad del movimiento UV de las normales (inicial
  0.35). Su reloj es independiente de los PNG y de la distorsión; 0 lo congela.
- `water_roughness`: rugosidad. Valores bajos (0.08–0.18) dan brillos más definidos;
  subirlo los hace más anchos y suaves.
- `highlight_strength`: intensidad de reflejos especulares (inicial 1.5; 0 los
  elimina). Empezar con 2 si se busca más brillo con poca espuma.

`spray_opacity` sigue siendo la opacidad global: 0 oculta espuma, agua y brillos.
Para aclarar el spray manteniendo reflejos visibles, reducir primero
`foam_opacity` y ajustar después `water_opacity` y `highlight_strength`.
La transparencia de agua y espuma se combina y se compensa entre las capas.
El agua conserva el recorte del sprite, los fades de bordes/contacto y el breakup:
no aparece un rectángulo transparente completo alrededor del spray.

El shader usa iluminación real tanto para la espuma como para el agua: no hay
emisión. Los PNG, el tinte y el brillo definen el albedo; el sol, la luna, el
ambiente y las luces locales determinan su aspecto iluminado. Sin iluminación
no aparece spray luminoso. La espuma es más rugosa que la película de agua.
También recibe sombras, conservando la ocultación manual del casco. Una normal map
requiere tangentes: estas se calculan sobre la malla ya ondulada, también para
la cara posterior. El fade lateral usa la normal geométrica, para que el ruido
no haga reaparecer los bordes. Los brillos responden al ángulo de cámara y luz.

No se añade lectura de color de pantalla ni un paso nuevo de refracción. Se
mantienen el orden respecto al mar, la ocultación por sólidos y la transición
underwater existente. Este cambio no modifica océano, FFT ni física.

Referencias: [normales e iluminación en shaders espaciales](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html)
y [normal procedural con NoiseTexture2D](https://docs.godotengine.org/en/stable/classes/class_noisetexture2d.html).

## Ocultar el spray cuando el jet ski se sumerge

La profundidad ya calculada de los cuatro contactos del casco controla una
supresión independiente. Se usa el contacto menos sumergido para distinguir
el casco completo bajo el agua de la flotación normal o una proa/cola inmersa.
La cámara underwater no determina este estado: depende del vehículo.

En **Submersion Suppression** de `BowSprayRoot`:

- `submersion_fade_start_depth`: empieza a reducir cuando los cuatro contactos
  superan esta profundidad (inicial 0.35 m).
- `submersion_hide_depth`: oculta por completo ambos lados cuando el contacto
  menos profundo llega a este valor (inicial 0.60 m).

Al alcanzar el límite se apagan inmediatamente las mallas, incluyendo espuma,
agua transparente y reflejos. Al salir reaparecen con el suavizado habitual.
Un dato de contacto inválido conserva la última supresión para evitar destellos.
Los parámetros se refieren a la profundidad de los contactos, no a la posición
del origen del nodo. Se pueden ajustar al calado del casco. No se añaden consultas
FFT ni se modifica la física, el océano o el comportamiento de la cámara.

Seleccionar `BowSprayRoot` en el inspector:

- `bow_spray_enabled`: ON/OFF de ambos lados.
- `spray_render_priority`: 100 por defecto, para componer el spray después de
  los materiales transparentes del mar. Se ordena desde la proa, no desde el
  centro de los bounds ampliados por el shader. La ocultación por sólidos se
  resuelve con la copia de profundidad opaca; no se dibuja ciegamente encima
  de la moto. Ver los límites del pipeline indicados arriba.
- `speed_start` / `speed_full`: inicio y máxima intensidad, en m/s horizontales
  reales (`linear_velocity.xz`), independientemente del throttle.
- `spray_opacity` / `spray_scale`: opacidad y tamaño general.
- `distortion_strength`: distorsión en UV locales del fotograma.
- `breakup_strength`: influencia de la máscara; 0 la desactiva, 1 recorta completamente.
- `steering_tilt_strength`: inclinación visual máxima en radianes.
- `sheet_length_low`, `sheet_width_low`, `sheet_height_low`: forma a poca velocidad.
- `sheet_length`, `sheet_width`, `sheet_height`: forma a máxima velocidad.
- `nose_up_slide` / `nose_down_slide`: recorrido longitudinal hacia el centro
  al levantar el morro y hacia la punta al bajarlo.
- `attachment_pitch_full_degrees` / `attachment_response`: ángulo de máximo
  recorrido y suavizado del deslizamiento.
- `attachment_height_influence` / `attachment_height_full`: aportación opcional
  de subir/hundirse respecto al agua ya muestreada, solo al desplazamiento
  longitudinal. Usar influencia 0 para que el recorrido dependa solo del pitch.
- `attachment_slide_enabled`: desactivar para fijar el origen al punto elegido.
- `preview_in_editor`, `preview_speed`, `preview_steering`: previsualización
  del editor; no sustituyen los datos reales durante el juego.

Se leen los contactos ya calculados por `WaterPhysicsSystem`. Solo contacto
trasero reduce la intensidad al 15%; contacto en ambos lados de proa la permite
completa. En aire se limita inmediatamente el factor de contacto al 2%. Sin
contacto y sin estado de aire confirmado, el spray desaparece con un fade corto.
Se suavizan intensidad y steering sin modificar ningún estado del vehículo.

Los sprites están anclados al casco: se conserva la posición y rotación que se
edita en cada sheet y heredan todos los movimientos del jet ski. Ya no se
corrige su altura para seguir el mar. Solo se desliza el origen por el eje
longitudinal del casco, tomando las posiciones editadas como referencia. Los
antiguos `waterline_offset` y `waterline_follow_limit` se han retirado.

**La posición, rotación y escala de `BowSprayLeft` y `BowSprayRight` son siempre
editables**, incluso con `preview_in_editor` activado. El controlador no escribe
sus transformaciones ni restaura posiciones guardadas al apagar el preview.
Seleccionar cada hijo y moverlo con el gizmo o con **Transform** del inspector;
no hace falta cambiar su jerarquía ni apagar la previsualización. Se respetan
las posiciones ya guardadas en la escena.

El recorrido opcional por pitch/heave se aplica como `attachment_offset` a los
vértices del shader, separado de la transformación manual. La posición del
nodo es el anclaje base. Para que la geometría salga exactamente de ese anclaje
en cualquier inclinación, desactivar `attachment_slide_enabled` en `BowSprayRoot`.

Se puede mover `BowSprayRoot` dentro de `VisualRoot` u otro nodo visual del
jet ski: el controlador encuentra el vehículo ascendiendo por la jerarquía.
Conservar la transformación global al reparentar para mantener la colocación
y orientación de los sprites. No mover los dos hijos fuera de `BowSprayRoot`.
`preview_pitch_degrees` permite revisar el recorrido en el editor.

## Assets integrados

Copias de los originales del root en `bow_spray/textures/`, asignadas en la escena:

| Archivo | Campo | Uso |
| --- | --- | --- |
| `bow_spray_flipbook.png` | `flipbook_texture` | Atlas anterior de respaldo, 1254×1254 |
| `foam_breakup_mask.png` | `breakup_mask` | Máscara independiente, blanco conserva / negro elimina |
| `distortion_noise.png` | `distortion_texture` | Ruido gris repetible, canales muestreados con offsets distintos; datos lineales |
| `droplets_atlas.png` | `droplets_atlas` | Asignado y reservado; no emite gotas secundarias en esta V1 |

El atlas se recorre de izquierda a derecha y de arriba abajo. Los parámetros
manuales `frames_x` y `frames_y` mantienen 8×8 por defecto, y `anim_fps` comienza
en 20. `auto_detect_atlas_grid` analiza una imagen reducida en memoria una sola
vez por cambio de textura: para este asset detecta 8×7 (56 frames). Así se evita
partir los sprites con una cuadrícula 8×8 incorrecta. Desactivarlo para usar la
cuadrícula manual. `flipbook_frames` limita el número de fotogramas al tamaño
efectivo del grid. La detección es una heurística; otros atlas pueden requerir
configuración manual. Se interpolan fotogramas; un margen
de medio texel evita tomar la celda contigua. Para el primer atlas usar filtrado
lineal sin mipmaps; si se usan mipmaps, añadir gutters a cada celda.
U recorre proa→cola del spray y V casco→borde exterior. La máscara usa esas
mismas UV y no se interpreta como un segundo atlas.
`flipbook_flip_y = true` coloca la base inferior de estos sprites en la línea
de agua (V de la malla = 0). La curvatura mantiene ese borde a altura constante.

El atlas anterior tiene alpha residual en el fondo. Para ese asset se pueden
usar `alpha_from_luminance = true`, `alpha_cutoff = 0.12` y
`alpha_softness = 0.10`, `alpha_gain = 1.5`. Subir el cutoff elimina más fondo; bajarlo conserva
más niebla fina. `alpha_gain` ajusta densidad sin cambiar `spray_opacity`.
`frame_crop` permite recortar márgenes de cada celda: izquierda, arriba,
derecha y abajo, en fracciones del fotograma. Los PNG originales no se editan.

Cada lado y cada vehículo tienen material propio para evitar compartir
intensidad y fase. Si se retira el atlas, se utiliza la apariencia procedural
de respaldo. La máscara y el ruido no se interpretan como flipbooks.

Esta implementación no añade estela, espuma trasera ni splash de aterrizaje.
Los efectos anteriores de `jet_ski_water_contact_fx.gd` siguen siendo independientes.

## Verificación

`validation/bow_spray_preview.tscn` permite revisar los dos lados con casco
inmóvil sobre una superficie plana de presentación. No carga el océano. Los
parámetros `display_speed`, `display_steering`, `display_airborne`,
`display_pitch_degrees` y `display_heave` pertenecen
solo a esa escena de validación.

`validation/bow_spray_visual_validation.gd` comprueba velocidad horizontal,
contactos, aire, steering, ON/OFF, slots de textura, rangos degenerados y
aislamiento de materiales y estado físico en una fixture sin simulación.
También comprueba que mover/rotar/escalar un hijo durante las actualizaciones
no se sobrescribe, y que el offset sigue el eje del casco.

`validation/bow_spray_editor_placement_validation.gd` se ejecuta con
`--editor --headless --script` y comprueba la rama real de previsualización:
colocación manual mientras está activa, nuevos movimientos y apagado sin
restaurar posiciones antiguas.

`validation/bow_spray_occlusion_validation.gd` prueba píxeles renderizados del
shader de producción: spray sobre agua transparente que escribe profundidad,
ocultación por un sólido delante, visibilidad con sólido detrás y ocultación
sin mar (editor). Pasa en Forward+/D3D12 y en Compatibility/OpenGL.
Incluye vistas de canto con y sin desvanecido y ambas caras de la superficie.

`validation/bow_spray_water_highlights_validation.gd` prueba reflejos reales con
opacidad de agua 0.2 y espuma 0: cambiar la normal cambia el brillo, fuerza 0
recupera la normal plana, apagar la luz elimina los brillos y opacidad global
0 oculta todo. Pasa en Forward+/D3D12 y Compatibility/OpenGL. La prueba runtime
de transición underwater también pasa con el nuevo material.
