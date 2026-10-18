# Reflexiones planares: segunda revisión de ingeniería

## Resultado

Se conserva SSPR como método predeterminado y Planar como opción. Se han corregido la aceptación de proyección, el aislamiento fijo por capa 20, la gestión de otras cámaras, la publicación de capturas obsoletas y el trabajo innecesario cuando el agua no es visible. Se añade un contrato explícito de recorte parcial y un filtrado espacial por rugosidad que utiliza el Kawase ya conectado.

No se certifica todavía cualquier costa ni una carrera completa. El recorte de materiales StandardMaterial3D arbitrarios no se resuelve automáticamente; requiere conversión revisada o exclusión explícita. Las mediciones son preliminares y muestran variación importante con seis motos.

## Cambios frente a las consideraciones recibidas

| Consideración | Implementación y evidencia |
| --- | --- |
| Profundidad proyectada | Se exige `w > 0.00001`, `-w <= z <= w` y UV válidas. Se usa el intervalo de la matriz CPU de Camera3D, no el de profundidad reverse-Z del backend. |
| Capa 20 y otras cámaras | Selección automática de capas libres o selección explícita con detección de conflicto. Se agrupan objetos por sus máscaras originales y se remapean cámaras y máscaras de luces del mismo mundo, preservando visibilidad selectiva y restaurando los bits administrados. El conflicto provoca fallback al entorno. |
| Geometría sumergida | Se omiten objetos completamente sumergidos según su AABB mundial. Un grupo permite excluir subárboles completos. Para MeshInstance3D con ShaderMaterial compatible hay descarte parcial por altura solo desde la cámara reflejada, mediante variantes privadas y reversibles. |
| Captura continua | Se utiliza UPDATE_ONCE por captura. La superficie oculta o fuera de frustum detiene el trabajo. La detección es conservadora e incluye los límites de desplazamiento FFT; no detecta toda oclusión por otros objetos. |
| Cadencia | Opcional, 0 conserva actualización por fotograma. Las imágenes retenidas mantienen la matriz de su captura. Cambios de cámara/mundo, tamaño y saltos importantes invalidan la salida. Puede haber saltos visuales al limitar FPS durante conducción rápida. |
| Rugosidad | Planar Roughness Blur mezcla la captura original y Kawase en cada píxel según rugosidad y distancia. No se simula rugosidad reduciendo únicamente la intensidad. Es opcional para conservar el comportamiento del slider Kawase existente. |
| Instanciación | SSPR no crea el nodo ni el viewport planar. Se crean al seleccionar Planar por primera vez; después permanecen pausados al volver a SSPR. |

## Recorte: alcance y preparación de la escena

El grupo predeterminado `ocean_planar_clip` habilita recorte parcial en MeshInstance3D, también a través de un padre agrupado. Requiere ShaderMaterial con `fragment()`, sin `next_pass`, y hasta 13 declaraciones de `instance uniform`; utiliza dos parámetros de instancia adicionales. Las variantes no modifican recursos compartidos, mallas ni shaders originales y se restauran al desactivar. Las modificaciones de las fuentes se recogen en el siguiente escaneo (0.5 s); las aplicaciones que animen parámetros deben mantener su referencia al material original.

StandardMaterial3D, MultiMesh, partículas, shaders con proyecciones personalizadas o desplazamientos especiales requieren revisión propia. Los materiales incompatibles se notifican y se enumeran en el estado del capturador. Un objeto no compatible no se convierte ni se elimina silenciosamente: usar `ocean_planar_exclude` cuando proceda. Estas opciones no equivalen a un plano oblicuo universal del motor.

