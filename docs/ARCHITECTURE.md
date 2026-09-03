# Arquitectura de Production

Este documento describe únicamente lo que existe hoy en Production.

## Open Ocean P0

`Ocean` es el componente público. Posee la configuración de autoría, crea un único `OpenOceanFFT` y llama a `initialize()` al entrar en juego. Al desactivar `Enabled` o `Open Ocean FFT`, llama a `shutdown()` y elimina ese hijo; al volver a activar, lo reconstruye.

`OceanWaveProfile` transforma las bandas LONG/MID/SHORT en tres `OceanFftConfig`. Sus datos pasan a `JonswapHasselmannSpectrum`, que construye H0 en CPU con una semilla derivada por banda.

`OpenOceanFFT` es el propietario de runtime: crea tres `OceanGPUStockhamFFT`, tres pares de `Texture2DRD` publicados y una `OceanClipmapSurface`. En cada frame envía el tiempo de render a los tres solvers en el hilo de render.

`OceanGPUStockhamFFT` posee sus RIDs: H0, ping-pong A/B/C, displacement, normal, shaders, pipelines y uniform sets. Crea, despacha y libera esos recursos exclusivamente en el hilo de render. `OpenOceanFFT.shutdown()` desconecta primero los `Texture2DRD`, después solicita la liberación de cada solver y finalmente libera la superficie; no comparte ownership de RIDs con otros módulos.

`OceanClipmapSurface` posee las instancias de malla. `OceanClipmapMeshBuilder` crea el centro y anillos 2:1 una vez durante inicialización. La superficie consume las texturas publicadas de las tres bandas y sigue la cámara; no crea RIDs ni mallas por frame.

El flujo CPU/GPU es: perfil CPU → H0 CPU → creación y dispatch GPU → mapas GPU publicados como `Texture2DRD` → shader de superficie. P0 no contiene otros módulos ni rutas de datos.

## Coastal Runtime P1

`OceanCoastalRuntime` consume un Resource de bake válido cuando `Ocean.coastal` está activo. Construye las texturas de propagación y warp desde datos ya horneados y las entrega a `OceanClipmapSurface`; no crea RIDs de `RenderingDevice`, no despacha compute y no hornea datos. La superficie aplica esos datos exclusivamente al muestreo de LONG. MID y SHORT permanecen en el flujo P0.

Al apagar Coastal, `OpenOceanFFT` limpia el runtime Coastal y la superficie desactiva los uniforms antes de soltar sus referencias. Sin bake válido, el resultado es el flujo P0 sin errores ni trabajo Coastal. El bake pertenece al proyecto/escena que lo suministra; el addon conserva sólo referencias mientras Coastal está activo.
