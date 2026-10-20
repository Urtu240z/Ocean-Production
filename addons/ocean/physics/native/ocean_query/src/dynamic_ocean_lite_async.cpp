#include "dynamic_ocean_lite_async.h"
#include <chrono>
#include <cmath>
#include <algorithm>
#if defined(_M_X64) || defined(__x86_64__)
#include <xmmintrin.h>
#endif

namespace oq {
namespace {
uint64_t now_ns() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
uint32_t get_mxcsr() {
#if defined(_M_X64) || defined(__x86_64__)
    return _mm_getcsr();
#else
    return 0;
#endif
}
void set_mxcsr(uint32_t state) {
#if defined(_M_X64) || defined(__x86_64__)
    _mm_setcsr(state);
#else
    (void)state;
#endif
}
}

DynamicOceanLiteAsync::DynamicOceanLiteAsync(std::array<DynamicOceanPhysicsField, 3> &&builders, bool avx2)
    : builders_(std::move(builders)), avx2_(avx2) {
    for (auto &slot : slots_) {
        slot = std::make_shared<LiteSnapshot>();
        for (size_t band = 0; band < 3; ++band) builders_[band].initialize_lite_snapshot(slot->bands[band]);
    }
    for (size_t band = 0; band < 3; ++band) {
        jobs_[band] = {this, band, false, 0};
        builders_[band].save_lite_phase(checkpoints_[band]);
        memory_bytes_ += builders_[band].lite_memory_bytes();
        if (builders_[band].lite_packed_field().empty()) memory_bytes_ +=
            size_t(builders_[band].resolution()) * builders_[band].resolution() * sizeof(std::complex<double>) * 2;
        const auto &h = checkpoints_[band];
        memory_bytes_ += (h.cosine.capacity()+h.sine.capacity()+h.rotor_cosine.capacity()+h.rotor_sine.capacity()) * sizeof(double);
        for (const auto &slot : slots_) memory_bytes_ += slot->bands[band].lite_memory_bytes();
    }
}

DynamicOceanLiteAsync::~DynamicOceanLiteAsync() { shutdown(); }

void DynamicOceanLiteAsync::wait_locked_(std::unique_lock<std::mutex> &lock) {
    if (pending_ == 0) return;
    const uint64_t start = now_ns();
    completed_.wait(lock, [&] { return pending_ == 0; });
    const uint64_t duration = (now_ns() - start) / 1000;
    stats_.wait_us += duration;
    stats_.max_wait_us = std::max(stats_.max_wait_us, duration);
}

bool DynamicOceanLiteAsync::request_locked_(const LiteSnapshotKey &key, std::unique_lock<std::mutex> &lock) {
    if (stopping_ || !std::isfinite(key.time)) return false;
    if (target_ && target_->key == key) return true;
    wait_locked_(lock);
    const bool rollback = target_ && !accepted_;
    if (rollback) ++stats_.invalidated;
    target_.reset();
    const uint64_t buffer_start = now_ns();
    while (!target_) {
        for (auto &slot : slots_) {
            // The writer owns one reference; all reader and publication leases
            // must have retired before the slot can be reused.
            if (slot.use_count() == 1) { target_ = slot; break; }
        }
        if (!target_) {
            completed_.wait_for(lock, std::chrono::milliseconds(1));
            if (stopping_) return false;
        }
    }
    stats_.buffer_wait_us += (now_ns() - buffer_start) / 1000;
    target_->key = key;
    target_->valid = true;
    target_->queue_ns = now_ns();
    target_->build_wall_us = 0;
    pending_ = 3;
    accepted_ = false;
    ++stats_.requests;
    void *contexts[3];
    for (size_t band = 0; band < 3; ++band) {
        jobs_[band].rollback = rollback;
        jobs_[band].mxcsr = get_mxcsr();
        contexts[band] = &jobs_[band];
    }
    DynamicOceanPhysicsField::submit_lite_jobs(&run_band_, contexts, 3);
    return true;
}

bool DynamicOceanLiteAsync::request(const LiteSnapshotKey &key) {
    std::unique_lock<std::mutex> lock(mutex_);
    return request_locked_(key, lock);
}

DynamicOceanLiteAsync::SnapshotPtr DynamicOceanLiteAsync::consume(const LiteSnapshotKey &key) {
    std::unique_lock<std::mutex> lock(mutex_);
    const uint64_t wait_before = stats_.wait_us;
    const bool predicted = target_ && target_->key == key;
    if (!predicted) ++stats_.recoveries;
    if (!predicted || pending_ != 0) ++stats_.misses;
    if (!request_locked_(key, lock)) return {};
    wait_locked_(lock);
    stats_.last_wait_us = stats_.wait_us - wait_before;
    if (!target_->valid || !(target_->key == key)) { ++stats_.failures; return {}; }
    if (!accepted_) ++stats_.publications;
    accepted_ = true;
    published_ = target_;
    return published_;
}

void DynamicOceanLiteAsync::run_band_(void *context) {
    auto &job = *static_cast<BandJob *>(context);
    auto &self = *job.owner;
    auto &builder = self.builders_[job.band];
    auto &slot = *self.target_;
    const uint32_t previous_mxcsr = get_mxcsr();
    set_mxcsr(job.mxcsr);
    bool success = false;
    try {
        const uint64_t start = now_ns();
        if (job.rollback) builder.restore_lite_phase(self.checkpoints_[job.band]);
        builder.save_lite_phase(self.checkpoints_[job.band]);
        const uint64_t saved = now_ns();
        slot.checkpoint_us[job.band] = (saved - start) / 1000;
        success = builder.build_lite(slot.key.time, self.avx2_);
        const uint64_t built = now_ns();
        slot.band_us[job.band] = (built - saved) / 1000;
        if (success) builder.publish_lite_snapshot(slot.bands[job.band]);
        slot.transfer_us[job.band] = (now_ns() - built) / 1000;
    } catch (...) {
        success = false;
    }
    set_mxcsr(previous_mxcsr);
    std::lock_guard<std::mutex> lock(self.mutex_);
    slot.valid = slot.valid && success;
    if (--self.pending_ == 0) {
        slot.build_wall_us = (now_ns() - slot.queue_ns) / 1000;
        self.completed_.notify_all();
    }
}

LiteAsyncStats DynamicOceanLiteAsync::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}

void DynamicOceanLiteAsync::release_builders(std::array<DynamicOceanPhysicsField, 3> &destination) {
    std::unique_lock<std::mutex> lock(mutex_);
    stopping_ = true;
    wait_locked_(lock);
    for (size_t band = 0; band < 3; ++band) {
        if (target_ && !accepted_) builders_[band].restore_lite_phase(checkpoints_[band]);
        // Baseline will rebuild before any query; its phase is the accepted one.
        destination[band] = std::move(builders_[band]);
    }
}

void DynamicOceanLiteAsync::shutdown() {
    std::unique_lock<std::mutex> lock(mutex_);
    stopping_ = true;
    wait_locked_(lock);
    completed_.notify_all();
}
} // namespace oq
