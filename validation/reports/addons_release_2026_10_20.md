# Release Ocean + Jet Ski — 20 de octubre de 2026

La fase de optimización queda cerrada. Se consolida el historial y los cambios
locales del usuario, y se entregan tres ZIP físicamente creados y probados desde
instalaciones nuevas. No hay una nueva optimización ni una ganancia de FPS.

## Identidad y estado Git

- Master remoto inicial comprobado tras fetch: `ce2a34346aefc9e62b3bac8623f22bfcf203f9f0`.
- Código, addons y herramientas validados: `5d8064f2dde447c3bd3b7fc1cd9ef40e365651ad`.
- El cierre documental que contiene este informe no altera el contenido de los addons.
- **SHA final publicado:** figura en `source_commit` del `manifest.json` externo y
  en `master_sha` de `publication_receipt.json`, generados al verificar el push.
  El recibo exige igualdad entre HEAD, master, origin/master y el SHA del servidor.
  Esto distingue el commit de los tests del commit final que añade el informe.
- Los ZIP definitivos se reconstruyen en memoria desde ese master publicado y
  se comparan byte a byte con los archivos probados. El manifiesto conserva también
  los árboles de ambos addons y los hashes exactos de los ZIP cubiertos por los tests.
- No se usa force push, reset destructivo, squash ni borrado de ramas.

Commits conservados e integrados después del master inicial:

| Commits | Contenido |
|---|---|
| `f759022`, `6488ac5`, `eeac635`, `e4f647d`, `654be29` | Contact Pipeline 3: informes, fixtures y herramientas de paridad/coste |
| `068e15c` | Eliminación local intencionada del límite de 144 FPS |
| `f395020` | Segundo mar local activado y estado guardado de animación/spray |
| `3946ad9` | Merge que conserva ambas líneas de historial |
| `7c00a7b`, `6f4914d`, `a2306be` | Empaquetador, documentación, auditoría de dependencias y aviso MIT |
| `5d8064f` | Conservación de fuentes GLSL en exportación y comprobación de la entrega |

La ascendencia de PERF-NATIVE-PRODUCTION `a03a6fa`, PERF-LOCAL-AREAS-2 `475cd5e`,
PERF-CONTROLLER-SCALING `b717765`, Async 3 `13c1e7c`, Native Performance 2
`d6940e8`/`3f0bc1a`/`ce2a343` y Contact Pipeline 3 `654be29` se ha comprobado.
PERF-CONTACT-1 y PERF-HULL-NATIVE-1 ya estaban incluidos en el master inicial.
La rama `codex/contact-pipeline-3` permanece en `654be29`; su worktree no se ha
modificado. Los parches descartados se conservan únicamente como evidencia bajo
`validation/`, no están aplicados ni entran en ningún ZIP.

Checkpoint previo: `codex/checkpoint-release-addons-20261020`. La copia del diff
original y del `.import` se conserva en `temp/addons_release_20261020/`.
Los commits de usuario preservan exactamente estos bytes, vueltos a comprobar
después del smoke final:

| Archivo | SHA256 |
|---|---|
| `project.godot` | `faf6f594c7c996088748a67dcab13c632386530528eda7884e05533aed0fc5b4` |
| `validation/hull_wave_physics_playground.tscn` | `df28c8f612b49683463de023f7b3879f45b1aa6c721d5ea598a8f1e70c4e9b24` |
| `validation/reports/async_fft_comparison_2026_10_19.svg.import` | `310aaf1df713e50d37daa2208a4df9718eac73e958fd967b7a18e2c6babfe45d` |

El `.import` de esa gráfica de benchmark sigue físicamente presente y respaldado,
pero no se versiona: se ignoran solamente los `.svg.import` de informes. No se
ignoran los ajustes de importación necesarios de los addons. La ausencia de
`application/run/max_fps` conserva el valor predeterminado **0**, sin límite;
no se restauró 144. La física permanece en **60 Hz**.

## Producción conservada

Se compararon directamente con `ce2a343` los árboles de fuentes/binarios C++,
`ocean.gd`, el proveedor/contactos y los sistemas/controlador/recursos de la moto:
sin diferencias de ejecución. Se conserva Ocean V4, CPU Lite 128/128/128 cúbica,
Async 3 real, AVX2/FFT, HULL V1 con geometría exclusivamente C++ y sin fallback
geométrico GDScript, y LEGACY_4POINT como modelo físico separado.

No se cambian áreas locales/composición, Hull Waves, Hull Foam/Running Foam,
tsunami, wave drift, presets, cámara, conducción, sprays, splash o partículas.
Los ajustes locales del usuario permanecen en la escena de producción; no se
copian arbitrariamente como nuevos valores predeterminados de los addons.

Los únicos cambios dentro de los addons son documentación/manifiesto, ejemplo
de exportación, activación del hook en el proyecto de ejemplo, el hook de
exportación y un aviso de terceros. No hay cambios matemáticos ni visuales.

## Empaquetado y dependencias

