"""Four real A/B runs, complete geometry timings and backend counters."""
import json
from collections import defaultdict
from pathlib import Path
from analyze_async_fft_comparison import collect_case, stats

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / "temp/hull_native_1/real"


def analyze():
    groups = defaultdict(lambda: defaultdict(list))
    errors = defaultdict(int)
    runs, cases, metadata = [], [], []
    for label in ["A1", "B1", "B2", "A2"]:
        path = FOLDER / (label + ".json")
        if not path.exists(): continue
        capture = json.loads(path.read_text(encoding="utf-8"))
        variant = label[0]
        metadata.append({"label": label, "metadata": capture["metadata"]})
        run_values = defaultdict(list)
        for case in capture["cases"]:
            values, _, failures, _ = collect_case(case, 1)
            for row in case["hull_geometry"]:
                values["water_physics_ms"].append(row[1] / 1000)
                values["cell_geometry_complete_ms"].append(row[2] / 1000)
                values["tetra_loop_ms"].append(row[3] / 1000 if variant == "A" else row[4] / 1e6)
                if variant == "B": values["native_call_internal_ms"].append(row[5] / 1e6)
                values["native_fallback_count"].append(row[6])
                values["native_geometry_uploads"].append(row[7])
                values["native_batches"].append(row[8])
            for key, samples in values.items():
                groups[variant][key].extend(samples)
                run_values[key].extend(samples)
            for key, value in failures.items(): errors[variant + "." + key] += value
            cases.append({"label": label, "case": case["case"],
                          "metrics": {k: stats(v) for k, v in values.items() if k in ["cell_geometry_complete_ms", "controller_total_per_tick_ms", "wall_ms", "engine_physics_ms"]}})
        metrics = {key: stats(values) for key, values in run_values.items()}
        metrics["fps_average"] = len(run_values["wall_ms"]) * 1000 / sum(run_values["wall_ms"])
        runs.append({"label": label, "metrics": metrics})
    result = []
    for variant, values in sorted(groups.items()):
        metrics = {key: stats(value) for key, value in values.items()}
        metrics["fps_average"] = len(values["wall_ms"]) * 1000 / sum(values["wall_ms"])
        result.append({"variant": variant, "metrics": metrics})
    return {"runs": runs, "groups": result, "errors": dict(errors), "metadata": metadata, "cases": cases}


if __name__ == "__main__": print(json.dumps(analyze(), indent=2))
