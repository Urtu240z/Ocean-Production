# Integración de Native Performance 2 — 2026-10-20

`master` se avanzó de `88cf3ae5bca090bb34404ce362ad4a7966df2a24` a **`ce2a34346aefc9e62b3bac8623f22bfcf203f9f0`** mediante fast-forward. Se conservan los commits individuales `d6940e8`, `3f0bc1a` y `ce2a343` y la rama `codex/native-performance-2`.

**Push completado**: `git push origin master`. Después se verificó la coincidencia del master local, `origin/master` y `git ls-remote origin refs/heads/master`, todos en el SHA indicado. El fetch previo confirmó que el remoto continuaba en `88cf3ae`; no hubo divergencia ni conflictos.

La integración y validación se hicieron en el worktree externo `C:/Users/DEV/.codex/worktrees/contact-pipeline-3/Water Race Ocean Production`. El árbol original permanece en su rama anterior con sus modificaciones de `project.godot`, escena y `.svg.import`; no se incluyeron esos cambios en master. Sus hashes de partida se conservaron para comprobarlos al terminar el bloque B.

Validación mínima en la copia limpia integrada:

- Importación del proyecto y carga de GDExtension correctas.
- 192 comprobaciones binarias de firmas/valores, cero fallos en Windows y Linux.
- Smoke normal guardado con Vulkan: HULL V1 nativo, tres workers Async reales, 60 Hz, una carga de geometría, 119 lotes nativos, muestras y cuerpo finitos, cero fallos.
- Firma rápida de mares locales activa; referencia y fixtures disponibles.
- DLL Windows SHA256 `e22176c1d2e0ef058d4816d63b76ba353ed516ed2e8b52de7cfdfd0fbec3f0d0`; SO Linux `3f9fb2f1cb9422dc8d2f0d82e79342f1e9561a846011b0759495e8720a9387c9`. Sin cambios C++ ni recompilación innecesaria.
- Advertencia preexistente de UID de `default_style.tres`: Godot resuelve la ruta textual; no hubo error funcional.

Después del push se creó **`codex/contact-pipeline-3`**, con commit inicial `ce2a34346aefc9e62b3bac8623f22bfcf203f9f0`, en el mismo worktree externo. El trabajo posterior de esa rama no se publicará sin autorización adicional.
