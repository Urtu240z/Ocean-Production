# Integración final a master — 2026-10-20

Registro de validaciones del árbol que se entrega para el merge. El SHA final de publicación se confirma mediante Git HEAD/master/origin/master y en la entrega, no mediante un hash autorreferencial dentro de este archivo.

## Estado preservado e historial

- Rama de trabajo: codex/async-fft-lite-workers.
- Base remota comprobada tras fetch: `081dd40fd8fcefb585a634c09652ec8bd72fafed`.
- Cambios locales previos revisados y guardados en `128158cccac7f83cf5dd94f2a0b86c5c6c1f4061`; referencia de seguridad codex/checkpoint-before-master-20261020.
- Se conservan los commits individuales de ASYNC, PERF-CONTACT-1, PERF-HULL-NATIVE-1, a03a6fa, 475cd5e y b717765. No squash, rebase, force push ni reset --hard.
- Los pendientes pertenecían al proyecto: autoría de escenas/presets/FX, integración tsunami/waterline/caustics, instrumentación y evidencias/UID. Se conservaron sus valores actuales. Guardarlos no implica retunar parámetros respecto al estado local recibido.
- La única selección nueva de producción es fft_execution_mode = ASYNC_3_WORKERS en el proveedor normal. No se toca la resolución, espectro, AVX2, fórmulas de flotabilidad, fuerzas ni conducción.

## HULL y Async reales

La producción no contiene GeometryBackend/geometry_backend, fallback geométrico GDScript ni rutinas dinámicas _submerged_tetra. La referencia queda solo en validation/. LEGACY_4POINT conserva su modelo y no sustituye automáticamente un HULL inválido.

El smoke carga la escena guardada sin seleccionar workers ni backend geométrico por argumentos. Resultado: modo nativo 1, **3 trabajadores reales**, 60 Hz, una subida de geometría y 119 lotes HULL en la ventana de 120 ticks. Muestra de agua y estado del vehículo finitos y válidos, cero fallos.

El proyecto mantiene run/main_scene = res://validation/p0_open_ocean.tscn. También se arrancó esa escena principal, sin override de renderer, durante 120 frames: Forward+ Vulkan / RTX 4070 Laptop, sin errores. La escena de vehículo guardada se comprobó con D3D12, sin cambiar el proyecto.

## DLL Windows y SO Linux

| Biblioteca | Bytes | SHA256 |
|---|---:|---|
| DLL Windows x86_64 | 993280 | e22176c1d2e0ef058d4816d63b76ba353ed516ed2e8b52de7cfdfd0fbec3f0d0 |
| SO Linux x86_64 | 2931416 | 3f9fb2f1cb9422dc8d2f0d82e79342f1e9561a846011b0759495e8720a9387c9 |

La SO anterior no contenía HULL nativo ni las interfaces Async Lite; se reconstruyó antes de permitir el merge. Usa el SDK API 4.7 y el sysroot existente GCC 9.4 / glibc 2.31, libstdc++/libgcc estáticas y máximo GLIBC 2.29. ldd -r resuelve sus dependencias y el motor Linux registra las clases y ejecuta sus métodos reales. No se distribuye una SO antigua con un script que requiera HULL nuevo.

SCons Windows confirma que la DLL y su SDK están al día con las fuentes C++ finales; su hash se conserva. El descriptor activo selecciona la DLL o SO canónicas según plataforma, mínimo Godot 4.7.

Godot oficial usado en ambos sistemas: 4.7.1 a13da4feb. El runtime Linux se descargó de la release oficial a temp/, sin incorporarlo al repositorio.

## Comprobaciones funcionales

| Comprobación | Windows | Linux WSL |
|---|---|---|
| Carga real de la GDExtension | PASS | PASS |
| HULL aislado, comparación binaria con referencia local | 31.600 valores, 0 diferencias | 31.600 valores, 0 diferencias |
| Async Lite frente a sync, fixtures existentes | 81.120 valores exactos, 0 fallos | 81.120 valores exactos, 0 fallos |
| Escena de vehículo, sin override de workers | PASS: 3 workers, HULL nativo | No prueba gráfica nueva |
| Escena principal configurada | PASS: Vulkan, 120 frames | No prueba gráfica nueva |

La regresión focalizada de los cambios locales de waterline/tsunami pasa sus nueve posiciones; error máximo de altura GPU/CPU 0.000234603882 m. No hay errores de ejecución en los logs de validación aceptados. El aviso preexistente de UID de foam2d resuelto por ruta se conserva.

No se repiten benchmarks completos. Estos son tests funcionales y smokes, no nuevas cifras de rendimiento ni certificación Steam Deck. La igualdad nativa/GDScript se exige dentro de cada plataforma; no se promete trayectoria binaria idéntica entre compiladores o sistemas.

## Rapier

addons/godot-rapier3d ya no existía al recibir esta integración; su desaparición se registró en el trabajo previo. No se restaura ni se convierte en dependencia.

La configuración real usa Jolt Physics. La búsqueda acotada de scripts, escenas, recursos, manifiestos y descriptores no encuentra uso ejecutable de Rapier, Fluid3D o StateManager3D. Solo quedan referencias históricas en informes. La caché de extensiones contiene únicamente Ocean Query Native, y los smokes actuales cargan sin errores de dependencia ausente.

## Reproducibilidad y cierre Git

- build_final_linux_wsl.sh reutiliza el sysroot existente, verifica la identidad del workspace montado y desmonta solamente su propio montaje.
- hull_native_isolated.gd admite --output para conservar separadas las capturas Windows/Linux sin sobrescribir evidencias anteriores.
- final_master_integration_smoke.gd comprueba el modo normal de producción.
- Resultados y logs locales: temp/final_integration/. [Resumen verificable](master_integration_checks_2026_10_20.json).
- El manifiesto Jet Ski exige explícitamente las clases nativas finales; LINUX.md distingue el binario actual de la base histórica E1.

Tras versionar este árbol, crear checkpoint-ready, volver a verificar origin, fusionar con --no-ff en master, ejecutar el smoke y comprobar la conservación de ancestros antes de git push origin master. Verificar después que HEAD = master = origin/master = refs/heads/master remoto. No publicar si falla cualquiera de esos pasos.
