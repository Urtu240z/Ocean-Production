"""Exact A/B replay comparison, including startup, contacts and torque outputs."""
import json
import struct
import sys
from pathlib import Path


def compare(a, b, path, result):
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a) != set(b): result["different"] += 1
        for key in sorted(a.keys() & b.keys()): compare(a[key], b[key], path + "." + key, result)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b): result["different"] += 1
        for i, (x, y) in enumerate(zip(a, b)): compare(x, y, path + "[%d]" % i, result)
    else:
        result["values"] += 1
        equal = type(a) is type(b) and (struct.pack("!d", a) == struct.pack("!d", b) if isinstance(a, float) else a == b)
        if not equal:
            result["different"] += 1
            if len(result["first"]) < 8: result["first"].append({"path": path, "A": a, "B": b})


if __name__ == "__main__":
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "temp/async_fft/deterministic"
    a = json.loads((folder / "contact_A_overlap.json").read_text(encoding="utf-8"))
    b = json.loads((folder / "contact_B_overlap.json").read_text(encoding="utf-8"))
    result = {"values": 0, "different": 0, "first": [], "ticks": len(a["rows"]), "boats": a["boats"]}
    compare(a["rows"], b["rows"], "rows", result)
    result["coverage"] = {"base_only": 0, "one_area": 0, "overlap": 0, "invalid_body_rows_after_startup": 0}
    for row in a["rows"]:
        affected = sum(weight > 0 for weight in row["area_weights"])
        result["coverage"][["base_only", "one_area", "overlap"][min(affected, 2)]] += 1
        if row["tick"] > 0:
            result["coverage"]["invalid_body_rows_after_startup"] += sum(not all(body["sample_valid"]) for body in row["bodies"])
    print(json.dumps(result, indent=2))
    sys.exit(1 if result["different"] or not all(result["coverage"][key] for key in ["base_only", "one_area", "overlap"]) else 0)
