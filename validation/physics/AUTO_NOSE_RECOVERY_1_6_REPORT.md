# Hito 1.6 — Auto Nose Recovery / Submarine Override

Implementado sobre `wip/feel-soft-water`, después de `22073cf`, conservando las modificaciones locales. No se cambian océano, FFT, shaders, casco, motor, masa, inercia, flotabilidad ni resistencia hidrodinámica.

## Comportamiento y ajustes

El controlador añade una asistencia de cabeceo exclusivamente con contacto real de proa y soporte de agua, sin salida de salto ni liberación de trucos aéreos. Se mide el ángulo con el vector de avance respecto a la horizontal del mundo. La ayuda no exige propulsión y también permite recuperarse cuando la toma queda fuera del agua.

Grupo **Auto Nose Recovery** del inspector:

| Parámetro | Inicial | Función |
|---|---:|---|
| `auto_nose_recovery_enabled` | true | Activar/desactivar la asistencia |
| `nose_recovery_start_angle_degrees` | 10° | Inclinación hacia abajo permitida antes de intervenir |
| `nose_recovery_response_rate` | 5 s⁻¹ | Intensidad de recuperación, calculada con la inercia real |
| `nose_recovery_damping_ratio` | 1 | Amortiguación angular |
| `nose_recovery_max_torque_nm` | 6000 N·m | Límite de torque adicional |
| `nose_recovery_resume_seconds` | 0.35 s | Retorno suave tras Lean Front/Submarine |

La demanda angular crece con el exceso sobre −10° y la velocidad de caída del morro. La entrada se suaviza durante los primeros 5° de exceso y con la profundidad de contacto. Al subir el morro, la amortiguación reduce la ayuda hasta cero; nunca se añade torque de recuperación hacia abajo. No se escriben transformaciones ni velocidades en la implementación.

Se descuentan los torques de flotación/HEAVY HULL/UPRIGHT, amortiguación del agua, resistencia, propulsión y piloto, incluido su límite de pitch existente. Solo se añade la corrección que falta; una recuperación existente más fuerte recibe cero ayuda adicional. El límite positivo de H1.5 conserva su cálculo, ahora compartiendo la lectura de esos torques. Las regiones positiva y negativa no se superponen. El objetivo de esta asistencia es salir de la inclinación excesiva, no imponer pitch cero.

Lean Front se comprueba tanto mediante la acción mantenida como mediante la entrada sin filtrar, antes de emitir el torque. Esto también cubre entradas opuestas que cancelan el vector. Suprime la ayuda desde el primer paso de física, antes de que exista `SUBMARINE_DIVE`. El truco activo mantiene la supresión. Tras soltar la orden se usa una rampa suave, el progreso de salida del Submarine y la relajación del desplazamiento del piloto todavía filtrado.

**Configuración local conservada:** `gameplay/jet_ski_ocean.gd` desactiva explícitamente `submarine_dive_enabled` al crear la moto. La prueba lo habilita únicamente en su instancia de validación para comprobar el truco real; no cambia ese ajuste del proyecto ni los umbrales de entrada del Submarine.

## Validación breve

Godot 4.7.1 con Jolt y el proveedor CPU Lite real, escena `gameplay/jet_ski_ocean.tscn`. Comprobación de scripts sin errores y ejecución gráfica de `auto_nose_recovery_smoke.gd`: **PASS**, salida 0, sin errores ni avisos registrados.

- Olas: viento de 18 m/s, swell 0.4, escala de altura 1. Entrada controlada a −25°, 18 m/s y velocidad angular de caída de 3 rad/s para ejercitar una situación exigente. Hubo 8 observaciones con ayuda; máximo 6000 N·m; la proa se recuperó por encima de −10° y alcanzó +14.61°. Empuje máximo: **10 000 N**, sin reducir potencia.
- Matemática del torque: progresión con el ángulo, amortiguación, límite, ausencia de duplicación con una corrección existente más fuerte y aceleración angular exclusivamente de pitch bajo distintos yaw y roll.
- Lean Front: ayuda cero desde el primer paso observado; sigue anulada incluso con Lean Back simultáneo.
- Submarine: entrada real desde el aire, contacto primero de proa, a −34.02°; ayuda cero durante entrada y truco. No se inyecta el estado del Submarine.
- Liberación: primer avance de la rampa 0.0476, retorno hasta 1 y salida completa del truco. Después, pitch −1.06° en agua plana y cero torque residual de recuperación.
- Aire: cero torque y cero autoridad de recuperación. Masa, inercia y potencia conservadas. Comprobación breve adicional de compatibilidad con `LEGACY_4POINT`.

Los valores corresponden a la última ejecución; las olas evolucionan y las observaciones pueden variar con el tiempo de simulación. Es una validación acotada con condiciones iniciales controladas, no una evaluación exhaustiva de conducción.

## Origen adicional de la frenada — sin cambios

`JetSkiWaterPhysicsSystem._apply_point_hydrodynamic_drag()` aplica resistencia tangencial por cada uno de los cuatro contactos compatibles. En HULL_V1, cada cuadrante utiliza su muestra más profunda. La inmersión se normaliza por `max_submersion_depth` (0.8 m) y se eleva a `drag_depth_exponent` (1). La resistencia longitudinal es:

`clamp((15*v + 1.5*v*abs(v)) * immersion, -3500, 3500)` N por contacto, con `v` relativo al agua y proyectado sobre su plano tangente.

Hay, por tanto, una contribución importante a la frenada al sumergirse la proa a velocidad elevada, aunque no se ha establecido que sea excesiva en todas las situaciones. En la última prueba la suma de resistencia longitudinal de proa alcanzó **2537.5 N** y su momento de cabeceo llegó a **−657.0 N·m**, reforzando el morro hacia abajo. El máximo de fuerza equivale a aproximadamente **8.46 m/s²** sobre 300 kg si se considerara aislado; no representa la aceleración neta, que incluye motor y demás fuerzas. El momento procede de aplicar esa resistencia en los contactos desplazados respecto al centro de masa.

A plena inmersión y 20 m/s tangenciales, los coeficientes actuales producen 900 N por contacto, 1800 N para los dos delanteros. A 30 m/s serían 1800 N por contacto delantero. El aumento de profundidad y el término cuadrático explican el crecimiento de resistencia. Además, una proa clavada puede elevar la popa y sacar la toma del agua, reduciendo el empuje por su lógica de contacto existente.

La resistencia, sus puntos de aplicación, límites, coeficientes y dependencia de profundidad permanecen intactos. La amortiguación normal y la respuesta vertical tampoco se modifican.

## Archivos del commit

- `gameplay/vehicles/common/core/jet_ski_controller.gd`: parámetros, excepción inmediata, rampa de retorno e integración de asistencia; lectura compartida de los torques ya aplicados.
- `gameplay/vehicles/common/systems/jet_ski_auto_nose_recovery.gd`: cálculo progresivo y limitado del torque.
- `validation/physics/auto_nose_recovery_smoke.gd`: validación acotada reproducible.
- Este informe.
