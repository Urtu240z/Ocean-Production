"""PERF-SCALING-2: diagnostic clocks stay separate from the four performance runs."""
import json, hashlib
from collections import defaultdict
from pathlib import Path
from analyze_async_fft_comparison import collect_case, metric_pair, stats

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / "temp/scaling_2"

def diagnostics(label, boats):
    capture = json.loads((FOLDER / (label + ".json")).read_text(encoding="utf-8"))
    values, calls = defaultdict(list), defaultdict(list)
    used = excluded = 0
    all_keys = {k for c in capture["cases"] for row in c["metrics_ticks"].values() for k in row}
    all_keys |= {"area.gradient", "slot0.sample", "slot1.sample", "slot0.native_query", "slot1.native_query"}
    for case in capture["cases"]:
        for row in case["metrics_ticks"].values():
            if metric_pair(row.get("controller.integrate"))[0] != boats:
                excluded += 1
                continue
            used += 1
            for key in all_keys:
                n, us = metric_pair(row.get(key))
                values[key].append(us/1000)
                calls[key].append(n)
            def us(key): return metric_pair(row.get(key))[1]
            values["area.composition_exclusive"].append((us("area.composition_including_gradient")-us("area.gradient"))/1000)
            samples = us("slot0.sample")+us("slot1.sample")
            native = us("slot0.native_query")+us("slot1.native_query")
            values["area.dispatch_exclusive"].append((us("area.local_dispatch")-samples)/1000)
            values["area.sample_exclusive"].append((samples-native)/1000)
            children = us("area.weights_mapping")+us("area.local_dispatch")+us("area.composition_including_gradient")
            values["area.wrapper_and_clock_overhead"].append((us("apply")-children)/1000)
            phases = sum(us(k) for k in row if k.startswith("controller.") and k != "controller.integrate")
            values["controller.wrapper_and_diagnostic_overhead"].append((us("controller.integrate")-phases)/1000)
    ticks = sum(c["contact_diagnostic_ticks_including_settle"] for c in capture["cases"])
    totals = defaultdict(int)
    for c in capture["cases"]:
        for k, v in c["contact_diagnostic_including_settle"].items(): totals[k] += v
    return {"full_controller_ticks":used,"boundary_or_noncontroller_rows":excluded,
        "metrics":{k:stats(v) for k,v in values.items()},
        "calls_per_tick":{k:sum(v)/len(v) for k,v in calls.items()},
        "provider_window":"Includes settle, unlike phase metrics. Do not subtract across these windows.",
        "provider_ticks_including_settle":ticks,
        "provider_totals":dict(totals),"provider_per_tick":{k:v/ticks for k,v in totals.items()},
        "metadata":capture["metadata"]}

def performance(labels=None):
    groups = defaultdict(lambda:defaultdict(list))
    runs, metadata, errors = [], [], defaultdict(int)
    for label in labels or ["clean_A1","clean_B1","clean_B2","clean_A2"]:
        path = FOLDER/(label+".json")
        if not path.exists(): continue
        capture = json.loads(path.read_text(encoding="utf-8"))
        group = label.split("_")[1][0]
        rv = defaultdict(list)
        for c in capture["cases"]:
            values, _, failures, _ = collect_case(c,1)
            for row in c["hull_geometry"]:
                values["water_physics_ms"].append(row[1]/1000)
                values["hull_geometry_ms"].append(row[2]/1000)
            for k,v in values.items(): groups[group][k].extend(v); rv[k].extend(v)
            for k,v in failures.items(): errors[group+"."+k] += v
        metrics = {k:stats(v) for k,v in rv.items()}
        metrics["fps_average"] = len(rv["wall_ms"])*1000/sum(rv["wall_ms"])
        runs.append({"label":label,"metrics":metrics})
        metadata.append({"label":label,"metadata":capture["metadata"]})
    aggregate = {}
    for group, values in groups.items():
        aggregate[group] = {k:stats(v) for k,v in values.items()}
        aggregate[group]["fps_average"] = len(values["wall_ms"])*1000/sum(values["wall_ms"])
    return {"runs":runs,"groups":aggregate,"errors":dict(errors),"metadata":metadata}

def replay(candidate):
    folder = ROOT/"temp/async_fft/deterministic"
    a = json.loads((folder/"hull_B_binary.json").read_text(encoding="utf-8"))
    b = json.loads((folder/(candidate+".json")).read_text(encoding="utf-8"))
    mismatch = [x["tick"] for x,y in zip(a["rows"],b["rows"]) if x["physical_binary_sha256"] != y["physical_binary_sha256"]]
    assert len(b["rows"]) == len(a["rows"]) == 720 and not mismatch
    return {"ticks":len(b["rows"]),"mismatches":mismatch,"golden":"hull_B_binary","candidate":candidate}

def analyze():
    integrity = []
    for p in sorted(FOLDER.glob("*")):
        if p.is_file() and p.suffix in [".json",".log"]:
            integrity.append({"path":p.relative_to(ROOT).as_posix(),"sha256":hashlib.sha256(p.read_bytes()).hexdigest(),"bytes":p.stat().st_size})
    labels = ["clean_A1","clean_B1","clean_B2","clean_A2"]
    fingerprints = []
    for label in labels:
        run = json.loads((FOLDER/(label+".run.json")).read_text(encoding="utf-8-sig"))
        assert run["fingerprint_before"] == run["fingerprint_after"]
        assert "ERROR:" not in (FOLDER/(label+".stderr.log")).read_text(errors="replace")
        fingerprints.append(run["fingerprint_before"])
    assert all(value == fingerprints[0] for value in fingerprints)
    return {"diagnostics":{str(n):diagnostics("diagnostic"+str(n),n) for n in [1,6]},
        "source_micro":json.loads((FOLDER/"source_micro.json").read_text()),
        "replays":[replay("hull_production"),replay("source_B"),replay("source_clean_B")],
        "environment_integrity":{"accepted_labels":labels,"all_equal":True,"fingerprint":fingerprints[0]},
        "performance":performance(),
        "excluded_initial_cohort":performance(["source_A1","source_B1","source_B2","source_A2"]),
        "excluded_tail_followup":performance(["tail_A","tail_B"]),
        "exclusion_reason":"Rapier directory disappeared between B2 and A2. A2 and both tail runs logged three startup extension errors. These runs are retained but never pooled with the clean cohort.",
        "capture_integrity":integrity}

if __name__ == "__main__": print(json.dumps(analyze(),indent=2))
