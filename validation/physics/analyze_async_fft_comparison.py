"""Summarize completed A/B/C runs; never combine inclusive timers.

Prints JSON, or a publication-ready SVG (--svg), to stdout. Raw captures remain
under the selected capture directory. Run after the benchmark has stopped.
"""
import argparse
import csv
import io
import json
import math
import re
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path

NAMES = {0: "SYNC", 1: "3 WORKERS", 2: "4 WORKERS"}


def percentile(values, q):
    if not values:
        return None
    a = sorted(values)
    position = (len(a) - 1) * q
    lo = int(position)
    hi = min(lo + 1, len(a) - 1)
    return a[lo] + (a[hi] - a[lo]) * (position - lo)


def stats(values):
    values = [float(v) for v in values if isinstance(v, (int, float)) and math.isfinite(v)]
    if not values:
        return {"n": 0}
    return {"n": len(values), "mean": statistics.fmean(values), "p50": percentile(values, .5),
            "p95": percentile(values, .95), "p99": percentile(values, .99), "max": max(values), "min": min(values)}


def metric_pair(value):
    if isinstance(value, str):
        numbers = re.findall(r"-?\d+(?:\.\d+)?", value)
        return (float(numbers[0]), float(numbers[1])) if len(numbers) == 2 else (0, 0)
    return value if isinstance(value, list) and len(value) == 2 else (0, 0)


def sustained_fps(frames):
    durations, total, count = [], 0., 0
    for frame in frames:
        total += frame[2]
        count += 1
        if total >= 1000:
            durations.append(count * 1000 / total)
            total, count = 0., 0
    return durations


def collect_case(case, mode):
    values = defaultdict(list)
    measured_ticks = {row[0] for row in case["ticks"]}
    complete_physics = [r for r in case.get("engine_physics", []) if r[3] > 0 and r[1] in measured_ticks]
    values["wall_ms"] = [f[2] for f in case["frames"]]
    values["engine_physics_ms"] = [r[2] for r in complete_physics]
    values["engine_physics_single_tick_ms"] = [r[2] for r in complete_physics if r[3] == 1]
    values["physics_steps_per_render"] = [r[3] for r in complete_physics]
    values["legacy_physics_monitor_1s_max_ms"] = [f[4] for f in case["frames"]]
    values["node_physics_callbacks_ms"] = [t[2] for t in case["ticks"]]
    values["fps_1s"] = sustained_fps(case["frames"])
    values["gpu_viewport_ms"] = [r[5] for r in case["render"] if r[5] > 0]
    for row in case["metrics_ticks"].values():
        calls, microseconds = metric_pair(row.get("controller.integrate"))
        if calls > 0:
            values["controller_total_per_tick_ms"].append(microseconds / 1000)
            values["controller_per_call_ms"].append(microseconds / 1000 / calls)
    stages = defaultdict(float)
    previous_times = {}
    previous_wait = {}
    previous_buffer_wait = {}
    errors = {"wrong_tick": 0, "wrong_time": 0, "wrong_resolution": 0, "invalid": 0,
              "misses": 0, "recoveries": 0, "invalidated": 0, "failures": 0,
              "profiler_boundary_ticks_without_sample": 0, "profiler_outside_window_samples": 0}
    covered_ticks = set()
    for row in complete_physics:
        covered_ticks.update(set(range(row[1]-row[3]+1,row[1]+1)) & measured_ticks)
    errors["profiler_boundary_ticks_without_sample"] = len(measured_ticks-covered_ticks)
    errors["profiler_outside_window_samples"] = len(case.get("engine_physics", []))-len(complete_physics)
    async_first, async_last = {}, {}
    for tick_row in case.get("fft", []):
        workspace_mib = 0.0
        states = [("base", tick_row["base"], tick_row["async"])] + [
            ("local%d" % i, row["profile"], row["async"]) for i, row in enumerate(tick_row["locals"])]
        for state, profile, asynchronous in states:
            if mode:
                errors["wrong_tick"] += asynchronous.get("tick") != tick_row["tick"]
                errors["wrong_time"] += asynchronous.get("time") != profile.get("simulation_time")
                errors["wrong_resolution"] += profile.get("resolutions") != [128, 128, 128]
                errors["invalid"] += not profile.get("valid", False)
                wait = asynchronous.get("wait_us", 0)
                blocked = max(0, wait-previous_wait[state]) if state in previous_wait else asynchronous.get("last_wait_us",0)
                values[state + "_wait_ms"].append(blocked/1000)
                previous_wait[state] = wait
                buffer_wait = asynchronous.get("buffer_wait_us",0)
                if state in previous_buffer_wait:
                    values[state + "_buffer_wait_ms"].append(max(0,buffer_wait-previous_buffer_wait[state])/1000)
                previous_buffer_wait[state] = buffer_wait
                async_first.setdefault(state, asynchronous)
                async_last[state] = asynchronous
            time = profile.get("simulation_time")
            # Baseline local fields are demand-driven. Do not count a cached
            # field's old build profile again on every subsequent idle tick.
            new_build = profile.get("valid") and (mode or state == "base" or (state in previous_times and time != previous_times[state]))
            previous_times[state] = time
            if new_build:
                values[state + "_build_wall_ms"].append(profile["update_us"] / 1000)
                for band, duration in enumerate(profile.get("band_build_us", [])):
                    values[state + "_band%d_build_ms" % band].append(duration / 1000)
                for name, key in [("phase", "phase_us"), ("evolution", "spectrum_evolution_us"),
                                  ("packing", "packing_us"), ("ifft", "ifft_us"),
                                  ("publication", "field_publication_us")]:
                    stages[name] += sum(profile.get(key, []))
                if mode:
                    stages["checkpoint"] += sum(asynchronous.get("checkpoint_us", []))
                    stages["snapshot_transfer"] += sum(asynchronous.get("transfer_us", []))
            workspace_mib += profile.get("memory_bytes", 0) / 1048576
        values["fft_workspace_mib"].append(workspace_mib)
    for state, last in async_last.items():
        first = async_first[state]
        for key in ["misses", "recoveries", "invalidated", "failures"]:
            errors[key] += max(0, last.get(key, 0) - first.get(key, 0))
    pool = {"jobs": [0] * 6, "peak": 0, "task_wall_us": 0}
    if mode and "base" in async_last:
        a = async_first["base"].get("pool_jobs_peak_busy_us", [0] * 8)
        b = async_last["base"].get("pool_jobs_peak_busy_us", [0] * 8)
        pool = {"jobs": [max(0, b[i] - a[i]) for i in range(6)], "peak": b[6], "task_wall_us": max(0, b[7] - a[7])}
    return values, dict(stages), errors, pool


