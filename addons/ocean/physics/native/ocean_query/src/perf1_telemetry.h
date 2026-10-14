#pragma once
// Bounded, allocation-free producer. No logging or filesystem access here.
#include "dynamic_ocean_physics_field.h"
#include "perf2_telemetry.h"
#include <array>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <vector>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace oq {
inline uint64_t perf1_now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
}
inline int64_t perf1_thread_cpu_ns() {
#ifdef _WIN32
    FILETIME created{}, exited{}, kernel{}, user{};
    if (!GetThreadTimes(GetCurrentThread(), &created, &exited, &kernel, &user)) return -1;
    ULARGE_INTEGER k{}, u{};
    k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
    return static_cast<int64_t>((k.QuadPart + u.QuadPart) * 100);
#else
    return -1;
#endif
}
struct Perf1Context {
    int64_t physics_tick = -1, process_frame = -1, render_frame = -1, spectrum_generation = -1;
    int selected_backend = -1;
    bool comparison_enabled = false;
};
struct Perf1Build {
    uint64_t sequence = 0, start_ns = 0, wall_us = 0;
    int64_t thread_cpu_us = -1;
    uint64_t thread_id = 0;
    int64_t thread_cycles = -1;
    Perf1Context context{};
    double simulation_time = 0, simulation_delta = 0;
    bool lite = true, succeeded = false, avx2 = false, rewind_reset = false;
    std::array<int, 3> resolutions{}, configure_reason{};
    std::array<uint64_t, 3> configure_us{}, band_us{}, ifft_us{}, publication_us{}, memory_before{}, memory_after{};
    std::array<DynamicOceanBuildProfile, 3> stages{};
};
class Perf1Journal {
public:
    static constexpr size_t CAPACITY = 2048, CONTEXT = 16, WINDOW_SIZE = CONTEXT * 2 + 1, MAX_WINDOWS = 32;
    struct Window {
        uint64_t trigger = 0;
        size_t count = 0, remaining = 0;
        std::array<Perf1Build, WINDOW_SIZE> rows{};
    };
    struct Snapshot {
        uint64_t sequence = 0, overwritten = 0, dropped_windows = 0;
        std::vector<Perf1Build> recent;
        std::vector<Window> windows;
        struct Frame { int64_t process_frame, render_frame, first_tick, last_tick; uint64_t steps; };
        std::vector<Frame> frames;
    };
    std::atomic<bool> enabled{true};
    Perf2Journal perf2;
    void context(const Perf1Context &value) { std::lock_guard<std::mutex> lock(mutex_); context_ = value; }
    Perf1Context context() { std::lock_guard<std::mutex> lock(mutex_); return context_; }
    void tick(int64_t tick, int64_t frame, int64_t rendered) {
        if (!enabled.load(std::memory_order_relaxed)) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (!frame_sequence_ || frames_[(frame_sequence_ - 1) % CAPACITY].process_frame != frame) {
            frames_[frame_sequence_++ % CAPACITY] = {frame, rendered, tick, tick, 1};
        } else {
            auto &f = frames_[(frame_sequence_ - 1) % CAPACITY];
            if (f.last_tick != tick) { f.last_tick = tick; ++f.steps; }
        }
    }
    void push(Perf1Build row) {
        if (!enabled.load(std::memory_order_relaxed)) return;
        perf2.stage(row.context.process_frame, NATIVE_BUILD, row.wall_us, 1);
        const auto end_qpc = perf2_qpc();
        const auto frequency = perf2_qpc_frequency();
        perf2_etw_span(NATIVE_BUILD, row.context.process_frame, row.context.physics_tick,
                frequency ? end_qpc - row.wall_us * frequency / 1000000 : 0, end_qpc, row.wall_us, 1);
        std::lock_guard<std::mutex> lock(mutex_);
        row.sequence = ++sequence_;
        for (size_t i = 0; i < window_count_; ++i) {
            auto &w = windows_[i];
            if (w.remaining && w.count < WINDOW_SIZE) { w.rows[w.count++] = row; --w.remaining; }
        }
        rows_[(sequence_ - 1) % CAPACITY] = row;
        count_ = std::min(count_ + 1, CAPACITY);
        if (row.wall_us > 8000) {
            if (window_count_ == MAX_WINDOWS) { ++dropped_windows_; return; }
            auto &w = windows_[window_count_++];
            w.trigger = sequence_; w.count = 0; w.remaining = CONTEXT;
            const uint64_t first = sequence_ > CONTEXT ? sequence_ - CONTEXT : 1;
            for (uint64_t s = first; s <= sequence_; ++s) w.rows[w.count++] = rows_[(s - 1) % CAPACITY];
        }
    }
    // Allocate snapshot storage before locking. Serialization happens after unlocking.
    std::vector<Perf1Build> builds_for_frames(int64_t first, int64_t last) {
        std::vector<Perf1Build> result; result.reserve(CAPACITY);
        std::lock_guard<std::mutex> lock(mutex_);
        for (uint64_t s = sequence_ - count_ + 1; s <= sequence_; ++s) {
            const auto &row = rows_[(s - 1) % CAPACITY];
            if (row.context.process_frame >= first && row.context.process_frame <= last) result.push_back(row);
        }
        return result;
    }
    Snapshot snapshot(size_t recent_limit = CAPACITY) {
        Snapshot result;
        recent_limit = std::min(recent_limit, CAPACITY);
        result.recent.reserve(recent_limit); result.windows.reserve(MAX_WINDOWS);
        result.frames.reserve(CAPACITY);
        std::lock_guard<std::mutex> lock(mutex_);
        result.sequence = sequence_; result.overwritten = sequence_ - count_;
        result.dropped_windows = dropped_windows_;
        const uint64_t frame_count = std::min<uint64_t>(frame_sequence_, CAPACITY);
        for (uint64_t f = frame_sequence_ - frame_count; f < frame_sequence_; ++f) result.frames.push_back(frames_[f % CAPACITY]);
        const size_t export_count = std::min(count_, recent_limit);
        for (uint64_t s = sequence_ - export_count + 1; s <= sequence_; ++s) result.recent.push_back(rows_[(s - 1) % CAPACITY]);
        size_t pending = 0;
        for (size_t i = 0; i < window_count_; ++i) {
            result.windows.push_back(windows_[i]);
            if (windows_[i].remaining) windows_[pending++] = windows_[i];
        }
        window_count_ = pending;
        return result;
    }
private:
    std::mutex mutex_;
    Perf1Context context_{};
    uint64_t sequence_ = 0, dropped_windows_ = 0;
    uint64_t frame_sequence_ = 0;
    std::array<Snapshot::Frame, CAPACITY> frames_{};
    size_t count_ = 0, window_count_ = 0;
    std::array<Perf1Build, CAPACITY> rows_{};
    std::array<Window, MAX_WINDOWS> windows_{};
};
class Perf1Scope {
public:
    Perf1Build row{};
    explicit Perf1Scope(Perf1Journal &journal, bool lite, double time) : journal_(journal) {
        active_ = journal_.enabled.load(std::memory_order_relaxed);
        if (!active_) return;
        row.start_ns = perf1_now_ns(); cpu_start_ = perf1_thread_cpu_ns();
        row.context = journal_.context(); row.lite = lite; row.simulation_time = time;
#ifdef _WIN32
        row.thread_id = GetCurrentThreadId();
        ULONG64 cycles = 0;
        if (QueryThreadCycleTime(GetCurrentThread(), &cycles)) cycles_start_ = cycles;
#endif
    }
    ~Perf1Scope() {
        if (!active_) return;
        row.wall_us = (perf1_now_ns() - row.start_ns) / 1000;
        const auto cpu_end = perf1_thread_cpu_ns();
        if (cpu_start_ >= 0 && cpu_end >= cpu_start_) row.thread_cpu_us = (cpu_end - cpu_start_) / 1000;
#ifdef _WIN32
        ULONG64 cycles = 0;
        if (cycles_start_ >= 0 && QueryThreadCycleTime(GetCurrentThread(), &cycles)) row.thread_cycles = cycles - cycles_start_;
#endif
        journal_.push(row);
    }
private:
    Perf1Journal &journal_;
    bool active_ = false;
    int64_t cpu_start_ = -1, cycles_start_ = -1;
};
}
