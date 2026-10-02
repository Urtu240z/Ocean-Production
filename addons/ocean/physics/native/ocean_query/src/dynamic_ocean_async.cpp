#include "dynamic_ocean_async.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>

namespace oq {

namespace {
Cascade copy_fft_configuration(const Cascade &source) {
    Cascade result;
    result.material_resolution = source.material_resolution;
    result.material_domain_m = source.material_domain_m;
    result.inv_n2 = source.inv_n2;
    result.kx = source.kx; result.ky = source.ky; result.omega = source.omega;
    result.a1 = source.a1; result.a2 = source.a2;
    result.c11 = source.c11; result.c12 = source.c12; result.c21 = source.c21; result.c22 = source.c22;
    result.parity = source.parity; result.weight = source.weight;
    result.h0_re = source.h0_re; result.h0_im = source.h0_im;
    result.h0n_re = source.h0n_re; result.h0n_im = source.h0n_im;
    return result;
}
}

uint64_t DynamicOceanAsyncPublisher::steady_now_ns_() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

DynamicOceanAsyncPublisher::DynamicOceanAsyncPublisher(
        std::array<DynamicOceanPhysicsField, 3> &builders,
        const std::array<Cascade, 3> &cascades,
        double initial_time, uint64_t initial_tick,
        uint64_t configuration_version, bool use_avx2)
        : builders_(builders), use_avx2_(use_avx2) {
    {
        auto config = std::make_shared<ImmutableConfig>();
        for (size_t band = 0; band < cascades.size(); ++band)
            config->cascades[band] = copy_fft_configuration(cascades[band]);
        config->version = configuration_version;
        config_ = std::move(config);
        buffers_[0] = std::make_shared<DynamicOceanSnapshot>();
        buffers_[1] = std::make_shared<DynamicOceanSnapshot>();
        const size_t field_values = static_cast<size_t>(DynamicOceanPhysicsField::FIELD_COUNT);
        for (size_t band = 0; band < 3; ++band) {
            if (!builders_[band].ready() || builders_[band].resolution() <= 0) return;
            const int resolution = builders_[band].resolution();
            const size_t count = field_values * static_cast<size_t>(resolution) * resolution;
            for (auto &buffer : buffers_) {
                buffer->bands[band].resolution = resolution;
                buffer->bands[band].domain_m = builders_[band].domain_size_m();
            }
            buffers_[0]->bands[band].fields = builders_[band].take_spatial_fields();
            if (buffers_[0]->bands[band].fields.size() != count) return;
            buffers_[1]->bands[band].fields.resize(count);
            buffers_[0]->bands[band].simulation_time = initial_time;
            buffers_[1]->bands[band].simulation_time = initial_time;
        }
        buffers_[0]->simulation_time = initial_time;
        buffers_[0]->physics_tick_id = initial_tick;
        buffers_[0]->configuration_version = configuration_version;
        buffers_[0]->generation = 1;
        buffers_[0]->finished_steady_ns = steady_now_ns_();
        buffers_[0]->valid = true;
        buffers_[1]->valid = false;
        std::shared_ptr<const DynamicOceanSnapshot> initial = buffers_[0];
        std::atomic_store_explicit(&published_, std::move(initial), std::memory_order_release);
        stats_.configuration_version = configuration_version;
        worker_configuration_version_ = configuration_version;
        stats_.last_field_time = initial_time;
        stats_.last_field_tick = initial_tick;
        producer_ = std::thread(&DynamicOceanAsyncPublisher::worker_loop_, this);
        valid_ = true;
    }
}

DynamicOceanAsyncPublisher::~DynamicOceanAsyncPublisher() { shutdown(); }

DynamicOceanAsyncPublisher::SnapshotPtr DynamicOceanAsyncPublisher::acquire_snapshot() const {
    return std::atomic_load_explicit(&published_, std::memory_order_acquire);
}

DynamicOceanAsyncTickResult DynamicOceanAsyncPublisher::advance(uint64_t tick_id,
        double current_time, double next_time, double wall_dt_seconds) {
    const uint64_t begin_ns = steady_now_ns_();
    DynamicOceanAsyncTickResult result;
    std::unique_lock<std::mutex> lock(mutex_);
    ++stats_.ticks;
    stats_.last_tick_id = tick_id;

    if (state_ == COMPLETE && completed_buffer_ >= 0) {
        auto &completed = *buffers_[static_cast<size_t>(completed_buffer_)];
        const bool config_matches = config_ && completed.configuration_version == config_->version;
        const bool not_future = completed.simulation_time <= current_time + 1.0e-9;
        const bool canceled_future = has_latest_request_ &&
            latest_request_.simulation_time + 1.0e-9 < completed.simulation_time;
        const bool too_old = has_latest_request_ && latest_request_.requires_build &&
            latest_request_.tick_id > completed.physics_tick_id + 2;
        if (!completed.valid || !config_matches || canceled_future || too_old) {
            ++stats_.discarded_obsolete;
            ++stats_.obsolete_builds;
            completed_buffer_ = -1;
            state_ = has_latest_request_ ? QUEUED : IDLE;
            buffer_released_.notify_all();
        } else if (not_future) {
            completed.generation = stats_.publications + 2;
            std::shared_ptr<const DynamicOceanSnapshot> next = buffers_[static_cast<size_t>(completed_buffer_)];
            const uint64_t publication_begin_ns = steady_now_ns_();
            std::atomic_store_explicit(&published_, std::move(next), std::memory_order_release);
            stats_.last_publication_us = (steady_now_ns_() - publication_begin_ns) / 1000;
            ++stats_.publications;
            ++stats_.swaps;
            stats_.last_published_ns = steady_now_ns_();
            stats_.last_field_time = completed.simulation_time;
            stats_.last_field_tick = completed.physics_tick_id;
            if (completed.finished_steady_ns <= request_.deadline_ns) ++stats_.ready_on_time;
            result.published = true;
            completed_buffer_ = -1;
            state_ = has_latest_request_ ? QUEUED : IDLE;
            buffer_released_.notify_all();
        }
        stats_.worker_state = state_;
        if (state_ == QUEUED) work_ready_.notify_one();
    }

    SnapshotPtr published = std::atomic_load_explicit(&published_, std::memory_order_acquire);
    const bool advances = next_time > current_time + 1.0e-12;
    const double wanted_time = advances ? next_time : current_time;
    const uint64_t wanted_tick = advances ? tick_id + 1 : tick_id;
    const bool published_matches = published && published->valid && config_ &&
        published->configuration_version == config_->version &&
        std::abs(published->simulation_time - wanted_time) <= 1.0e-9;

    // A single latest-request mailbox replaces a FIFO. Every physics tick may
    // overwrite an unsent target, while the in-flight FFT is always allowed to
    // finish. The worker skips it if a newer coherent target arrived.
    const bool same_as_latest = has_latest_request_ && latest_request_.config && config_ &&
        latest_request_.config->version == config_->version &&
        latest_request_.requires_build == !published_matches &&
        std::abs(latest_request_.simulation_time - wanted_time) <= 1.0e-9;
    const bool same_as_building = build_in_progress_ && request_.config && config_ &&
        request_.config->version == config_->version &&
        std::abs(request_.simulation_time - wanted_time) <= 1.0e-9;
    const bool same_as_completed = state_ == COMPLETE && completed_buffer_ >= 0 && config_ &&
        buffers_[static_cast<size_t>(completed_buffer_)]->configuration_version == config_->version &&
        std::abs(buffers_[static_cast<size_t>(completed_buffer_)]->simulation_time - wanted_time) <= 1.0e-9;
    const bool pending_target_differs = (has_latest_request_ && !same_as_latest) ||
        (build_in_progress_ && !same_as_building) || (state_ == COMPLETE && !same_as_completed);
    const bool needs_request = !published_matches || pending_target_differs;
    if (config_ && needs_request && !same_as_latest && !same_as_building && !same_as_completed) {
        if (has_latest_request_ || build_in_progress_) ++stats_.coalesced_requests;
        latest_request_.tick_id = wanted_tick;
        latest_request_.simulation_time = wanted_time;
        latest_request_.requested_ns = begin_ns;
        latest_request_.deadline_ns = begin_ns + static_cast<uint64_t>(std::max(0.0, wall_dt_seconds) * 1.0e9);
        latest_request_.config = config_;
        latest_request_.requires_build = !published_matches;
        has_latest_request_ = true;
        latest_request_requires_build_ = latest_request_.requires_build;
        if (latest_request_.requires_build) {
            ++stats_.requests;
            stats_.last_requested_ns = begin_ns;
            stats_.last_requested_time = wanted_time;
            result.scheduled = true;
        }
        if (!build_in_progress_ && state_ != COMPLETE) {
            state_ = QUEUED;
            stats_.worker_state = QUEUED;
            work_ready_.notify_one();
        }
    }

    if (published) {
        result.field_time = published->simulation_time;
        result.field_tick = published->physics_tick_id;
        result.current_time_ready = std::abs(published->simulation_time - current_time) <= 1.0e-7 &&
            config_ && published->configuration_version == config_->version;
        const double age = std::max(0.0, current_time - published->simulation_time);
        const double dt = std::max(wall_dt_seconds, 1.0e-9);
        result.field_age_ticks = age / dt;
        stats_.last_age_ticks = result.field_age_ticks;
        stats_.max_age_ticks = std::max(stats_.max_age_ticks,
            static_cast<uint64_t>(std::ceil(result.field_age_ticks)));
        if (result.field_age_ticks > 1.0e-3) ++stats_.stale_ticks;
    }
    if (result.field_age_ticks < 1.0) {
        stats_.missed_streak = 0;
        deadline_counted_ = false;
    } else {
        ++stats_.missed_deadlines;
        ++stats_.missed_streak;
        stats_.max_missed_streak = std::max(stats_.max_missed_streak, stats_.missed_streak);
        deadline_counted_ = false;
    }
    stats_.worker_state = state_;
    const uint64_t end_ns = steady_now_ns_();
    result.main_wait_us = (end_ns - begin_ns) / 1000;
    stats_.wait_total_us += result.main_wait_us;
    stats_.wait_max_us = std::max(stats_.wait_max_us, result.main_wait_us);
    return result;
}

void DynamicOceanAsyncPublisher::update_configuration(const std::array<Cascade, 3> &cascades,
                                                       uint64_t version) {
    auto replacement = std::make_shared<ImmutableConfig>();
    for (size_t band = 0; band < cascades.size(); ++band)
        replacement->cascades[band] = copy_fft_configuration(cascades[band]);
    replacement->version = version;
    std::lock_guard<std::mutex> lock(mutex_);
    if (config_ && config_->version == version) return;
    if (has_latest_request_ || build_in_progress_) ++stats_.coalesced_requests;
    config_ = std::move(replacement);
    stats_.configuration_version = version;
    SnapshotPtr published = std::atomic_load_explicit(&published_, std::memory_order_acquire);
    latest_request_.tick_id = has_latest_request_ ? latest_request_.tick_id :
        (build_in_progress_ ? request_.tick_id : (published ? published->physics_tick_id : stats_.last_tick_id));
    latest_request_.simulation_time = has_latest_request_ ? latest_request_.simulation_time :
        (build_in_progress_ ? request_.simulation_time : (published ? published->simulation_time : stats_.last_field_time));
    latest_request_.requested_ns = steady_now_ns_();
    latest_request_.deadline_ns = latest_request_.requested_ns;
    latest_request_.config = config_;
    latest_request_.requires_build = true;
    has_latest_request_ = true;
    latest_request_requires_build_ = true;
    ++stats_.requests;
    stats_.last_requested_ns = latest_request_.requested_ns;
    stats_.last_requested_time = latest_request_.simulation_time;
        if (!build_in_progress_ && state_ != COMPLETE) {
            state_ = QUEUED;
        stats_.worker_state = QUEUED;
        work_ready_.notify_one();
    }
}

DynamicOceanAsyncStats DynamicOceanAsyncPublisher::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    DynamicOceanAsyncStats result = stats_;
    result.worker_state = state_;
    return result;
}