Se actualizó **`tools/package_water_addons.py`**, sin crear un empaquetador paralelo.
Lee blobs de un commit Git mediante `git archive`, nunca los archivos pendientes
o regenerados del worktree. Rechaza destinos dentro del repositorio y carpetas
de release existentes. Orden, fecha ZIP, permisos y compresión quedan fijados.
La fecha de este release es `2026-10-20`.

Los tres ZIP arrancan directamente en `addons/`, más un README de instalación
en la raíz. Ocean incluye todas sus carpetas runtime y bibliotecas de ambas
plataformas. Jet Ski contiene su prefab, físicas, cámaras, efectos, editor,
recursos y demo; **requiere Ocean**. El completo es la instalación recomendada.

Se conservan los `.uid` y `.import` versionados, includes y recursos dinámicos.
No se podaron recursos por nombre ni se consideraron huérfanos sin prueba.
La auditoría literal, sensible a mayúsculas, no encontró dependencias ausentes
o externas. Se comprobaron además **28 includes de shaders**, sin discrepancias
de rutas. `res://coastal_bakes` es una salida creada por el autor de bakes, no
un recurso de entrada; se distingue expresamente en la auditoría.

Se excluyen Git, caché Godot, temporales, intermediarios nativos, godot-cpp
descargado, capturas/logs de rendimiento, validaciones y herramientas MCP.
No se incluyen `addons/godot_mcp_toolkit`, Rapier ni escenas de desarrollo de raíz.
El aviso MIT de godot-cpp acompaña las bibliotecas en `THIRD_PARTY_NOTICES.md`.

### Corrección necesaria de exportación

La auditoría inicial descubrió que `*.glsl,*.inc,*.source` no bastaba para retener
el texto original de los GLSL importados como RDShaderFile. Una ruta existente
compila variantes leyendo GLSL mediante FileAccess. El ZIP sí tenía esos archivos,
pero la exportación preliminar sólo conservaba algunos como recursos importados.
Esa exportación preliminar no se acepta como entrega final.

**Ocean Shader Export** añade el texto GLSL al PCK además del recurso SPIR-V
importado, sin sustituirlo ni modificar el shader. Es un EditorExportPlugin de
23 líneas más su descriptor, independiente de Jet Ski. Debe activarse antes de
exportar; el proyecto de ejemplo lo activa. El editor plugin Jet Ski Inspector
sigue siendo opcional. Importar y ejecutar Ocean no requiere el hook.

La exportación final contiene **las 41 fuentes `.glsl`/`.inc`/`.source`**
comprobadas, además de los recursos importados, descriptor y registro de la
extensión. PCK v4: **622 entradas**, todas con MD5 interno verificado. La DLL
exportada coincide con su hash de producción. El ejecutable de comprobación
arrancó 600 frames con D3D12 desde su propia carpeta, sin dependencias del árbol
de desarrollo y sin errores. No se confunde esa comprobación con los ZIP de addons.

## Bibliotecas y plataformas

Descriptor: `addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension`.
Declara mínimo ABI 4.7 y claves Windows/Linux x86_64 que seleccionan la biblioteca
release tanto para editor como para export. El mínimo soportado/probado de este
paquete es **Godot 4.7.1**, Forward+ / RenderingDevice y CPU x86_64 AVX2.

| Biblioteca en `bin/` | SHA256 |
|---|---|
| `ocean_query_native.windows.template_release.x86_64.dll` | `e22176c1d2e0ef058d4816d63b76ba353ed516ed2e8b52de7cfdfd0fbec3f0d0` |
| `ocean_query_native.linux.template_release.x86_64.so` | `3f9fb2f1cb9422dc8d2f0d82e79342f1e9561a846011b0759495e8720a9387c9` |

No se recompilaron: son los binarios ya validados para el C++ que permanece intacto.
Ambos cargan OceanQueryNative y HullBuoyancyGeometryNative y la interfaz Async Lite.
Se verificaron sus hashes en los dos proyectos extraídos, además de la DLL exportada.

## Resultados de instalación y smokes

Cada proyecto se creó **extrayendo el ZIP**, en una carpeta nueva sin `.godot`.
JetSki_Addon.zip también pasó descompresión completa y CRC en `JetSkiArchive/`;
no se presenta como un addon ejecutable sin Ocean.

| Prueba | Resultado y alcance |
|---|---|
| OceanOnly import | PASS, sólo Ocean; sin Jet Ski, MCP o validation |
| OceanOnly gráfico | PASS, D3D12/RTX 4070 Laptop, océano/FFT y muestra válida, 128 cúbica, pool Async de 3 workers y cero fallos |
| TestAddons import | PASS, ambos addons y plugins del ejemplo cargados |
| TestAddons gráfico | PASS, Jolt 60 Hz, HULL nativo, 419 lotes geométricos, propulsión real, movimiento, cámara y reset con estado finito |
| Producción guardada | PASS, escena original con cambios del usuario, 119 lotes HULL, una carga geométrica, Async modo 1 / 3 workers y 60 Hz |
| Linux OceanOnly/TestAddons | PASS, Ubuntu 22.04 WSL2; descriptor, ambas clases nativas e interfaz Async, sin render gráfico |
| ZIP/estructura/dependencias | PASS, CRC, bytes extraídos y rutas sensibles a mayúsculas; todo bajo los dos addons |
| Exportación Windows | PASS, PCK/descriptor/DLL y 41 fuentes; arranque real del ejecutable exportado sin errores |

