# Hito 1 — Flotabilidad distribuida

Rama de partida: `wip/feel-soft-water`. El modo por defecto sigue siendo
`LEGACY_4POINT`. Durante el juego, **H** alterna con `HULL_BUOYANCY_V1`;
el indicador de la esquina superior derecha muestra modo, muestras y masa.

## Modelo

- 12 muestras: 6 estaciones longitudinales, cada una dividida en babor/estribor.
- Las secciones se extraen del casco convexo de colisión existente y se
  extruyen sobre cada intervalo longitudinal. Volumen aproximado: 1.2158 m³.
- Cada celda se descompone en tetraedros y se recorta contra el plano local
  de agua. Se integran volumen sumergido y centro de volumen, también con
  el casco inclinado o invertido. Empuje: `rho * |g| * V`, opuesto a gravedad,
  con `rho = 1000 kg/m³`.
- La amortiguación normal usa velocidad del cuerpo en el centro sumergido
  menos velocidad del agua, incluyendo la rotación del cuerpo. Su coeficiente
  se distribuye según volumen y área de cada celda, y se desvanece al secarse.
  La amortiguación disipa movimiento relativo y puede producir fuerza hacia
  abajo al ascender; no se recorta junto con el empuje hidrostático.
- Fuerzas aplicadas en sus centros sumergidos, sin reducir momentos,
  limitar aumentos de fuerza ni añadir impulsos de despegue o anti-hop.
- Se reutiliza `begin_gameplay_contacts` del proveedor CPU Lite actual:
  doce consultas precargadas, seguidas por los puntos auxiliares existentes.
  No se modifica el proveedor ni el océano visual.
- Los resultados se agrupan en FrontLeft/FrontRight/RearLeft/RearRight para
  conservar máscaras, contactos, navegación, aterrizajes y efectos existentes.
  El arrastre tangencial conserva los cuatro coeficientes originales.

La aproximación representa cada sección mediante el perfil en el punto medio
de su intervalo y una superficie de agua tangente por celda. No es una
integración exacta de la malla visual ni un modelo de planeo nuevo.

## Validación breve

Godot 4.7.1, escena `gameplay/jet_ski_ocean.tscn`, renderer habitual:

`HULL_V1_SMOKE: PASS | samples=12 | hull_volume=1.2158 m3 | errors=0`

Comprobado: inicialización CPU Lite, volumen seco/completo y conservación en
recortes parciales complementarios, selección de ambos modos por el manejador
real de H, etiqueta HUD, precarga 12/4, contacto con agua en 60 ticks,
fuerzas/momentos finitos e interfaz de cuatro contactos. Salida 0, sin errores
de escena, scripts ni ejecución. No se ejecutaron benchmarks ni pruebas largas.

Para repetir: abrir la escena y pulsar H, o ejecutar Godot con
`--path <Ocean-Production> --script res://validation/physics/hull_buoyancy_v1_smoke.gd`.

Los cambios previos sin commit se conservan fuera del commit de este hito.
No se ha iniciado el siguiente hito.
