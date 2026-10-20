#pragma once

#include "dynamic_ocean_physics_field.h"
#include <condition_variable>
#include <memory>
#include <mutex>

namespace oq {

struct LiteSnapshotKey {
    uint64_t tick = 0, spectrum_version = 0, resource_generation = 0;
    double time = 0.0;
    bool operator==(const LiteSnapshotKey &b) const {
        return tick == b.tick && time == b.time && spectrum_version == b.spectrum_version &&
            resource_generation == b.resource_generation;
    }
};

struct LiteSnapshot {
    LiteSnapshotKey key;
    std::array<DynamicOceanPhysicsField, 3> bands;
    std::array<uint64_t, 3> band_us{}, checkpoint_us{}, transfer_us{};
    uint64_t build_wall_us = 0, queue_ns = 0;
    bool valid = false;
};

struct LiteAsyncStats {
    uint64_t requests = 0, publications = 0, misses = 0, recoveries = 0;
    uint64_t invalidated = 0, failures = 0, wait_us = 0, max_wait_us = 0;
    uint64_t buffer_wait_us = 0;
    uint64_t last_wait_us = 0;
};

// Control methods run on the physics owner thread. Each band has exactly one
// persistent builder and phase history. Jobs execute on the existing FFT pool,
// with no additional producer threads. Readers retain immutable shared leases.
class DynamicOceanLiteAsync {
public:
    using SnapshotPtr = std::shared_ptr<const LiteSnapshot>;
    explicit DynamicOceanLiteAsync(std::array<DynamicOceanPhysicsField, 3> &&builders, bool avx2);
    ~DynamicOceanLiteAsync();
    bool request(const LiteSnapshotKey &key);
    SnapshotPtr consume(const LiteSnapshotKey &key);
    LiteAsyncStats stats() const;
    size_t memory_bytes() const { return memory_bytes_; }
    // Retires speculative work and returns the last accepted phase to baseline.
    void release_builders(std::array<DynamicOceanPhysicsField, 3> &destination);
    void shutdown();

private:
    struct BandJob {
        DynamicOceanLiteAsync *owner = nullptr;
        size_t band = 0;
        bool rollback = false;
        uint32_t mxcsr = 0;
    };
    static void run_band_(void *context);
    bool request_locked_(const LiteSnapshotKey &key, std::unique_lock<std::mutex> &lock);
    void wait_locked_(std::unique_lock<std::mutex> &lock);
    std::array<DynamicOceanPhysicsField, 3> builders_;
    std::array<DynamicOceanPhysicsField::LitePhaseHistory, 3> checkpoints_;
    std::array<BandJob, 3> jobs_;
    std::array<std::shared_ptr<LiteSnapshot>, 3> slots_;
    std::shared_ptr<LiteSnapshot> target_;
    SnapshotPtr published_;
    mutable std::mutex mutex_;
    std::condition_variable completed_;
    LiteAsyncStats stats_;
    size_t pending_ = 0;
    bool accepted_ = true, stopping_ = false, avx2_ = false;
    size_t memory_bytes_ = 0;
};
} // namespace oq
