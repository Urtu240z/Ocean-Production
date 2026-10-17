# Ocean: costa, transiciones de oleaje y zonas de carrera

Registrado el 17 de octubre de 2026 sobre `wip/feel-soft-water`, base
`44d5a13`. Estado: requisitos pendientes de implementación. Este documento
no activa sistemas ni modifica el comportamiento actual del juego.

## 1. Coastal bake desde un escenario

**Necesidad:** al preparar un nivel nuevo, poder generar y asignar su bake
costero mediante una herramienta sencilla del addon Ocean.

- Seleccionar geometría del escenario, nivel del mar, límites del área y
  resolución del bake; permitir excluir objetos que no representan costa/fondo.
- Generar los datos costeros necesarios fuera de la carrera, guardarlos como
  recursos recuperables y reutilizarlos al ejecutar el nivel.
- Ofrecer una acción clara de generar/actualizar, información de progreso y
  validación del resultado. No ejecutar un bake completo al iniciar cada partida.
- Asignar el resultado a Ocean sin necesitar scripts obligatorios en la raíz
  del juego ni archivos de `validation/` del proyecto de desarrollo.
- Revisar el script del Water Race anterior cuando se recupere como referencia;
  su equivalencia con el sistema actual todavía no se ha comprobado.

**Base comprobada:** `addons/ocean/ocean.gd` expone `coastal_bake`.
`addons/ocean/coastal/ocean_coastal_runtime.gd` ya activa recursos de
propagación, warp y batimetría, publica datos físicos y mantiene una caché.
Esto acredita un consumidor de bakes, no una herramienta terminada para hornear
cualquier escenario. El manifiesto histórico `CoastalBakeAsset` vive en
`validation/p4_paradise/coastal_bake_asset.gd` y usa tipos propios de esa ruta;
no debe convertirse en una dependencia oculta del addon distribuible.

**Aceptación:** hornear dos niveles distintos desde un proyecto limpio, guardar,
recargar y ejecutar el recurso sin depender del mapa ni de las herramientas del
proyecto original. Verificar costa, profundidad, límites y consultas físicas.

## 2. Cambiar el estado del mar durante una carrera

**Necesidad:** pasar de mar picado a tranquilo, y a la inversa, con duración
configurable; ejemplos de 10, 20 y 30 segundos.

- Poder pedir un estado objetivo desde la lógica de carrera mediante una API
  sencilla de Ocean. La API concreta se definirá antes de implementarla.
- Mantener continuidad de fases y reloj: sin reiniciar las olas, saltos de
  altura, muestras inválidas, tirones ni pausas de conducción.
- Conservar resoluciones FFT, recursos residentes y el campo compartido.
  Evitar reinicializar/reconfigurar toda la simulación durante la transición.
- Una construcción física normal por tick, compartida entre consumidores.
  «Sin reconstruir» no significa detener las actualizaciones FFT normales.
- Publicar el mismo estado temporal en render y física. La flotabilidad debe
  seguir el agua visible; no se reajustan fuerzas, amortiguación ni conducción.
- Poder terminar en el objetivo solicitado y definir cómo se reemplaza una
  transición en curso por otro objetivo, sin saltos.

**Base comprobada:** `Ocean.set_sea_state()` asigna propiedades existentes.
Los setters de altura, viento, dirección y swell llaman a `_request_rebuild()`;
esa ruta invalida la fuente física y programa una reconstrucción. Por tanto,
la API actual de authoring no cumple por sí sola esta transición de carrera.
No se implementará interpolando repetidamente esos setters con un Tween.

**Diseño pendiente:** separar cambios de intensidad compatibles con las bandas
residentes de cambios de espectro/dirección que puedan necesitar preparar un
objetivo. Revisar la representación nativa y GPU antes de elegir la mezcla;
no prometer cambios arbitrarios de espectro sin coste. Conservar altura,
normal y velocidad del agua coherentes durante la interpolación.

**Aceptación:** ida/vuelta en 10/20/30 segundos, cambio de objetivo a mitad de
transición y uno/dos/doce consumidores. Comprobar continuidad, validez, reloj,
construcciones por tick y coste de preparación/lotes/integración antes/después.

## 3. Zonas de oleaje dentro del mismo nivel

**Necesidad:** convivir en una carrera con mar abierto, bocanas protegidas y
canales urbanos cuyo oleaje sea distinto del exterior.

- Zonas configurables por posición/forma, perfil y franja de transición suave.
  Prever prioridad y mezcla cuando se solapan.
- Evaluar por posición del agua, también cuando un casco cruza parcialmente
  un límite. No cambiar el océano global al entrar una sola moto en un área.
- Permitir que varias motos estén simultáneamente en zonas diferentes.
- La representación visual y las consultas físicas deben usar la misma
  transformación espacial. Cuidar también normales y velocidades en los bordes;
  reducir solo la altura visual no basta.
- Mantener proveedor directo, lotes y contextos de contacto aislados. No añadir
  adaptadores GDScript, objetos por contacto ni FFT independientes por vehículo.
- Definir la interacción con el bake costero y con el estado global del mar:
  un canal protegido debe seguir protegido mientras cambia el tiempo global.

**Diseño pendiente:** estudiar primero perfiles espaciales sobre las bandas
compartidas y su integración costera. Un canal con menos energía y otra mezcla
de bandas no equivale automáticamente a un espectro/dirección totalmente
independiente; evaluar coste y continuidad antes de prometer ese alcance.
Esta revisión inicial no constituye una auditoría exhaustiva de zonas antiguas
ni confirma que su implementación anterior sea reutilizable sin cambios.

**Aceptación:** ruta mar abierto → bocana → canal y vuelta, casco sobre un borde,
zonas solapadas, doce vehículos repartidos y transición global simultánea.
Verificar agua visible/consultada, continuidad y ausencia de reconstrucciones
por vehículo o entrada/salida de zona.

## Orden propuesto

1. Herramienta portable de bake y contrato de sus recursos de producción.
2. Transición temporal del estado global con render y física sincronizados.
3. Zonas espaciales sobre esa base, con pruebas de convivencia entre ambas.

Antes de modificar los cálculos, concretar las capacidades de transición y
zonas y medir su coste sobre la implementación actual. Mantener estos trabajos
dentro de Ocean; Jet Ski continúa consumiendo directamente su proveedor.
No se recuperan automáticamente experimentos antiguos ni se alteran los ajustes
funcionales actuales como parte de esta anotación.
