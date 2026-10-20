"""Contact Pipeline 3: source-tagged traces, exclusive costs, rejected prototype."""
import json
import hashlib
import statistics
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / "temp/contact_pipeline_3"
DETERMINISTIC = ROOT / "temp/async_fft/deterministic"

def stats(values):
    ordered = sorted(values)
    def q(fraction):
        position = (len(ordered)-1)*fraction
        low = int(position)
        high = min(low+1,len(ordered)-1)
        return ordered[low]+(ordered[high]-ordered[low])*(position-low)
    return {"n":len(ordered),"mean":statistics.mean(ordered),"p50":q(.5),"p95":q(.95),"p99":q(.99),
            "min":ordered[0],"max":ordered[-1]}

def load(label):
    run = json.loads((FOLDER/(label+".run.json")).read_text(encoding="utf-8-sig"))
    assert run["exit_code"] == 0 and run["fingerprint_before"] == run["fingerprint_after"]
    errors = (FOLDER/(label+".stderr.log")).read_text(errors="replace")
    assert "ERROR:" not in errors and "SCRIPT ERROR" not in errors
    return json.loads((FOLDER/(label+".json")).read_text()),run

def trace(label):
    capture,run = load(label)
    queries = [row for case in capture["cases"] for row in case["cp3_trace"]]
    ticks = [row for case in capture["cases"] for row in case["cp3"]]
    flags = ["root_equal","prefetched_exact_matches","active_is_own","own_prepare_tick_age",
             "same_backend","same_mode","same_spectrum","same_source_revision","same_space_revision",
             "field_tick_age","sample_tick_age","cursor","cache_size"]
    return {"query_count":len(queries),"ticks":len(ticks),
            "flags":{k:dict(Counter(str(row[k]) for row in queries)) for k in flags},
            "identical_field_time":sum(row["field_time"] == row["own_field_time"] for row in queries),
            "by_vehicle":dict(Counter(row["vehicle"] for row in queries)),
            "metadata":capture["metadata"],"run":run}

def costs(label):
    capture,run = load(label)
    labels = capture["cases"][0]["cp3_labels"]
    rows = [dict(zip(labels,row[1])) for case in capture["cases"] for row in case["cp3"]]
    full = [row for row in rows if row["callbacks"] == 6]
    counts = {key:stats([row[key] for row in full]) for key in labels if not key.endswith("_us") and key != "reserved"}
    durations = {key:stats([row[key]/1000 for row in full]) for key in labels if key.endswith("_us")}
    child_keys = ["validation_us","positions_us","native_bridge_us","decode_us","areas_us",
                  "hull_waves_us","tsunami_us","drift_stamp_us"]
    durations["callback_excluding_sample_ms"] = stats([(row["callback_us"]-row["sample_us"])/1000 for row in full])
    durations["native_bridge_excluding_fft_ms"] = stats([(row["native_bridge_us"]-row["fft_native_us"])/1000 for row in full])
    durations["query_administration_remainder_ms"] = stats([(row["sample_us"]-sum(row[k] for k in child_keys))/1000 for row in full])
    if "local_native_bridge_us" in labels:
        durations["areas_excluding_local_native_ms"] = stats([(row["areas_us"]-row["local_native_bridge_us"])/1000 for row in full])
    return {"full_ticks":len(full),"boundary_rows":len(rows)-len(full),"counts":counts,"milliseconds":durations,
            "warning":"Diagnostic costs only, not a clean FPS or whole-frame performance comparison.",
            "metadata":capture["metadata"],"run":run}

def replay():
    a = json.loads((DETERMINISTIC/"cp3_replay_A.json").read_text())
    b = json.loads((DETERMINISTIC/"cp3_replay_B.json").read_text())
    assert len(a["rows"]) == len(b["rows"]) == 720
    mismatch = [x["tick"] for x,y in zip(a["rows"],b["rows"]) if x["physical_binary_sha256"] != y["physical_binary_sha256"]]
    assert not mismatch,mismatch[:5]
    totals = [[sum(row["cp3"]["contact_calls_hits_misses_invalid"][i] for row in capture["rows"]) for i in range(4)] for capture in [a,b]]
    assert totals[0] == totals[1]
    return {"ticks":720,"boats":6,"binary_mismatch_ticks":mismatch,"contact_totals_A":totals[0],
            "contact_totals_B":totals[1],"coverage":b["rows"][-1]["np2_water"]["coverage"],
            "raw_fft_fields_compared":True,"candidate_retained":False}

def analyze():
    micro = json.loads((FOLDER/"compact_micro.json").read_text())
    linux = json.loads((FOLDER/"compact_micro_linux.json").read_text())
    guards = json.loads((FOLDER/"compact_micro_guards.json").read_text())
    assert micro["checks"] == linux["checks"] == 32
    assert not micro["binary_mismatch_iterations"] and not linux["binary_mismatch_iterations"]
    assert guards["nonzero_force_steps"] > 0 and not guards["binary_mismatch_iterations"]
    savings = {}
    for flag in [False,True]:
        rows = [row for row in micro["blocks"] if row["profiling"] == flag]
        means = {variant:statistics.mean(row["metrics"]["mean_ms"] for row in rows if row["variant"] == variant) for variant in ["A","B"]}
        savings[str(flag)] = {**means,"saving_ms":means["A"]-means["B"]}
    disabled = costs("arcade_disabled6")
    assert disabled["counts"]["queries"]["max"] == 0
    files = list(FOLDER.glob("*.json")) + list(DETERMINISTIC.glob("cp3_replay_*.json"))
    return {"published_master":"ce2a34346aefc9e62b3bac8623f22bfcf203f9f0",
            "branch":"codex/contact-pipeline-3","production_optimization_retained":False,
            "traces":{"benchmark_route":trace("arcade_trace6"),"free_motion":trace("arcade_free6")},
            "arcade_costs":costs("arcade_cost6"),"arcade_disabled":disabled,
            "local_native_separation_not_pooled":costs("arcade_cost6_local"),
            "micro":micro,"micro_savings":savings,"micro_guards":{"nonzero_force_steps":guards["nonzero_force_steps"],"every_consumer_native_batches":32},
            "linux_micro_parity":{"checks":32,"differences":0},
            "replay":replay(),"no_graphical_ABBA_reason":"Net adapter saving is too small; no production change retained.",
            "captures":[{"path":path.relative_to(ROOT).as_posix(),"bytes":path.stat().st_size,
                         "sha256":hashlib.sha256(path.read_bytes()).hexdigest()} for path in sorted(files)]}

if __name__ == "__main__":
    destination = ROOT/"validation/reports/contact_pipeline_3_checks_2026_10_20.json"
    destination.write_text(json.dumps(analyze(),indent=2)+"\n",encoding="utf-8")
    print(destination)
