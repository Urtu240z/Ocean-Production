# E2 — exportar el ejemplo autónomo

Los presets de este directorio se copian a la raíz de una instalación limpia de
Ocean E1 + Jet Ski E1. No sustituyen los del proyecto de desarrollo. Se reutilizó
`temp/phase_e1_20261016/clean_windows`; no se creó otra instalación completa.

1. Instalar ambos addons E1, conservando sus rutas.
2. Copiar `addons/jet_ski/examples/project.godot.example` como `project.godot`.
3. Copiar `e2_export_presets.cfg` como `export_presets.cfg`.
4. Importar con Godot 4.7.1 Forward+ y crear los directorios de salida.
5. Usar las plantillas oficiales 4.7.1 ya instaladas:

```sh
godot --path /ruta/proyecto_limpio --export-release "Linux Demo x86_64" /ruta/salida/linux/water_race_demo.x86_64
godot --path /ruta/proyecto_limpio --export-release "Windows Demo x86_64" /ruta/salida/windows/water_race_demo.exe
```

Se puede exportar Linux desde el editor Windows. No hace falta instalar un segundo
editor ni plantillas en WSL. La importación y exportación de GLSL se hicieron con
RenderingDevice real, sin recurrir a una importación headless de shaders.

El resultado es **el ejemplo Ocean + Jet Ski que ya existía en E1**, con sus mismos
perfiles. No incluye la isla, HUD de depuración ni escenas del laboratorio.
El proyecto original sigue conservando todos esos contenidos y sus parámetros.

Los presets incluyen todos los recursos de ambos addons, con sus modos antiguos
todavía presentes. Los filtros añaden los archivos `.glsl`, `.inc` y `.source`
que se leen dinámicamente. Godot copia la biblioteca nativa de la plataforma
seleccionada junto al ejecutable; conservarla allí. No copiar ambos binarios
nativos indiscriminadamente a cada distribución, ni mover la biblioteca a mano.

El PCK está incrustado. Se preserva shader_baker, S3TC/BPTC y script export mode
del proyecto existente, sin cambios a calidad, shaders o física. En Windows no
se requiere rcedit porque no se modifica icono ni branding del ejecutable.
Las salidas y compilaciones intermedias quedan fuera del contenido exportable.

## Verificar y ejecutar

`e2_pack_audit.py` comprueba el directorio del PCK v4 incrustado, MD5 de cada
entrada, escenas, ocho PNG, shaders dinámicos, descriptor, ausencia de recursos
de desarrollo y SHA-256 de la biblioteca externa. La inspección de rutas físicas
en contenido se limita a entradas menores de 1 MB; no pretende borrar rutas de
diagnóstico que puedan existir en binarios nativos compilados anteriormente.

```sh
python e2_pack_audit.py /ruta/water_race_demo.x86_64 --native-sha256=9f6a5fb026eb092dc2283418534e59a6b1fa2c47794cefc5ed5244539fa1f176 --result=pack_linux.json
```

Ejecutar normalmente, desde cualquier carpeta, manteniendo juntos los dos archivos
de la distribución. En Linux dar permiso de ejecución si el descompresor no lo
conserva. Forward+ usa Vulkan en Linux y D3D12 en Windows.

La plantilla release oficial restringe `--path` e ignora el intento de inyectar
un script de auditoría externo. Se conservaron esos intentos y no se recompiló el
motor para desactivar la protección. Las pruebas finales arrancan el release real
sin esos argumentos, desde `/tmp` y `C:/Windows/Temp`, durante 120 fotogramas.
La telemetría ya existente acredita 90 campos CPU Lite correctos, 128/128/128,
sin comparación adicional ni más de una construcción por tick tras configurar.
No es una nueva prueba de rendimiento ni una certificación de Steam Deck.

En E2 se valida arranque/render/campo físico del release. Las pruebas extensas de
conducción, spray, cámara y underwater siguen siendo las de E1 sobre estos mismos
recursos; no se afirma que se hayan repetido maniobras manuales en el release E2.
