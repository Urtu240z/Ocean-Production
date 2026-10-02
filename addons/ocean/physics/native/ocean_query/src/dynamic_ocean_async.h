#pragma once

#include "dynamic_ocean_physics_field.h"

#include <array>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>

namespace oq {

struct DynamicOceanAsyncTickResult {
    bool published = false;
    bool scheduled = false;
    bool current_time_ready = false;
    double field_time = 0.0;
    uint64_t field_tick = 0;
    double field_age_ticks = 0.0;
    uint64_t main_wait_us = 0;
};

struct DynamicOceanAsyncStats {
    uint64_t ticks = 0, requests = 0, builds_started = 0, builds_finished = 0;
    uint64_t coalesced_requests = 0, obsolete_builds = 0;
    uint64_t configuration_phase_resets = 0;
    uint64_t publications = 0, ready_early = 0, ready_on_time = 0;
    uint64_t missed_deadlines = 0, missed_streak = 0, max_missed_streak = 0;
    uint64_t stale_ticks = 0, max_age_ticks = 0, discarded_obsolete = 0;
    uint64_t swaps = 0, wait_total_us = 0, wait_max_us = 0;
    uint64_t build_total_us = 0, build_max_us = 0, buffer_wait_us = 0;
    uint64_t last_tick_id = 0, last_requested_ns = 0, last_started_ns = 0;
    uint64_t last_finished_ns = 0, last_published_ns = 0;
    double last_requested_time = 0.0, last_field_time = 0.0;
    uint64_t last_field_tick = 0;
    double last_age_ticks = 0.0;
    uint64_t configuration_version = 0;
    uint64_t last_long_evolution_us = 0, last_mid_evolution_us = 0, last_short_evolution_us = 0;
    uint64_t last_long_transform_us = 0, last_mid_transform_us = 0, last_short_transform_us = 0;
    uint64_t last_build_duration_us = 0;
    std::array<DynamicOceanBuildProfile, 3> last_band_profile{};
    DynamicOceanBatchProfile last_batch_profile{};
    uint64_t last_publication_us = 0;
    int worker_state = 0;
};

// One persistent producer thread schedules FFT tasks onto the existing native
// worker pool. Published spatial arrays are immutable and are never written by
// the producer until no query holds the previous buffer.
class DynamicOceanAsyncPublisher {
public:
    using SnapshotPtr = std::shared_ptr<const DynamicOceanSnapshot>;
    using SpectrumPtr = std::shared_ptr<const std::array<Cascade, 3>>;
    static SpectrumPtr prepare_spectrum(const std::array<Cascade, 3> &cascades);
    static SpectrumPtr prepare_spectrum(const std::vector<Cascade> &cascades);

    DynamicOceanAsyncPublisher(std::array<DynamicOceanPhysicsField, 3> &builders,
                               const std::array<Cascade, 3> &cascades,
                               double initial_time, uint64_t initial_tick,
                               uint64_t configuration_version, bool use_avx2);
    ~DynamicOceanAsyncPublisher();
    DynamicOceanAsyncPublisher(const DynamicOceanAsyncPublisher &) = delete;
    DynamicOceanAsyncPublisher &operator=(const DynamicOceanAsyncPublisher &) = delete;

    bool valid() const { return valid_; }
    SnapshotPtr acquire_snapshot() const;
    DynamicOceanAsyncTickResult advance(uint64_t tick_id, double current_time,
                                       double next_time, double wall_dt_seconds);
    void update_configuration(const std::array<Cascade, 3> &cascades, uint64_t version);
    void transition_configuration(SpectrumPtr source, SpectrumPtr target,
                                  double start_time, double duration, uint64_t version);
    DynamicOceanAsyncStats stats() const;
    std::array<uint64_t, 29> build_profile_us() const;
    void shutdown();

private:
    struct ImmutableConfig {
        SpectrumPtr source;
        SpectrumPtr target;
        double start_time = 0.0, duration = 0.0;
        uint64_t version = 0;
    };
    struct BuildRequest {
        uint64_t tick_id = 0;
        double simulation_time = 0.0;
        uint64_t requested_ns = 0, deadline_ns = 0;
        std::shared_ptr<const ImmutableConfig> config;
        bool requires_build = true;
    };
    enum WorkerState : int { IDLE = 0, QUEUED = 1, RUNNING = 2, COMPLETE = 3, STOPPING = 4 };

    void worker_loop_();
    void refresh_state_locked_();
    static uint64_t steady_now_ns_();

    std::array<DynamicOceanPhysicsField, 3> &builders_;
    std::array<Cascade, 3> working_cascades_;
    // Producer-owned, preallocated once. Recomputed only on a config version
    // change, before dispatch; never written while band jobs borrow it.
    std::array<DynamicOceanWeatherDelta, 3> weather_deltas_;
    // Published, writer, and spare. A short-lived reader of the retired
    // snapshot must not hold up the next build.
    std::array<std::shared_ptr<DynamicOceanSnapshot>, 3> buffers_;
    std::shared_ptr<const DynamicOceanSnapshot> published_;
    std::shared_ptr<const ImmutableConfig> config_;
    mutable std::mutex mutex_;
    std::condition_variable work_ready_;
    std::condition_variable buffer_released_;
    std::thread producer_;
    BuildRequest request_;
    BuildRequest latest_request_;
    DynamicOceanAsyncStats stats_;
    WorkerState state_ = IDLE;
    std::array<bool, 3> ready_buffers_{};
    bool deadline_counted_ = false;
    bool has_latest_request_ = false;
    bool latest_request_requires_build_ = false;
    bool build_in_progress_ = false;
    bool stopping_ = false;
    bool valid_ = false;
    bool use_avx2_ = false;
    uint64_t worker_configuration_version_ = 0;
};

} // namespace oq
