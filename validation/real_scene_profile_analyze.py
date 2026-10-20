"""Analyze captured time series without confusing inclusive spans or monitor peaks."""
import csv, json, math, sys
from pathlib import Path

def dist(a):
    a = sorted(x for x in a if math.isfinite(x))
    return {} if not a else {"n": len(a), "p50": round(a[int((len(a)-1)*.5)], 4), "p95": round(a[int((len(a)-1)*.95)], 4), "mean": round(sum(a)/len(a), 4)}

def metric(bucket, key, count=False):
    value = bucket.get(key, "(0, 0)")
    if isinstance(value, str): value = [int(x.strip()) for x in value.strip("()").split(",")]
    return value[0] if count else value[1]/1000

def analyze(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    result = {"metadata": data["metadata"], "cases": []}
    for case in data["cases"]:
        frames = case["frames"]
        valid_ids = {int(f[0]) for f in frames}
        tick_metrics = [b for b in case["metrics_ticks"].values() if "synchronize" in b]
        frame_metrics = {int(k): b for k, b in case["metrics_frames"].items()}
        native = [r for r in case["native"].get("frames", []) if r["process_frame"] in valid_ids]
        intervals = [r[2] for r in frames]
        row = {"case": case["case"], "fps_throughput": round(1000*len(frames)/sum(intervals), 3), "wall_ms": dist(intervals),
               "gpu_viewport_ms": dist([r[5] for r in case["render"]]), "cpu_viewport_ms": dist([r[4] for r in case["render"]]),
               "physics_callbacks_ms": dist([r[2] for r in case["ticks"]]),
               "monitor_process_peak_1s_ms": dist([r[3] for r in frames]), "monitor_physics_peak_1s_ms": dist([r[4] for r in frames]),
               "process_callbacks_ms": dist([metric(b,"process.callbacks") for b in frame_metrics.values() if "process.callbacks" in b]),
               "per_tick": {}, "per_build_count": {}, "gpu_regions_ms": {}, "native_tail": {}, "water_states": {}}
        for key in ["controller.integrate","synchronize","get_runtime","apply","slot0.sample","slot1.sample","slot0.native_query","slot1.native_query","slot0.build_128_128_128","slot1.build_128_128_128"]:
            values = [metric(b,key) for b in tick_metrics]
            if key == "controller.integrate" and not any(key in b for b in tick_metrics): values = []
            row["per_tick"][key] = dist(values)
        for key in ["synchronize","apply","input_contacts","slot0.affected","slot1.affected","slot0.build_128_128_128","slot1.build_128_128_128"]:
            row["per_tick"][key+".calls"] = dist([metric(b,key,True) for b in tick_metrics])
        for count in range(4):
            selected = []
            for f in frames:
                b = frame_metrics.get(int(f[0]),{})
                n = sum(metric(b,"slot%d.build_128_128_128"%s,True) for s in range(2))
                if n == count: selected.append(f[2])
            row["per_build_count"][str(count)] = dist(selected)
        for stage, name in enumerate(["controller","contacts","water_physics","cell_integration","tetra_loop","query_batch","source_validity","ocean_source","exterior_build"]):
            row["native_tail"][name] = dist([r["stages"][stage]["inclusive_us"]/1000 for r in native if r["stages"][stage]["calls"] > 0])
        gpu = {}; by_state = {}; spatial = {s["frame"]:s for s in case.get("spatial",[])}
        for render in case["render"]:
            starts = {}
            stamps = render[8]
            marker = next((s[0] for s in stamps if s[0].startswith("RealScene.Process.")),None)
            space = spatial.get(int(marker.split(".")[2]),{}) if marker else {}
            for i in range(len(stamps)-1):
                name, ns, _ = stamps[i]
                if name in ["Render 3D Transparent Pass","Process Pre Transparent Compositor Effects","Process Post Transparent Compositor Effects","Render Opaque Pass","Render Directional/SpotLight Shadows","Process SSAO"]:
                    ms = (stamps[i+1][1]-ns)/1e6
                    gpu.setdefault(name,[]).append(ms)
                    state = space.get("water_state","unknown")
                    by_state.setdefault(state,{}).setdefault(name,[]).append(ms)
            for name, gpu_ns, cpu_us in render[8]:
                if name.endswith(".begin"): starts[name[:-6]] = gpu_ns
                elif name.endswith(".end") and name[:-4] in starts:
                    gpu.setdefault(name[:-4],[]).append((gpu_ns-starts[name[:-4]])/1e6)
        row["gpu_regions_ms"] = {k:dist(v) for k,v in gpu.items()}
        row["gpu_by_state_ms"] = {k:{n:dist(v) for n,v in b.items()} for k,b in by_state.items()}
        for sample in case.get("spatial",[]):
            name = sample["water_state"]
            row["water_states"][name] = row["water_states"].get(name,0)+1
        windows=[]; total=0; n=0
        for f in frames:
            total+=f[2]; n+=1
            if total>=1000:
                windows.append(1000*n/total); total=0; n=0
        row["fps_1s"] = dist(windows)
        result["cases"].append(row)
    return result

def timeline_csv(path, output):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    names = ["case","frame","physics_tick","wall_interval_ending_here_ms","controller_this_frame_ms","sync_this_frame_ms","apply_this_frame_ms","build0_this_frame_ms","build1_this_frame_ms","build0_calls","build1_calls","contacts","affected0","affected1","process_previous_frame_ms","gpu_previous_draw_ms","transparent_previous_draw_ms","post_transparent_previous_draw_ms","water_state_previous_draw","boat_x","boat_y","boat_z"]
    with open(output,"w",newline="",encoding="utf-8") as stream:
        writer = csv.writer(stream); writer.writerow(names)
        for case in data["cases"]:
            metrics = {int(k):v for k,v in case["metrics_frames"].items()}
            spatial = {int(s["frame"]):s for s in case.get("spatial",[])}
            gpu = {}
            for render in case["render"]:
                stamps = render[8]
                marker = next((s[0] for s in stamps if s[0].startswith("RealScene.Process.")),None)
                if not marker: continue
                f = int(marker.split(".")[2]); v = {}; begins = {}
                for i,(name,ns,_) in enumerate(stamps):
                    if name.startswith("vp_begin_"): begins[name[len("vp_begin_"):]] = ns
                    if name.startswith("vp_end_") and name[len("vp_end_"):] in begins:
                        v["viewport"] = (ns-begins[name[len("vp_end_"):]])/1e6
                    if i<len(stamps)-1 and name in ["Render 3D Transparent Pass","Process Post Transparent Compositor Effects"]:
                        v[name] = (stamps[i+1][1]-ns)/1e6
                gpu[f] = v
            for frame in case["frames"]:
                f = int(frame[0]); b = metrics.get(f,{}); previous = metrics.get(f-1,{})
                g = gpu.get(f-1,{}); s = spatial.get(f-1,{})
                writer.writerow([case["case"],f,frame[1],frame[2]]+
                    [metric(b,k) for k in ["controller.integrate","synchronize","apply","slot0.build_128_128_128","slot1.build_128_128_128"]]+
                    [metric(b,k,True) for k in ["slot0.build_128_128_128","slot1.build_128_128_128","input_contacts","slot0.affected","slot1.affected"]]+
                    [metric(previous,"process.callbacks"),g.get("viewport",""),g.get("Render 3D Transparent Pass",""),g.get("Process Post Transparent Compositor Effects",""),s.get("water_state","")]+frame[6:9])

if __name__ == "__main__":
    result = analyze(sys.argv[1])
    if len(sys.argv)>2: Path(sys.argv[2]).write_text(json.dumps(result,indent=2),encoding="utf-8")
    if len(sys.argv)>3: timeline_csv(sys.argv[1],sys.argv[3])
    for r in result["cases"]:
        print(r["case"], "FPS",r["fps_throughput"],"WALL",r["wall_ms"].get("p50"),r["wall_ms"].get("p95"),"GPU",r["gpu_viewport_ms"].get("p50"),r["gpu_viewport_ms"].get("p95"))
