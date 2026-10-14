#pragma once
#include <algorithm>
#include <array>
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
inline uint64_t perf2_qpc() {
#ifdef _WIN32
    LARGE_INTEGER value{}; QueryPerformanceCounter(&value); return value.QuadPart;
#else
    return 0;
#endif
}
inline uint64_t perf2_qpc_frequency() {
#ifdef _WIN32
    LARGE_INTEGER value{}; QueryPerformanceFrequency(&value); return value.QuadPart;
#else
    return 0;
#endif
}
enum Perf2Stage { CONTROLLER, CONTACTS, WATER_PHYSICS, CELL_INTEGRATION,
    TETRA_LOOP, QUERY_BATCH, SOURCE_VALIDITY, OCEAN_SOURCE, NATIVE_BUILD, REPORT_SAVE, STAGE_COUNT };
void perf2_etw_initialize();
void perf2_etw_shutdown();
bool perf2_etw_enabled();
void perf2_etw_span(int stage, int64_t frame, int64_t tick, uint64_t start_qpc,
    uint64_t end_qpc, uint64_t duration_us, uint64_t calls);
void perf2_etw_frame(int64_t frame, uint64_t begin_qpc, uint64_t end_qpc, uint64_t interval_us, bool hitch);

struct Perf2Frame {
    int64_t frame = -1, render_frame = -1;
    uint64_t interval_us = 0, begin_qpc = 0, end_qpc = 0;
    std::array<uint64_t, STAGE_COUNT> stage_us{}, stage_calls{};
};
class Perf2Journal {
public:
    static constexpr size_t CAPACITY = 2048, CONTEXT = 32, WINDOW_SIZE = CONTEXT * 2 + 1, MAX_WINDOWS = 16;
    struct Window {
        int64_t trigger = -1;
        size_t count = 0, remaining = 0;
        bool complete = false;
        std::array<Perf2Frame, WINDOW_SIZE> frames{};
    };
    struct Snapshot {
        int64_t last_frame = -1;
        uint64_t dropped = 0;
        std::vector<Perf2Frame> recent;
        std::vector<Window> windows;
    };
    void stage(int64_t frame, int stage, uint64_t duration, uint64_t calls) {
        if (frame < 0 || stage < 0 || stage >= STAGE_COUNT) return;
        std::lock_guard<std::mutex> lock(mutex_);
        auto &row = slot_(frame); row.stage_us[stage] += duration; row.stage_calls[stage] += calls;
    }
    void boundary(int64_t frame, int64_t rendered, uint64_t qpc, uint64_t frequency, uint64_t threshold_us) {
        if (frame < 0) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (frame <= last_frame_) return;
        auto &row = slot_(frame); row.render_frame = rendered;
        row.begin_qpc = last_qpc_; row.end_qpc = qpc;
        if (last_qpc_ && frequency && qpc >= last_qpc_) row.interval_us = (qpc - last_qpc_) * 1000000 / frequency;
        for (size_t i = 0; i < window_count_; ++i) {
            auto &w = windows_[i];
            // Refresh the previous/current row after later process callbacks added spans.
            if (w.count) {
                auto &tail = w.frames[w.count - 1];
                const auto &latest = rows_[tail.frame % CAPACITY];
                if (latest.frame == tail.frame) tail = latest;
            }
            if (w.remaining && w.count < WINDOW_SIZE) { w.frames[w.count++] = row; --w.remaining; }
            else if (!w.remaining) w.complete = true;
        }
        if (row.interval_us > threshold_us) {
            if (window_count_ == MAX_WINDOWS) ++dropped_;
            else {
                auto &w = windows_[window_count_++]; w = Window{};
                w.trigger = frame; w.remaining = CONTEXT;
                const int64_t first = std::max<int64_t>(0, frame - CONTEXT);
                for (int64_t f = first; f <= frame; ++f) {
                    const auto &candidate = rows_[f % CAPACITY];
                    if (candidate.frame == f) w.frames[w.count++] = candidate;
                }
            }
        }
        last_frame_ = frame; last_qpc_ = qpc;
    }
    Snapshot snapshot() {
        Snapshot result; result.recent.reserve(256); result.windows.reserve(MAX_WINDOWS);
        std::lock_guard<std::mutex> lock(mutex_);
        result.last_frame = last_frame_; result.dropped = dropped_;
        for (int64_t f = std::max<int64_t>(0, last_frame_ - 255); f <= last_frame_; ++f) {
            const auto &row = rows_[f % CAPACITY]; if (row.frame == f) result.recent.push_back(row);
        }
        size_t pending = 0;
        for (size_t i = 0; i < window_count_; ++i) {
            auto &w = windows_[i];
            if (w.count) { auto &tail = w.frames[w.count - 1]; const auto &latest = rows_[tail.frame % CAPACITY]; if (latest.frame == tail.frame) tail = latest; }
            result.windows.push_back(w);
            if (!w.complete) windows_[pending++] = w;
        }
        window_count_ = pending;
        return result;
    }
private:
    Perf2Frame &slot_(int64_t frame) {
        auto &row = rows_[frame % CAPACITY];
        if (row.frame != frame) { row = Perf2Frame{}; row.frame = frame; }
        return row;
    }
    std::mutex mutex_;
    int64_t last_frame_ = -1;
    uint64_t last_qpc_ = 0, dropped_ = 0;
    size_t window_count_ = 0;
    std::array<Perf2Frame, CAPACITY> rows_{};
    std::array<Window, MAX_WINDOWS> windows_{};
};
}
