# HITO 1.3 — Local Surface Choppy Contact

Implementado sobre `wip/feel-soft-water`, después de `431032d`, conservando los commits y las modificaciones locales anteriores. No se cambian shaders, FFT visual, aspecto del mar, masa, propulsión, inercias, amortiguación ni fuerzas de HULL_V1/LEGACY.

## Uso y configuración

La partida comienza con `DIRECT`. **L** alterna `DIRECT` / `LOCAL_SURFACE`, independientemente de **H**, que selecciona LEGACY / HULL_V1. Ambos proveedores de contactos alimentan el mismo sistema de fuerzas existente; no hay una segunda implementación de flotabilidad.

En el inspector del proveedor `PhysicalWater` están disponibles:

| Parámetro | Inicial | Función |
|---|---:|---|
| Local Surface Useful Radius M | 4 m | Semiextensión útil alrededor del casco |
| Local Surface Spacing M | 0.35 m | Paso solicitado de la triangulación |
| Local Surface Max Vertices Per Side | 65 | Presupuesto de vértices por lado |
| Local Surface Continuity Slack M | 0.35 m | Tolerancia al detectar un cambio inesperado de rama |

La superficie añade al área útil el margen conservador de desplazamiento XZ del shader. Si el área de origen no cabe en el presupuesto, aumenta el paso efectivo en lugar de aumentar sin límite la cantidad de vértices. Con los valores iniciales hay como máximo 4.225 vértices y 8.192 triángulos. La superficie se mueve con el casco, se construye una vez por tick normal y no genera malla visual ni wireframe durante gameplay.

El HUD muestra modo de contacto, tiempo de construcción, tiempo de consulta del lote de contactos, resolución efectiva y contadores de cruces múltiples, fallback y transiciones de rama. Los tiempos son instantáneos, no resultados de un benchmark.

## Datos reutilizados y composición

La inspección confirmó que CPU Lite dispone realmente de XZ. `DynamicOceanPhysicsField::build_lite()` ya empaquetaba Dx/Dz en su segundo campo reducido, a partir de H0 y el choppiness del espectro. `sample_lite_horizontal_displacement()` consulta esos campos con la interpolación existente. No se añade ninguna FFT ni transformación de campos.

Se reutiliza `build_dynamic_lite_local_surface()`. Cada vértice se obtiene del mismo conjunto de rejillas y del tiempo `current_field_time` de contactos:

- Fase en dominios originales: `base_world_xz / Clipmap Geometry Scale`.
- Contribuciones por banda y fades de distancia evaluados en el punto base, como en el shader.
- Desplazamientos XZ con el choppiness del espectro y los multiplicadores horizontales del perfil visual actual; escala horizontal aplicada después de componerlos.
- Altura y velocidad vertical escaladas por Ocean Scale, conservando el nivel del mar como pivote.

La sincronización de instancia, espectro y Ocean Space de los hitos anteriores sigue invalidando geometría, cachés e historial. Una reconstrucción nunca publica contactos del estado anterior. Los hosts antiguos que no tienen reducción horizontal por perfil usan multiplicadores unitarios.

## Contactos, continuidad y fallos

La consulta reutiliza los bins y triángulos desplazados de LocalSurface. Obtiene por coordenadas baricéntricas altura, punto de origen y velocidad vertical, y calcula la normal de la cara seleccionada, normalizada y orientada hacia arriba. La profundidad es la diferencia con la Y mundial del contacto.

Sin historial, elige la intersección superior. Cuando hay historial válido, selecciona entre las intersecciones actuales mediante la altura prevista por velocidad/slope y la proximidad al punto de origen anterior. No hace inversión global ni Newton experimental. El índice del triángulo no se utiliza como identidad persistente, porque la superficie móvil se vuelve a triangular.

Los cambios A/B, la recuperación de un fallo y las discontinuidades de rama diagnosticadas se conectan con una transición de muestras de **0.12 s**. Durante esa transición se interpolan altura, normal y velocidad; al terminar se devuelve la intersección geométrica actual. La respuesta normal a las olas no recibe un filtro temporal adicional. El historial para elegir ramas guarda la geometría real, separado de las muestras de transición.

