# Jet Ski — addon de producción D3

Requiere **Godot 4.7.1, Forward+ y `addons/ocean/` D2 o posterior**. Ocean es una
dependencia directa y obligatoria. No activar ningún plugin de editor ni copiar
autoloads, `gameplay/`, validadores, MCP o `.godot` del proyecto original.

## Instalación y ejemplo

1. Descomprimir el paquete Ocean D2 y `JetSki_D3_Windows_Godot_4.7.1.zip` en la
   raíz de un proyecto vacío. Deben aparecer `addons/ocean/` y `addons/jet_ski/`.
2. En un proyecto nuevo se puede copiar
   `addons/jet_ski/examples/project.godot.example` a la raíz como `project.godot`.
   En uno existente, usar Forward+, física 3D **Jolt Physics** e **interpolación
   física activada**, como producción. En Windows la validación usa D3D12.
   Abrir el editor e importar los recursos con RenderingDevice activo.
3. Abrir `res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn` y ejecutarla, o
   establecerla como escena principal del proyecto.

El ejemplo tiene Ocean, iluminación y una instancia del vehículo. Su script
configura el proveedor de Ocean una vez, espera su fuente física y entrega la
referencia al vehículo. No calcula fuerzas, flotación, cámara, impactos ni spray.
El ejemplo usa los perfiles predeterminados de Ocean y activa underwater; el
escenario de desarrollo conserva sus parámetros y perfiles propios.

## Usarlo en otra escena

Instanciar `res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn`. Antes de añadirlo al
árbol, llamar `vehicle.configure_ocean(ocean)`. Esta función conserva el proveedor
compartido de Ocean, crea el contexto de contactos del vehículo y conecta sus
efectos de contacto mediante la API directa de Ocean.

El host configura **una vez por Ocean**, después de que
`ocean.get_physics_source_state().status == "OK"`:

```gdscript
var water := ocean.get_water_provider()
water.lite_resolutions = PackedInt32Array([128, 128, 128])
water.lite_interpolation_modes = PackedInt32Array([1, 1, 1])
water.wave_drift_enabled = true
water.wave_drift_strength = 0.75
water.wave_drift_max_speed_mps = 0.5
if not water.configure(ocean, CpuFftWaterProvider.Backend.CPU_LITE_B, false):
    push_error("Ocean CPU Lite no disponible")
    return
water.set_query_mode(CpuFftWaterProvider.QueryMode.DIRECT)
water.set_water_race_mode(true)
```

Es la configuración CPU Lite de producción existente, sin otra capa de consultas.
Mantener congelados los vehículos hasta completar la configuración inicial.
Cada vehículo conserva su propio contexto; todos reciben el mismo proveedor y
objeto nativo. No configurar otro proveedor ni reconstruir la FFT por vehículo.
Para una integración que ya tenga el proveedor, sigue disponible
`configure_water_provider(provider)`; configurar también
`vehicle.get_node("WaterContactFx").configure_ocean(ocean)` una vez.

## Configuración del vehículo

Los valores serializados de casco, colisión, flotabilidad, conducción, lean,
spray y cámara se conservan. `ProductionSetup` aplica una vez los ajustes que
antes imponía el integrador: Water Race, modo angular estabilizado, inercia
combinada del piloto, modos actuales de lastre/calado/conducción y diagnóstico
desactivado. `trick_preload_enabled = false` procede de aquel integrador y ahora
está serializado en la escena. No es un reajuste físico.

Los 23 parámetros de cámara están en `CameraRig`. Su nodo `Controls` es opcional;
desactivarlo no elimina seguimiento, vibración ni impactos. `BowSprayRoot` y
`WaterContactFx` pertenecen al vehículo. Los ocho PNG de animación están dentro
de `common/visual/bow_spray/sequences/Splash_1/`. No se necesitan PNG externos.

Legacy y Heavy permanecen disponibles; el valor de producción es **V1 normal**.
El HUD que permite alternar modos se conserva en `debug/jet_ski_buoyancy_hud.gd`:
añadirlo explícitamente como hijo del vehículo si se desea. La escena del vehículo
y el ejemplo no dependen de ese HUD.

## Controles e inputs

`ProductionSetup.input_bindings` apunta a `resources/default_input_bindings.tres`.
Solo registra acciones que no existan en InputMap, durante la inicialización.
Las acciones existentes del proyecto tienen prioridad, incluidos sus eventos,
deadzones y las acciones deliberadamente vacías. No se modifica InputMap por tick.

Para personalizar, crear un recurso `JetSkiInputBindings`, editar sus eventos en
el inspector y asignarlo a `ProductionSetup`, o definir las acciones directamente
en Proyecto → Ajustes → Mapa de entradas. Conservar estos nombres de acciones:

| Acción | Tecla física predeterminada |
| --- | --- |
| `throttle` | W |
| `brake` | S, frena y después permite reversa |
| `steer_left` / `steer_right` | A / D |
| `rider_shift_forward` / `rider_shift_back` | Flecha arriba / abajo |
| `rider_shift_left` / `rider_shift_right` | Flecha izquierda / derecha |
| `reset_vehicle` | R |
| `recover_vehicle` | T |
| `eject_rider` | E |

Cámara actual: C cambia preset; +/− y rueda acercan/alejan; PageUp/PageDown
cambian altura. Conserva los controles originales y sus incrementos.
Las acciones InputMap son compartidas, como en D2. La extracción no implementa
multijugador ni un esquema de inputs separado por jugador.

## Plataformas y límites

Validado en Windows x86-64 con el binario nativo incluido en Ocean D2. No se
modifica la DLL ni se necesita una segunda DLL en Jet Ski. **Falta el binario
Linux de Ocean**: Steam Deck requiere su propia compilación y validación física,
visual y de rendimiento. Las medidas Windows no certifican Steam Deck.

No se incluyen escenas del laboratorio, validadores ni herramientas PERF en
este addon. Las evidencias D3 y sus mediciones se entregan por separado.
