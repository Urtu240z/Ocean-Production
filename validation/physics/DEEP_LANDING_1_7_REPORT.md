# Hito 1.7 — Deep Landing / Buoyancy Impact Tuning

Rama `wip/feel-soft-water`, sobre `71a96a0`, conservando los cambios locales anteriores.

## Configuración de referencia

Referencia **confirmada por el usuario**: **HULL_BUOYANCY_V1 con Wheelie existente + HULL_V1_PREVIOUS**. La validación usa STOCK, 300 kg, inercia combinada con piloto, draft STANDARD y el proveedor CPU Lite actual en DIRECT. Wheelie y sus controles permanecen habilitados y sin cambios. No se crea ni se renombra un perfil.

**HEAVY HULL no se activa en la validación.** La nueva asistencia se excluye expresamente si `heavy_hull_enabled` es true. Sus parámetros, inercia y funciones de respuesta se conservan; tampoco se modifica la selección predeterminada de los modos anteriores.

## Auditoría de fuerzas

El HULL_V1 integra doce celdas del casco. Sus fuerzas están separadas:

- **Hidrostática:** `rho * g * submerged_volume`, con rho = 1000 kg/m³. La masa real sigue siendo 300 kg y pesa aproximadamente 2940 N. El volumen completo del casco actual es 1.2158 m³; completamente sumergido puede aportar unos 11.9 kN. Este cálculo permanece intacto.
- **Amortiguación normal dinámica:** `-normal * c * immersed_fraction * relative_normal_speed`, donde `c = 2 * damping_ratio * sqrt(waterplane_stiffness * cell_mass)` y damping_ratio sigue siendo 0.9. La velocidad incluye la rotación del cuerpo y se compara con la velocidad del agua. En agua plana es la principal resistencia vertical al impacto.
- **Resistencia hidrodinámica tangencial:** componentes longitudinal y lateral aplicadas mediante los cuatro contactos compatibles, con sus coeficientes y límites existentes. En la caída vertical sobre agua plana su componente ascendente medida fue cero. En superficies inclinadas puede tener componente vertical; no se modifica esa ley ni se atenúa su fuerza horizontal.

En la referencia sin ajuste, a los 50 ms del contacto y descendiendo a unos 7.21 m/s, la amortiguación ascendente llega a **31.88 kN**, mientras el empuje hidrostático es aproximadamente 9.78 kN en ese instante. El máximo de empuje hidrostático durante la caída ronda 11.91 kN. La amortiguación domina la frenada inicial.

## Ajuste y A/B

Grupo **Deep Landing (HULL V1 Previous)** en el inspector del controlador:

| Parámetro | Inicial | Rango |
|---|---:|---:|
| `landing_penetration_enabled` | true | ON/OFF |
| `landing_entry_speed_threshold` | 3 m/s | 0.5–12 m/s |
| `landing_upward_damping_multiplier` | 0.4 | 0–1 |

**G** alterna únicamente `landing_penetration_enabled`. El HUD muestra ON/OFF y el multiplicador efectivo, o BYPASSED (HEAVY) cuando corresponde. La opción no cambia masa, inercia, motor, propulsión, dirección, modos del agua ni selección de respuesta del casco.

Una entrada solo puede armarse tras al menos 0.08 s sin volumen sumergido. El primer contacto con volumen real requiere velocidad descendente del cuerpo respecto al agua por encima del umbral. La variación normal de las olas mientras se permanece en contacto no arma el ajuste.

Con los valores iniciales, la componente **positiva vertical de la amortiguación existente** se multiplica por 0.4 cuando la caída relativa alcanza 4.5 m/s. Entre 4.5 y 3 m/s vuelve continuamente a 1 mediante smoothstep; por debajo de 3 m/s se recupera la amortiguación completa. La asistencia termina cuando la velocidad descendente media, ponderada por volumen sumergido, cae por debajo del umbral.

La amortiguación ya crece con la fracción de volumen sumergido y el empuje hidrostático crece con el volumen desplazado. Así se conserva la resistencia que detiene la caída y devuelve el casco a la superficie. No se fija una profundidad objetivo, no se teletransporta el cuerpo y no se añade una fuerza descendente: se reduce una componente ascendente que ya existía. Al ascender, la amortiguación original queda intacta.

