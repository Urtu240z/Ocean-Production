"""Compact audit evidence and render measured world-XZ cells; no ocean model here.

Run after the completed corpus and six-case material capture. Pillow draws actual cells, not an
interpolated field or an invented surface. The archived reference corpus stays
in place. All generated outputs are validation artifacts.
"""
from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import json
import math
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "validation" / "physics"
PHASE = "PHYS-GPU-SURFACE-CONTRACT-1"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def distribution(values):
    values = sorted(v for v in values if isinstance(v, (int, float)) and math.isfinite(v))
    if not values:
        return {"n": 0}
    result = {"n": len(values)}
    for name, fraction in [("min", 0), ("p05", .05), ("p25", .25), ("p50", .5), ("p75", .75), ("p95", .95), ("max", 1)]:
        result[name] = values[int(math.floor(fraction * (len(values) - 1) + .5))]
    return result


def gap_bin(gap):
    if gap is None:
        return "no_second_root"
    if gap < .002:
        return "below_2mm"
    if gap < .01:
        return "2_to_10mm"
    if gap < .05:
        return "10_to_50mm"
    if gap <= .2:
        return "50_to_200mm"
    return "above_200mm"


def finite_json(value):
    # Godot emits a very large exponent for INF (e.g. the absent runner-up
    # distance for a one-root temporal sample). Preserve absence as JSON null.
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, list):
        return [finite_json(v) for v in value]
    if isinstance(value, dict):
        return {k: finite_json(v) for k, v in value.items()}
    return value


def component_mask(patch, side):
    mask = Image.new("L", (side, side), 0)
    draw = ImageDraw.Draw(mask)
    if "known_component_rectangles" in patch:
        scale = side / 1024
        for x, z, size in patch["known_component_rectangles"]:
            x, z, size = round(x * scale), round((1024 - z - size) * scale), round(size * scale)
            draw.rectangle((x, z, min(side - 1, x + size - 1), min(side - 1, z + size - 1)), fill=255)
        return np.asarray(mask) > 0
    for c in patch["map_cells"]:
        if not c["central_component"]:
            continue
        x = round((c["x"] + .4) / .8 * side)
        z = round((.4 - c["z"] - c["size"]) / .8 * side)
        size = max(1, round(c["size"] / .8 * side))
        draw.rectangle((x, z, min(side - 1, x + size - 1), min(side - 1, z + size - 1)), fill=255)
    return np.asarray(mask) > 0


def edt_1d(values):
    # Lower envelope of parabolas: exact squared Euclidean distance on the
    # raster. This is geometry analysis of measured cells, not ocean filtering.
    n = len(values)
    sites, cuts, k = [0] * n, [-math.inf] + [0.] * (n - 1) + [math.inf], 0
    for q in range(1, n):
        s = ((values[q] + q * q) - (values[sites[k]] + sites[k] * sites[k])) / (2 * (q - sites[k]))
        while s <= cuts[k]:
            k -= 1
            s = ((values[q] + q * q) - (values[sites[k]] + sites[k] * sites[k])) / (2 * (q - sites[k]))
        k += 1
        sites[k], cuts[k], cuts[k + 1] = q, s, math.inf
    answer, k = [0.] * n, 0
    for q in range(n):
        while cuts[k + 1] < q:
            k += 1
        answer[q] = (q - sites[k]) ** 2 + values[sites[k]]
    return answer


