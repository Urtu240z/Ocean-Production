#include "ocean_query_native.h"
#include <godot_cpp/classes/time.hpp>
using namespace godot;
Dictionary perf1_record_dictionary(const oq::Perf1Build &row);
namespace {
Dictionary frame_dictionary(const oq::Perf2Frame &row) {
    Dictionary d; Array stages;
    d["process_frame"] = row.frame; d["render_frame"] = row.render_frame;
    d["frame_interval_us"] = static_cast<int64_t>(row.interval_us);
    d["boundary_begin_qpc"] = static_cast<int64_t>(row.begin_qpc);
    d["boundary_end_qpc"] = static_cast<int64_t>(row.end_qpc);
    for (int i = 0; i < oq::STAGE_COUNT; ++i) {
        Dictionary stage; stage["id"] = i;
        stage["inclusive_us"] = static_cast<int64_t>(row.stage_us[i]);
        stage["calls"] = static_cast<int64_t>(row.stage_calls[i]); stages.append(stage);
    }
    d["stages"] = stages; return d;
}
}
Dictionary OceanQueryNative::perf2_initialize() {
    oq::perf2_etw_initialize();
    Dictionary d;
    d["provider_name"] = "OceanProduction.Perf2";
    d["provider_guid"] = "a3d2398c-762f-4b16-a89c-61238e641702";
    d["process_id"] = static_cast<int64_t>(
#ifdef _WIN32
        GetCurrentProcessId()
#else
        0
#endif
    );
    d["qpc_frequency"] = static_cast<int64_t>(oq::perf2_qpc_frequency());
    d["qpc_anchor"] = static_cast<int64_t>(oq::perf2_qpc());
    d["godot_ticks_usec_anchor"] = static_cast<int64_t>(Time::get_singleton()->get_ticks_usec());
    d["frame_measurement"] = "wall interval between SceneTree.process_frame boundaries; contains current physics and previous render/process tail; not exact Godot profiler Frame Time";
    d["stage_measurement"] = "inclusive spans, nested; do not sum controller, contacts, water physics, cells, tetra loop and queries";
    d["etw_span_qpc"] = "estimated from Godot monotonic span timestamps calibrated at record call; markers include PID/TID in ETW header";
    return d;
}
void OceanQueryNative::perf2_record_span(int stage, int64_t frame, int64_t tick,
        int64_t start_us, int64_t end_us, int64_t calls) {
    if (!perf1_.enabled.load(std::memory_order_relaxed) || end_us < start_us || start_us < 0 || calls < 0) return;
    const auto duration = static_cast<uint64_t>(end_us - start_us);
    perf1_.perf2.stage(frame, stage, duration, calls);
    if (!oq::perf2_etw_enabled()) return;
    const auto now_qpc = oq::perf2_qpc(), frequency = oq::perf2_qpc_frequency();
    const auto now_us = Time::get_singleton()->get_ticks_usec();
    const auto since_start = now_us >= static_cast<uint64_t>(start_us) ? now_us - start_us : 0;
    const auto since_end = now_us >= static_cast<uint64_t>(end_us) ? now_us - end_us : 0;
    oq::perf2_etw_span(stage, frame, tick, now_qpc - since_start * frequency / 1000000,
            now_qpc - since_end * frequency / 1000000, duration, calls);
}
void OceanQueryNative::perf2_frame_boundary(int64_t frame, int64_t rendered, int64_t threshold_us) {
    if (!perf1_.enabled.load(std::memory_order_relaxed)) return;
    const auto qpc = oq::perf2_qpc(), frequency = oq::perf2_qpc_frequency();
    const auto interval = perf2_last_qpc_ && frequency ? (qpc - perf2_last_qpc_) * 1000000 / frequency : 0;
    perf1_.perf2.boundary(frame, rendered, qpc, frequency, std::max<int64_t>(1000, threshold_us));
    oq::perf2_etw_frame(frame, perf2_last_qpc_, qpc, interval, interval > static_cast<uint64_t>(threshold_us));
    perf2_last_qpc_ = qpc;
}
Dictionary OceanQueryNative::get_perf2_capture() {
    const auto snapshot = perf1_.perf2.snapshot();
    Dictionary d; Array frames, windows;
    for (const auto &row : snapshot.recent) frames.append(frame_dictionary(row));
    for (const auto &window : snapshot.windows) {
        Dictionary w; Array rows, builds;
        uint64_t expected_builds = 0;
        for (size_t i = 0; i < window.count; ++i) rows.append(frame_dictionary(window.frames[i]));
        for (size_t i = 0; i < window.count; ++i) expected_builds += window.frames[i].stage_calls[oq::NATIVE_BUILD];
        if (window.count) {
            const auto native_rows = perf1_.builds_for_frames(window.frames[0].frame, window.frames[window.count - 1].frame);
            for (const auto &row : native_rows) builds.append(perf1_record_dictionary(row));
        }
        w["trigger_frame"] = window.trigger; w["complete"] = window.complete;
        w["post_frames_remaining"] = static_cast<int64_t>(window.remaining);
        w["frames"] = rows; windows.append(w);
        w["build_records"] = builds;
        w["expected_build_records"] = static_cast<int64_t>(expected_builds);
        w["missing_build_records"] = std::max<int64_t>(0, static_cast<int64_t>(expected_builds) - builds.size());
    }
    d["last_frame"] = snapshot.last_frame; d["frames"] = frames; d["frame_hitch_windows"] = windows;
    d["dropped_frame_windows"] = static_cast<int64_t>(snapshot.dropped);
    d["etw_enabled"] = oq::perf2_etw_enabled();
    return d;
}
