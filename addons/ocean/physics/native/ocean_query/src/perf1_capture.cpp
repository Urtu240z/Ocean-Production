#include "ocean_query_native.h"
#include <godot_cpp/variant/array.hpp>
using namespace godot;
Dictionary perf1_record_dictionary(const oq::Perf1Build &r) {
    Dictionary d;
    d["sequence"] = static_cast<int64_t>(r.sequence);
    d["physics_tick"] = r.context.physics_tick; d["process_frame"] = r.context.process_frame;
    d["render_frame"] = r.context.render_frame; d["spectrum_generation"] = r.context.spectrum_generation;
    d["selected_backend"] = r.context.selected_backend;
    d["comparison_enabled"] = r.context.comparison_enabled;
    d["build_backend"] = r.lite ? "CPU_LITE_B" : "FULL_CPU";
    d["is_comparison"] = r.context.selected_backend >= 0 && (r.lite != (r.context.selected_backend == 1));
    d["start_steady_ns"] = static_cast<int64_t>(r.start_ns);
    d["wall_us"] = static_cast<int64_t>(r.wall_us); d["thread_cpu_us"] = r.thread_cpu_us;
    d["thread_cycles"] = r.thread_cycles; d["thread_id"] = static_cast<int64_t>(r.thread_id);
    d["wall_minus_thread_cpu_us"] = r.thread_cpu_us < 0 ? int64_t(-1) : std::max<int64_t>(0, static_cast<int64_t>(r.wall_us) - r.thread_cpu_us);
    d["simulation_time"] = r.simulation_time; d["simulation_delta"] = r.simulation_delta;
    d["succeeded"] = r.succeeded; d["avx2"] = r.avx2; d["rewind_reset"] = r.rewind_reset;
    d["fft_backend"] = r.avx2 ? "AVX2" : "scalar";
    uint64_t configure_total = 0, bands_total = 0;
    Array bands;
    for (int i = 0; i < 3; ++i) {
        const auto &p = r.stages[i]; Dictionary b;
        b["resolution"] = r.resolutions[i]; b["configure_reason_mask"] = r.configure_reason[i];
        Array fft_environment;
        for(int pair=0;pair<2;++pair) {
            Dictionary f;f["pair"]=pair;f["mxcsr_before"]=int64_t(p.ifft_mxcsr_before[pair]);
            f["mxcsr_after"]=int64_t(p.ifft_mxcsr_after[pair]);f["cpu_before"]=int64_t(p.ifft_cpu_before[pair]);
            f["cpu_after"]=int64_t(p.ifft_cpu_after[pair]);f["probe_input_copy_us"]=int64_t(p.fft_probe_copy_us[pair]);
            fft_environment.append(f);
        }
        b["fft_environment"]=fft_environment;
        b["configure_us"] = static_cast<int64_t>(r.configure_us[i]);
        b["build_us"] = static_cast<int64_t>(r.band_us[i]);
        b["phase_us"] = static_cast<int64_t>(p.phase_us);
        b["phase_reason"] = p.phase_reason; b["phase_delta_s"] = p.phase_delta_s;
        b["phase_updates_before"] = static_cast<int64_t>(p.phase_updates_before);
        b["phase_updates_after"] = static_cast<int64_t>(p.phase_updates_after);
        b["phase_initialize_us"] = static_cast<int64_t>(p.phase_initialize_us);
        b["phase_rotor_us"] = static_cast<int64_t>(p.phase_rotor_us);
        b["phase_rebase_us"] = static_cast<int64_t>(p.phase_rebase_us);
        b["rotor_rebuilt"] = p.rotor_rebuilt;
        b["evolution_us"] = static_cast<int64_t>(p.evolve_us); b["packing_us"] = static_cast<int64_t>(p.packing_us);
        b["frequency_prepare_us"] = static_cast<int64_t>(p.frequency_prepare_us);
        b["ifft_us"] = static_cast<int64_t>(r.ifft_us[i]);
        b["row_x_us"] = static_cast<int64_t>(p.row_x_us);
        b["transpose_to_columns_us"] = static_cast<int64_t>(p.transpose_to_columns_us);
        b["row_z_us"] = static_cast<int64_t>(p.row_z_us);
        b["transpose_back_us"] = static_cast<int64_t>(p.transpose_back_us);
        b["unpack_us"] = static_cast<int64_t>(p.unpack_us);
        b["publication_us"] = static_cast<int64_t>(r.publication_us[i]);
        b["memory_before_bytes"] = static_cast<int64_t>(r.memory_before[i]);
        b["memory_after_bytes"] = static_cast<int64_t>(r.memory_after[i]);
        b["memory_change_bytes"] = static_cast<int64_t>(r.memory_after[i]) - static_cast<int64_t>(r.memory_before[i]);
        configure_total += r.configure_us[i]; bands_total += r.band_us[i];
        bands.append(b);
    }
    d["configure_total_us"] = static_cast<int64_t>(configure_total);
    d["bands_total_us"] = static_cast<int64_t>(bands_total);
    // FULL_CPU band durations overlap on workers, so their sum isn't wall time.
    d["outside_bands_us"] = r.lite ? std::max<int64_t>(0, static_cast<int64_t>(r.wall_us) - static_cast<int64_t>(configure_total) - static_cast<int64_t>(bands_total)) : int64_t(-1);
    d["bands"] = bands; return d;
}
void OceanQueryNative::perf3_set_fft_probe(bool enabled,bool require_etw,int64_t minimum_us) {
    perf1_.fft_probe_minimum_us.store(uint64_t(std::max<int64_t>(0,minimum_us)),std::memory_order_relaxed);
    perf1_.fft_probe_require_etw.store(require_etw,std::memory_order_relaxed);
    perf1_.fft_probe_enabled.store(enabled,std::memory_order_release);
}
Array OceanQueryNative::get_perf3_fft_snapshots() {
    Array result;
    for(auto &p:perf1_.fft_probes) {
        if(!p.ready.load(std::memory_order_acquire) || p.exported.exchange(true))continue;
        const size_t n=p.header.n,count=n*n;
        const size_t bytes=sizeof(p.header)+n*sizeof(uint32_t)+6*(n-1)*sizeof(double)+32*sizeof(uint64_t)+2*count*sizeof(std::complex<double>);
        PackedByteArray raw;raw.resize(bytes);auto *dst=raw.ptrw();size_t offset=0;
        auto append=[&](const void *src,size_t length){std::memcpy(dst+offset,src,length);offset+=length;};
        append(&p.header,sizeof(p.header));append(p.bit_reverse.data(),n*sizeof(uint32_t));
        append(p.real.data(),(n-1)*sizeof(double));append(p.imag.data(),(n-1)*sizeof(double));
        append(p.real_dup.data(),2*(n-1)*sizeof(double));append(p.imag_dup.data(),2*(n-1)*sizeof(double));
        static_assert(sizeof(size_t)==sizeof(uint64_t),"PERF-3 replay requires a 64-bit build");
        append(p.offsets.data(),32*sizeof(uint64_t));append(p.input.data(),count*sizeof(std::complex<double>));append(p.output.data(),count*sizeof(std::complex<double>));
        Dictionary snapshot;snapshot["bytes"]=raw;snapshot["band"]=int64_t(p.header.band);snapshot["pair"]=int64_t(p.header.pair);
        snapshot["process_frame"]=p.header.frame;snapshot["physics_tick"]=p.header.tick;snapshot["ifft_us"]=int64_t(p.header.ifft_us);
        result.append(snapshot);
    }
    return result;
}
void OceanQueryNative::perf1_set_context(int64_t tick, int64_t process_frame, int64_t render_frame,
        int backend, bool comparison, int64_t spectrum_generation) {
    perf1_.context({tick, process_frame, render_frame, spectrum_generation, backend, comparison});
}
void OceanQueryNative::perf1_set_enabled(bool enabled) { perf1_.enabled.store(enabled, std::memory_order_relaxed); }
void OceanQueryNative::perf1_record_tick(int64_t tick, int64_t frame, int64_t rendered) { perf1_.tick(tick, frame, rendered); }
Dictionary OceanQueryNative::get_perf1_capture() {
    const auto snapshot = perf1_.snapshot(256);
    Dictionary d; Array rows, windows, frames;
    for (const auto &f : snapshot.frames) {
        Dictionary frame;
        frame["process_frame"] = f.process_frame; frame["render_frame"] = f.render_frame;
        frame["first_physics_tick"] = f.first_tick; frame["last_physics_tick"] = f.last_tick;
        frame["physics_steps"] = static_cast<int64_t>(f.steps);
        frames.append(frame);
    }
    for (const auto &row : snapshot.recent) rows.append(perf1_record_dictionary(row));
    for (const auto &window : snapshot.windows) {
        Dictionary w; Array context;
        for (size_t i = 0; i < window.count; ++i) context.append(perf1_record_dictionary(window.rows[i]));
        w["trigger_sequence"] = static_cast<int64_t>(window.trigger);
        w["complete"] = window.remaining == 0; w["post_builds_remaining"] = static_cast<int64_t>(window.remaining);
        w["records"] = context; windows.append(w);
    }
    d["schema_version"] = 1; d["native_build"] = __DATE__ " " __TIME__;
    d["sequence"] = static_cast<int64_t>(snapshot.sequence);
    d["ring_capacity"] = static_cast<int64_t>(oq::Perf1Journal::CAPACITY);
    d["recent_export_limit"] = 256;
    d["context_builds_each_side"] = static_cast<int64_t>(oq::Perf1Journal::CONTEXT);
    d["overwritten_ring_records"] = static_cast<int64_t>(snapshot.overwritten);
    d["dropped_hitch_windows"] = static_cast<int64_t>(snapshot.dropped_windows);
    d["thread_cpu_scope"] = "calling_thread_only; gap includes waits/preemption and clock quantization";
    d["records"] = rows; d["hitch_windows"] = windows;
    d["physics_frames"] = frames;
    return d;
}
