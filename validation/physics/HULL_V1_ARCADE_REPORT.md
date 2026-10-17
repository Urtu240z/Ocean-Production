# HULL V1 normal: clavada, rebote y salida

Primera pasada de conducción sobre la rama local. Sólo se activa con
`HULL_BUOYANCY_V1`, respuesta `HULL_V1_PREVIOUS` y `hull_v1_arcade_enabled`.
El océano, sus consultas, el casco y las inercias no se modifican.

## Revisión 5: picado de entrada y avance horizontal sumergido

La V1 normal distingue ahora entrada y mantenimiento. Al ganar profundidad
(inicio por defecto a 0.6 m), el objetivo pasa gradualmente de los 38° de
picado a 0°. La mezcla tarda como mínimo 0.35 s y queda retenida durante el
truco. El control de actitud compensa los momentos existentes usando la
inercia completa, estabiliza pitch/roll y conserva la aceleración de yaw.
Lean front se interpreta como mantener el truco: su par de peso de picado y
su amortiguación manual se atenúan a medida que entra el control horizontal.

Se elimina el límite de 1.25 s sólo para esta variante. Se mantiene hasta
soltar lean front, pulsar lean rear, bajar de 3 m/s o alcanzar los límites
de seguridad. El motor pierde progresivamente su autoridad durante el
avance horizontal para que el truco avance por inercia y el rozamiento pueda
reducir la velocidad incluso con gas mantenido. Al salir vuelve la
flotabilidad con la transición existente. Una salida exige soltar y volver
a pulsar lean front antes de repetir: no se reinicia sola si vuelve a subir
la velocidad mientras la tecla sigue apretada.

Nuevos ajustes de **HULL V1 Normal - Arcade**:

- `hull_v1_submarine_level_start_depth_m = 0.6`
- `hull_v1_submarine_level_transition_seconds = 0.35`
- `hull_v1_submarine_level_rate = 4.0`
- `hull_v1_submarine_exit_speed_mps = 3.0`

El temporizador `submarine_max_duration` queda para la variante anterior;
Heavy y Legacy no habilitan el mantenimiento nuevo.

Validación de la escena completa: PASS. Profundidad máxima del origen
1.503 m, punto más alto del casco hasta 1.316 m bajo la superficie. Durante
120 ticks de mantenimiento ya nivelado se registra un máximo de 3.10° de
pitch y roll prácticamente nulo; sigue activo tras el límite anterior.
Las comprobaciones funcionales adicionales verifican salida por liberación,
por lean rear y por velocidad baja con gas y lean front mantenidos; esta
última conserva 338 ticks de truco y sale por `low_speed`, vuelve a flotar
y no se reinicia al acelerar sin soltar. Las ondas sintéticas conservan
41 ticks sin contacto frente a 45 con las ayudas desactivadas. Todas pasan.

## Revisión 4: bloqueo en la escena de juego y trim bajo gas

Se revisó el vídeo `20261015-1307-51.3351149.mp4`. La escena real
`jet_ski_ocean.gd` asignaba `ski.submarine_dive_enabled = false` antes de añadir
el vehículo. Por ello las correcciones del controlador quedaban anuladas en
esa escena. Se retira únicamente esa anulación: se respeta el valor editable
del vehículo. Las pruebas anteriores instanciaban el vehículo sin pasar por
este arranque y no detectaban la diferencia.

Se añade **Powered Running Trim - HULL V1 Normal**: mínimo suave de 4° bajo
gas, intensidad 4/s y par máximo 6000 N·m, mediante pitch y sin fuerzas
verticales. Usa el tensor completo y cuenta los pares ya aplicados. También
funciona con gas mantenido cuando el limitador reduce el empuje instantáneo.
Se inhibe con lean front/rear, submarine/recuperación, ausencia de soporte de
agua, suelo, despegue y trucos. El límite superior y la prioridad de lean rear
se conservan. Es configurable con `powered_trim_enabled`,
`powered_trim_min_angle_degrees`, `powered_trim_response_rate` y
`powered_trim_max_torque_nm`.

`gameplay_submarine_trim_validation.gd` ejecuta la escena completa con su
renderizador D3D12 y proveedor CPU Lite reales, el perfil WATER RACE y la
inercia combinada que configura el arranque. Sólo en el montaje de prueba
se usa agua plana y una posición inicial de mar abierto a x=512, para evitar
la rampa sólida guardada en z=-67. No se alteran esos valores en los archivos
del océano. El modo headless no inicializa este proveedor y no cuenta como
validación satisfactoria de la escena completa.

