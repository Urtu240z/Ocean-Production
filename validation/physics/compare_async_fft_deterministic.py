"""Compare actual replayed physics outputs; ignore no differences silently."""
import json
import math
import sys
import copy
from pathlib import Path


def compare(a, b, path="", summary=None):
    if summary is None:
        summary = {"values": 0, "different": 0, "max_error": 0., "first": [], "discrete_mismatches": 0}
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a) != set(b):
            summary["discrete_mismatches"] += 1
            summary["first"].append(path + " keys")
        for key in a.keys() & b.keys():
            compare(a[key], b[key], path + "." + key, summary)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            summary["discrete_mismatches"] += 1
            summary["first"].append(path + " length")
        for index, (x, y) in enumerate(zip(a, b)):
            compare(x, y, path + "[%d]" % index, summary)
    else:
        summary["values"] += 1
        if a != b:
            summary["different"] += 1
            if isinstance(a, (int, float)) and not isinstance(a, bool) and isinstance(b, (int, float)) and not isinstance(b, bool):
                error = abs(a-b)
                summary["max_error"] = max(summary["max_error"], error) if math.isfinite(error) else math.inf
            else:
                summary["discrete_mismatches"] += 1
            if len(summary["first"]) < 8:
                summary["first"].append({"path":path,"baseline":a,"candidate":b})
    return summary


def physical_view(rows):
    out = copy.deepcopy(rows)
    unqueried = []
    for row in out:
        # The first row is captured before the first body force evaluation.
        # Async has already prepared its next field; baseline is demand-driven.
        # Preserve and report that metadata separately, while still comparing
        # every body value in this row. Never suppress later clock differences.
        if row["tick"] == 0 and all(not any(body["sample_valid"]) for body in row["bodies"]):
            unqueried.append({"tick":row["tick"],"prepared_field_time":row.pop("wave_time")})
    return out, unqueried


folder = Path(sys.argv[1])
results = []
for boats in [1,4,6]:
    baseline = json.loads((folder / ("b%d_m0.json" % boats)).read_text())
    reference, reference_preparation = physical_view(baseline["rows"])
    for mode in ["0_control",1,2]:
        candidate = json.loads((folder / ("b%d_m%s.json" % (boats,mode))).read_text())
        actual, actual_preparation = physical_view(candidate["rows"])
        result = compare(reference, actual)
        result.update(boats=boats,mode=mode,ticks=len(baseline["rows"]))
        result["unqueried_startup_preparation"] = {"baseline":reference_preparation,"candidate":actual_preparation}
        results.append(result)
print(json.dumps({"results":results}, indent=2))
sys.exit(1 if any(r["different"] or r["discrete_mismatches"] for r in results) else 0)
