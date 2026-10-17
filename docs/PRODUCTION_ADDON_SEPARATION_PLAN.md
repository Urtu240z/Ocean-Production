# Separación de Ocean y Jet Ski para producción

Estado de la revisión: 15 de octubre de 2026. Este documento organiza el trabajo;
no confirma que la extracción, las fusiones o la limpieza ya estén realizadas.

## Resultado que buscamos

Dos paquetes que se puedan instalar en un proyecto Godot limpio:

- `addons/ocean/`: océano, render, FFT, consultas de superficie, underwater,
  recursos y extensión nativa necesarios. Ocean no depende del jet ski.
- `addons/jet_ski/`: escena del vehículo, conducción, flotabilidad V1 normal,
  controles, spray y sus texturas, cámara y efectos de cámara.

El jet ski recibe un proveedor de agua mediante una interfaz pequeña. Su
integración con Ocean traduce las consultas de Ocean a esa interfaz. El
conector puede distribuirse dentro de Jet Ski, sin un tercer addon obligatorio.
La escena de ejemplo instancia los dos componentes y los conecta; no contiene
comportamiento necesario para que funcionen ni parámetros exclusivos del vehículo.

## Hallazgos de esta revisión

- Rama actual: `wip/feel-soft-water`, HEAD `fef7870`.
- 30 archivos versionados modificados y 329 entradas sin seguimiento al tomar
  la muestra. Algunas entradas representan carpetas completas; no son 329
  archivos de producción pendientes de incorporar.
- Siete ramas locales y cuatro worktrees registrados.
- `master`, `wip/phys-cpu-lite` y `wip/phys-opt-1` son antecesores de la rama
  actual. No requieren una fusión para recuperar sus commits.
- El commit exclusivo de `codex/h4.6a` tiene un parche equivalente ya incluido.
- `investigation/p5_6-anti-faceting` tiene un commit no incluido (`9159716`,
  "To check"). Hay que revisar su contenido antes de decidir su destino.
- `wip/phys-opt-2` tiene seis commits no incluidos, relacionados con compilación,
  validación y resultados de pruebas. Se revisan individualmente.
- El worktree `p5_fix_worktree` conserva seis archivos versionados modificados
  y tres entradas sin seguimiento. Aunque su HEAD está incluido, su trabajo
  local todavía necesita preservación.
- `Water Race Ocean Production P3 Clean` está limpio y tiene un commit no
  incluido. `Water Race Ocean Production Visibility Clean` está limpio y su
  HEAD está incluido.
- Cámara, sacudidas e impactos se configuran y coordinan todavía desde
  `gameplay/jet_ski_ocean.gd`. Los auxiliares ya están separados, pero el conjunto
  aún no se puede transportar copiando únicamente la escena del jet ski.
- Esa escena de integración también precarga validadores de conducción.
- Las escenas de spray y del vehículo referencian imágenes de `res://Splash_1/`.
  Esos recursos deben acompañar al addon del vehículo.
- El proveedor CPU y la estimación de deriva están en `gameplay/water/`; hay que
  decidir su interfaz y ubicación antes de extraer los paquetes.
- El proyecto tiene un autoload de MCP para desarrollo. Los paquetes de
  producción no deben necesitarlo.

La inspección de rutas se ha limitado a referencias directas `res://` en los
recursos y scripts revisados. No sustituye la comprobación de rutas dinámicas,
clases globales, señales, acciones de entrada, extensión nativa o shaders.

## Orden de trabajo

### 1. Preservar y consolidar el estado funcional

1. Inventariar y respaldar los cambios de cada worktree, incluidos archivos sin
   seguimiento y recursos ignorados necesarios. Un bundle Git por sí solo no
   guarda esos archivos.
2. Separar código y assets necesarios de capturas, registros, cachés y artefactos
   generados. No incorporar todo mediante un añadido indiscriminado al índice.
3. Guardar el trabajo actual en commits revisables por subsistema: Ocean,
   conducción/flotabilidad, spray y cámara/integración, según sus dependencias.
4. Revisar los commits pendientes de otras ramas y del worktree P3. Incorporar
   únicamente lo necesario y registrar por qué el resto queda archivado o
   superado. No fusionar experimentos antiguos automáticamente.
5. Validar la escena funcional y fijar una referencia de recuperación antes
   de comenzar la separación.

No eliminar ramas ni worktrees antes de completar su preservación y revisión.

### 2. Integrar primero la cámara dentro del jet ski

- Crear un rig de cámara como parte de la escena del vehículo.
- Mover seguimiento, distancia por velocidad, movimiento, vibración e impactos
  a un controlador de cámara del vehículo.
- Conectar allí las señales y lecturas del jet ski. La escena de ejemplo deja
  de decidir cómo reacciona la cámara.
- Trasladar también los valores que el usuario ha guardado en la escena actual;
  no perderlos al retirar los exports anteriores.
- Mantener un único propietario de cada parámetro, evitando exports duplicados.
- Separar el HUD y los controles de depuración del comportamiento de producción.

Esta fase conserva la física y los modos existentes para aislar cualquier
regresión de cámara o integración.

### 3. Extraer los dos paquetes

- Establecer el contrato de consultas de agua y el conector para Ocean.
- Mantener la extensión y el cálculo compartido de campos de agua bajo Ocean;
  evitar reconstruir el FFT por separado para cada vehículo.
- Ubicar la respuesta arcade de deriva de la moto en la integración del vehículo,
  con sus ajustes fuera de la escena de ejemplo.
- Mover los recursos del vehículo y actualizar sus referencias y UIDs.
- Asegurar que inputs, clases y recursos no dependan de la configuración privada
  del proyecto de desarrollo.
- Incluir los recursos nativos de ejecución necesarios para Windows y documentar
  los requisitos de compilación. La portabilidad a otras plataformas se valida
  por separado; no queda demostrada por una extracción de carpetas.
- Mantener ejemplos y validaciones fuera del código obligatorio de los addons.

### 4. Probar la instalación en un proyecto limpio

- Ocean por separado: carga y ejecución sin el proyecto original ni MCP.
- Jet Ski: carga de escena y cámara con un proveedor de prueba mínimo.
- Ambos juntos: flotación, conducción, salto, lean, submarino, spray, cámara,
  impactos y deriva según el oleaje.
- Comprobar referencias ausentes, clases duplicadas, imports y archivos nativos.

Esta instalación limpia es la prueba de aceptación de la separación.

### 5. Limpiar después de comprobar la extracción

- Si V1 normal queda confirmada como único modo de producción, retirar Legacy,
  Heavy y los selectores y parámetros que dejen de tener uso, en un cambio propio.
- Revisar usos en escenas, recursos, señales y llamadas dinámicas antes de
  declarar un export o una función sin uso.
- Acordar y guardar los defaults de producción; conservar antes una referencia
  de los ajustes actuales. No restaurar valores históricos por su antigüedad.
- Archivar pruebas y resultados útiles, y retirar del paquete distribuible
  material temporal y artefactos generados.
- Cerrar los worktrees revisados y archivar ramas superadas al final.

Cada fase debe terminar con su validación y un commit independiente. No mezclar
la extracción de carpetas con la eliminación de modos físicos o un reajuste de
conducción: necesitamos poder identificar y revertir cada clase de cambio.