Resultado: **PASS**, velocidad de entrada **31.61 m/s**, mínimo de pitch en
alta velocidad **3.999°**. Lean front llega con raw=-1, activa el truco en el
primer paso observado y alcanza **1.532 m** de profundidad del origen; el
punto más alto del casco queda **0.153 m** bajo la superficie. El trim es
exactamente cero mientras se pulsa lean front, y lean rear desactiva ambos
guardas automáticos. La comprobación adicional de ondas sintéticas conserva
saltos: **41 ticks secos** con ayudas y trim (45 con ayudas desactivadas).
Todas las regresiones funcionales pasan. Son pruebas de comportamiento, no
benchmarks ni capturas de rendimiento.

Para aplicar la corrección de arranque a una ejecución ya abierta hay que
detenerla y volver a ejecutar la escena: eliminar la asignación de `_ready`
no cambia retroactivamente un vehículo ya creado con el truco desactivado.

## Revisión 3: entrada manual desde navegación recta

Se reprodujo la secuencia del usuario acelerando desde reposo, con orientación
inicial neutra y sin saltos ni preinclinación. El requisito heredado de 25° de
morro abajo también se aplicaba a la entrada manual desde superficie: retrasaba
la fuerza de hundimiento mientras el peso del piloto levantaba la popa.
La prueba anterior de clavada ya arrancaba a -28° y omitía este fallo.

La entrada manual de superficie ahora acepta una actitud normal de navegación,
incluido el morro levantado por la aceleración. Mantiene contacto frontal,
velocidad mínima, roll y límites de seguridad. La condición de salida por morro
arriba distingue esta entrada de la entrada desde aterrizaje para no cancelar
el truco inmediatamente mientras comienza el picado. Legacy y los criterios
de entrada desde aterrizaje conservan sus ángulos originales.

Prueba reproducida antes del arreglo: entrada a 29.35 m/s y -1.77° de pitch,
lean front en tick 180; el truco se activaba en tick 212 y no cubría todo el
casco. Después: se activa en tick 181, profundidad del origen 1.53 m, todo el
casco al menos 0.157 m bajo el agua y referencia del piloto hasta 0.724 m.
Segundo caso acelerando desde reposo: entrada a 20.62 m/s con morro todavía
16.25° arriba; lean front en tick 60, truco activo en tick 61, profundidad
1.47 m y casco completo al menos 0.129 m bajo agua. Ambas pruebas usan inputs
reales del controlador y no escriben transforms ni velocidades durante el
recorrido. Resultado de todos los casos funcionales: PASS.

## Causas y cambios

- La resistencia distribuida del agua, aplicada lejos del centro de masa,
  genera momentos de giro cuando entra una proa inclinada. Al clavarse,
  la ayuda sustituye progresivamente la fuerza horizontal neta del agua por
  frenado en la dirección de la velocidad relativa. Compensa la aceleración
  de yaw de los momentos del agua usando el tensor completo de inercia.
  Conserva la flotabilidad vertical y las aceleraciones de pitch/roll.
  La amortiguación de yaw cede ante steering y el agarre lateral arcade se
  atenúa durante la clavada. No se fija el transform ni la velocidad.
- El submarine original sólo podía iniciarse al recuperar contacto desde
  el aire. La V1 normal admite además entrada desde la superficie con lean
  front, conservando las condiciones de velocidad, roll y seguridad; el ángulo
  mínimo de picado sólo se exige a la entrada desde aterrizaje.
  Durante la maniobra, la flotabilidad a inmersión completa puede bajar al
  85% del peso. La revisión 2 añade control vertical central de inmersión:
  compensa la oposición vertical del agua durante el truco y busca una
  profundidad del origen de 1.4 m, con descenso de hasta 2.2 m/s y
  aceleración neta acotada. Esto hunde el conjunto sin aplicar más pitch
  ni escribir posiciones o velocidades. Entrada y recuperación se mezclan
  gradualmente; soltar lean front termina la maniobra. Se atenúa el motor
  al clavar la proa para que la reducción de drag no produzca aceleración.
- El retorno desde inmersión pierde energía con una resistencia central
  exclusivamente al ascenso relativo al agua. La revisión 2 elimina su
  aplicación general en navegación: sólo se arma después de superar 0.55 m
  de profundidad del origen y sumergir al menos el 90% del volumen del casco.
  Se desvanece al resurgir y se borra al quedar seco, resetear o cambiar de
  modo. No actúa durante el submarine activo. Es cero en reposo y descenso.
  Las salidas ordinarias de olas conservan su ascenso. También se evita
  interpretar una ola cubriendo sólo la proa como inmersión profunda.