Los logs finales no contienen errores de importación, parseo, ejecución ni fugas
ObjectDB detectadas. Las capturas gráficas de OceanOnly y TestAddons se revisaron.
Las pruebas no cambian parámetros ni seleccionan un backend alternativo para la
moto. La prueba OceanOnly configura un consumidor de agua y proporciona cámara,
luz y entorno como lo haría cualquier host sin gameplay.

Limitaciones explícitas: no se ejecutó este release en Steam Deck física, GPU AMD
Linux ni bajo un Steam Linux Runtime elegido. No se realizó exportación del juego
Linux. La carga SO no se declara como certificación gráfica de Linux. Los smokes
ejercitan arranque, flotación/propulsión y reset; no sustituyen una matriz visual
completa de cada efecto, mapa, perfil o modo físico. No se repiten benchmarks.

## ZIP finales

Carpeta externa al repositorio:
`C:/Users/ehort/Documents/GODOT PROJECTS/WaterRace_Addons_Release_2026-10-20/`.
Los tamaños siguientes son bytes exactos; el número incluye el README de cada ZIP.

| Archivo | Archivos | Bytes | SHA256 |
|---|---:|---:|---|
| Ocean_Addon.zip | 415 | 37820759 | `f5d2084dd7d3d55980f4322273e32684a81fc8753ac7950c00972b0cee7ec05b` |
| JetSki_Addon.zip | 183 | 60762036 | `f605bae9d1b33f47eced397b0c7a86be336f31ffecfdb6e9165ca40ad39d705f` |
| WaterRace_Addons_Complete.zip | 597 | 98580511 | `dcf88ca5cde8de0223d1bbaa6a3451f5ee12a494ac2c74057845c4257fe1b8f4` |

Rutas absolutas:

- `C:/Users/ehort/Documents/GODOT PROJECTS/WaterRace_Addons_Release_2026-10-20/Ocean_Addon.zip`
- `C:/Users/ehort/Documents/GODOT PROJECTS/WaterRace_Addons_Release_2026-10-20/JetSki_Addon.zip`
- `C:/Users/ehort/Documents/GODOT PROJECTS/WaterRace_Addons_Release_2026-10-20/WaterRace_Addons_Complete.zip`

La misma carpeta contiene `manifest.json`, `README_INSTALLATION.md`,
`test_results.json`, los proyectos extraídos y las evidencias de exportación.
El manifiesto registra SHA publicado, fecha, conteos, tamaños, hashes ZIP/nativos,
dependencias, plataformas, resultados y hashes de cada archivo de los addons.

## Instalación y reproducción

1. Extraer el completo en la raíz de un proyecto Godot 4.7.1 Forward+, conservando
   `addons/ocean/` y `addons/jet_ski/`. No añadir una carpeta contenedora.
2. En un proyecto nuevo, copiar `addons/jet_ski/examples/project.godot.example`
   como `project.godot` e importar. En uno existente configurar Jolt, 60 Hz e
   interpolación y respetar sus entradas existentes.
3. Ejecutar `res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn`.
   Para integrar manualmente, instanciar `ocean.tscn` y `jet_ski_01.tscn` y asignar
   la referencia Water → Ocean. Ocean sin Jet Ski necesita la cámara/luz del host.
4. Usar W/S, A/D, flechas, R/T y controles de cámara documentados. El plugin
   Inspector es opcional. Antes de exportar, activar Ocean Shader Export y usar
   los filtros `*.glsl,*.inc,*.source`; hay un `export_presets.cfg.example` incluido.

Reproducción del empaquetado desde el repositorio:

```text
python -B tools/package_water_addons.py --ref master --date 2026-10-20 --out <carpeta-nueva-externa>
python -B validation/addon/check_addons_release.py <carpeta-release-con-evidencias>
python -B tools/package_water_addons.py --ref master --date 2026-10-20 --out <carpeta-release> --verify --tests <carpeta-release>/test_results.json
```

El harness `validation/addon/addons_release_smoke.gd` se copia como
`release_smoke.gd` en los proyectos extraídos: ejecución normal para OceanOnly,
`-- --complete` para TestAddons y `--headless ... -- --native-only` en Linux.
No es una dependencia del addon. La auditoría de exportación reutiliza
`validation/export/e2_pack_audit.py`; la recolección exige logs sin errores,
hashes correctos, clases cargadas, tres workers reales y todas las fuentes PCK.

El grafo MCP no estuvo disponible (Transport closed); la inspección de código,
dependencias y configuración se hizo directamente sobre las fuentes actuales.
No se trabajó en nuevas optimizaciones ni se incorporó el prototipo descartado.