Una consulta sin intersección válida utiliza una muestra **DIRECT actual**, de las mismas rejillas y tiempo, y registra el fallo. No mantiene alturas antiguas indefinidamente. Si la fuente de agua está reconstruyéndose o es inválida, se rechazan ambos modos. Teleports/cambios de distribución no trasladan el plano de un contacto antiguo a una posición lejana. Las consultas de comparación no sobrescriben el historial del backend principal.

## Validación mínima

DLL Release nativa reconstruida correctamente. Godot 4.7.1 con renderer gráfico y escena real `gameplay/jet_ski_ocean.tscn`:

`Godot_v4.7.1-stable_win64_console.exe --path <repo> --script res://validation/physics/local_surface_choppy_smoke.gd`

Resultado final: `LOCAL_CHOPPY_SMOKE: PASS | errors=0 | imports=3`, salida 0, sin errores/advertencias de ejecución. Los imports corresponden al arranque y a dos cambios meteorológicos; construir LocalSurface no importa otro espectro.

- Agua plana: equilibrio vertical estable, superficie al nivel del mar, normal UP y velocidad cero; 100 pasos de comprobación.
- Olas normales: viento 12 m/s, 60 pasos de comprobación y acelerador activo. Contactos finitos, propulsión positiva.
- Temporal: viento 40 m/s, 90 pasos de comprobación. Cero consultas perdidas y cero cambios inesperados de rama en los contactos de esta ejecución.
- A/B mediante la misma tecla L del HUD, DIRECT → LOCAL_SURFACE → DIRECT → LOCAL_SURFACE, manteniendo masa, inercia e instancia del sistema de fuerzas.
- Superficie limitada al presupuesto, sin geometría de depuración y con tiempo idéntico al campo CPU Lite actual.
- Diagnóstico determinista de dos triángulos superpuestos: elección superior inicial, conservación de rama inferior por historial, normal geométrica, velocidad interpolada, discontinuidad y consulta fuera del área; siete comprobaciones superadas. El diagnóstico restaura el estado real antes de retornar.
- Una consulta fuera de la superficie recupera una muestra DIRECT actual y aumenta el contador de fallos.

En una comparación puntual de nueve puntos durante el temporal, contra una triangulación CPU más fina del mismo campo y tiempo: error medio **LOCAL_SURFACE 0.01189 m / DIRECT 0.02382 m**. Es una referencia CPU, no una lectura de la GPU, y no demuestra ese resultado para todos los estados del mar.

Últimas instantáneas de construcción/consulta del lote: plana 0.455/0.013 ms, normal 1.380/0.015 ms, temporal 3.116/0.018 ms. El número de ticks reales puede superar los pasos del script por la programación de fotogramas; no se ha ejecutado un benchmark extenso.

## Límites

La superficie reproduce la composición de desplazamientos del océano abierto sobre los campos disponibles de CPU Lite. Conserva su resolución reducida y su filtrado de longitudes de onda; la triangulación tiene además una resolución finita. No representa una copia exacta de todos los detalles de la malla GPU ni añade deformaciones costeras/breakers que no estén en esas rejillas.

CPU Lite proporciona velocidad vertical analítica. Se interpola esa velocidad en el triángulo y se aplica la escala de tiempo; la componente horizontal permanece cero. No se inventa una velocidad orbital horizontal a partir del movimiento del contacto o de Dx/Dz, ni se añade otra FFT para calcularla.

## Archivos del commit

- `addons/ocean/physics/native/ocean_query/src/ocean_query_native.cpp` y `.h`: presupuesto de LocalSurface, composición por perfil, consulta geométrica con historial y diagnóstico acotado.
- `gameplay/water/cpu_fft_water_provider.gd`: selección de ruta, configuración, seguimiento del casco, sincronización, fallback y tiempos.
- `gameplay/water/local_surface_contact_state.gd`: historial de geometría y transiciones cortas de muestras.
- `gameplay/vehicles/common/visual/jet_ski_buoyancy_hud.gd`: tecla L, modo y diagnósticos.
- `validation/physics/local_surface_choppy_smoke.gd`: validación breve.
- Este informe.

La composición por multiplicadores, que ya existía en el código nativo local, se incluye como dependencia necesaria de este hito. El resto de trabajo local ajeno permanece fuera del commit. La DLL compilada es un artefacto local ignorado por el repositorio; para otro checkout se reconstruye con `addons/ocean/physics/native/ocean_query/build_windows_release.bat` desde el entorno MSVC habitual.