La API de Godot 4.7.1 instalada fue inspeccionada: ni Camera3D ni RenderingServer exponen una proyección personalizada/plano oblicuo. La limitación también está recogida en las [propuestas del motor](https://github.com/godotengine/godot-proposals/issues/501). No se modificó el ejecutable de Godot.

## Pruebas

- `ocean_planar_hardening_runtime.gd`: nivel del mar 7 con render real; objeto que atraviesa el agua y oculta un marcador fuera de pantalla; tras recorte, el marcador pasa de 0 a 914 píxeles en la captura. Cámaras adicionales con máscaras 1 y 2, luz con máscara selectiva, conflicto real de capa 20, selección alternativa automática, restauración de máscaras/materiales, pausa por visibilidad y frustum, cadencia conservando matriz, cambio de cámara y oleaje/espuma/distorsión activos con cámara móvil.
- `ocean_planar_reflection_runtime.gd`: publicación sobre el agua, cambio de resolución, variantes Optics, SSPR/Planar, Kawase, desactivación, inmersión y reanudación.
- `ocean_reflection_kawase_runtime.gd`: intensidad, dispersión espacial, conservación HDR y confianza, bypass exacto y tamaños.
- `p5_reflections_runtime_validation.gd`: regresión existente con 40 cambios de variante.

La prueba de costa usa geometría controlada; no sustituye inspección de todos los materiales de la isla o de una costa comercial. La prueba con mar distinto de cero ya no se limita a mirror_transform().

## Benchmark preliminar

Godot 4.7.1 oficial, Forward+, D3D12 12_0, RTX 4070 Laptop, ventana/render a 1920 × 1080, VSync desactivado. Motos reales con física y efectos, oleaje de 3 m, espuma y distorsión activos, cámara de persecución móvil. Se mantiene la isla de P0; se desactiva el módulo costero y no hay IA ni colisiones entre motos. Kawase desactivado en todos los casos para comparar el productor de reflejos.

18 casos: 1/4/6 motos × SSPR 0.5 / Planar 0.5 / Planar 0.35 × dos repeticiones con orden inverso. Cada caso tiene 40 fotogramas de calentamiento y 80 muestras. Datos crudos y metadatos: `planar_benchmark_2026_10_18.json`. No se congeló la física ni se hizo replay determinista: las posiciones, velocidades, oleaje y partículas varían entre casos. No se interpreta la diferencia entre métodos como un porcentaje de mejora definitivo.

Rangos de las medianas de ambas repeticiones; milisegundos. La GPU de render es la suma de tiempos de los viewports principal y planar, no solo el principal. No incluye trabajo de cómputo global no atribuido a esos viewports, ni representa GPU total. El tiempo wall corresponde a la aplicación completa.

| Motos | Método | GPU render, p50 | Solo captura planar, p50 | Wall, p50 |
| --- | --- | ---: | ---: | ---: |
| 1 | SSPR 0.5 | 6.16–7.01 | — | 11.03–11.79 |
| 1 | Planar 0.5 | 7.32–7.57 | 1.42–1.43 | 12.24–12.55 |
| 1 | Planar 0.35 | 6.25–7.26 | 1.05–1.17 | 11.10–11.91 |
| 4 | SSPR 0.5 | 10.18–10.24 | — | 20.67–33.65 |
| 4 | Planar 0.5 | 7.91–10.88 | 1.56–2.04 | 19.72–26.47 |
| 4 | Planar 0.35 | 8.55–9.88 | 1.36–1.37 | 19.23–27.74 |
| 6 | SSPR 0.5 | 6.30–7.41 | — | 60.32–131.00 |
| 6 | Planar 0.5 | 8.39–8.94 | 1.47–1.66 | 57.34–121.71 |
| 6 | Planar 0.35 | 7.86–8.28 | 1.22–1.28 | 67.95–98.97 |

La captura adicional cuesta aproximadamente 1.05–2.04 ms GPU en estos casos. Con seis motos, la variación wall es demasiado grande para sacar conclusiones de FPS o atribuir el cuello de botella a los reflejos: hay que perfilar física/CPU y cómputo fuera del viewport por separado. El monitor periódico TIME_PROCESS se conserva como diagnóstico en los datos crudos, sin interpretarlo como una medición sincronizada de CPU de cada fotograma.

Reproducción: ejecutar Godot con `--script res://validation/ocean_reflection_benchmark.gd --resolution 1920x1080 -- --samples=80 --warmup=40 --rounds=2`. La comparación final de producción debe usar una captura/replay controlada de la carrera, ventanas de muestreo más largas y las seis motos con colisiones e IA reales.

## Historial

No se reescribe el commit bb8a31b ya publicado. Esta revisión afecta a reflexiones, sus pruebas y documentación; no cambia las herramientas de horneado costero ni los ajustes de espuma/motos abiertos en paralelo. Un commit posterior debe seleccionar estos archivos explícitamente para no repetir la mezcla de funcionalidades.
