# Diagnóstico del vídeo del jet ski — 13/10/2026

Este documento conserva el diagnóstico anterior al cambio. La corrección implementada y sus resultados están en `JETSKI_PHYSICS_RESPONSE_FIX.md`.

Vídeo revisado: `20261013-1648-18.4238017.mp4`, duración 42,56 s. La moto muestra cabeceos grandes, pérdidas de contacto, giros y vuelcos repetidos. La cámara cambia de dirección con el casco y amplifica la sensación. El HUD identifica `LEGACY 4POINT`.

No se ha cambiado la física, la escena del vehículo ni el océano para este diagnóstico.

## Hallazgo principal confirmado: inmersión y amortiguación acopladas

- `gameplay/vehicles/jet_ski_01/jet_ski_01.tscn:188–196`: masa 300 kg, COM `(0, -0.22, 0)`, **`max_submersion_depth = 5.0`**.
- `gameplay/vehicles/common/core/jet_ski_controller.gd:54–60`: rigidez 4250 N/m por punto, amortiguación 1698,2 N·s/m por punto; profundidad predeterminada 0,8 m.
- `jet_ski_controller.gd:1572–1597`: transfiere esos ajustes al sistema físico.
- `gameplay/vehicles/common/systems/jet_ski_water_physics_system.gd:353–365`: multiplica la amortiguación por `clamp(support_depth / max_submersion_depth, 0, 1)`.

A 20 cm de inmersión, la escena aplica el 4 % del coeficiente de amortiguación, frente al 25 % con 0,8 m: una reducción de 6,25 veces. En agua plana, la inmersión estática aproximada es 17,3 cm; el coeficiente efectivo ronda 59 N·s/m por punto. Este cálculo describe la flotación vertical aislada, no todos los pares de giro ni los controles del piloto.

La misma profundidad divide el factor de arrastre (`water_physics_system.gd:353, 422–429, 1473–1490`). El exponente del controlador es 1,0. A poca inmersión también se reduce 6,25 veces la resistencia al avance y al deslizamiento respecto de 0,8 m.

## Comprobación nativa en Godot 4.7.1

Script: `validation/physics/jetski_video_damping_probe.gd`.

Lee masa, rigidez, amortiguación y posición de los cuatro puntos de la escena actual y ejecuta el **sistema real de flotación legacy**. Agua plana inmóvil, velocidad inicial vertical −2 m/s desde el equilibrio aproximado, 600 pasos a 60 Hz. Rotación bloqueada, sin motor, piloto ni cámara; amortiguación global lineal desactivada para aislar el contacto. Los dos casos solo cambian la profundidad en el cuerpo de prueba.

| Profundidad | Pico de rebote ascendente | Desplazamiento vertical máximo desde equilibrio | Pasos completamente secos | Oscilación máxima en los últimos 2 s |
|---|---:|---:|---:|---:|
| Actual: 5 m | 1,679 m/s | 0,253 m | 11 | 0,0113 m |
| Comparación: 0,8 m | 0,654 m/s | 0,162 m | 0 | 0,00018 m |

El caso actual pierde contacto incluso sin oleaje. Esta prueba confirma el defecto de amortiguación y su efecto vertical; no reproduce todos los giros del vídeo ni determina las entradas del jugador.

Reproducción:

```text
Godot_v4.7.1-stable_win64_console.exe --headless --path "<proyecto>" --fixed-fps 60 --script res://validation/physics/jetski_video_damping_probe.gd
```

## Factores que agravan la rotación

1. **Cuatro apoyos discretos.** `water_physics_system.gd:412–458` convierte la fuerza de cada punto en momento respecto al COM. Contactar primero con la proa o con un lado produce cabeceo o balanceo. Esto es esperable; el problema es la intensidad y cuánto se disipa.
2. **Reentrada inmediata.** `jet_ski_controller.gd:63–68` tiene momento de flotación al 100 %, amortiguación angular pitch/roll de 20/80, límite de subida de fuerza 0 (desactivado) y rampa de momento 0 s. Aunque el modo se llama estabilizado, la rampa termina en el primer paso con estos ajustes (`water_physics_system.gd:443–457`). La amortiguación angular también disminuye cuando quedan menos puntos mojados (`1281–1289`).
3. **Ayudas condicionadas.** El límite de proa requiere propulsión y al menos dos puntos mojados; la recuperación de proa requiere apoyo y contacto delantero (`jet_ski_controller.gd:921–990`). La asistencia al despegue omite casos extremos, entre ellos pitch ≥60° o roll ≥50° (`water_physics_system.gd:849–872, 912–929`). Una vez iniciada una rotación grande, esas ayudas no garantizan detenerla.
4. **Heavy Hull no interviene en este modo.** Sus parámetros solo actúan con `HULL_BUOYANCY_V1` (`jet_ski_controller.gd:993–995`). Modificarlos mientras el HUD muestra Legacy no corregirá esa respuesta.
5. **Cámara.** `gameplay/jet_ski_ocean.gd:163–175` proyecta el eje longitudinal del casco sobre el plano horizontal. Cerca de la vertical, esa dirección se vuelve débil; al superar la vertical puede invertirse. El fallback fijo y la inversión pueden cambiar bruscamente el objetivo de cámara. Es un problema separado de las fuerzas.

## Corrección propuesta, en orden

1. **Separar profundidades funcionales.** Introducir una profundidad independiente para que la amortiguación alcance su intensidad completa cerca de la superficie, y otra para el arrastre. Mantener continuidad de fuerza al entrar en el agua. `max_submersion_depth` debería regular la curva de flotación, sin debilitar accidentalmente ambos frenos. Empezar por comparar con el comportamiento anterior de 0,8 m; después calibrar la profundidad de amortiguación por separado. No cambiar a ciegas el coeficiente 1698,2.
2. **Ajustar la respuesta angular después.** Comparar una rampa corta de reentrada de 0,08–0,12 s y mayor disipación de pitch/roll con el mismo oleaje y recorrido. Son candidatos de prueba, no valores finales. No reducir toda la flotación ni activar anti-hop indiscriminadamente: la validación FEEL-5 anterior encontró resultados mixtos y recortó algunos saltos grandes.
3. **Conservar rumbo de cámara estable.** Recordar el último rumbo horizontal válido, con umbral e histéresis alrededor de la vertical y giro suavizado. Comprobar que una voltereta no provoque una inversión brusca de cámara, manteniendo los giros normales del jugador.
4. **Validar el conjunto.** Misma fase de oleaje, velocidad e inputs antes/después; registrar fuerzas por punto, contactos, pitch/roll y velocidades angulares. Probar flotación quieta, olas pequeñas/medias, salto grande y buceo intencionado. El objetivo es amortiguar el rebote y los giros accidentales, conservando los saltos y maniobras.

El servicio de grafo no estuvo disponible (`Transport closed`); las referencias se comprobaron directamente en los archivos locales. No hay telemetría sincronizada de inputs/fuerzas del vídeo, por lo que no se atribuye cada vuelco a una única causa.
