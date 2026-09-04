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

Al apagar Coastal, la deformación de ola LONG se desactiva. Si existe un bake válido, su máscara horneada de seabed real puede seguir siendo consumida por P4: la propagación `field.a` nunca decide profundidad óptica. Sin bake válido, el resultado es el flujo P0/P4 de océano abierto, sin profundidad somera inventada. El bake pertenece al proyecto/escena que lo suministra; el addon conserva sólo referencias y no incluye baker runtime.

## Crest Foam P2

P2 promueve `Crest V3 Core`: una señal de compresión Jacobiana persistente por cascada. Cada `OceanGPUStockhamFFT` posee exclusivamente su snapshot de desplazamiento anterior, dos acumuladores RG16F ping-pong (fresh y residual empaquetados) y sus shader, pipeline y uniform sets de Crest. `OpenOceanFFT` publica el acumulador actual como `Texture2DRD`; `OceanClipmapSurface` sólo lo consume junto con el breakup procedural y no posee RIDs Crest.

El compute calcula `source_i = max(0, whitecap_i - Jacobian_i)`, ataca fresh hacia `source_i * weight_i`, decae residual, deposita fresh y lo advecta. LONG, MID y SHORT aportan su propio estado físico. En la superficie se hace la unión complementaria LONG + detalle MID/SHORT, `smoothstep`, contraste V3, breakup, fade 0–5000 m y PBR residual.

Con `Ocean.crest_foam = OFF`, los solvers liberan snapshots, acumuladores, sampler y uniform sets Crest y no despachan los compute Crest; la superficie desactiva la mezcla. Las tres FFT base, bandas y geometría permanecen sin cambios. El Crest Filigree que requiere topología Direct-J de Surface Foam no forma parte de P2 y queda pendiente para P3.

P2 V3 Core tiene `Structural: PASS`, `Runtime: PASS` y `Visual: PASS — Eric`.

## Surface Foam P3

`OceanSurfaceFoam` es el módulo P3 dedicado y único propietario de su solver auxiliar J-only, Direct-J topology, field persistente y MID eligibility history. Se crea en el hilo de render por `OpenOceanFFT` sólo con `Ocean.surface_foam = true`; las texturas publicadas son wrappers `Texture2DRD` consumidos por `OceanClipmapSurface`. No consulta Main FFT SHORT ni modifica P0/P1.

Su Source ocupa 512 a 14.5 m, produce un IFFT complejo empaquetado (18 butterflies), y actualiza a 30 Hz. El field RG16F ping-pong ocupa 1024 a 88 m. Topology RG16F 512 contiene R Surface Foam y G Crest Filigree, con mipmaps compute. MID history consume únicamente el Jacobiano de `displacement_mid.a`. Al apagar Surface Foam se desconectan los wrappers y se liberan todos sus RIDs; P2 Crest Core continúa sin Filigree.

P3 Surface Foam V3 está cerrado con `Structural: PASS`, `Runtime: PASS` y `Visual: PASS — Eric`. Su coste oficial se registra como delta marginal Surface OFF vs Surface ON; las mediciones históricas P0/P1/P2 no se usan para ese delta.

## Water Optics / Refraction P4

P4 reside en una variante dinámica de `OceanClipmapSurface`. El shader base P0–P3 no contiene `hint_screen_texture` ni `hint_depth_texture`; `Ocean.set_optics()` sólo cambia el shader/material de superficie y sus uniforms, sin reconstruir FFT, Crest, Surface Foam ni Coastal.

La variante calcula Beer–Lambert RGB desde el path de vista limitado. Si hay un `CoastalBakeAsset`, toma `metrics.r` como profundidad local sólo dentro del dominio, con feather de borde y cobertura binaria `real_seabed_coverage`; `field.a` queda exclusivamente como validez de propagación. La cobertura G modula visibilidad/match del fondo. Sin ambas autoridades, P4 conserva el fallback de agua profunda y nunca crea un seabed falso.

La refracción LONG/MID/SHORT usa el depth buffer, clamp en píxeles, profundidad candidata detrás del agua, tolerancia dependiente del espesor, confianza de borde y fallback al sample original. Foam P2/P3 se compone después de P4 porque la inyección ocurre antes de sus mezclas de `ALBEDO`/PBR. P4 es `Structural: PASS`, `Runtime: PASS`, `Visual: PENDING — Eric`, `Performance: PENDING`.
