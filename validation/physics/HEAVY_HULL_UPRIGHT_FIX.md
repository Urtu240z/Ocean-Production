# Heavy Hull — inclinación suave y enderezado

Base: `392b1fd`, estado local actual conservado.

La elevación hidrostática de HULL_V1 ya apuntaba contra la gravedad. La
inclinación provenía principalmente de los momentos de fuerzas distribuidas
y de la componente lateral de la amortiguación sobre la normal de cada ola.
El aumento de inercia anterior no impedía que esos momentos volcaran la moto.

En HEAVY HULL se añade una ayuda de gameplay para desacoplar la inclinación
del casco de la pendiente del mar, manteniendo la respuesta vertical:

- Componentes laterales de amortiguación normal al 10%; su componente
  vertical se conserva exactamente para la misma muestra/pose/velocidad.
- Momentos hidrostáticos y de amortiguación normal en pitch/roll al 12%,
  mediante un torque compensador. La fuerza neta se conserva; no se escala
  el momento local de yaw. El arrastre tangencial y el motor no se modifican.
- Enderezado amortiguado hacia la vertical de la gravedad, no hacia la
  normal del mar. Sólo actúa con volumen sumergido válido, se desvanece
  al salir del agua y no modifica directamente transformaciones o velocidades.
- Respuesta angular críticamente amortiguada, tasa inicial 4 /s y aceleración
  limitada a 12 rad/s². La tasa también se limita según el paso de física.
- El desplazamiento deliberado del peso del piloto reduce la ayuda hasta
  el 20%, para conservar su autoridad. La ayuda no ordena torque local de yaw.

No se cambia rho*g*V, calado, masa, heave de Heavy Hull, inercia,
motor, propulsión, controles, proveedor CPU Lite, FFT ni shaders.
La trayectoria vertical puede variar indirectamente al conservar otra postura;
las fórmulas y coeficientes de elevación vertical permanecen iguales.

Inspector del JetSki: **Heavy Hull (HULL V1) / Gentle Wave Inclination**:

| Parámetro | Inicial |
| --- | --- |
| Heavy Upright Enabled | true |
| Heavy Wave Tilt Influence | 0.12 |
| Heavy Normal Lateral Influence | 0.10 |
| Heavy Upright Response Rate | 4.0 /s |

Desactivar Heavy Upright Enabled recupera la respuesta angular del Heavy Hull
anterior conservando su heave e inercia. J mantiene el A/B completo anterior.
LEGACY_4POINT y HULL V1 PREVIOUS conservan su funcionamiento.
El HUD muestra UPRIGHT y la influencia de inclinación seleccionada.

## Validación breve

Godot 4.7.1, escena habitual, 360 ticks con las olas actuales. Tras los
primeros 120 ticks se aplica acelerador 0.4 durante los 240 restantes:

`UPRIGHT_WAVES: pitch_max=8.32 deg roll_max=18.22 deg vertical_span=2.195 m max_thrust=4000.0 N`

`UPRIGHT_SMOKE: PASS | errors=0`

También se comprueban conservación de fuerza vertical y momento local de yaw,
selección/desactivación de la ayuda y ausencia de torque estabilizador en el aire.
La comprobación anterior de Heavy Hull vuelve a pasar: equilibrio plano,
masa de 300 kg, piloto, A/B, propulsión y fuerzas nulas en el aire.

Son comprobaciones breves de escenarios concretos; no garantizan ausencia
de vuelcos bajo cualquier velocidad, oleaje o maniobra. Sin benchmarks.
Los cambios locales anteriores del usuario se conservan fuera de este commit.
