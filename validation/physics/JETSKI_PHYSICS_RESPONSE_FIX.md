# Corrección de respuesta del jet ski — 13/10/2026

Se corrigió el acoplamiento entre profundidad máxima de flotación, amortiguación y arrastre del modo legacy. La escena conserva masa 300 kg, COM `(0, -0.22, 0)`, rigidez 4250 N/m por punto y profundidad máxima 5 m. No se modificaron el océano FFT, la generación de olas, la fuerza del motor, el sistema de buceo ni el bow spray.

## Ajustes aplicados

En `gameplay/vehicles/common/core/jet_ski_controller.gd`, editables en el inspector:

| Parámetro | Valor |
|---|---:|
| `buoyancy_damping_full_depth_m` (nuevo) | 0,25 m |
| `hydrodynamic_drag_full_depth_m` (nuevo) | 0,8 m |
| `wet_pitch_damping` | 180 N·m·s/rad |
| `wet_roll_damping` | 250 N·m·s/rad |
| `max_buoyancy_force_rise_N_per_s` | 60000 N/s por punto |
| `buoyancy_reentry_torque_ramp_seconds` | 0,12 s |

La amortiguación y el arrastre alcanzan su intensidad completa a sus propias profundidades; cambiar `max_submersion_depth` ya no los debilita. La fuerza sigue entrando continuamente desde cero en la superficie. Se conserva la curva de flotación profunda y el límite de fuerza. El límite de subida y la rampa angular existentes ahora están activos en el modo estabilizado, que usa la escena de juego. No se activó anti-hop ni se redujo globalmente el momento de flotación.

El estimador de fuerzas de comparación ahora usa la misma profundidad efectiva y modulación de amortiguación que el contacto real, evitando diagnosticar fuerzas diferentes a las aplicadas.

En `gameplay/vehicles/common/visual/jet_ski_camera_heading.gd` se conserva el último rumbo horizontal válido cerca de la vertical o con el casco invertido. La histéresis evita alternar de modo y la interpolación angular limita los cambios de cámara. `gameplay/jet_ski_ocean.gd` utiliza este controlador de rumbo; los giros normales siguen funcionando.

## Pruebas nativas: PASS

Godot 4.7.1, 60 pasos por segundo.

### Entrada vertical aislada en agua plana

`jetski_video_damping_probe.gd`: mismo sistema de flotación real, velocidad inicial −2 m/s, 10 s de simulación; rotación bloqueada y amortiguación global desactivada para aislar el soporte.

| Configuración | Rebote máximo ascendente | Excursión máxima | Pasos completamente secos |
|---|---:|---:|---:|
| Anterior, acoplada a 5 m | 1,679 m/s | 0,253 m | 11 |
| Anterior, acoplada a 0,8 m | 0,654 m/s | 0,162 m | 0 |
| Final, flotación 5 m y amortiguación 0,25 m | 0,300 m/s | 0,141 m | 0 |

### Controlador completo con oleaje reproducible

`jetski_surface_response_validation.gd`: escena real del vehículo sin nodos visuales, motor RACE, inercia combinada con piloto, navegación, controles, ayudas de proa y buceo reales. Proveedor sintético coherente de dos ondas cruzadas, 20 s por caso, mismo inicio y fase. Es una prueba del vehículo; no sustituye una comparación con el espectro FFT del vídeo.

| Caso | Tiempo completamente sin contacto | Pitch máximo | Roll máximo | Pasos invertido |
|---|---:|---:|---:|---:|
| Olas medias, configuración anterior | 55,7 % | 84,1° | 72,6° | 0 |
| Olas medias, configuración final | 22,2 % | 76,0° | 42,0° | 0 |
| Agua plana, configuración final | 0 % | 6,3° | 0° | 0 |
| Olas grandes, configuración final | 55,0 % | 62,0° | 57,5° | 0 |

Los máximos incluyen despegues y aterrizajes. Se conservan los saltos grandes; la moto sigue pudiendo perder contacto sobre oleaje fuerte.

- Salto deliberado: alcanzó 3,19 m con 78 pasos sin contacto, seguido de aterrizaje; sin vuelco.
- Buceo deliberado: se activó durante 75 pasos, alcanzó 1,11 m de profundidad media y recuperó la navegación; sin vuelco.
- Cámara: una vuelta completa de pitch conservó el rumbo horizontal; un giro normal de yaw de 90° siguió correctamente.
- Todos los estados físicos fueron finitos.

### Integración con el océano real

Se inició `res://gameplay/jet_ski_ocean.tscn` mediante el editor y se verificaron los siete ajustes físicos activos. Se inyectó acelerador durante 15 s y después se liberó. La captura completa incluyó 29,36 s y 1002 muestras, con viento 40 m/s y velocidad de ola ×2: 11 transiciones al aire y 31,8 % de muestras sin contacto. No hubo errores en la consola. Esta comprobación fue funcional; no constituye un A/B con la misma fase FFT ni una medida de todos los vuelcos del vídeo original.

También pasaron la compilación de `gameplay/jet_ski_ocean.gd`, la regresión visual de bow spray y la comprobación de espacios de los archivos modificados.

## Ajuste posterior

Para más amortiguación cerca de la superficie, reducir ligeramente `buoyancy_damping_full_depth_m`; para más libertad, aumentarlo. La rampa de reentrada y `wet_pitch_damping` / `wet_roll_damping` regulan la dureza angular. Cambiar un parámetro cada vez y comparar el mismo recorrido. Reiniciar la escena después de editar valores del controlador en el inspector, porque la configuración se transfiere a los sistemas en `_ready()`.

Las pruebas controladas cubren los casos indicados; otras fases, velocidades, combinaciones de controles o choques pueden producir vuelcos. No se han eliminado las rotaciones ni impuesto una orientación rígida al casco.
