"""Current-cohort CPU inventory and A/B/B/A; never pool historical gains."""
import json
import hashlib
from pathlib import Path
from collections import defaultdict
from analyze_async_fft_comparison import collect_case, metric_pair, stats

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / "temp/native_performance_2"
LABELS = ["fingerprint_A1", "fingerprint_B1", "fingerprint_B2", "fingerprint_A2"]


def diagnostic(label, boats):
    capture = json.loads((FOLDER / (label + ".json")).read_text())
    rows = [r for c in capture["cases"] for r in c["metrics_ticks"].values()
            if metric_pair(r.get("controller.integrate"))[0] == boats]
    keys = {k for r in rows for k in r}
    values = {k: stats([metric_pair(r.get(k))[1]/1000 for r in rows]) for k in keys}
    calls = {k: sum(metric_pair(r.get(k))[0] for r in rows)/len(rows) for k in keys}
    # Exclusive partitions use children from the same recorder/window only.
    for name, parent, children in [
        ("area.composition_exclusive", "area.composition_including_gradient", ["area.gradient"]),
        ("area.dispatch_exclusive", "area.local_dispatch", ["slot0.sample", "slot1.sample"]),
        ("area.sample_bridge", "slot1.sample", ["slot1.native_query"]),
        ("water.cell_loop_excluding_force_math", "controller.water.cell_loop_excluding_jolt", ["controller.water.cell_force_math"]),
    ]:
        values[name] = stats([(metric_pair(r.get(parent))[1]-sum(metric_pair(r.get(c))[1] for c in children))/1000 for r in rows])
    ticks = sum(c["contact_diagnostic_ticks_including_settle"] for c in capture["cases"])
    provider = defaultdict(int)
    for case in capture["cases"]:
        for k, v in case["contact_diagnostic_including_settle"].items(): provider[k] += v
    # The cloned batch implementation bypasses these older wrapper counters.
    # Their zeros mean uninstrumented, never zero physical FFT evaluations.
    unsupported = ["batch_calls","batch_us","native_base_batches","native_base_contacts","native_base_us"]
    for k in unsupported: provider.pop(k,None)
    return {"ticks":len(rows),"metrics_ms":values,"calls_per_tick":calls,
            "provider_ticks_including_settle":ticks,"provider_per_tick_including_settle":{k:v/ticks for k,v in provider.items()},
            "uninstrumented_legacy_counters":unsupported,"metadata":capture["metadata"]}


def performance():
    grouped = defaultdict(lambda: defaultdict(list))
    results, integrity, failures = [], [], defaultdict(int)
    pools = defaultdict(lambda: {"jobs":[0]*6,"task_wall_us":0,"peak":0})
    for label in LABELS:
        capture = json.loads((FOLDER/(label+".json")).read_text())
        run = json.loads((FOLDER/(label+".run.json")).read_text(encoding="utf-8-sig"))
        assert run["exit_code"] == 0 and run["fingerprint_before"] == run["fingerprint_after"]
        stderr = (FOLDER/(label+".stderr.log")).read_text(errors="replace")
        assert "ERROR:" not in stderr and "SCRIPT ERROR" not in stderr
        variant = label.split("_")[-1][0]
        values = defaultdict(list)
        for case in capture["cases"]:
            metrics, _, errors, pool = collect_case(case,1)
            for k,v in metrics.items(): values[k].extend(v); grouped[variant][k].extend(v)
            for k,v in errors.items(): failures[label+"."+k] += v
            for i in range(6): pools[variant]["jobs"][i] += pool["jobs"][i]
            pools[variant]["task_wall_us"] += pool["task_wall_us"]
            pools[variant]["peak"] = max(pools[variant]["peak"],pool["peak"])
        result = {k:stats(v) for k,v in values.items()}
        result["fps_average"] = len(values["wall_ms"])*1000/sum(values["wall_ms"])
        results.append({"label":label,"metrics":result,"metadata":capture["metadata"]})
        integrity.append(run["fingerprint_before"])
    changing = {"addons/ocean/areas/ocean_local_sea_state.gd", "addons/ocean/core/ocean_wave_band_profile.gd"}
    common = [{k:v for k,v in row.items() if k not in changing} for row in integrity]
    assert all(row == common[0] for row in common)
    assert integrity[0] == integrity[3] and integrity[1] == integrity[2]
    aggregate = {group:{k:stats(v) for k,v in values.items()} for group,values in grouped.items()}
    for group,values in grouped.items():
        aggregate[group]["fps_average"] = len(values["wall_ms"])*1000/sum(values["wall_ms"])
    return {"runs":results,"groups":aggregate,"errors":dict(failures),"pools":dict(pools),"common_fingerprint":common[0],"only_intended_files_differ":True}


def replay():
    folder = ROOT/"temp/async_fft/deterministic"
    a = json.loads((folder/"np2_replay_A.json").read_text())
    b = json.loads((folder/"np2_replay_B.json").read_text())
    mismatches = [x["tick"] for x,y in zip(a["rows"],b["rows"]) if x["physical_binary_sha256"] != y["physical_binary_sha256"]]
    assert len(a["rows"]) == len(b["rows"]) == 720
    assert not mismatches, mismatches[:10]
    return {"ticks":len(a["rows"]),"boats":a["boats"],"bit_differences":0,
            "configuration_checks":b["rows"][-1]["np2_water"]["hot_configuration_checks"],
            "coverage":b["rows"][-1]["np2_water"]["coverage"]}


def analyze():
    files = list(FOLDER.glob("*.json")) + list((ROOT/"temp/async_fft/deterministic").glob("np2_replay_*.json"))
    result = {"base_head":"88cf3ae5bca090bb34404ce362ad4a7966df2a24","branch":"codex/native-performance-2",
              "performance":performance(),"replay":replay(),
              "fingerprint":json.loads((FOLDER/"fingerprint_parity.json").read_text()),
              "linux_fingerprint":json.loads((FOLDER/"fingerprint_parity_linux.json").read_text()),
              "production_smoke":json.loads((FOLDER/"production_smoke.json").read_text()),
              "diagnostics":{label:diagnostic(label,boats) for label,boats in [
                  ("current_diagnostic6",6),("forces_diagnostic6",6),("final_diagnostic1",1),("final_diagnostic6",6)]},
              "captures":[{"path":p.relative_to(ROOT).as_posix(),"bytes":p.stat().st_size,
                           "sha256":hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(files)]}
    return result


if __name__ == "__main__":
    output = ROOT/"validation/reports/native_performance_2_checks_2026_10_20.json"
    output.write_text(json.dumps(analyze(),indent=2)+"\n",encoding="utf-8")
    print(output)
