# Linux x86-64 — E1

## Binario distribuido

`bin/ocean_query_native.linux.template_release.x86_64.so` es ELF64 x86-64,
con el símbolo `ocean_query_native_library_init`. El descriptor selecciona
automáticamente este archivo en editor y export Linux. La DLL Windows sigue
siendo la de D3. Se distribuye una biblioteca release por plataforma, compatible
con el motor oficial single precision, Godot 4.7.1.

SDK: `godot-cpp` commit `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`, API 4.7.
Compilador del binario E1: GCC 9.4.0, Ubuntu 20.04, glibc 2.31, SCons 4.8.1.
Los bindings se limitan a las clases que usa la extensión y el propio SDK:
`Engine`, `OS`, `RefCounted`, `Time`, más las dependencias obligatorias del SDK.
No se recortan métodos ni cálculos de OceanQueryNative.

libstdc++ y libgcc se enlazan estáticamente. Dependencias dinámicas:
libc, libm, libpthread y el cargador ELF del sistema. La versión GLIBC más reciente
referenciada es 2.29; no se distribuye una copia privada de glibc. La ejecución
se comprueba en Ubuntu 22.04/WSL2 y el enlace se verifica también con glibc 2.31.
No es una certificación de todas las distribuciones ni de Steam Linux Runtime.

## Compilar

Instalar GCC/G++, Python 3.8 o posterior y SCons 4.8.1. Obtener el SDK indicado
fuera del addon distribuido (no se necesita para ejecutar):

```sh
git clone https://github.com/godotengine/godot-cpp.git /ruta/godot-cpp
git -C /ruta/godot-cpp checkout 507ed9d840c01a3c5b2a39af8bb4000bfac30bf5
python3 -m pip install SCons==4.8.1
cd addons/ocean/physics/native/ocean_query
GODOT_CPP_PATH=/ruta/godot-cpp JOBS=2 sh build_linux_release.sh
```

Usar una base de glibc antigua como la del binario E1 si se quiere conservar su
alcance ABI. Compilar en una distribución más reciente puede elevar el requisito
GLIBC; revisar `readelf --version-info` y `ldd` sobre el resultado. No usar
`-march=native`, fast-math, ni cambiar precisión o resoluciones para esta fase.
El script genera el descriptor únicamente después de enlazar correctamente.
Los objetos Linux y Windows se guardan en carpetas distintas. El SDK también
debe tener sus intermedios separados cuando se cambie de compilador/sysroot.

Los archivos SIMD existentes se compilan con AVX2 y FMA, aislados de la unidad
base x86-64. El dispatch GCC/Clang comprueba AVX2, FMA y el soporte del SO antes
de entrar en ellos; si no están disponibles se conserva la ruta escalar.
Se desactiva la contracción implícita de multiplicaciones/sumas en esas unidades;
las intrinsics FMA explícitas existentes permanecen intactas. No cambia la FFT.
La detección y flags MSVC no se modifican.

## Validación y diferencias de plataforma

`validation/ocean_linux_native_runtime.gd` pertenece a las herramientas del
proyecto, no es una dependencia del addon. Genera un fixture binario del espectro
de producción con la DLL Windows y lo reproduce en Linux:

```sh
godot --headless --path /ruta/proyecto_minimo \
  --script /ruta/validation/ocean_linux_native_runtime.gd -- \
  --fixture=/ruta/native_fixture.bin --result=/ruta/native_linux.json
```

Prueba lotes de altura/normal/velocidad y contactos con historial, 128/128/128,
interpolación cúbica, 645 tiempos, rebase de fase de 600 actualizaciones, salto
mayor de 0,25 s y rebobinado. El fixture preserva los PackedArray originales.
La repetición local exige igualdad exacta. La comparación entre compiladores y
libm distintos usa tolerancia absoluta 1e-8; flags e iteraciones exigen igualdad.
No se promete determinismo bit a bit entre Windows y Linux para una partida.

Forward+ usa D3D12 en las pruebas Windows y Vulkan en Linux. Los shaders, FFT,
calidad, agua, vehículo, cámara y VFX conservan los de D3. WSL dispone de Vulkan
llvmpipe por software: permite comprobar carga/ejecución pero no rendimiento AMD.
Las mediciones de velocidad de ese renderizador no deben extrapolarse a Deck.

ETW, QPC, contadores PMU y el tiempo CPU de hilo de las herramientas PERF Windows
no están implementados en Linux. Sus ramas existentes devuelven no disponible;
no usar sus ceros o valores -1 como medidas Linux. No se cambia el reloj del agua.

Pendiente: Steam Deck físico, GPU AMD/RADV, consumo/temperatura, frame pacing,
gamepad y export Linux real dentro del Steam Linux Runtime elegido. El binario
compatible y las pruebas WSL no equivalen a Deck Verified.

Referencias de plataforma:

- [GDExtension y compilación](https://docs.godotengine.org/en/latest/tutorials/scripting/cpp/gdextension_cpp_example.html).
- [Detección x86 de GCC](https://gcc.gnu.org/onlinedocs/gcc/x86-Built-in-Functions.html).
- [Modelos del Steam Runtime](https://github.com/ValveSoftware/steam-runtime/blob/master/doc/possible-designs.md).
