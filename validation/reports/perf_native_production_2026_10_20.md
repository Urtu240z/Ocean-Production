# PERF-NATIVE-PRODUCTION — 20/10/2026

HULL_BUOYANCY_V1 utiliza exclusivamente HullBuoyancyGeometryNative. No hay selector geométrico ni fallback GDScript/LEGACY. LEGACY_4POINT conserva su lógica. Se mantiene la rama y el estado local previo; no se ha hecho push.

## Cambio y ciclo de vida

configure() conserva la construcción fija de seis secciones y doce celdas, incluido _tetra_moment(), y registra inmediatamente la geometría C++. Una subida por generación y objeto/buffers privados por moto. El núcleo C++ y su DLL no cambian. Las muestras devueltas por el proveedor se retienen antes del lote y se aplican las fuerzas en el orden anterior.

La integración dinámica GDScript, _plane_intersection y _submerged_tetra están solo en validation/fixtures/hull_geometry_gdscript_reference.gd. El fixture aislado hereda esa referencia; gameplay nunca la carga.

Una clase nativa ausente, configuración rechazada o lote inválido emite un error explícito. Un resultado fallido borra la salida y marca el casco no disponible. El controlador interrumpe el resto del tick y congela el RigidBody3D mediante una operación diferida. No sustituye el modelo. Reconfigurar recupera la dependencia y restaura el estado de freeze que suspendió este guard. Un reset/respawn intenta reconfigurar únicamente si faltaba la dependencia; el respawn normal no reconstruye geometría.

## Verificación

- Fixture aislado: 31.600 componentes, cero diferencias binarias y cero no finitos.
- Ciclo de vida: 164 comprobaciones, cero fallos; dos errores deliberados por ausencia de clase y resultado rechazado. Inicialización, reconstrucción, invalidación, liberación de buffers, restauración, congelación y seis objetos nativos distintos.
- Replay existente: temp/async_fft/deterministic/hull_production.json frente a hull_B_binary.json del experimento anterior: **720/720 hashes físicos idénticos**. Incluye seis motos, solapamiento, cambios de escala/tiempo/QueryMode, invalidación y respawn.
- El mismo replay gráfico D3D12/Jolt y las capturas focalizadas de gameplay de los bloques B/C sirven de smoke. Ningún error de ejecución en los runs aceptados.
- Los primeros arranques dentro del sandbox fallaron antes de cargar el proyecto. La ejecución autorizada fuera del sandbox pasó; no se cambió Rapier ni Jolt para resolverlo.

## Coste y límites

Referencia medida PERF-HULL-NATIVE-1: geometría completa 2,583→0,142 ms; controlador 7,987→5,419 ms, seis motos. Ahorro anterior demostrado 2,567 ms/tick. Esta consolidación retira rutas, no cambia el núcleo matemático: **no se reclama un ahorro adicional ni se repite ABBA** por limpieza. Los resultados actuales de diagnóstico, más instrumentados, se informan por separado en los bloques siguientes.

La bit-identidad corresponde a esta build Windows x86_64 de Godot 4.7.1 a13da4feb. Otros compiladores necesitan ejecutar los fixtures.

## Archivos y rollback

Producción: jet_ski_hull_buoyancy_v1.gd, jet_ski_water_physics_system.gd y dos guardas de integración/recuperación en jet_ski_controller.gd. Fixtures HULL actualizados para una sola ruta; referencia matemática aislada en validation/. El informe PERF-HULL-NATIVE-1 permanece histórico.

Commit independiente de consolidación: consultar el commit que añade este informe. Revertir ese commit recupera el selector experimental anterior. La DLL no necesita cambiar. Se preservan los cambios previos de escenas, proyecto, tsunami, efectos y el sink diagnóstico local del proveedor.

Siguiente coste medido: preparación de consultas y validación administrativa de la fuente; ver perf_local_areas_2_2026_10_20.md y perf_controller_scaling_2026_10_20.md.