def analyze(folder):
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8-sig"))
    grouped = defaultdict(lambda: {"values": defaultdict(list), "stages_us": defaultdict(float), "errors": defaultdict(int),
                                   "pool_jobs": [0] * 6, "peak": 0, "task_wall_us": 0, "runs": [], "cases": defaultdict(lambda: defaultdict(list))})
    run_summaries = []
    scene_hashes, layouts, fixtures = set(), set(), set()
    capture_checks = {"mist_disabled": True, "resolution_1080p": True, "physics_60hz": True, "d3d12": True, "complete_physics_profiler": True}
    gpu_rows = []
    gpu_file = folder / "gpu_telemetry.csv"
    if gpu_file.exists():
        for row in csv.reader(gpu_file.read_text(encoding="utf-8-sig").splitlines()[1:]):
            try:
                # nvidia-smi uses this host's Madrid local timestamp (UTC+2 on
                # the recorded 2026-10-19). Captures store UTC/unix separately.
                instant = datetime.strptime(row[0].strip(), "%Y/%m/%d %H:%M:%S.%f").replace(tzinfo=timezone(timedelta(hours=2))).timestamp()
                gpu_rows.append((instant, [float(x.strip()) for x in row[1:]]))
            except (ValueError, IndexError):
                pass
    for run in manifest["runs"]:
        if run["exit_code"] != 0 or not run["result_present"]:
            continue
        data = json.loads((folder / (run["label"] + ".json")).read_text(encoding="utf-8"))
        mode, boats = run["mode"], run["boats"]
        group = grouped[(boats, mode)]
        scene_hashes.add(data["metadata"]["scene_sha256"])
        layouts.add(data["metadata"].get("layout"))
        fixtures.add(len(data["metadata"]["area_entries"]))
        capture_checks["resolution_1080p"] &= data["metadata"]["root_size"] == "(1920, 1080)"
        capture_checks["physics_60hz"] &= data["metadata"]["physics_hz"] == 60
        capture_checks["d3d12"] &= data["metadata"]["driver"] == "d3d12"
        run_values = defaultdict(list)
        for case in data["cases"]:
            capture_checks["mist_disabled"] &= case.get("stern_mist_disabled_verified", False)
            capture_checks["complete_physics_profiler"] &= bool(case.get("engine_physics"))
            values, stages, errors, pool = collect_case(case, mode)
            for name, samples in values.items():
                group["values"][name].extend(samples)
                group["cases"][case["case"]][name].extend(samples)
                run_values[name].extend(samples)
            for name, value in stages.items(): group["stages_us"][name] += value
            for name, value in errors.items(): group["errors"][name] += value
            for i in range(6): group["pool_jobs"][i] += pool["jobs"][i]
            group["peak"] = max(group["peak"], pool["peak"])
            group["task_wall_us"] += pool["task_wall_us"]
            begin, end = case["measurement_start_unix"], case["measurement_end_unix"]
            for sample in run.get("process_samples", []) if manifest.get("process_sampler") == "engine_direct_v2" else []:
                instant = datetime.fromisoformat(sample["utc"].replace("Z", "+00:00")).timestamp()
                if begin <= instant <= end:
                    group["values"]["process_cpu_machine_percent"].append(sample["cpu_percent_machine"])
                    group["values"]["process_private_mib"].append(sample["private_bytes"] / 1048576)
                    group["values"]["process_working_set_mib"].append(sample["working_set_bytes"] / 1048576)
            for instant, sample in gpu_rows:
                if begin <= instant <= end:
                    for name, value in zip(["gpu_temperature_c", "gpu_clock_mhz", "gpu_memory_clock_mhz", "gpu_utilization_percent", "gpu_power_w"], sample):
                        group["values"][name].append(value)
        row = {"label": run["label"], "boats": boats, "mode": mode,
               "metrics": {key: stats(v) for key, v in run_values.items()}}
        group["runs"].append(row)
        run_summaries.append(row)
    groups = []
    for (boats, mode), group in sorted(grouped.items()):
        metrics = {key: stats(v) for key, v in group["values"].items()}
        wall = group["values"]["wall_ms"]
        metrics["fps_average"] = len(wall) * 1000 / sum(wall)
        exclusive = sum(group["stages_us"].get(k, 0) for k in ["phase", "evolution", "packing", "ifft", "publication"])
        groups.append({"boats": boats, "mode": mode, "name": NAMES[mode], "passes": len(group["runs"]),
                       "metrics": metrics, "stages_us": dict(group["stages_us"]),
                       "stage_percent": {key: value * 100 / exclusive for key, value in group["stages_us"].items()
                                         if key in ["phase", "evolution", "packing", "ifft", "publication"]} if exclusive else {},
                       "coordinator_overhead_relative_percent": {key: group["stages_us"].get(key, 0) * 100 / exclusive
                                                                for key in ["checkpoint", "snapshot_transfer"]} if exclusive else {},
                       "errors": dict(group["errors"]), "pool_jobs": group["pool_jobs"], "worker_peak": group["peak"],
                       "worker_task_wall_us": group["task_wall_us"],
                       "cases": {case: {key: stats(v) for key, v in values.items()} for case, values in group["cases"].items()},
                       "runs": group["runs"]})
    return {"source": str(folder), "completed_runs": len(run_summaries), "scene_hashes": sorted(scene_hashes),
            "layouts": sorted(layouts), "active_area_counts": sorted(fixtures), "cpu": manifest["cpu"],
            "process_sampler": manifest.get("process_sampler", "invalid_console_launcher"),
            "capture_checks": capture_checks, "groups": groups}


