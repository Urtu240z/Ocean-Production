# E2 — exportación y propuesta de recuperación de espacio

Base: `13e6c5fb9b4e0ae5e5f28a348b66ffecdad8f9bb`, `wip/feel-soft-water`.
Esta fase no elimina archivos, cachés, ramas, worktrees ni distribuciones WSL.
No modifica archivos de los addons, física, FFT, shaders, cámara, spray,
conducción ni parámetros del proyecto original. Solo añade herramientas,
presets reutilizables y documentación fuera de los addons.

## Auditoría de exportación

Los presets originales tienen `all_resources`, filtros de shaders dinámicos,
arquitectura x86-64, PCK incrustado y plantillas predeterminadas. Pero el proyecto
original arranca `validation/p0_open_ocean.tscn`, tiene variantes de benchmark y
autoload/plugin MCP. Exportarlo sin preparar una escena de distribución incluiría
contenido de desarrollo. No se cambia esa configuración ni se afirma haber
exportado la escena de isla/producción completa.

Se reutiliza la instalación limpia E1 y su ejemplo autónomo Ocean + Jet Ski.
Los nuevos presets están en `validation/export/e2_export_presets.cfg`. El mar
mantiene los perfiles del ejemplo E1; el proyecto original conserva los suyos.
Había seis plantillas 4.7.1 instaladas en cada perfil Windows, con hashes idénticos.
Se usan las existentes; **no hay descargas de herramientas/plantillas, compilaciones
ni instalaciones nuevas**. Solo se añaden los avisos de licencia del motor a los ZIP.
Linux se exporta desde el editor Windows, sin instalar plantillas en WSL.

| Comprobación | Linux release | Windows release |
| --- | --- | --- |
| Motor | Godot 4.7.1 oficial | Godot 4.7.1 oficial |
| Ejecutable | ELF x86-64, 199.031.232 bytes | PE x86-64, 235.640.664 bytes |
| Biblioteca externa | SO E1, 2.820.824 bytes | DLL D3/E1, 924.672 bytes |
| PCK incrustado | v4, 420 entradas | v4, 416 entradas |
| Integridad interna | Todos los MD5 verificados | Todos los MD5 verificados |
| Integridad de biblioteca | SHA-256 igual a E1 | SHA-256 igual a D3/E1 |
| Arranque real | Desde `/tmp`, Vulkan llvmpipe | Desde `C:/Windows/Temp`, D3D12 RTX 4070 |
| Ejecución | 120 fotogramas, salida 0 | 120 fotogramas, salida 0 |
| Campos físicos registrados | 90 correctos, cero fallidos | 90 correctos, cero fallidos |
| Configuración | CPU_LITE_B, AVX2, 128/128/128 | CPU_LITE_B, AVX2, 128/128/128 |
| Compartición | Máximo un build por tick tras configurar | Máximo un build por tick tras configurar |
| Errores del runtime | Ninguno registrado | Ninguno registrado |

Ambos PCK incluyen las escenas de Ocean, Jet Ski y ejemplo; ocho PNG, recursos,
shaders y los `.inc`/`.source` dinámicos. No incluyen `gameplay/`, `validation/`,
`temp/`, MCP, autoloads privados ni la carpeta `Splash_1` exterior. Las referencias
son `res://addons/...`; la biblioteca nativa se distribuye junto al ejecutable y
se carga correctamente sin el árbol fuente. La captura automática registra
`project_path` vacío y la escena empaquetada, no una ruta física de desarrollo.
No se han reconstruido campos por contacto ni introducido adaptadores.

Se conserva shader_baker: 3.392.936 bytes de caché Vulkan y 4.261.352 de D3D12,
según destino. No se incluyen cachés DXIL en el destino Linux. La diferencia de
tamaño restante procede de las plantillas y recursos exportados. No se recortan
Legacy/Heavy ni texturas asignadas para reducir el paquete.

El primer intento comenzó antes de terminar la copia del preset: falló por falta
de `export_presets.cfg`. Se conserva el registro. Otro intento de auditoría por
CLI detectó la protección de las plantillas release contra `--path`; `--script`
no ejecutó el probe externo. Se sustituyó esa auditoría por inspección directa
del formato PCK y arranque normal del ejecutable. No se cambió el motor ni se
añadió un validador obligatorio a los addons.

## Espacio medido y clasificación

