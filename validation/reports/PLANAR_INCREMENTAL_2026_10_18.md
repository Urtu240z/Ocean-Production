# Planar: actualización incremental y Kawase sincronizado

## Correcciones

El registro de visuales, cámaras y luces se construye una vez y recibe los nodos nuevos mediante `node_added`. La auditoría de 0,5 s revisa el registro para detectar cambios de grupos, máscaras y AABB sumergidos; no recorre todo el árbol ni restaura y reconstruye todas las capas. Conserva las asignaciones existentes y solo añade/retira las afectadas. Recupera capas vacías y reserva la reconstrucción para cambios de mundo o conflictos. Las máscaras de cámaras y luces solo se escriben si cambian.

Las variantes de recorte mantienen su identidad. Los uniformes modificados se sincronizan en la copia privada; cambiar el shader o sustituir el material reemplaza únicamente la variante afectada. Retirar el grupo restaura el material original. Sigue existiendo una revisión O(N) de las referencias registradas para cambios que Godot no notifica con señales específicas: no se presenta como invalidación exclusivamente por eventos ni como coste cero en islas grandes.

Planar entrega una revisión de contenido a Kawase. Sus tres viewports utilizan `UPDATE_ONCE`, conservan la textura entre capturas y permanecen detenidos si la revisión y la intensidad no cambian. Un cambio de intensidad vuelve a filtrar una vez la captura almacenada. SSR continúa actualizando por fotograma. La interpolación del primer pase se conserva: sus muestras protegen radiancia y confianza y no se sustituyen por una aproximación sin medir.

Las pruebas de integración comprueban la identidad de materiales tras varias auditorías, edición de uniformes y shader, retirada/reincorporación al grupo, pausa real de las tres pasadas Kawase entre capturas y refresco único al cambiar intensidad. También conservan pruebas de máscaras selectivas, conflictos, recorte, cambio de cámara, oleaje y tamaños mínimos.

## Medición secuencial con Kawase

RTX 4070 Laptop, Godot 4.7.1, Forward+, D3D12, 1920×1080. Una sola instancia de prueba; no se detectaron procesos Godot antes de empezar. 24 casos: 1/4/6 motos, Planar 0,35/0,5, Kawase desactivado/activado, dos repeticiones con orden inverso. Cada caso contiene 30 fotogramas de calentamiento y 60 muestras. Captura iluminada con efectos completos, intensidad Kawase 1, cadencia sin limitar. Los tiempos GPU suman por separado principal, captura y las tres pasadas 2D. Datos crudos: `planar_kawase_sequential_2026_10_18.json`.

**Limitación de esta ejecución:** se guardaron las 24 filas y se imprimió `REFLECTION_BENCH_PASS`, pero el proceso terminó con código 255 después de medir. Dos repeticiones reducidas guardaron sus 12 filas y reprodujeron el cierre anómalo, incluso liberando primero las motos y luego el océano. No hubo diagnóstico de error de script o render en la salida capturada; su causa no está determinada. Los datos se conservan como medición provisional, no como benchmark con terminación correcta ni certificación de estabilidad. No se han seguido repitiendo ejecuciones idénticas. Las pruebas funcionales independientes de Planar, Kawase, integración, costa real y variantes P5 terminaron con código 0.

| Motos | Escala | GPU de las tres pasadas Kawase, p50 ms | WALL con Kawase, p50 ms | WALL sin Kawase, p50 ms |
| --- | --- | ---: | ---: | ---: |
| 1 | 0,35 | 0,041 | 7,00–7,04 | 6,68–6,83 |
| 1 | 0,5 | 0,061 | 7,18–7,41 | 8,37–8,87 |
| 4 | 0,35 | 0,041 | 10,09–10,84 | 10,56–10,58 |
| 4 | 0,5 | 0,061 | 10,07–10,92 | 9,84–10,00 |
| 6 | 0,35 | 0,041 | 13,64–13,83 | 13,00–14,66 |
| 6 | 0,5 | 0,061 | 13,83–14,19 | 13,23–14,29 |

WALL mide tiempo real transcurrido entre muestras, incluidas esperas y competencia externa. No es tiempo de física ni GPU. Las diferencias de WALL entre casos no aíslan el coste del blur: trayectorias, física y partículas no son un replay determinista. Los valores GPU de Kawase son la suma de las tres pasadas medidas; no representan GPU total ni cómputo global. Las muestras son breves, útiles como comprobación localizada y no como certificación de una carrera completa.

El usuario confirma posible concurrencia de runtimes durante el benchmark anterior. Sus resultados quedan marcados como potencialmente contaminados. Esta repetición no reproduce los 60–131 ms con seis motos y no respalda aquella hipótesis de un cuello de botella interno de física/CPU. Un diagnóstico independiente requeriría replay controlado y perfilado de física, efectos, CPU, esperas y cómputo global. No se atribuye a ninguno de ellos una diferencia residual sin ese perfilado.

Reproducción: `--script res://validation/ocean_reflection_benchmark.gd --resolution 1920x1080 -- --kawase-suite --samples=60 --warmup=30 --rounds=2 --result=res://validation/reports/planar_kawase_sequential_2026_10_18.json`. Ejecutar sin otros runtimes.

## Costa real y límites

`validation/ocean_planar_coast_runtime.gd` conserva la isla importada `testisland.glb` y su StandardMaterial3D original, usa oleaje de 3 m y tres cortes de cámara. Guarda vista principal y captura en `temp/planar_coast/`. Comprueba que el material incompatible se informa y permanece intacto, y que vuelve a publicarse el reflejo después de los cortes. No convierte automáticamente el material: el recorte parcial StandardMaterial3D sigue sin estar soportado. Esta prueba y las capturas no certifican ausencia de artefactos en cualquier costa ni resuelven geométricamente cada cresta del FFT.

Resultado real: salida 0, `failures=[]`. Inspección de `main_1.png` y `reflection_1.png`: el océano y la isla se dibujan, pero la captura muestra la parte inferior sin recortar del terreno. Es un defecto visual confirmado para esta costa, no una costa certificada. Antes de presentarlo como solución general hay que convertir de forma revisada su material a un ShaderMaterial compatible o diseñar geometría de costa para la captura. La conversión artística de ese material queda fuera de esta corrección localizada de rendimiento.

SSPR sigue siendo el valor predeterminado del recurso base. Kawase sigue desactivado por defecto; los recursos de usuario mantienen su elección. El modo de silueta y escala 0,01 son opciones independientes del benchmark de calidad iluminada.
