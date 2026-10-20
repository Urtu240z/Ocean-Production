"""PERF-CONTACT-1: four uninstrumented A/B runs; diagnostics kept separate."""
import json
import re
from collections import defaultdict
from pathlib import Path
from analyze_async_fft_comparison import collect_case, stats

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / "temp/async_fft/perf_contact_1"


def summarize(labels):
    groups = defaultdict(lambda: defaultdict(list))
    runs = []
    errors = defaultdict(int)
    for label in labels:
        path = FOLDER / (label + ".json")
        if not path.exists():
            continue
        capture = json.loads(path.read_text(encoding="utf-8"))
        variant = label[0]
        run_values = defaultdict(list)
        for case in capture["cases"]:
            values, _, case_errors, _ = collect_case(case, 1)
            for key, samples in values.items():
                groups[variant][key].extend(samples)
                run_values[key].extend(samples)
            for key, value in case_errors.items():
                errors[variant + "." + key] += value
        runs.append({"label": label, "metrics": {k: stats(v) for k, v in run_values.items()
                     if k in ["wall_ms", "engine_physics_ms", "controller_total_per_tick_ms", "gpu_viewport_ms"]}})
    result = []
    for variant, values in sorted(groups.items()):
        metrics = {key: stats(value) for key, value in values.items()}
        metrics["fps_average"] = len(values["wall_ms"]) * 1000 / sum(values["wall_ms"])
        result.append({"variant": variant, "metrics": metrics})
    return {"runs": runs, "groups": result, "errors": dict(errors)}


def diagnostics(label):
    path = FOLDER / (label + ".json")
    if not path.exists():
        return {}
    capture = json.loads(path.read_text(encoding="utf-8"))
    total = defaultdict(int)
    ticks = 0
    stage_us, stage_calls = defaultdict(int), defaultdict(int)
    measured_ticks = 0
    for case in capture["cases"]:
        ticks += case["contact_diagnostic_ticks_including_settle"]
        for key, value in case["contact_diagnostic_including_settle"].items():
            # Initial A capture called this contacts counter 'positions'.
            key = "native_base_contacts" if key == "native_base_positions" else key
            total[key] += value
        for row in case["metrics_ticks"].values():
            measured_ticks += int("controller.integrate" in row)
            for key, value in row.items():
                numbers = re.findall(r"-?\d+", value)
                if len(numbers) == 2:
                    stage_calls[key] += int(numbers[0])
                    stage_us[key] += int(numbers[1])
    return {"ticks_including_settle": ticks, "totals": dict(total),
            "per_tick": {key: value / ticks for key, value in total.items()},
            "measured_ticks": measured_ticks,
            "stages_per_measured_tick_us": {k: v / measured_ticks for k, v in stage_us.items()},
            "stage_calls_per_measured_tick": {k: v / measured_ticks for k, v in stage_calls.items()}}


if __name__ == "__main__":
    result = summarize(["A1", "B1", "B2", "A2"])
    result["diagnostics"] = {label: diagnostics(label) for label in ["diagnostic_A", "diagnostic_B"]}
    print(json.dumps(result, indent=2))
