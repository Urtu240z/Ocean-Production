# HITO 1.5 — Límite de elevación de proa

Sobre el estado local de `wip/feel-soft-water`, después de `45bc899`, conservando todos los cambios anteriores. No se modifica océano, FFT, LOCAL_SURFACE, flotabilidad, masa, motor, controles ni inercias.

## Parámetros y funcionamiento

Inspector del JetSki, grupo **Powered Nose Up Limit**:

| Parámetro | Inicial | Rango |
|---|---:|---:|
| `nose_up_limit_enabled` | true | Activado / desactivado |
| `nose_up_max_angle_degrees` | 25° | 10–45° |
| `nose_up_soft_zone_degrees` | 8° | 1–15° |
| `nose_up_response_rate` | 8 s⁻¹ | 2–16 s⁻¹ |

El ángulo utiliza el forward físico `-basis.z`: `atan2(forward.y, length(forward.xz))`. Mide elevación respecto a la horizontal del mundo sin Euler y sin depender de yaw o roll.

La protección entra progresivamente en la zona anterior al techo, con anticipación de la velocidad angular y de los torques ya aplicados. Combina restitución de pitch positivo y amortiguación de la rotación que continúa levantando la proa. Un guardado predictivo del siguiente paso añade el frenado necesario cerca del techo ante una aceleración intensa; sigue siendo torque finito aplicado por Jolt.

El torque se obtiene convirtiendo una aceleración de pitch puro mediante el tensor de inercia mundial actual. Así no añade aceleración de yaw ni roll por el mero hecho de que la moto esté inclinada. No hay cambios directos de transform, escrituras de velocidad angular, fuerzas lineales nuevas ni reducción de la fuerza del motor. Por debajo de la zona de intervención no se impone un objetivo de actitud ni una amortiguación angular general.

La respuesta requiere propulsión **real hacia delante**, toma del motor mojada, al menos dos contactos de agua y soporte de navegación válido. Dos contactos traseros permiten actuar cuando la proa empieza a salir del agua. La autoridad aumenta suavemente con la carga soportada y el contacto de la toma; en HULL_V1 se usa el volumen desplazado, y en LEGACY la carga de flotación existente.

Con contacto insuficiente, salida real del agua, lanzamiento de truco, ventana de despegue o modo de buceo, queda desactivada. También deja completamente libre el pitch negativo. No conserva torque residual al dejar de propulsar o perder el apoyo. La corrección tampoco pretende fijar la actitud durante un salto: es un límite de proa bajo propulsión con apoyo suficiente, no un bloqueo de rotación en el aire.

## Coordinación con límites anteriores

La auditoría encontró el límite positivo del piloto, inicialmente 34°, que solo se utiliza al desplazar manualmente su peso. Mientras la nueva protección tiene autoridad, ese límite positivo cede la responsabilidad al techo configurable. Sus límites de roll y de pitch negativo permanecen activos; al desactivar la nueva protección se recupera íntegramente la regla anterior.

La estabilización de HULL_V1 y la amortiguación mojada existentes se conservan. El cálculo considera el torque de propulsión respecto al COM real, el torque aplicado de flotabilidad/estabilización, los momentos de drag y el torque actual del piloto. Solo añade corrección negativa de pitch cuando la aceleración resultante aún lo necesita. Un torque restaurador existente más fuerte no recibe una segunda corrección equivalente.

## Validación breve

Godot 4.7.1, renderer gráfico, escena `gameplay/jet_ski_ocean.tscn` y HULL_V1, con las fuerzas e inercias locales actuales:

`Godot_v4.7.1-stable_win64_console.exe --path <repo> --script res://validation/physics/nose_up_limit_smoke.gd`

Resultado: **`NOSE_UP_SMOKE: PASS | errors=0`**, salida 0, sin errores ni advertencias de ejecución.

| Caso | Proa máxima | Ticks con corrección | Empuje máximo |
|---|---:|---:|---:|
| A fondo desde parado, agua plana | 13.352° | 0 | 9.743,9 N |
| Arranque de prueba a 22° y velocidad de pitch ascendente | 24.452° | 31 | 10.000 N |
| Aceleración continuada sobre olas, viento 18 m/s | 20.657° | 12 | 10.000 N |

La configuración de 22° es una condición inicial de validación, no una intervención del limitador sobre el transform. La prueba confirma que se ejecuta su callback real de Jolt cerca del techo.

El empuje de cada muestra propulsada se contrasta con la fórmula original: potencia × mando suavizado × contacto de la toma × factor de velocidad × autoridad del medio. No aparece ningún factor de reducción del limitador. La diferencia desde parado respecto a 10.000 N corresponde a los factores existentes de contacto/velocidad; en esa fase el limitador ni siquiera aplica torque.

Comprobaciones adicionales acotadas:

- Nueve combinaciones de yaw/roll: ángulo mundial correcto y aceleración correctora sin componentes de yaw/roll.
- Pitch negativo, soporte cero y actitud baja sin torque corrector.
- Restauración existente más fuerte sin torque duplicado.
- Barrera numérica bajo torque ascendente sostenido de 12.000 N·m y techos de 10°, 25° y 45°, sin exceder esos valores. Es una comprobación de protección, no un objetivo de que la moto navegue pegada al techo.
- Pose en el aire con acelerador y rotación: torque de protección exactamente cero y límite anterior del piloto sin anulación externa.
- Masa, inercia y fuerza nominal del motor conservadas. Sin benchmarks extensos.

## Archivos modificados

- `gameplay/vehicles/common/core/jet_ski_controller.gd`: parámetros, autoridad de contacto, cálculo de torques actuales y aplicación de la protección.
- `gameplay/vehicles/common/systems/jet_ski_nose_up_limit.gd`: medida de pitch mundial y barrera progresiva/predictiva.
- `gameplay/vehicles/common/systems/jet_ski_rider_dynamics_system.gd`: coordinación exclusiva del límite positivo del piloto.
- `validation/physics/nose_up_limit_smoke.gd`: validación breve.
- Este informe.

El commit incluye solo este hito; las modificaciones locales anteriores del controlador y los demás sistemas permanecen conservadas.
