# Hito 1.2 — Heavy Hull / inercia hidrodinámica

Base local: `wip/feel-soft-water`, con `91aee79` y `fc658d5` conservados.

## Auditoría inicial

- Masa real: 300 kg; centro de masa: (0, -0.22, 0).
- COMBINED RIDER ya modela 80 kg de piloto dentro de esos 300 kg, con
  desplazamiento respecto al casco (0, 0.85, 0.55) y ejes paralelos.
- Inercia con piloto: pitch 208.0871, yaw 172.6869, roll 62.88359 kg·m².
- HULL_V1 usa empuje rho*g*V y amortiguación normal distribuida con ratio 0.9.
  Su calado, volumen integrado, geometría y amortiguación anterior se conservan.
- Toma de propulsión local actual del usuario: (0, -0.34347618, 1.25).
  Se conserva exactamente; no se edita la escena del vehículo.

## Implementación y A/B

En HULL_BUOYANCY_V1, HEAVY HULL se selecciona inicialmente. **J** alterna
HEAVY HULL / HULL V1 PREVIOUS; **H** conserva el selector de flotabilidad.
El perfil anterior recupera los valores locales actuales de HULL_V1, incluyendo
piloto, calado, toma de agua y correcciones recientes; no usa una versión antigua.

Inspector del JetSki, grupo **Heavy Hull (HULL V1)**:

| Parámetro | Inicial | Efecto |
| --- | --- | --- |
| Hull Response Mode | HEAVY_HULL | A/B sin cambiar el modo de flotabilidad |
| Heavy Pitch Inertia Multiplier | 2.5 | Multiplica pitch después de combinar casco/piloto |
| Heavy Roll Inertia Multiplier | 2.5 | Multiplica roll; yaw queda intacto |
| Heavy Heave Added Mass Coefficient | 0.35 | Masa efectiva de agua = coeficiente * rho * V sumergido |
| Heavy Heave Resistance Rate | 1.5 /s | Arrastre vertical instantáneo relativo al agua |

La inercia con piloto pasa a (520.2177, 172.6869, 157.209) kg·m². No se
añade otro peso de 80 kg, no se cambia el centro de masa y no se multiplican
repetidamente los resultados. El piloto se conserva como cuerpo acoplado en
el modelo de inercia existente, con amortiguación distribuida del casco; no se
introduce un controlador autónomo de postura ni se retocan sus controles.

## Heave y estabilidad

Se integra exactamente el mismo volumen sumergido y se aplican las mismas
fuerzas hidrostáticas y momentos de HULL_V1. Al terminar las celdas, se añade
una fuerza vertical central, sólo cuando existe volumen sumergido válido.

Con F0 = componente vertical de empuje/amortiguación previa menos m*g:

- m_added = 0.35 * rho * V: unos 105 kg en equilibrio, sin peso adicional.
- F_drag = -C * velocidad relativa vertical del centro de masa al agua,
  ponderando la velocidad del agua por volumen sumergido.
- F_inertia = -m_added/(m + m_added) * (F0 + F_drag).
- Por tanto, a = (F0 + F_drag)/(m + m_added) para la respuesta al agua.

Es una aproximación de masa añadida únicamente en heave: no calcula una
matriz hidrodinámica completa, aceleración del fluido ni derivadas ruidosas
de ticks anteriores. Las fuerzas de motor/control posteriores conservan su
aplicación original. La corrección central no introduce torque de yaw.

En reposo F0 y la velocidad relativa son cero: la corrección también lo es.
Sin contacto V=0 y todas las contribuciones nuevas se anulan. No hay filtros
temporales, impulsos ni límites nuevos sobre el empuje de las olas grandes.
El coeficiente del damper adicional se limita para consumir como máximo un
25% de la velocidad relativa por paso con la masa efectiva. Los multiplicadores
angulares permanecen asociados al perfil elegido, también durante el vuelo;
las fuerzas de agua desaparecen al secarse.

## Validación breve

Godot 4.7.1, `gameplay/jet_ski_ocean.tscn`, agua plana temporal de validación,
240 ticks de asentamiento y comprobaciones cortas de A/B, propulsión y aire:

`HEAVY_HULL_EQUILIBRIUM: I=(520.2177, 172.6869, 157.209) base=(208.0871, 172.6869, 62.88359) volume=0.2999 added=105.0 kg y_span=0.00078 m vy=-0.00247 m/s`

`HEAVY_HULL_PROPULSION: force=1432.3 N nozzle=(0.0, -0.343476, 1.25)`

`HEAVY_HULL_SMOKE: PASS | errors=0`

Verificado: masa de 300 kg, piloto existente, yaw sin cambios, equilibrio,
desplazamiento, restauración exacta A/B, calado y toma conservados, controles
y motor originales, empuje con throttle y ausencia de fuerzas/momentos de
agua en el aire. LEGACY_4POINT mantiene su inercia anterior. Salida 0, sin
errores de escena o ejecución. Sin benchmarks ni ajuste de otros sistemas.

Repetir con:
`--path <Ocean-Production> --script res://validation/physics/heavy_hull_smoke.gd`

No se modifican FFT, shaders, proveedor de agua, masa, geometría, motor,
propulsión ni controles. Los cambios locales previos quedan fuera del commit
del hito. No se inicia el siguiente hito.
