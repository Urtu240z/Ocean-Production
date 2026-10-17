"""Publish the selected, equivalent hull-spray measurements for visual review."""
from pathlib import Path
import argparse
import hashlib
import json
import statistics

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "temp/hull_spray"
OUT = ROOT / "temp/foam2d/review/revision9"
MODES = ("off", "sides", "tail3", "tail4", "all3", "all4")
LABELS = {
    "off": "Referencia sin nuevos sprays",
    "sides": "Solo laterales Splash 2",
    "tail3": "Solo cola Splash 3",
    "tail4": "Solo cola Splash 4",
    "all3": "Laterales + cola Splash 3",
    "all4": "Laterales + cola Splash 4",
}


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[int((len(ordered) - 1) * fraction)]


def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", default="final_matrix")
    parser.add_argument("--review", default="revision9")
    parser.add_argument("--inspector", action="store_true")
    parser.add_argument("--confirmation", default="")
    args = parser.parse_args()
    OUT = ROOT / "temp/foam2d/review" / args.review
    runs = []
    proofs = []
    replacements = {"r1_tail4_12": "r0_tail4_12", "r1_all3_12": "r0_all3_12"} if args.matrix == "final_matrix" else {}
    for round_id in range(2):
        for count in (1, 12):
            reference = read(RAW / f"{args.matrix}/r0_off_{count}/report.json")
            for mode in MODES:
                run_id = f"r{round_id}_{mode}_{count}"
                relative = (f"camera_recheck/{replacements[run_id]}" if run_id in replacements
                            else f"{args.matrix}/{run_id}")
                folder = RAW / relative
                report = read(folder / "report.json")
                metrics = read(folder / "process_metrics.json")
                rows = report["rows"]
                assert len(rows) == 540, run_id
                equivalent = report["checksums"] == reference["checksums"]
                assert equivalent, f"Conditions differ: {run_id}"
                errors = []
                for log in ("stdout.log", "stderr.log"):
                    errors.extend(line for line in (folder / log).read_text(encoding="utf-8-sig").splitlines()
                                  if "ERROR:" in line or "SCRIPT ERROR" in line)
                assert not errors, (run_id, errors)
                assert report["providers"] == 1
                assert all(item["state"]["extra_water_queries"] == 0 for item in report["spray"])
                run = {
                    "id": run_id, "source": relative, "vehicles": count, "mode": mode,
                    "wall_median_ms": statistics.median(row["wall_ms"] for row in rows),
                    "wall_p95_ms": percentile([row["wall_ms"] for row in rows], .95),
                    "cpu_process_ms_per_frame": metrics["cpu_ms_per_frame"],
                    "gpu_raster_median_ms": statistics.median(row["render_gpu_ms"] for row in rows),
                    "vram_median_mib": statistics.median(row["video_bytes"] for row in rows) / 2**20,
                    "private_start_mib": metrics["first_private_bytes"] / 2**20,
                    "private_growth_mib": (metrics["last_private_bytes"] - metrics["first_private_bytes"]) / 2**20,
                    "resident_start_mib": metrics["first_working_set_bytes"] / 2**20,
                    "resident_growth_mib": (metrics["last_working_set_bytes"] - metrics["first_working_set_bytes"]) / 2**20,
                    "window_seconds": metrics["wall_seconds"],
                    "max_queries": report["max_queries"],
                }
                runs.append(run)
                proofs.append({"run": run_id, "equivalent_body_camera_wave": equivalent, "errors": len(errors)})
    aggregate = []
    for count in (1, 12):
        for mode in MODES:
            selected = [run for run in runs if run["vehicles"] == count and run["mode"] == mode]
            item = {"vehicles": count, "mode": mode, "label": LABELS[mode]}
            for key in selected[0]:
                if key not in ("id", "source", "vehicles", "mode"):
                    item[key] = statistics.mean(run[key] for run in selected)
            item["wall_run_median_range_ms"] = [min(r["wall_median_ms"] for r in selected),
                                                max(r["wall_median_ms"] for r in selected)]
            aggregate.append(item)
    quiet = sha(OUT / "rest_off.png") == sha(OUT / "rest_new.png")
    assert quiet
    assert read(OUT / "controls_proof.json")["passed"]
    assert read(OUT / "impact_proof.json")["passed"]
    data = {
        "device": reference["device"], "frames_per_run": 720, "warmup": 180,
        "measured_frames_per_run": 540, "effective_runs": 24,
        "method": "Two reversed-order rounds, one and twelve vehicles." + (" Two contaminated camera runs repeated; originals retained." if replacements else " No replacement runs."),
        "gpu_scope": reference["gpu_scope"],
        "cpu_scope": "OS process CPU summed across all threads, marker endpoints sampled at 20 ms; CPU work is not frame latency.",
        "baseline": "Revision 8 foam plus original bow spray; new hull/tail sprays disabled.",
        "ram_scope": "Private committed process memory and resident working set, measured after warmup; growth is end minus start.",
        "proof": {"equivalent_conditions": all(p["equivalent_body_camera_wave"] for p in proofs),
                  "idle_images_identical": quiet, "run_checks": proofs,
                  "replaced_camera_runs": replacements},
        "aggregate": aggregate, "runs": runs,
    }
    text = """# Splash 2 lateral y alternativas de cola Splash 3 / Splash 4

Prototipo para aprobación visual. Sin commit ni push.

## Cómo probarlo

Abre `validation/foam2d_playground.tscn` en Water Race Ocean Production, ejecuta F6 y haz clic en **Salpicaduras y cola**, a la izquierda de la pantalla. El panel se abre con ese botón y se oculta con **Cerrar**. No tiene atajo de teclado. El selector superior cambia **Splash 3 / Splash 4** durante la ejecución. **Guardar estos valores** conserva la elección en `addons/jet_ski/common/visual/hull_spray/default_style.tres`. F7 continúa ajustando la espuma. El Inspector del recurso incluye color, brillo, rugosidad y especular, además de los controles de animación y tamaño.

## Comportamiento y recursos

Splash 2 responde al impacto normal de los contactos V1 de cada lado, mientras la moto avanza. Varían fuerza, duración, separación y retraso entre lados. Un golpe sostenido no dispara continuamente. Las gotas heredan parte de la velocidad horizontal al nacer y se frenan. No nacen ráfagas laterales nuevas en reposo, marcha atrás, seco o vuelo. La cola responde al acelerador y al contacto mojado de popa; se corta en vuelo e inmersión completa.

Los originales se conservan en `Splash_2/` (32 PNG), `Splash_3/` (48 PNG) y `Splash_4/` (24 PNG). Se usan atlas compartidos y una malla fija compartida, con un máximo de cuatro instancias laterales y una de cola por moto. Las dos superficies cruzadas de cada efecto están dentro de esas instancias. No se reconstruye geometría por fotograma ni se añaden consultas de agua, fuerzas o simulación de olas. La caché carga las variantes seleccionadas y queda limitada a tres atlas.

El bow spray original y tus ajustes guardados de espuma se conservan; se compararon sus hashes con la copia anterior. La escena de la moto solo añade el recurso y nodo HullSprayRoot. El recorte inferior de estos PNG usa la altura de contacto V1, no la simulación individual de todas las gotas. Puede requerir ajuste visual en oleaje muy inclinado. Los cortes de color del océano visibles en las capturas también están en la referencia sin los nuevos sprays.

## Verificación

- Prueba de impactos: reposo, seco, vuelo y marcha atrás no emiten; un lado seco no responde; el contacto constante no se repite; fuerzas y retrasos varían; no se consume la aleatoriedad global.
- Panel de salpicaduras: apertura y cierre mediante botones, 24 cambios de variante, reutilización del mismo atlas al volver, caché acotada a tres, activación independiente y guardado/carga correctos. No se guardaron cambios de prueba en tus valores por defecto.
- Capturas: misma trayectoria, cámara y tiempo de olas en las cuatro variantes. Las imágenes de reposo con y sin efectos nuevos son idénticas byte a byte.
- Rendimiento: 24 ejecuciones válidas sin errores. Un proveedor de agua y cero consultas adicionales de estos efectos. Máximo de consultas del escenario: 70 con una moto y 840 con doce.

## Medición

GPU: NVIDIA GeForce RTX 4070 Laptop GPU. Dos rondas con orden invertido, una y doce motos, 720 fotogramas por ejecución; 180 de calentamiento y 540 medidos. Sin capturas ni lectura de imágenes durante la medición. La referencia conserva espuma de revisión 8 y bow spray original; solo desactiva los nuevos efectos.

Se repitieron dos pasadas con doce motos porque la entrada manual había cambiado la cámara: `r1_tail4_12` y `r1_all3_12`. Sus reemplazos están en `temp/hull_spray/camera_recheck/`; las otras 22 proceden de `temp/hull_spray/final_matrix/`. Los originales permanecen conservados, pero no entran en la media. El medidor bloquea la entrada manual de cámara y conserva el seguimiento automático. En las 24 pasadas seleccionadas coinciden todas las muestras registradas de posición, orientación, velocidad, cámara y tiempo de olas.

La tabla muestra la media de las dos medianas por ejecución; P95 es la media de sus percentiles. CPU es trabajo total del proceso entre todos sus hilos dividido por fotogramas; puede superar el tiempo de fotograma. GPU es el contador de rasterizado del viewport, no una medida garantizada de toda la GPU incluyendo cómputo del océano.

| Motos | Modo | Fotograma ms | P95 ms | CPU ms/f | GPU raster ms |
|---:|---|---:|---:|---:|---:|
"""
    if args.inspector:
        intro = """# Sprays integrados en BowSprayRoot con exports

Prototipo sin commit ni push. Los nuevos PNG utilizan el mismo shader que el bow spray, con perfiles independientes y 77 exports comunes verificados.

## Ajustes

Abre `addons/jet_ski/jet_ski_01/jet_ski_01.tscn`, selecciona **BowSprayRoot** y despliega **Hull Splashes / Tail Jet**. **Editar Splash 2** abre el perfil de laterales y **Editar cola Splash 3 / 4** el de cola. Ambos muestran Animation, Soft Edges, Spray Color, Transparent Water, Submersion Suppression, Sheet Shape Low/High, Spray Volume, Layer Scale, Hull Attachment y Editor Preview, además de texturas, alfa y oclusión.

El selector está en **Hull Spray Settings → Tail Variant**. Los puntos de salida **SplashLeft**, **SplashRight** y **TailJet** están dentro de BowSprayRoot y respetan sus transforms editables. El controlador visual HullSprays está en esa misma jerarquía. El panel en pantalla es opcional y no tiene atajo. La escena manual lee el recurso del nodo y no lo sustituye.

Los overrides guardados del bow original y los de espuma se compararon con la copia previa y se conservan. La rama nueva del shader está desactivada para el bow original. La mezcla temporal, alfa, color, película de agua, normales y highlights comparten implementación. Los PNG originales permanecen en la raíz y se emplean sus atlas optimizados. Droplets Atlas conserva el campo reservado del bow; no crea partículas adicionales.

## Validación

- 77 exports equivalentes, shader compartido, perfiles independientes y cambios del material en vivo.
- Anim FPS = 0 pausa la fase de PNG mientras los relojes de normales y distorsión siguen avanzando.
- Volumen configurable de una a cinco capas; la malla se reutiliza al volver al mismo número.
- 24 cambios de cola reutilizando los atlas, caché máxima de tres y guardado/carga de valores anidados.
- Apertura/cierre por botones. Ajustes persistentes mediante exports, sin depender del panel.
- Prueba de impactos: sin nuevas ráfagas laterales en reposo, seco, marcha atrás o vuelo; retrasos y fuerzas variables.
- Se corrigieron la retención de recursos al cerrar y los valores nulos durante la recarga del editor. El cierre y la comprobación del Inspector se repitieron después de corregirlos.

Cada moto conserva un máximo de cuatro ráfagas y un chorro. No se construyen mallas por fotograma ni se añaden consultas de agua, fuerzas o simulación de olas. Subir las capas aumenta el trabajo de dibujo. El recorte inferior usa la altura de contacto V1 y es una aproximación visual; los cortes de color del océano ya aparecen en la referencia.

"""
        text = intro + text[text.index("## Medición"):]
        paragraph_start = text.index("Se repitieron dos pasadas")
        paragraph_end = text.index("\n\nLa tabla", paragraph_start)
        text = text[:paragraph_start] + "Las 24 ejecuciones de esta revisión están en `temp/hull_spray/inspector_matrix/`. No se sustituyó ninguna. Coinciden todas las muestras registradas de posición, orientación, velocidad, cámara y tiempo de olas. El medidor ignora la entrada manual de cámara, conservando su seguimiento automático." + text[paragraph_end:]
    for item in aggregate:
        text += f'| {item["vehicles"]} | {item["label"]} | {item["wall_median_ms"]:.3f} | {item["wall_p95_ms"]:.3f} | {item["cpu_process_ms_per_frame"]:.3f} | {item["gpu_raster_median_ms"]:.3f} |\n'
    text += "\nRAM y VRAM se miden por separado. RAM inicial y crecimiento corresponden a la ventana posterior al calentamiento; valores en MiB, medias de las dos ejecuciones. VRAM es el contador total del motor, no solo el tamaño de los atlas.\n\n| Motos | Modo | RAM privada inicial | Crecimiento privada | RAM residente inicial | Crecimiento residente | VRAM |\n|---:|---|---:|---:|---:|---:|---:|\n"
    for item in aggregate:
        text += f'| {item["vehicles"]} | {item["label"]} | {item["private_start_mib"]:.1f} | {item["private_growth_mib"]:+.1f} | {item["resident_start_mib"]:.1f} | {item["resident_growth_mib"]:+.1f} | {item["vram_median_mib"]:.1f} |\n'
    text += "\nLas diferencias pequeñas entre modos están cerca de la variación entre pasadas; dos rondas no permiten atribuir mejoras ni garantizar un coste exacto. Con doce motos crece la RAM también en la referencia: estas ventanas cortas no permiten descartar una fuga a largo plazo. `performance.json` contiene valores sin redondear, duración, rango de medianas y rutas seleccionadas. La matriz preliminar `temp/hull_spray/matrix/` se excluye por corresponder a una versión anterior.\n\n## Archivos\n\n- Implementación y ajustes: `addons/jet_ski/common/visual/hull_spray/`.\n- Integración: `addons/jet_ski/jet_ski_01/jet_ski_01.tscn` y `validation/foam2d_playground.gd`.\n- Capturas finales: `temp/hull_spray/final_off/`, `final_sides/`, `published_all3/` y `published_all4/`.\n- Contratos: `validation/hull_spray_impact_contract.gd` y `hull_spray_controls_check.gd`.\n- Ejecución reproducible: `validation/hull_spray_matrix.ps1`; publicación: `tools/generate_hull_spray_review.py`.\n- Los estados anteriores de espuma y la copia anterior a estos sprays permanecen recuperables.\n"
    if args.inspector:
        text = text.replace("La matriz preliminar `temp/hull_spray/matrix/` se excluye por corresponder a una versión anterior.", "Las matrices anteriores se conservan y no se mezclan con esta revisión.")
        text = text.replace("`temp/hull_spray/final_off/`, `final_sides/`, `published_all3/` y `published_all4/`", "`temp/hull_spray/inspector_capture_off/`, `inspector_capture_all3/` y `inspector_capture_all4/`")
    if args.confirmation:
        confirmation = []
        reference = read(RAW / args.confirmation / "r0_off_12/report.json")
        for mode in ("off", "all3", "all4"):
            values = []
            for round_id in range(2):
                folder = RAW / args.confirmation / f"r{round_id}_{mode}_12"
                report = read(folder / "report.json")
                metrics = read(folder / "process_metrics.json")
                assert report["checksums"] == reference["checksums"]
                assert len(report["rows"]) == 540
                for log in ("stdout.log", "stderr.log"):
                    assert not any("ERROR:" in line or "SCRIPT ERROR" in line
                                   for line in (folder / log).read_text(encoding="utf-8-sig").splitlines())
                values.append({"source": str(folder.relative_to(ROOT)),
                               "wall_median_ms": statistics.median(r["wall_ms"] for r in report["rows"]),
                               "cpu_process_ms_per_frame": metrics["cpu_ms_per_frame"],
                               "gpu_raster_median_ms": statistics.median(r["render_gpu_ms"] for r in report["rows"]),
                               "private_growth_mib": (metrics["last_private_bytes"]-metrics["first_private_bytes"])/2**20})
            confirmation.append({"mode": mode, "label": LABELS[mode], "runs": values,
                                 **{key: statistics.mean(v[key] for v in values) for key in values[0] if key != "source"}})
        data["confirmation"] = {"vehicles": 12, "runs": 6, "equivalent_conditions": True,
                                "scope": "Editor kept idle for the complete confirmation matrix.", "aggregate": confirmation}
        text += "\n## Confirmación con el editor en reposo\n\nLa matriz principal se registró mientras se comprobaba el Inspector. Se añadieron seis pasadas con doce motos, sin interactuar con el editor durante toda esta segunda matriz, en dos órdenes invertidos. No se mezclan con las 24 anteriores. Todas las muestras de trayectoria, cámara y oleaje coinciden y no hay errores. La carga del editor y las condiciones térmicas pueden influir en diferencias pequeñas.\n\n| Modo | Fotograma ms | CPU ms/f | GPU raster ms | Crecimiento RAM privada MiB |\n|---|---:|---:|---:|---:|\n"
        for item in confirmation:
            text += f'| {item["label"]} | {item["wall_median_ms"]:.3f} | {item["cpu_process_ms_per_frame"]:.3f} | {item["gpu_raster_median_ms"]:.3f} | {item["private_growth_mib"]:+.1f} |\n'
        text += f'\nFuentes: `temp/hull_spray/{args.confirmation}/`.\n'
    (OUT / "performance.json").write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (OUT / "REPORT.md").write_text(text, encoding="utf-8")
    print(json.dumps({"published": str(OUT), "equivalent": data["proof"]["equivalent_conditions"],
                      "aggregate": [{key: item[key] for key in ("vehicles", "mode", "wall_median_ms", "gpu_raster_median_ms", "private_growth_mib")} for item in aggregate]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