def svg(summary):
    import matplotlib
    matplotlib.use("svg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "svg.fonttype": "none"})
    fig, axes = plt.subplots(2, 2, figsize=(12, 8))
    fig.subplots_adjust(top=.80, bottom=.08, left=.07, right=.98, hspace=.42, wspace=.17)
    colors = ["#6b7280", "#007f8b", "#b55b00"]
    fleets = sorted({g["boats"] for g in summary["groups"]})
    for axis, metric, quantile, title in [
        (axes[0,0], "wall_ms", "p99", "WALL frame · p99"),
        (axes[0,1], "engine_physics_ms", "p99", "Física completa · p99 del máximo tick por frame"),
        (axes[1,0], "controller_total_per_tick_ms", "p99", "Controladores por tick · p99"),
        (axes[1,1], "gpu_viewport_ms", "p95", "GPU viewport · p95")]:
        for mode, color in enumerate(colors):
            points = [next((g for g in summary["groups"] if g["boats"] == fleet and g["mode"] == mode), None) for fleet in fleets]
            xs = [i + (mode-1)*.23 for i in range(len(fleets))]
            ys = [g["metrics"].get(metric, {}).get(quantile, 0) if g else 0 for g in points]
            axis.bar(xs, ys, width=.22, label=NAMES[mode], color=color)
        axis.set_xticks(range(len(fleets)), [str(f) for f in fleets])
        axis.set_xlabel("Motos")
        axis.set_ylabel("ms")
        axis.set_title(title, loc="left", fontweight="bold")
        axis.grid(axis="y", alpha=.18)
        axis.set_axisbelow(True)
        axis.spines[["top", "right"]].set_visible(False)
    handles, labels = axes[0,0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(.5, .89), ncol=3, frameon=False)
    fig.suptitle("FFT física CPU Lite · 3 pasadas por modo y carga\n1920×1080 · 60 Hz · D3D12 · Stern Mist apagado", fontsize=14, y=.98)
    output = io.StringIO()
    fig.savefig(output, format="svg", bbox_inches="tight", metadata={"Date": "2026-10-19"})
    return output.getvalue()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path)
    parser.add_argument("--svg", action="store_true")
    parser.add_argument("--compact", action="store_true")
    arguments = parser.parse_args()
    summary = analyze(arguments.folder)
    if arguments.compact:
        key_metrics = ["wall_ms","engine_physics_ms","engine_physics_single_tick_ms","controller_total_per_tick_ms","gpu_viewport_ms"]
        for group in summary["groups"]:
            group["cases"] = {name:{key:{q:value for q,value in metrics[key].items() if q in ["p95","p99","max"]}
                for key in key_metrics if key in metrics} for name,metrics in group["cases"].items()}
            for run in group["runs"]:
                run["metrics"] = {key:value for key,value in run["metrics"].items() if key in key_metrics}
    print(svg(summary) if arguments.svg else json.dumps(summary, ensure_ascii=False, indent=2))