def raster_thickness(patch, side=1024):
    original = component_mask(patch, side)
    mask = np.pad(original, 1)
    height, width = mask.shape
    vertical = np.zeros(mask.shape, dtype=np.float64)
    for y in range(1, height):
        vertical[y] = np.where(mask[y], vertical[y - 1] + 1, 0)
    for y in range(height - 2, -1, -1):
        vertical[y] = np.where(mask[y], np.minimum(vertical[y], vertical[y + 1] + 1), 0)
    distance = np.sqrt(np.asarray([edt_1d(row.tolist()) for row in vertical ** 2]))
    skeleton = mask.copy()
    iterations = 0
    for iterations in range(1, 2049):
        removed = 0
        for phase in range(2):
            p = [skeleton[:-2, 1:-1], skeleton[:-2, 2:], skeleton[1:-1, 2:], skeleton[2:, 2:], skeleton[2:, 1:-1], skeleton[2:, :-2], skeleton[1:-1, :-2], skeleton[:-2, :-2]]
            neighbors = sum(v.astype(np.uint8) for v in p)
            transitions = sum((~p[i] & p[(i + 1) % 8]).astype(np.uint8) for i in range(8))
            if phase == 0:
                clear = ~(p[0] & p[2] & p[4]) & ~(p[2] & p[4] & p[6])
            else:
                clear = ~(p[0] & p[2] & p[6]) & ~(p[0] & p[4] & p[6])
            erase = skeleton[1:-1, 1:-1] & (neighbors >= 2) & (neighbors <= 6) & (transitions == 1) & clear
            removed += int(erase.sum())
            skeleton[1:-1, 1:-1][erase] = False
        if removed == 0:
            break
    pitch = .8 / side
    # Distance to exterior pixel centers differs from distance to the union
    # of cell edges by at most half a pixel diagonal. Double for full width.
    widths = (2 * pitch * distance[skeleton]).tolist()
    maximum = float(2 * pitch * distance.max())
    edge_touch = bool(original[0].any() or original[-1].any() or original[:, 0].any() or original[:, -1].any())
    return {"pixel_pitch_m": pitch, "local_skeleton_width_m": distribution(widths), "max_inscribed_diameter_m": maximum, "raster_width_error_m": math.sqrt(2) * pitch, "patch_edge_censored": edge_touch, "skeleton_iterations": iterations, "skeleton_converged": iterations < 2048, "qualification": "Widths of the reconstructed known-cell region; includes tips and uncertainty-created necks. Censored patch edges are treated as exterior. This is not a bound on true-sheet thickness or unmeasured topology."}


