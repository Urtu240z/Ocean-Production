# E1 — Linux x86-64 y preparación de Steam Deck

Base D3: `9d34603a08c758f5d7ef5032f92715b072d02f39`, rama
`wip/feel-soft-water`. Referencia: `preserve/phase-e1-before-20261016`.

## Implementación

- `.so` Linux x86-64 dentro de Ocean, junto a la DLL Windows D3 inalterada.
- Descriptor activo y template con mínimo Godot 4.7, correspondiente a la API
  4.7 del SDK; probado con Godot 4.7.1 oficial `a13da4feb` en ambos sistemas.
  Se conservan las rutas Windows y Linux existentes y el símbolo de entrada.
- SConstruct usa objetos compartidos PIC y nombre canónico sin prefijo `lib`
  en Linux. Separa intermedios por plataforma y admite `object_dir` explícito.
  Windows mantiene su ruta de objetos, flags MSVC y enlace advapi32 anteriores.
- Los kernels SIMD existentes necesitan AVX2/FMA; GCC recibe esos flags solo en
  sus dos unidades aisladas, sin contracción implícita. La detección de CPU en la
  unidad base añade GCC/Clang con comprobación AVX2/FMA y soporte del SO.
  La rama MSVC, la ruta escalar y las fórmulas de la FFT no se modifican.
- Script Linux y perfil mínimo de bindings del SDK, sin recortar los métodos de
  OceanQueryNative. No se añade trabajo por contacto ni cambia el reloj de olas.
- Documentación de instalación, manifiesto Jet Ski y validador nativo E1.

No hay cambios en física, conducción, flotabilidad, cámara, spray, shaders,
resoluciones, perfiles del océano ni configuración del proyecto de producción.
Los archivos Jet Ski ejecutables son exactamente los de D3; solo cambian sus
documentos y manifiesto de plataformas. No se incorporan P5, nuevos proveedores,
adaptadores ni modos de agua. No se eliminan Legacy/Heavy ni evidencias.

## Herramientas, ABI y espacio

Al empezar: 10.361.335.808 bytes libres, aproximadamente 9,65 GiB, una sola unidad.
No había distribución WSL ni compilador Linux. Se importa un rootfs mínimo oficial
Ubuntu 22.04 en `temp/phase_e1_20261016/wsl`, distribución
`WaterRace-E1-Ubuntu22`. No se instala Docker, otra VM ni una copia del proyecto.
Solo se exporta el SDK nativo necesario y se crean proyectos mínimos con addons.

La primera compilación Ubuntu 22.04 enlazaba GLIBC 2.35. No se distribuye: se
recompila con un sysroot Ubuntu 20.04 pequeño dentro del mismo WSL para ampliar
compatibilidad ABI, sin cambiar cálculos. GCC 9.4.0, glibc 2.31, SCons 4.8.1,
`godot-cpp` `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`, API 4.7, single precision,
release, optimize=speed, lto=none, sin fast-math ni `-march=native`.

Binario final: 2.820.824 bytes, SHA-256
`9f6a5fb026eb092dc2283418534e59a6b1fa2c47794cefc5ed5244539fa1f176`.
ELF64 x86-64, símbolo `ocean_query_native_library_init`, sin símbolos pendientes
de enlace. libstdc++/libgcc estáticas; dependencias dinámicas libc/libm/libpthread
y cargador ELF. Símbolo GLIBC máximo 2.29. `dlopen` correcto con glibc 2.31 y
carga/ejecución real en Ubuntu 22.04, kernel WSL2 6.6.87.2.

DLL Windows: SHA-256 D3 conservado
`296710eb0e1a84239cfa2387eb97708a2a93b573c56460674ca037912ddd3a5c`.
No se recompila ni sustituye durante E1.

## Pruebas

| Prueba | Resultado |
| --- | --- |
| Compilación Linux y enlace | Correctos, GCC 9.4 / glibc 2.31 |
| Descriptor y clase nativa | Carga real, registro e instanciación correctos |
| Reproducción nativa Linux | 645 tiempos por repetición, 24 posiciones por lote, 340.560 valores |
| Comparación con DLL Windows | Error absoluto máximo 3,74278386061633e-12; cero valores fuera de tolerancia 1e-8 |
| Validez, flags e iteraciones | Coinciden exactamente entre plataformas |
| Determinismo Linux local | Segunda repetición exacta, error cero |
| Límites de fases | Primer build, rebase de 600, salto >0,25 s y rebobinado incluidos |
| Configuración nativa | 128/128/128 y cúbica, espectro y pesos reales de producción |
| Regresión Windows D3 | 4.080 muestras y 1.140 pasos emparejados, error cero |
| Instalación Windows | Paquete con DLL/SO, importación y ejecución D3D12 correctas |
| Instalación Linux | Solo addons, configuración pública documentada y probe externo; Forward+ Vulkan real |
| Vehículo Linux/Windows | Conducción, contacto, lean, salto, dos aterrizajes y recuperación pasan |
| FX y cámara Linux/Windows | Ocho PNG, partículas, spray, seguimiento y nueve controles pasan |
| Underwater Linux/Windows | AIR_SAFE → UNDERWATER_SAFE → AIR_SAFE, waterline válida |
| Campo compartido | En la prueba funcional no supera una construcción por tick; cero fallos de campo |
| Dependencias de desarrollo | Sin HUD obligatorio, gameplay, autoloads MCP ni configuración privada |