- La limpieza de velocidades angulares de salida también se admite en V1
  normal y respeta sus ejes manuales. Se suma ayuda de actitud durante
  0.22 s desde la pérdida real de soporte; los ejes con entrada manual
  quedan libres. Lean conserva su control aéreo y steering permite yaw.

Heavy y Legacy quedan fuera de estas ayudas. El selector de respuesta y
el modo de flotabilidad inicial del proyecto se conservan.

## Inspector del JetSki

Grupo **HULL V1 Normal - Arcade**:

| Parámetro | Valor inicial | Efecto |
|---|---:|---|
| hull_v1_arcade_enabled | true | A/B de esta pasada en V1 normal |
| hull_v1_bow_braking_mps2 | 3.0 | Frenado máximo durante clavada completa |
| hull_v1_buried_thrust_factor | 0.15 | Motor que queda con proa enterrada |
| hull_v1_bow_yaw_damping_rate | 5.0 | Reducción del giro residual al clavar |
| hull_v1_rebound_damping_rate | 5.0 | Resistencia al ascenso de recuperación profunda |
| hull_v1_rebound_min_depth_m | 0.55 | Profundidad previa que arma la recuperación, con 90% del casco sumergido |
| hull_v1_submarine_target_depth_m | 1.4 | Profundidad objetivo del origen del JetSki durante el truco |
| hull_v1_submarine_sink_speed_mps | 2.2 | Velocidad máxima objetivo de descenso del truco |
| hull_v1_submarine_support_ratio | 0.85 | Fracción de peso soportada a inmersión completa durante dive |
| hull_v1_takeoff_assist_seconds | 0.22 | Ventana de ayuda de salida |
| hull_v1_takeoff_level_rate | 3.0 | Intensidad de corrección de actitud |
| hull_v1_air_yaw_rate | 0.9 | Velocidad de giro objetivo con steering aéreo |
| hull_v1_air_yaw_torque_nm | 900 | Límite del par manual de yaw aéreo |

## Validación funcional

Godot 4.7.1, sin render ni FFT, con el controlador y escena reales del JetSki
y proveedor sintético de agua plana. No se ha armado WPR ni ejecutado una
captura o benchmark de rendimiento.

`hull_v1_arcade_validation.gd` verifica fuerzas disipativas, ausencia de
resistencia en seco y descenso, equilibrio estático, tensor inclinado,
prioridad de ejes manuales, giro aéreo y exclusión de modos. Compara la
clavada y recuperación con la ayuda apagada/encendida y comprueba que
soltar lean front permite recuperar la superficie.

Resultados de la prueba concreta de clavada (28° de morro abajo, 10° de
roll, 16 m/s iniciales; lean front durante 90 ticks): desviación máxima de
rumbo **54.16° -> 1.17°**. Con ayuda, el origen del cuerpo alcanza unos
**1.55 m** bajo la superficie y su velocidad horizontal final es **12.76 m/s**.
El punto más alto de todo el casco queda **0.20 m bajo el agua**; la referencia
del piloto virtual (la ya configurada para su inercia, no una malla de cabeza)
queda hasta **0.73 m bajo el agua**. Se comprueba que soltar lean front termina
el truco y su recuperación especial.
En la liberación vertical desde -1.25 m, el máximo ascenso baja de
**1.64 a 1.42 m/s** y la altura máxima de **0.300 a 0.289 m**.

La prueba de despegue siembra una pérdida de soporte controlada con el
cuerpo ya en el aire: valida la rama de salida y su corrección progresiva,
no reproduce una ola FFT ni demuestra la altura de salto de una ola real.
También se comprueba steering aéreo con entrada real del sistema de control.

La revisión 2 incluye además recorrido físico real sobre ondas sintéticas
de 1 m de amplitud, con motor, sin sembrar soporte previo ni escribir el
estado durante el recorrido. En 150 ticks, se registran **65 ticks sin
contacto** con las ayudas (45 con ellas desactivadas), con velocidad vertical
máxima de **6.28 m/s**. Valida que puede despegar de olas y que la ayuda de
salida se activa por pérdida real de contacto. No es una captura del océano
FFT concreto del usuario ni una comparación de rendimiento.

Resultado: **PASS**. Falta valorar la sensación en conducción real con las
olas y entradas del jugador; estos valores son un punto de partida ajustable.
