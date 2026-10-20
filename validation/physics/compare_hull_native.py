"""Exact physical replay; only backend telemetry is separated, never physics."""
import copy
import json
import sys
from pathlib import Path
from compare_perf_contact import compare

folder = Path(__file__).resolve().parents[2] / "temp/async_fft/deterministic"
a = json.loads((folder / "hull_A_exact.json").read_text(encoding="utf-8"))
b = json.loads((folder / "hull_B_exact.json").read_text(encoding="utf-8"))
rows = [copy.deepcopy(a["rows"]), copy.deepcopy(b["rows"])]
telemetry = []
for candidate in rows:
    diagnostics = [row.pop("hull_backend_diagnostics") for row in candidate]
    telemetry.append(diagnostics[-1])
    for row in candidate:
        for body in row["bodies"]:
            for cell in body["hull_cell_geometry"]:
                if cell is not None:
                    assert isinstance(cell["center"], list) and len(cell["center"]) == 3
result = {"values": 0, "different": 0, "first": [], "ticks": len(rows[0]), "boats": a["boats"]}
compare(rows[0], rows[1], "rows", result)
result["backend_telemetry"] = {"A": telemetry[0], "B": telemetry[1]}
result["invalid_contact_rows"] = [{"tick": row["tick"], "bodies": [i for i, body in enumerate(row["bodies"]) if not all(body["sample_valid"])]}
                                  for row in rows[0] if any(not all(body["sample_valid"]) for body in row["bodies"])]
result["area_coverage"] = {"base": 0, "one_area": 0, "overlap": 0}
for row in rows[0]:
    key = ["base", "one_area", "overlap"][min(2, sum(value > 0 for value in row["area_weights"]))]
    result["area_coverage"][key] += 1
print(json.dumps(result, indent=2))
sys.exit(1 if result["different"] or any(x["fallbacks"] or x["uploads"] != 1 for x in telemetry[1]) else 0)