El fixture binario guarda el espectro y PackedArray originales de Windows;
no convierte los datos a JSON. Se excluyen únicamente las columnas de tiempo
de ejecución de las comparaciones numéricas. No se modifica el proveedor para
reproducirlo. `ocean_linux_native_runtime.gd` y los probes son herramientas de
validación, fuera de los addons distribuidos.

La diferencia nativa entre sistemas es diminuta pero no es igualdad bit a bit.
Es compatible con redondeos de compiladores/libm distintos. No se promete una
trayectoria bit a bit entre SO. El máximo de velocidad de la prueba funcional
es 30,568828583 m/s en Windows y 30,568845749 m/s en Linux; no es una comparación
completa de trayectorias. La prueba de trayectoria exacta repetida en Windows
continúa pasando contra el oráculo anterior.

## Vulkan, incidencias y límites

Windows usa NVIDIA RTX 4070 Laptop / D3D12. Linux WSLg ofrece Vulkan 1.3.255,
Mesa 23.2.1, llvmpipe LLVM 15 por software. Se mantiene Forward+, toda la FFT y
los shaders sin cambios. Solo la ventana de la prueba Linux es 320×180 para
limitar coste de rasterización; no se cambian resolución FFT ni calidad del agua.
Las pruebas funcionales de instalación usan `--fixed-fps 60` como reloj del
ensayo; no se modifica el proyecto ni se toma su duración como benchmark.
La captura Linux conservada muestra el océano y el vehículo renderizados.

Se conservan los intentos iniciales y sus registros:

- El perfil inicial de bindings omitía OS, requerido por el propio SDK. Se añadió
  al perfil. Los primeros enlaces detectaron flags FMA y objetos estáticos; se
  corrigió exclusivamente la configuración de compilación Linux.
- El primer replay empezó antes del escaneo del editor: ahora el validador puede
  cargar explícitamente el descriptor si aún no está registrado. Después de
  importar, la instalación normal registra la extensión automáticamente.
- La primera clasificación de columnas del validador trataba dos alturas como
  flags. Se corrigió conforme al layout nativo; no se relajó la tolerancia ni se
  cambió el código de consultas. La evidencia de ese intento se conserva.
- El primer import Linux registró audio/portal de escritorio ausentes en WSL.
  La ejecución funcional usa audio Dummy y no registra errores del addon. El
  aviso de portal es del editor/compositor WSL, no de una consulta de agua.
- Un primer arranque de importación Windows cerró con `0xC0000005`, sin stack
  útil. La repetición idéntica y las pruebas completas pasan. No se atribuye su
  causa a E1 ni se oculta el registro; no se ha demostrado por qué ocurrió.

ETW/QPC/PMU y tiempo efectivo del hilo de las herramientas Windows siguen sin
implementación Linux. Las ramas no Windows existentes indican no disponible;
no se interpretan sus ceros/-1 como tiempos efectivos. El reloj de simulación
y los campos CPU compartidos sí funcionan y conservan su implementación.

**Steam Deck no validada.** Pendientes: dispositivo físico, AMD/RADV, consumo,
temperatura, frame pacing, gamepad, export Linux real y Steam Linux Runtime
seleccionado. Tampoco se certifica carga en todas las distribuciones glibc ≥2.29.
No se hacen optimizaciones específicas de Deck en esta fase.

## Entrega y reproducción

Paquetes: `Ocean_E1_Windows_Linux_Godot_4.7.1.zip` y
`JetSki_E1_Windows_Linux_Godot_4.7.1.zip`. Ocean contiene DLL y SO; Jet Ski depende
directamente de Ocean. Instalar siguiendo `addons/jet_ski/INSTALLATION.md` y
`addons/ocean/physics/native/ocean_query/LINUX.md`.

Evidencias de desarrollo: `temp/phase_e1_20261016/`. La entrega estable se conserva
fuera del proyecto, en `Water Race Backups/20261016_e1_linux_validated/`:
paquetes, inventarios SHA-256, fixture, resultados, logs, captura y procedimiento.
No incluye VHD, cachés, compiladores ni copias completas del proyecto.
`delivery.json` registra commit, tamaños, espacio final y comprobaciones.

Solo se incorporan los archivos explícitos E1 al commit. Las evidencias nuevas
en temp permanecen fuera del índice. Se conservan todas las referencias previas
y los archivos locales originales; no se inicia limpieza.
