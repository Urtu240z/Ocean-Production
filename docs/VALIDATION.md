# Infraestructura temporal de validación

`validation/` contiene escenas, cámaras y fixtures reutilizables para inspección manual durante la migración de Production. No forma parte de `addons/ocean/` y el addon no puede depender de ella.

## Free camera

`validation/free_camera.tscn` instancia `validation/free_camera.gd`. La cámara usa input directo y no requiere autoload ni entradas permanentes en `InputMap`.

| Control | Acción |
| --- | --- |
| W/A/S/D | Movimiento |
| Mouse | Mirada |
| Shift | Movimiento rápido |
| Space | Movimiento lento |
| Q/E | Bajar/subir |
| Esc | Capturar/liberar ratón |

La free camera puede instanciarse en las escenas de P1, P2, P3 y posteriores. No se elimina al cerrar una fase.

## Fixtures

`validation/fixtures/` puede contener datos temporales de una fase. Los fixtures se pueden cambiar o eliminar cuando dejan de ser necesarios.

## Benchmark

El benchmark no forma parte de esta infraestructura persistente. Para cada medición: crear la herramienta, medir, documentar el resultado y eliminarla.

## Limpieza final

Sólo cuando la migración y la validación global de Production hayan terminado se elimina por completo `validation/`. Antes de considerar el proyecto limpio para distribución, el contenido final debe quedar limitado al addon `addons/ocean/` y a la documentación/archivos de proyecto que se hayan decidido conservar.