def render_map(case, filename):
    cells = case["patch"]["map_cells"]
    side, left, top = 1024, 88, 102
    figure = Image.new("RGB", (1600, 1280), "white")
    raster = Image.new("RGB", (side, side), "#27313d")
    height_raster = Image.new("RGB", (side, side), "#27313d")
    height_draw = ImageDraw.Draw(height_raster)
    ys = [c["height"] for c in cells if c["height"] is not None]
    ymin, ymax = min(ys), max(ys)
    def height_color(y):
        anchors = [(36, 58, 128), (40, 175, 210), (242, 225, 103), (190, 46, 49)]
        f = max(0, min(3, 3 * (y - ymin) / max(1e-12, ymax - ymin)))
        i = min(2, int(f))
        return tuple(round(a + (b - a) * (f - i)) for a, b in zip(anchors[i], anchors[i + 1]))
    mask = Image.new("L", (side, side), 0)
    unknown_mask = Image.new("L", (side, side), 0)
    unknown_draw = ImageDraw.Draw(unknown_mask)
    draw, mask_draw = ImageDraw.Draw(raster), ImageDraw.Draw(mask)
    colors = {"central": "#47b779", "lower": "#4c79ab", "other_lower": "#86c6d4", "ambiguous": "#f1ae46", "other": "#a5abb1", "none": "#27313d"}
    labels = case["patch"].get("root_labels", case.get("center_roots", []))
    selected_q = case["record"]["capture"]["C"]["q"]
    distances = sorted((math.dist(selected_q, r["q"]), i) for i, r in enumerate(labels))
    selected_id = distances[0][1] if distances and distances[0][0] <= .02 else None
    for c in cells:
        x = round((c["x"] + .4) / .8 * side)
        z = round((.4 - c["z"] - c["size"]) / .8 * side)
        size = max(1, round(c["size"] / .8 * side))
        box = (x, z, min(side - 1, x + size - 1), min(side - 1, z + size - 1))
        unknown_original = case.get("map_method") == "FP64 spatial homotopy" and not c["highest_present"]
        category = "none" if c["upper"] < 0 else "ambiguous" if c["ambiguous"] else "central" if c["central_component"] else "other" if c["upper"] == 0 else "lower" if c["upper"] == selected_id else "other_lower"
        draw.rectangle(box, fill=colors[category])
        if unknown_original and not c["ambiguous"] and c["upper"] >= 0:
            unknown_draw.rectangle(box, fill=255)
        if c["height"] is not None:
            height_draw.rectangle(box, fill=height_color(c["height"]))
        if c["central_component"]:
            mask_draw.rectangle(box, fill=255)
    # One-pixel inner boundary at the measured connected-component edge.
    hatch = Image.new("L", (side, side), 0)
    hatch_draw = ImageDraw.Draw(hatch)
    for x in range(-side, side, 10):
        hatch_draw.line((x, 0, x + side, side), fill=255, width=1)
    raster.paste(colors["ambiguous"], (0, 0), ImageChops.multiply(unknown_mask, hatch))
    boundary = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(3)))
    raster.paste("#15251b", (0, 0), boundary)
    ring_draw = ImageDraw.Draw(raster)
    for radius in [.01, .025, .05, .1, .2, .4]:
        p = radius / .8 * side
        ring_draw.ellipse((side / 2 - p, side / 2 - p, side / 2 + p, side / 2 + p), outline="#e2e6e9", width=1)
    for width, color in [(5, "black"), (2, "white")]:
        ring_draw.line((side // 2 - 9, side // 2, side // 2 + 9, side // 2), fill=color, width=width)
        ring_draw.line((side // 2, side // 2 - 9, side // 2, side // 2 + 9), fill=color, width=width)
    figure.paste(raster, (left, top))
    text = ImageDraw.Draw(figure)
    font_path = Path("C:/Windows/Fonts/segoeui.ttf")
    font = ImageFont.truetype(str(font_path), 20) if font_path.exists() else ImageFont.load_default(size=20)
    small = ImageFont.truetype(str(font_path), 17) if font_path.exists() else ImageFont.load_default(size=17)
    r = case["record"]
    text.text((left, 12), f"{r['label']} | t = {r['time']:.6f} s | current GPU field", fill="black", font=font)
    text.text((left, 43), f"Target XZ = ({r['target'][0]:.6f}, {r['target'][1]:.6f}) m; pixel = 0.78125 mm", fill="black", font=small)
    text.text((left, 69), "Rings: 2, 5, 10, 20, 40, 80 cm diameter. Black line: boundary of the known cell region.", fill="black", font=small)
    for value in [-.4, -.2, 0, .2, .4]:
        px = left + (value + .4) / .8 * side
        py = top + (.4 - value) / .8 * side
        text.line((px, top + side, px, top + side + 5), fill="black")
        text.text((px - 19, top + side + 9), f"{value:.1f}", fill="black", font=small)
        text.text((left - 48, py - 10), f"{value:.1f}", fill="black", font=small)
    text.text((left + 395, top + side + 40), "World X offset (m)", fill="black", font=font)
    text.text((10, top + side // 2 - 35), "+Z", fill="black", font=font)
    hx, hy, hs = 1170, 102, 384
    text.text((hx, hy - 30), "Enumerated upper-envelope Y (m)", fill="black", font=small)
    figure.paste(height_raster.resize((hs, hs), Image.Resampling.NEAREST), (hx, hy))
    text.line((hx + hs // 2 - 6, hy + hs // 2, hx + hs // 2 + 6, hy + hs // 2), fill="white", width=2)
    text.line((hx + hs // 2, hy + hs // 2 - 6, hx + hs // 2, hy + hs // 2 + 6), fill="white", width=2)
    for i in range(hs):
        text.line((hx + i, hy + hs + 15, hx + i, hy + hs + 30), fill=height_color(ymin + (ymax - ymin) * i / (hs - 1)))
    text.text((hx, hy + hs + 34), f"{ymin:.3f}", fill="black", font=small)
    text.text((hx + hs - 55, hy + hs + 34), f"{ymax:.3f}", fill="black", font=small)
    text.text((hx, hy + hs + 66), "Same extent; nearest-cell display.", fill="black", font=small)
    p = case["patch"]
    thick = p.get("raster_thickness", {})
    lines = [f"Config {r['config']} | {case.get('map_method', 'local continuation')}", f"Connected known area: {p['projected_winner_area_m2']:.6f} m²", f"Equivalent diameter: {p['equivalent_circle_diameter_m']:.4f} m", f"Feret span: {p['min_feret_width_m']:.4f} m", f"Max inscribed width: {thick.get('max_inscribed_diameter_m', 0):.4f} m", "Widths describe the measured cell region.", "Orange areas remain unclassified.", "Patch-edge extent is censored."]
    for i, line in enumerate(lines):
        text.text((hx, 620 + 29 * i), line, fill="black", font=small)
    legend = [("central", "original highest component"), ("lower", "atlas-selected sheet wins"), ("other_lower", "another sheet wins"), ("ambiguous", "identity uncertain"), ("other", "disconnected winner"), ("none", "no tracked root")]
    x = 25
    for key, label in legend:
        text.rectangle((x, 1214, x + 15, 1229), fill=colors[key])
        text.text((x + 21, 1210), label, fill="black", font=small)
        x += [292, 262, 225, 224, 246, 0][legend.index((key, label))]
    text.text((25, 1246), "Orange hatching: original-sheet continuation unresolved; underlying color is the enumerated winner, not proven absence of the original sheet.", fill="black", font=small)
    figure.save(filename, optimize=True)


def compact_patch(p):
    p.pop("map_cells", None)
    for square in p.get("scales", []):
        for measure in [square, square.get("circle", {})]:
            total = measure.get("area_m2", 0)
            measure["enumerated_envelope_valid_fraction"] = measure.get("valid_area", 0) / total if total else None
            for key in ["weighted_y", "valid_area", "lower_y", "lower_area"]:
                measure.pop(key, None)


def compact_case(c):
    c = copy.deepcopy(c)
    if "patch" in c:
        compact_patch(c["patch"])
    for s in c.get("temporal", []):
        if "patch" in s:
            if s["dt"] == 0 and "patch" in c:
                s.pop("patch")
                s["patch_ref"] = "case.patch"
                continue
            compact_patch(s["patch"])
            if s["dt"] != 0:
                # Retain geometry/J/height evolution and the 20 cm contact/
                # anchor evidence; material cases also keep 10 cm. All six
                # scales remain at t0.
                scales = s["patch"].pop("scales")
                s["patch"]["footprint_20cm"] = scales[3]
                if "material_trace" in c:
                    # Preserve already measured smaller-footprint evolution
                    # for the six material cases; this requests no GPU work.
                    s["patch"]["footprint_10cm"] = scales[2]
                s["patch"].pop("confidence", None)
    return c


def material_class(m):
    center = next((s for s in m["temporal"] if abs(s["dt"]) < 1e-12), {})
    p = center.get("patch", {})
    m["review_indicators"] = {"regular_material_samples": sum(s["regular_same_orientation"] for s in m["material_trace"]), "material_smin": distribution([s["smin"] for s in m["material_trace"]]), "material_condition": distribution([s["condition"] for s in m["material_trace"]]), "feret_used_as_local_width": False}
    if not p or m["identity_ambiguous"] or p["budget_capped"] or p["central_component_unresolved"]:
        return "UNRESOLVED"
    def anchor_circle(p):
        return (p["scales"][3] if "scales" in p else p["footprint_20cm"])["material_anchor_circle"]
    broad_times = sorted(s["dt"] for s in m["temporal"] if "patch" in s and s["material_regular"] and anchor_circle(s["patch"])["support_lower_bound"] >= .25 and not anchor_circle(s["patch"])["patch_censored"])
    persistent_broad = any(a <= 0 <= c and abs(b - a - 1 / 60) < 1e-8 and abs(c - b - 1 / 60) < 1e-8 for a, b, c in zip(broad_times, broad_times[1:], broad_times[2:]))
    m["review_indicators"].update({"anchor_20cm_broad_times": broad_times, "broad_three_samples_including_t0_spanning_two_ticks": persistent_broad, "broad_at_all_nine_window_ticks": len(broad_times) == 9})
    if persistent_broad:
        return "PERSISTENT_BROAD"
    # A regular material point alone does not prove persistence of the same
    # narrow winning region. Retain uncertainty rather than inferring a life.
    return "UNRESOLVED"


def capture_identity(capture, roots):
    if not capture["valid"] or abs(capture["height"] - roots[0]["height"]) > .002:
        return "MISS"
    distances = sorted((math.dist(capture["q"], r["q"]), i) for i, r in enumerate(roots))
    distance, index = distances[0]
    margin = distances[1][0] - distance if len(distances) > 1 else math.inf
    if distance > .02 or margin < .0001:
        return "UNRESOLVED"
    if index == 0:
        return "CAPTURE"
    return "MISS" if abs(capture["height"] - roots[index]["height"]) <= .002 else "UNRESOLVED"


def summarize(cases):
    groups = {"ALL": cases}
    for name in ["A", "B", "C", "coarse_miss_dense_capture", "UNRESOLVED_CAPTURE"]:
        groups[name] = [c for c in cases if c["capture_group"] == name]
    for name, stage, state in [("A_coarse_captured", "A", "CAPTURE"), ("B_256_missed", "B", "MISS"), ("C_2048_missed", "C", "MISS"), ("C_2048_captured", "C", "CAPTURE")]:
        groups[name] = [c for c in cases if c["record"]["capture"].get(stage, {}).get("upper_identity_status") == state]
    output = {}
    for name, rows in groups.items():
        result = {"n": len(rows), "area_m2": distribution([c["patch"]["projected_winner_area_m2"] for c in rows]), "min_feret_width_m": distribution([c["patch"]["min_feret_width_m"] for c in rows]), "max_feret_width_m": distribution([c["patch"]["max_feret_width_m"] for c in rows]), "equivalent_circle_diameter_m": distribution([c["patch"]["equivalent_circle_diameter_m"] for c in rows]), "nearest_candidate_boundary_m": distribution([c["patch"]["nearest_candidate_boundary_m"] for c in rows]), "center_upper_next_gap_m": distribution([c["center_upper_next_gap"] for c in rows]), "center_fine_det": distribution([c["center_roots"][0]["det"] for c in rows]), "center_abs_fine_det": distribution([abs(c["center_roots"][0]["det"]) for c in rows]), "center_condition": distribution([c["center_roots"][0]["condition"] for c in rows]), "center_smin": distribution([c["center_roots"][0]["smin"] for c in rows]), "fixed_target_observed_seconds_before": distribution([c["observed_lifetime"]["seconds_before"] for c in rows]), "fixed_target_observed_seconds_after": distribution([c["observed_lifetime"]["seconds_after"] for c in rows]), "classification": dict(Counter(c["classification"] for c in rows)), "gap_bins": dict(Counter(gap_bin(c["center_upper_next_gap"]) for c in rows)), "footprints": []}
        for i, diameter in enumerate([.02, .05, .1, .2, .4, .8]):
            for shape in ["circle", "square"]:
                measures = [c["patch"]["scales"][i]["circle"] if shape == "circle" else c["patch"]["scales"][i] for c in rows]
                thresholds = []
                for threshold in [.01, .05, .1, .25, .5, .75]:
                    survive = sum(s["support_lower_bound"] >= threshold for s in measures)
                    fail = sum(s["support_upper_bound"] < threshold for s in measures)
                    thresholds.append({"support_threshold": threshold, "bounded_sample_survive": survive, "bounded_sample_fail": fail, "uncertain": len(rows) - survive - fail, "point_estimate_survive": sum(s["highest_component_fraction"] >= threshold for s in measures)})
                result["footprints"].append({"shape": shape, "diameter_or_side_m": diameter, "support_fraction": distribution([s["highest_component_fraction"] for s in measures]), "uncertainty_fraction": distribution([s["uncertainty_fraction"] for s in measures]), "area_weighted_upper_y_m": distribution([s["area_weighted_upper_y"] for s in measures]), "area_weighted_median_upper_y_m": distribution([s["area_weighted_median_upper_y"] for s in measures]), "lower_dominant_area_weighted_y_m": distribution([s["lower_dominant_area_weighted_y"] for s in measures]), "hypothetical_support_thresholds": thresholds})
                result["footprints"][-1]["maximum_enumerated_upper_y_m"] = distribution([s["max_y"] for s in measures])
        output[name] = result
        for metric, key in [("minimum_local_skeleton_width_m", "min"), ("p05_local_skeleton_width_m", "p05"), ("median_local_skeleton_width_m", "p50")]:
            result[metric] = distribution([c.get("local_width_audit", {}).get("raster_thickness", {}).get("local_skeleton_width_m", {}).get(key) for c in rows])
        result["maximum_local_inscribed_diameter_m"] = distribution([c.get("local_width_audit", {}).get("raster_thickness", {}).get("max_inscribed_diameter_m") for c in rows])
    return output


def export():
    parser = argparse.ArgumentParser()
    parser.add_argument("--allow-incomplete", action="store_true")
    parser.add_argument("--outcome", choices=["A", "B", "C"])
    parser.add_argument("--acceptance", choices=["PASS", "PARTIAL", "BLOCKED"])
    parser.add_argument("--decision", help="Reviewed evidence supporting the architectural choice")
    args = parser.parse_args()
    raw = load(ROOT / ".godot" / "phys_gpu_surface_contract_raw.json")
    material_path = ROOT / ".godot" / "phys_gpu_surface_contract_material.json"
    material = load(material_path) if material_path.exists() else {"cases": [], "checks": []}
    strict_path = ROOT / ".godot" / "phys_gpu_surface_contract_strict_capture.json"
    strict = load(strict_path) if strict_path.exists() else {"samples": [], "checks": []}
    prototype_path = ROOT / ".godot" / "phys_gpu_surface_contract_prototype.json"
    prototype = load(prototype_path) if prototype_path.exists() else {"checks": []}
    if not args.allow_incomplete:
        assert args.outcome and args.acceptance and args.decision, "final export needs a reviewed outcome, acceptance and rationale"
        assert len(raw["cases"]) == raw["corpus"]["count"], "incomplete corpus"
        assert len(material["cases"]) == 6, "incomplete physical temporal closure"
        assert all(m["complete"] and len(m["material_trace"]) == 65 and len(m["temporal"]) == 9 for m in material["cases"]), "incomplete material capture"
        assert strict_path.exists() and not strict["checks"], "incomplete strict capture closure"
        assert not raw["checks"] and not material["checks"], "GPU audit errors"
        assert raw["after_shutdown"]["errors"] == 0 and raw["after_shutdown"]["mismatches"] == 0
        assert raw["after_shutdown"]["owned_buffers"] == 0 and material["after_shutdown"]["owned_buffers"] == 0
        assert raw["after_shutdown"]["in_flight"] == 0 and material["after_shutdown"]["in_flight"] == 0
        assert material["after_shutdown"]["errors"] == 0 and material["after_shutdown"]["mismatches"] == 0
        assert all(all(s[k] == 0 for k in ["buffers", "errors", "in_flight", "mismatches", "owned"]) for s in strict["retirement"])
        assert not prototype["checks"] and len(prototype["precise_continuation_smoke"]) == 6
        assert prototype["legacy_prototype_comparison"]["rows"] == 126 and not prototype["legacy_prototype_comparison"]["mismatches"]
        assert all(prototype["after_shutdown"][k] == 0 for k in ["errors", "mismatches", "owned_buffers", "in_flight"])
    material_centers = {}
    for m in material["cases"]:
        for s in m["temporal"]:
            if s["dt"] == 0 and "map_cells" in s.get("patch", {}):
                s["patch"]["raster_thickness"] = raster_thickness(s["patch"])
                material_centers[m["label"]] = s["patch"]
    maps = []
    for c in raw["cases"]:
        if c["record"].get("decisive"):
            c["patch"]["raster_thickness"] = raster_thickness(c["patch"])
            filename = OUT / (PHASE + "-CASE-" + c["record"]["label"].split("/")[-1] + ".png")
            map_case = {"record": c["record"], "patch": material_centers[c["record"]["label"]], "map_method": "FP64 spatial homotopy"} if c["record"]["label"] in material_centers else c
            render_map(map_case, filename)
            maps.append({"label": c["record"]["label"], "method": map_case.get("map_method", "main local continuation"), "path": str(filename.relative_to(ROOT)).replace("\\", "/"), "sha256": hashlib.sha256(filename.read_bytes()).hexdigest()})
    cases = [compact_case(c) for c in raw["cases"]]
    extra_captures = {s["label"]: s["C"] for s in strict["samples"]}
    for c in cases:
        r, roots = c["record"], c["center_roots"]
        if r["label"] in material_centers:
            c["local_width_audit"] = {"raster_thickness": material_centers[r["label"]]["raster_thickness"], "projected_winner_area_m2": material_centers[r["label"]]["projected_winner_area_m2"], "method_variant": "decisive_FP64_material_chart_t0", "qualification": "Corrected material-continuation mask; the original corpus patch statistics are retained separately"}
        elif "raster_thickness" in c["patch"]:
            c["local_width_audit"] = {"raster_thickness": c["patch"]["raster_thickness"], "method_variant": "decisive_fine_boundary"}
        if r["label"] in extra_captures:
            r["capture"]["C"] = extra_captures[r["label"]]
        for capture in r["capture"].values():
            capture["correct_current_fine_reference"] = capture["valid"] and abs(capture["height"] - roots[0]["height"]) <= .002
            capture["upper_identity_status"] = capture_identity(capture, roots)
            capture["q_distance_to_upper_m"] = math.dist(capture["q"], roots[0]["q"])
            nearest = min(range(len(roots)), key=lambda i: math.dist(capture["q"], roots[i]["q"]))
            capture["nearest_enumerated_root_index"] = nearest
            capture["q_distance_to_nearest_root_m"] = math.dist(capture["q"], roots[nearest]["q"])
            capture["height_error_to_highest_m"] = capture["height"] - roots[0]["height"]
            capture["height_error_to_nearest_root_m"] = capture["height"] - roots[nearest]["height"]
        c["height_capture_group"] = c["capture_group"]
        c["legacy_span_based_classification"] = c["classification"]
        # Do not use convex span as minimum physical thickness. Fixed-target
        # persistence is kept distinct from the material-sheet classification.
        broad = c["patch"]["scales"][3]["circle"]["support_lower_bound"] >= .25
        c["review_indicators"]["broad"] = broad
        c["review_indicators"]["feret_used_as_local_width"] = False
        if c["classification"] in ["PERSISTENT_BROAD", "TRANSIENT_BROAD"] and not broad:
            c["classification"] = "UNRESOLVED"
        states = {s: v["upper_identity_status"] for s, v in r["capture"].items()}
        c["capture_group"] = "C" if states.get("C") == "MISS" else "B" if states["B"] == "MISS" else "A" if states["A"] == "CAPTURE" else "coarse_miss_dense_capture" if states["B"] == "CAPTURE" and states["A"] == "MISS" else "UNRESOLVED_CAPTURE"
    physical = [compact_case(c) for c in material["cases"]]
    for m in physical:
        for probe in m.get("local_discovery_checks", []):
            probe["original_sheet_height_compatible_5um"] = probe.pop("original_sheet_wins", False)
            probe["original_sheet_upper_identity_match"] = probe["original_sheet_path_valid"] and bool(probe["roots"]) and math.dist(probe["original_sheet_q"], probe["roots"][0]["q"]) <= .00002
        m["classification"] = material_class(m)
    archives = sorted((OUT / "gpu13_envelope").glob("*.jsonl.gz"))
    archive_manifest = [{"path": str(p.relative_to(ROOT)).replace("\\", "/"), "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in archives]
    diagnostic_paths = [Path(__file__), OUT / "phys_gpu_surface_contract_runner.gd", OUT / "surface_contract_query.gd", OUT / "surface_contract_query.comp"]
    source_paths = list((ROOT / "addons" / "ocean" / "physics" / "gpu").glob("*"))
    hashes = {str(p.relative_to(ROOT)).replace("\\", "/"): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths + diagnostic_paths if p.is_file() and p.suffix in [".gd", ".glsl", ".comp", ".vert", ".frag", ".inc", ".py"]}
    unique = {(c["record"]["config"], round(c["record"]["time"], 9), tuple(c["record"]["target"])) for c in cases}
    unique_xz = {tuple(c["record"]["target"]) for c in cases}
    ambiguous = sum(len(c["center_roots"]) >= 2 for c in cases)
    unique_ambiguous_xz = {tuple(c["record"]["target"]) for c in cases if len(c["center_roots"]) >= 2}
    if not args.allow_incomplete:
        assert ambiguous >= 256 and len(unique_ambiguous_xz) >= 256, "insufficient distinct ambiguous targets"
    measurements = {"phase": PHASE, "starting_head": raw["starting_head"], "status": "PARTIAL", "architectural_outcome": "pending physical support/identity confidence review; highest-Y point contract remains frozen", "environment": raw["environment"], "corpus": raw["corpus"], "unique_targets": len(unique), "gpu_confirmed_multi_root_targets": ambiguous, "strata": dict(Counter(c["record"].get("stratum", "mandatory") for c in cases)), "group_semantics": {"A": "coarse 128/q512 captured current fine upper root", "B": "256/q1024 missed; excludes C", "C": "2048/q2048 missed current fine upper root; includes all six mandatory failures", "coarse_miss_dense_capture": "coarse missed, 256/q1024 captured, no C miss"}, "method_limits": ["802 deterministic GPU discovery seeds plus archived roots: bounded discovery, not a global completeness certificate", "Intervals are adaptive cell/identity uncertainty envelopes, not mathematical bounds against undiscovered roots", "Main corpus uses float32 seeds and targets with FP64 refined roots; physical temporal closure preserves the material q seed in FP64", "Main temporal classification describes a fixed-target continuation candidate; it does not establish global sheet birth/death", "Physical temporal closure follows the original material q every 1/480 s and its connected winning component at nine tick times", "Feret width measures the convex caliper span of a connected component; it is not minimum local neck thickness", "Components reaching the +/-0.4 m patch edge have area and extent censored there", "Coarser corpus boundaries retain 12.5 mm cells and are uncertainty-labeled"], "summaries": summarize(cases), "cases": cases, "physical_temporal_closure": physical, "maps": maps, "reference_archives": archive_manifest, "final_source_hashes": hashes, "gpu_main_shutdown": raw.get("after_shutdown"), "gpu_material_shutdown": material.get("after_shutdown"), "checks": raw["checks"] + material["checks"]}
    json_path = OUT / (PHASE + "-MEASUREMENTS.json")
    measurements["distinct_world_xz_targets"] = len(unique_xz)
    measurements["distinct_gpu_multi_root_world_xz_targets"] = len(unique_ambiguous_xz)
    measurements["collection_complete"] = len(cases) == raw["corpus"]["count"] and len(physical) == 6 and all(m["complete"] for m in physical) and strict_path.exists() and not strict["checks"] and len(prototype.get("precise_continuation_smoke", [])) == 6 and not prototype["checks"]
    measurements["scope_cap"] = {"material_temporal_cases": 6, "additional_corpus_gpu_replay": False, "local_width_population": "six decisive cases only; other corpus fields use the existing completed 281-case evidence", "next_architecture_started": False}
    measurements["architectural_outcome"] = "OUTCOME " + args.outcome if args.outcome else "pending six-case physical review"
    measurements["architectural_decision_rationale"] = args.decision
    measurements["status"] = args.acceptance or "IN_PROGRESS"
    measurements["next_recommended_phase"] = {"A": "PHYS-GPU-ENVELOPE-ADAPTIVE-1", "B": "PHYS-GPU-SURFACE-SUPPORT-1", "C": "PHYS-GPU-SURFACE-HYBRID-1"}.get(args.outcome)
    measurements["diagnostic_smoke"] = {k: prototype.get(k) for k in ["environment", "diagnostic_source_hashes", "legacy_prototype_comparison", "precise_continuation_smoke", "after_shutdown", "checks"]}
    measurements["diagnostic_smoke"]["legacy_rows"] = prototype.get("cases", [{}])[0].get("rows", [])
    measurements["diagnostic_smoke"]["original_legacy_baseline_sha256"] = prototype.get("original_legacy_baseline_sha256")
    measurements["checks"] += prototype["checks"]
    if not measurements["collection_complete"]:
        measurements["status"] = "IN_PROGRESS"
    measurements["sampling_variants"] = dict(Counter(c.get("method_variant", "decisive_fine_boundary" if c["record"].get("decisive") else "corpus_fine_interiors") for c in cases))
    measurements["resume_history"] = raw.get("resume_history", {})
    measurements["strict_capture_closure"] = strict
    measurements["capture_stage_counts"] = {stage: {"tested": sum(stage in c["record"]["capture"] for c in cases), "identity_status": dict(Counter(c["record"]["capture"][stage]["upper_identity_status"] for c in cases if stage in c["record"]["capture"])), "upper_height_within_2mm": sum(c["record"]["capture"][stage]["correct_current_fine_reference"] for c in cases if stage in c["record"]["capture"])} for stage in ["A", "B", "C"]}
    measurements["group_semantics"] = {"A": "coarse 128/q512 confirmed nearest to the current fine upper root", "B": "256/q1024 missed that upper root; excludes C", "C": "2048/q2048 missed that upper root; includes all six mandatory failures", "coarse_miss_dense_capture": "coarse missed, 256/q1024 captured, no C miss", "UNRESOLVED_CAPTURE": "capture identity not separable at 0.1 mm q margin or unmatched beyond 20 mm q distance", "height_capture_group": "original 2 mm upper-height compatibility grouping retained separately; it does not assert sheet identity"}
    json_path.write_text(json.dumps(finite_json(measurements), ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n", encoding="utf-8")
    with (OUT / (PHASE + "-CASES.csv")).open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(["label", "capture_group", "stratum", "config", "time_s", "target_x", "target_z", "roots", "upper_y", "next_gap_m", "area_m2", "min_feret_m", "max_feret_m", "nearest_boundary_m", "center_fine_det", "center_condition", "center_smin", "support_2cm", "support_5cm", "support_10cm", "support_20cm", "support_40cm", "support_80cm", "fixed_target_classification", "minimum_local_skeleton_width_m", "p05_local_skeleton_width_m", "median_local_skeleton_width_m", "maximum_local_inscribed_diameter_m", "width_method", "material_t0_known_component_area_m2"])
        for c in cases:
            r, p, upper = c["record"], c["patch"], c["center_roots"][0]
            width_audit = c.get("local_width_audit", {})
            thickness = width_audit.get("raster_thickness", {})
            local = thickness.get("local_skeleton_width_m", {})
            writer.writerow([r["label"], c["capture_group"], r.get("stratum", "mandatory"), r["config"], r["time"], *r["target"], len(c["center_roots"]), upper["height"], c["center_upper_next_gap"], p["projected_winner_area_m2"], p["min_feret_width_m"], p["max_feret_width_m"], p["nearest_candidate_boundary_m"], upper["det"], upper["condition"], upper["smin"], *[s["circle"]["highest_component_fraction"] for s in p["scales"]], c["classification"], local.get("min"), local.get("p05"), local.get("p50"), thickness.get("max_inscribed_diameter_m"), width_audit.get("method_variant"), width_audit.get("projected_winner_area_m2")])
    print(json.dumps({"cases": len(cases), "unique": len(unique), "gpu_multi_root": ambiguous, "maps": len(maps), "physical_cases": len(physical), "json_bytes": json_path.stat().st_size, "classifications": dict(Counter(m["classification"] for m in physical))}))


if __name__ == "__main__":
    export()