Al inicio: 6.843.756.544 bytes libres, **6,37 GiB**. Los tamaños siguientes son
sumas de archivos reales, sin estimar a partir de tamaños de ZIP ni volver a
copiar proyectos. También se registra asignación NTFS mediante
`GetFileInformationByHandleEx(FileStandardInfo)`, sin fallbacks.
WSL usa `du -x -B1`; sus cifras se solapan con el VHD y no se suman dos veces.

| Elemento | Tamaño lógico GiB | Clasificación |
| --- | ---: | --- |
| WSL E1 `wsl/ext4.vhdx` | 2,482 | Conservar distribución y herramientas; no borrar |
| WSL `/opt/e1/focal` | 0,763 | Sysroot/compilador y cachés; contenido dentro del VHD |
| WSL `/opt/e1/clean_project` | 0,171 | Instalación mínima reproducible; incluye 0,116 GiB de caché |
| WSL `/opt/e1/godot-cpp` | 0,039 | SDK auxiliar inicial y compilación; dentro del VHD |
| E1 `clean_windows` | 0,170 al medir | Copia mínima reproducible; se reutiliza para E2 |
| Editor Godot Linux descomprimido | 0,135 | Herramienta útil; conservar por ahora |
| ZIP oficial Godot Linux | 0,071 | Descarga duplicada, regenerable; ejecutable conservado |
| Tar de fuentes godot-cpp | 0,032 | Regenerable desde Git del SDK fijado |
| Rootfs descargados Ubuntu 20.04 + 22.04 | 0,054 | Regenerables; distros/sysroot ya instalados |
| Producción `.godot/imported` | 0,437 | Caché regenerable, retirar con Godot cerrado |
| Producción `.godot/shader_cache` | 0,007 | Caché regenerable |
| Native `ocean_query/build` | 0,030 | Intermedios; conservar su `.gdignore` versionado |
| SDK local `godot-cpp` completo | 0,286 | Conservar código/Git; solo 0,253 GiB son generados |
| Evidencias estables E1 | 0,055 | Conservar; 68 archivos verificados por SHA-256 |
| Copias E1 idénticas a entrega estable | 0,054 | Recuperables solo verificando otra vez los hashes |
| Exportaciones E2 sin comprimir | 0,408 | Regenerables tras verificar sus ZIP estables |

Las cifras lógicas excluyen redondeo de clusters; el manifiesto contiene también
los bytes asignados por NTFS. La instalación Windows puede crecer con nuevas
cachés al exportar; antes de limpiar se debe verificar otra vez su estado.

**No borrar `.godot` completa.** Además de importaciones contiene aproximadamente
0,122 GiB de perfiles y resultados históricos, CSV/JSON/logs, incluido
`target_validation` de 69.715.183 bytes. Se preservan como evidencias, al igual
que preferencias de editor, UID y lista de extensiones. El inventario de borrado
propuesto solo enumera imported/shader_cache e intermedios no versionados.

## Limpieza propuesta — pendiente de autorización

Primera selección, en Windows, sin tocar WSL ni fuentes:

1. `.godot/imported/` y `.godot/shader_cache/`, con Godot cerrado.
2. Archivos no versionados de `addons/ocean/physics/native/ocean_query/build/`;
   dejar `.gdignore`. **Nunca borrar `bin/`**, la DLL, el SO ni el descriptor.
3. Solo archivos generados del SDK enumerados en el manifiesto: gen/bin,
   objetos y cachés Python no versionados. Conservar SDK fuente, `.git`, su commit
   fijado y los dos Info.plist de tests versionados bajo bin. No borrar esas
   carpetas completas sin aplicar la lista de archivos.
4. `temp/phase_e1_20261016/clean_windows/`, después de conservar el preset E2
   y verificar recursos contra los ZIP E1 y el código versionado.
5. ZIP Godot Linux, tar SDK y los dos rootfs descargados indicados arriba.
   Mantener el editor Linux descomprimido y ambas instalaciones dentro de WSL.
6. Solo las copias E1 que tengan hash idéntico a la entrega estable, sin retirar
   evidencia única. Las rutas y SHA-256 están enumeradas, no se usa un glob temp.
7. Exportaciones E2 sin comprimir en `temp/phase_e2_20261016/dist/`, únicamente
   después de verificar los ZIP distribuidos y conservar todos los logs/informes.