std::array<uint64_t, 29> DynamicOceanAsyncPublisher::build_profile_us() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::array<uint64_t, 29> result{};
    size_t slot = 0;
    for (const auto &band : stats_.last_band_profile) {
        result[slot++] = band.phase_us;
        result[slot++] = band.evolve_us;
        result[slot++] = band.frequency_prepare_us;
        result[slot++] = band.row_x_us;
        result[slot++] = band.transpose_to_columns_us;
        result[slot++] = band.row_z_us;
        result[slot++] = band.transpose_back_us;
        result[slot++] = band.unpack_us;
    }
    result[slot++] = stats_.last_batch_profile.prepare_queue_us;
    result[slot++] = stats_.last_batch_profile.prepare_barrier_us;
    result[slot++] = stats_.last_batch_profile.transform_queue_us;
    result[slot++] = stats_.last_batch_profile.transform_barrier_us;
    result[slot] = stats_.last_publication_us;
    return result;
}

void DynamicOceanAsyncPublisher::shutdown() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) return;
        stopping_ = true;
        state_ = STOPPING;
        stats_.worker_state = STOPPING;
    }
    work_ready_.notify_all();
    buffer_released_.notify_all();
    if (producer_.joinable()) producer_.join();
}

void DynamicOceanAsyncPublisher::worker_loop_() {
    for (;;) {
        BuildRequest request;
        int target_index = -1;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            work_ready_.wait(lock, [&] { return stopping_ ||
                (has_latest_request_ && !build_in_progress_ && state_ != COMPLETE); });
            if (stopping_) return;
            request = latest_request_;
            has_latest_request_ = false;
            const bool should_build = latest_request_requires_build_;
            latest_request_requires_build_ = false;
            if (!should_build) {
                state_ = IDLE;
                stats_.worker_state = IDLE;
                continue;
            }
            request_ = request;
            build_in_progress_ = true;
            state_ = RUNNING;
            stats_.worker_state = RUNNING;
            ++stats_.builds_started;
            stats_.last_started_ns = steady_now_ns_();
            auto active = std::atomic_load_explicit(&published_, std::memory_order_acquire);
            const uint64_t wait_started_ns = steady_now_ns_();
            for (;;) {
                if (stopping_) return;
                if (buffers_[0].get() != active.get() && buffers_[0].use_count() == 1) { target_index = 0; break; }
                if (buffers_[1].get() != active.get() && buffers_[1].use_count() == 1) { target_index = 1; break; }
                buffer_released_.wait_for(lock, std::chrono::milliseconds(1));
                active = std::atomic_load_explicit(&published_, std::memory_order_acquire);
            }
            stats_.buffer_wait_us += (steady_now_ns_() - wait_started_ns) / 1000;
        }

        const uint64_t started_ns = steady_now_ns_();
        auto &target = *buffers_[static_cast<size_t>(target_index)];
        if (request.config && request.config->version != worker_configuration_version_) {
            for (auto &builder : builders_) builder.reset_phase_history();
            worker_configuration_version_ = request.config->version;
            std::lock_guard<std::mutex> lock(mutex_);
            ++stats_.configuration_phase_resets;
        }
        target.valid = false;
        target.physics_tick_id = request.tick_id;
        target.configuration_version = request.config ? request.config->version : 0;
        target.simulation_time = request.simulation_time;
        target.requested_steady_ns = request.requested_ns;
        target.started_steady_ns = started_ns;
        target.finished_steady_ns = 0;
        std::array<DynamicOceanPhysicsField *, 3> builder_ptrs{};
        std::array<const Cascade *, 3> cascade_ptrs{};
        std::array<std::array<std::vector<std::complex<double>>, DynamicOceanPhysicsField::FIELD_COUNT / 2> *, 3> packed_outputs{};
        for (size_t band = 0; band < 3; ++band) {
            builder_ptrs[band] = &builders_[band];
            cascade_ptrs[band] = &request.config->cascades[band];
            packed_outputs[band] = &target.bands[band].packed_fields;
            target.bands[band].resolution = request.config->cascades[band].material_resolution;
            target.bands[band].domain_m = request.config->cascades[band].material_domain_m;
            target.bands[band].simulation_time = request.simulation_time;
            const size_t complex_values = static_cast<size_t>(target.bands[band].resolution) *
                target.bands[band].resolution;
            for (auto &pair : target.bands[band].packed_fields) pair.resize(complex_values);
            // The initial synchronous snapshot uses SoA doubles. Once that
            // buffer is inactive, release it and keep only the zero-copy
            // packed FFT representation for subsequent publications.
            if (!target.bands[band].fields.empty()) std::vector<double>().swap(target.bands[band].fields);
        }
        DynamicOceanBatchProfile batch_profile{};
        const bool built = DynamicOceanPhysicsField::build_all_packed_into(builder_ptrs, cascade_ptrs,
            packed_outputs, request.simulation_time, use_avx2_, &batch_profile);
        const uint64_t finished_ns = steady_now_ns_();
        target.valid = built;
        for (auto &band : target.bands) band.packed_fields_layout = built;
        target.finished_steady_ns = finished_ns;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            const bool config_superseded = request.config && config_ &&
                request.config->version != config_->version;
            const bool superseded_by_pause = has_latest_request_ &&
                latest_request_.simulation_time + 1.0e-9 < request.simulation_time;
            const bool too_old_for_latest = has_latest_request_ && latest_request_.requires_build &&
                latest_request_.tick_id > request.tick_id + 2;
            ++stats_.builds_finished;
            const uint64_t duration_us = (finished_ns - started_ns) / 1000;
            stats_.last_build_duration_us = duration_us;
            stats_.build_total_us += duration_us;
            stats_.build_max_us = std::max(stats_.build_max_us, duration_us);
            stats_.last_finished_ns = finished_ns;
            stats_.last_long_evolution_us = builders_[0].evolution_us();
            stats_.last_mid_evolution_us = builders_[1].evolution_us();
            stats_.last_short_evolution_us = builders_[2].evolution_us();
            stats_.last_long_transform_us = builders_[0].transforms_us();
            stats_.last_mid_transform_us = builders_[1].transforms_us();
            stats_.last_short_transform_us = builders_[2].transforms_us();
            for (size_t band = 0; band < builders_.size(); ++band)
                stats_.last_band_profile[band] = builders_[band].profile();
            stats_.last_batch_profile = batch_profile;
            build_in_progress_ = false;
            if (config_superseded || superseded_by_pause || too_old_for_latest) {
                ++stats_.discarded_obsolete;
                ++stats_.obsolete_builds;
                state_ = has_latest_request_ ? QUEUED : IDLE;
                has_latest_request_ = has_latest_request_ ||
                    (config_ && (std::abs(request.simulation_time - stats_.last_requested_time) > 1.0e-9 ||
                                 request.config->version != config_->version));
                if (!has_latest_request_ && config_) {
                    // A configuration may have changed without a time advance.
                    latest_request_.tick_id = request.tick_id;
                    latest_request_.simulation_time = request.simulation_time;
                    latest_request_.requested_ns = steady_now_ns_();
                    latest_request_.deadline_ns = latest_request_.requested_ns;
                    latest_request_.config = config_;
                    has_latest_request_ = true;
                    ++stats_.requests;
                    state_ = QUEUED;
                }
            } else if (built) {
                target.generation = stats_.publications + 2;
                target.finished_steady_ns = finished_ns;
                completed_buffer_ = target_index;
                state_ = COMPLETE;
            } else {
                ++stats_.discarded_obsolete;
                ++stats_.obsolete_builds;
                state_ = IDLE;
            }
            stats_.worker_state = state_;
        }
        buffer_released_.notify_all();
    }
}

} // namespace oq