La reducción conserva las fuerzas horizontales. Para conservar también los momentos originales de pitch, roll y yaw se mantiene el momento de la parte retirada mediante un torque equivalente `lever_arm.cross(removed_damping)`. La fuerza vertical cambia, mientras la suma de momentos coincide con la ley anterior evaluada en el mismo estado. Las trayectorias pueden variar al penetrar más; no se retocan las leyes angulares ni Wheelie.

Lean Front y el factor de flotabilidad del Submarine inhiben este ajuste durante la entrada, el truco y su salida. LOCAL_SURFACE, el proveedor de agua, el océano y sus shaders no se modifican. LEGACY conserva su ruta de fuerzas. Al cambiar entre modos de flotabilidad se descarta exclusivamente el historial de esta nueva asistencia.

## Validación breve

Godot 4.7.1/Jolt, escena real `gameplay/jet_ski_ocean.tscn`, CPU Lite y agua plana. Ejecución de `deep_landing_smoke.gd`: **PASS**, salida 0, sin errores ni avisos registrados. Los scripts modificados también pasan la comprobación de carga.

Caída vertical desde 5 m por encima de la posición de equilibrio, con velocidad inicial cero y sin propulsión. La velocidad de contacto es algo menor que sqrt(2*g*5) porque el casco ya estaba parcialmente sumergido en la posición de equilibrio. Se registra cada paso de física a 60 Hz:

| Medida | Ajuste OFF | Ajuste ON |
|---|---:|---:|
| Velocidad descendente de impacto | 9.33 m/s | 9.33 m/s |
| Profundidad máxima del casco bajo la superficie | 0.669 m | **0.969 m** |
| Inicio de recuperación estable tras contacto | 1.217 s | **1.400 s** |
| Pico de velocidad ascendente | 1.501 m/s | 1.612 m/s |
| Pico de amortiguación vertical ascendente | 31 876 N | **15 777 N** |
| Pico de empuje hidrostático | 11 910 N | 11 915 N |
| Resistencia tangencial ascendente en esta caída | 0 N | 0 N |

La profundidad es la máxima profundidad geométrica que ya informa HULL_V1, respecto a la superficie física; no es una profundidad impuesta al centro del cuerpo. El criterio de estabilidad exige velocidad vertical menor de 0.15 m/s y altura a menos de 0.08 m de la posición original, mantenidas durante 0.5 s. El tiempo tabulado corresponde al inicio de ese intervalo confirmado.

La posición de equilibrio inicial fue y = 0.2127 m y se recupera dentro de esa tolerancia. La intervención vuelve a cero en reposo. La pequeña diferencia entre máximos hidrostáticos proviene de las distintas fracciones sumergidas alcanzadas y el cálculo geométrico: en cada paso se comprobó `sum(hydrostatic_forces) == rho*g*volume`, con error máximo inferior a 0.0005 N en ambos modos.

Se comprueba la tecla G real del HUD, la ausencia de cambios en inercia/motor/modo del agua, el armado exclusivo tras vuelo, el retorno progresivo de amortiguación y la identidad de momentos bajo una reducción asimétrica. No hay rebote explosivo: la velocidad de retorno es aproximadamente 1.61 m/s y el cuerpo vuelve a una flotación estable. La penetración inicial queda cerca de 1 m, en el extremo bajo de la referencia solicitada, sin forzarla ni reducir la hidrostática.

## Archivos del commit

- `jet_ski_controller.gd`: tres parámetros del inspector y su sincronización con la física.
- `jet_ski_water_physics_system.gd`: reducción exclusiva de amortiguación ascendente durante aterrizajes y conservación de momentos.
- `jet_ski_landing_penetration.gd`: armado de aterrizaje y curva de recuperación por velocidad relativa.
- `jet_ski_buoyancy_hud.gd`: A/B mediante G e indicador.
- `deep_landing_smoke.gd`: comprobación breve de reposo y caída A/B de 5 m.
- Este informe.