Ahorro lógico medido: **1.190.549.428 bytes de E1/producción (~1,109 GiB)**,
más **438.417.392 bytes de salidas E2 (~0,408 GiB)** antes de sus README.
Total aproximado **1,52 GiB recuperables directamente en C:**, sujeto a la
verificación final de archivos y a que Godot esté cerrado. No se ha liberado aún.

Dentro de WSL, sin borrar la distribución, otra selección posible es:

- `/var/cache/apt/`: 280.576.000 bytes.
- `/var/lib/apt/lists/`: 331.026.432 bytes.
- `/opt/e1/focal/var/cache/apt/`: 173.289.472 bytes.
- `/opt/e1/focal/var/lib/apt/lists/`: 248.532.992 bytes.
- `/opt/e1/clean_project/.godot/`: 124.395.520 bytes.
- `/root/.cache/`: 6.619.136 bytes, previa revisión de contenido regenerable.

Son aproximadamente **1,08 GiB internos**. El VHD no se reduce necesariamente al
borrar dentro de Linux: **no cuentan como recuperación inmediata en C:**.
Una compactación posterior requeriría otra autorización, con WSL detenido y sus
datos preservados. No se ejecuta fstrim, compactación ni `wsl --unregister`.

Hay además 0,335 GiB de plantillas idénticas entre los perfiles Windows DEV y
ehort. La copia DEV es la usada ahora; no se recomienda retirar la otra sin
confirmar que ningún otro usuario/proyecto la utiliza. No se suma al ahorro seguro.

`space_audit.json` conserva rutas por archivo, hashes, tamaños y clasificación,
incluidos `regenerable_files`, `sdk_generated_files`, `e1_duplicate_evidence`,
`legacy_heavy_inventory`, `validation_inventory` y `old_asset_candidates`.
La propuesta evita `git clean`, borrados recursivos de temp y cambios del índice
de producción. Se mantienen VHD, fuentes, binarios, todos los commits y evidencias.

## Inventario para la siguiente fase

- **Legacy 4 puntos:** sigue siendo una rama seleccionable en controlador y
  `jet_ski_water_physics_system.gd`. Comparte marcadores y contratos con funciones
  actuales. No es seguro retirar esos marcadores o renumerar enums sin migración.
- **Heavy:** el script de respuesta se precarga desde el sistema de agua y tiene
  referencias activas en control de inercia/configuración. No se puede borrar el
  archivo aisladamente aunque no sea el modo predeterminado.
- **Atención:** `HULL_V1_PREVIOUS` es el nombre del modo V1 normal de producción,
  no equivale a `LEGACY_4POINT`. No clasificarlo como obsoleto por su nombre.
- HUD opcional y validadores Heavy/Legacy: conservar hasta una retirada coordinada
  de opciones, exports, referencias y pruebas. Nada de ello se elimina en E2.
- **Validación:** 804 archivos al iniciar la auditoría, 600.539.239 bytes. Incluye
  164 scripts, fixtures, 101 `.gz`, 40 JSON, CSV, capturas y recursos de escenario.
  El inventario no declara esos datos obsoletos ni prescindibles; algunos son
  oráculos y evidencias históricas que deben conservarse.
- **Assets antiguos candidatos:** 70 archivos, 21.571.100 bytes, incluidos
  `Splash_2`, atlas/máscaras en la raíz y variantes spindrift. No se necesitan en
  el ejemplo exportado, pero no se autoriza su retirada: revisar referencias
  dinámicas, usos de autoría y respaldo antes de hacerlo.
- Los atlas y droplets dentro del addon conservan referencias/controles de
  fallback y edición. No retirar un asset solo porque no se vea en la secuencia
  PNG actual: hay que modificar y validar sus referencias en otra fase.

## Entrega y límites

ZIP ejecutables, inventarios y evidencias en
`Water Race Backups/20261016_e2_exports/`. El manifiesto de entrega registra hashes,
tamaños finales, commit y espacio libre. Los ZIP de jugadores incluyen solo los
archivos necesarios para ejecutar; no incluyen herramientas de auditoría ni SDK.

Linux se ha ejecutado realmente en WSL2 con Vulkan por software. **Steam Deck
físico, AMD/RADV, gamepad, rendimiento, consumo y Steam Linux Runtime siguen
pendientes.** E2 no añade optimizaciones específicas ni declara Deck Verified.
El entorno WSL queda detenido al cerrar la fase, conservando distribución y datos.
