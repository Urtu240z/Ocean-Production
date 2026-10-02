#include "dynamic_ocean_async.h"
#include "dynamic_ocean_fft_avx2.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>

namespace oq {

namespace {
struct WeatherBandContext {
    Cascade *working;
    const Cascade *source;
    const Cascade *destination;
    std::vector<float> *h0;
    double alpha;
    bool use_avx2;
};

void prepare_weather_band(void *opaque) {
    const auto &context = *static_cast<WeatherBandContext *>(opaque);
    auto &working = *context.working;
    const auto &source = *context.source;
    const auto &destination = *context.destination;
    const double alpha = context.alpha;
    const size_t prefix = context.use_avx2 ? compose_weather_band_avx2(
        working, source, destination, context.h0->data(), alpha) : 0;
    for (size_t i = prefix; i < source.kx.size(); ++i) {
        const double sign = source.parity[i];
        const auto blend_h0 = [&](double a, double b, size_t channel) {
            const double mixed = alpha <= 0.0 ? a : alpha >= 1.0 ? b : a + (b - a) * alpha;
            const float value = static_cast<float>(mixed * sign);
            (*context.h0)[4 * i + channel] = value;
            return static_cast<double>(value) * sign;
        };
        working.h0_re[i] = blend_h0(source.h0_re[i], destination.h0_re[i], 0);
        working.h0_im[i] = blend_h0(source.h0_im[i], destination.h0_im[i], 1);
        working.h0n_re[i] = blend_h0(source.h0n_re[i], destination.h0n_re[i], 2);
        working.h0n_im[i] = blend_h0(source.h0n_im[i], destination.h0n_im[i], 3);
        working.a1[i] = source.a1[i] + (destination.a1[i] - source.a1[i]) * alpha;
        working.a2[i] = source.a2[i] + (destination.a2[i] - source.a2[i]) * alpha;
        working.c11[i] = source.c11[i] + (destination.c11[i] - source.c11[i]) * alpha;
        working.c12[i] = source.c12[i] + (destination.c12[i] - source.c12[i]) * alpha;
        working.c21[i] = source.c21[i] + (destination.c21[i] - source.c21[i]) * alpha;
        working.c22[i] = source.c22[i] + (destination.c22[i] - source.c22[i]) * alpha;
    }
}

Cascade copy_fft_configuration(const Cascade &source) {
    Cascade result;
    result.material_resolution = source.material_resolution;
    result.material_domain_m = source.material_domain_m;
    result.production_choppiness = source.production_choppiness;
    result.production_gravity = source.production_gravity;
    result.production_wind_x = source.production_wind_x; result.production_wind_z = source.production_wind_z;
    result.production_wind_speed = source.production_wind_speed;
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

DynamicOceanAsyncPublisher::SpectrumPtr DynamicOceanAsyncPublisher::prepare_spectrum(
        const std::array<Cascade, 3> &cascades) {
    auto result = std::make_shared<std::array<Cascade, 3>>();
    for (size_t band = 0; band < 3; ++band)
        (*result)[band] = copy_fft_configuration(cascades[band]);
    return result;
}

DynamicOceanAsyncPublisher::SpectrumPtr DynamicOceanAsyncPublisher::prepare_spectrum(
        const std::vector<Cascade> &cascades) {
    if (cascades.size() != 3) return {};
    auto result = std::make_shared<std::array<Cascade, 3>>();
    for (size_t band = 0; band < 3; ++band) (*result)[band] = copy_fft_configuration(cascades[band]);
    return result;
}

DynamicOceanAsyncPublisher::DynamicOceanAsyncPublisher(
        std::array<DynamicOceanPhysicsField, 3> &builders,
        const std::array<Cascade, 3> &cascades,
        double initial_time, uint64_t initial_tick,
        uint64_t configuration_version, bool use_avx2)
        : builders_(builders), use_avx2_(use_avx2) {
    {
        auto config = std::make_shared<ImmutableConfig>();
        config->source = prepare_spectrum(cascades);
        for (size_t band = 0; band < 3; ++band)
            working_cascades_[band] = copy_fft_configuration(cascades[band]);
        config->version = configuration_version;
        config_ = std::move(config);
        for (auto &buffer : buffers_) buffer = std::make_shared<DynamicOceanSnapshot>();
        const size_t field_values = static_cast<size_t>(DynamicOceanPhysicsField::FIELD_COUNT);
        for (size_t band = 0; band < 3; ++band) {
            if (!builders_[band].ready() || builders_[band].resolution() <= 0) return;
            const int resolution = builders_[band].resolution();
            const size_t count = field_values * static_cast<size_t>(resolution) * resolution;
            for (auto &buffer : buffers_) {
                buffer->bands[band].resolution = resolution;
                buffer->bands[band].domain_m = builders_[band].domain_size_m();
                buffer->bands[band].simulation_time = initial_time;
                for (auto &pair : buffer->bands[band].packed_fields)
                    pair.resize(static_cast<size_t>(resolution) * resolution);
                buffer->production_h0[band].resize(static_cast<size_t>(resolution) * resolution * 4);
                const auto &source = (*config_->source)[band];
                for (size_t i = 0; i < source.kx.size(); ++i) {
                    const double sign = source.parity[i];
                    buffer->production_h0[band][4 * i] = static_cast<float>(source.h0_re[i] * sign);
                    buffer->production_h0[band][4 * i + 1] = static_cast<float>(source.h0_im[i] * sign);
                    buffer->production_h0[band][4 * i + 2] = static_cast<float>(source.h0n_re[i] * sign);
                    buffer->production_h0[band][4 * i + 3] = static_cast<float>(source.h0n_im[i] * sign);
                }
                buffer->choppiness[band] = source.production_choppiness;
                buffer->gravity[band] = source.production_gravity;
                buffer->wind_x[band] = source.production_wind_x;
                buffer->wind_z[band] = source.production_wind_z;
                buffer->wind_speed[band] = source.production_wind_speed;
            }
            buffers_[0]->bands[band].fields = builders_[band].take_spatial_fields();
            if (buffers_[0]->bands[band].fields.size() != count) return;
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

void DynamicOceanAsyncPublisher::refresh_state_locked_() {
    const bool ready = std::any_of(ready_buffers_.begin(), ready_buffers_.end(), [](bool v) { return v; });
    state_ = stopping_ ? STOPPING : build_in_progress_ ? RUNNING :
        has_latest_request_ ? QUEUED : ready ? COMPLETE : IDLE;
    stats_.worker_state = state_;
}

DynamicOceanAsyncTickResult DynamicOceanAsyncPublisher::advance(uint64_t tick_id,
        double current_time, double next_time, double wall_dt_seconds) {
    const uint64_t begin_ns = steady_now_ns_();
    DynamicOceanAsyncTickResult result;
    std::unique_lock<std::mutex> lock(mutex_);
    ++stats_.ticks;
    stats_.last_tick_id = tick_id;
    const bool advances = next_time > current_time + 1.0e-12;
    const double wanted_time = advances ? next_time : current_time;
    const uint64_t wanted_tick = advances ? tick_id + 1 : tick_id;

    auto previous = acquire_snapshot();
    int publish_index = -1;
    for (size_t slot = 0; slot < buffers_.size(); ++slot) {
        if (!ready_buffers_[slot]) continue;
        auto &completed = *buffers_[slot];
        const bool config_matches = config_ && completed.configuration_version == config_->version;
        const bool not_future = completed.simulation_time <= current_time + 1.0e-9;
        const bool canceled_future = (!advances && !not_future) || (has_latest_request_ &&
            latest_request_.simulation_time + 1.0e-9 < completed.simulation_time);
        const bool regresses = previous && previous->configuration_version == completed.configuration_version &&
            completed.simulation_time <= previous->simulation_time + 1.0e-9;
        // A late result can still be the freshest coherent field available.
        // Discarding it solely for its age prevents progress during catch-up
        // ticks after a main-thread hitch. Never regress; then build latest.
        if (!completed.valid || !config_matches || canceled_future || regresses) {
            ++stats_.discarded_obsolete;
            ++stats_.obsolete_builds;
            ready_buffers_[slot] = false;
        } else if (not_future) {
            if (publish_index < 0 || completed.simulation_time > buffers_[static_cast<size_t>(publish_index)]->simulation_time)
                publish_index = static_cast<int>(slot);
        }
    }
    if (publish_index >= 0) {
        auto &completed = *buffers_[static_cast<size_t>(publish_index)];
        completed.generation = stats_.publications + 2;
        std::shared_ptr<const DynamicOceanSnapshot> next = buffers_[static_cast<size_t>(publish_index)];
        const uint64_t publication_begin_ns = steady_now_ns_();
        std::atomic_store_explicit(&published_, std::move(next), std::memory_order_release);
        stats_.last_publication_us = (steady_now_ns_() - publication_begin_ns) / 1000;
        ++stats_.publications; ++stats_.swaps;
        stats_.last_published_ns = steady_now_ns_();
        stats_.last_field_time = completed.simulation_time;
        stats_.last_field_tick = completed.physics_tick_id;
        if (completed.finished_steady_ns <= completed.deadline_steady_ns) ++stats_.ready_on_time;
        result.published = true;
        for (size_t slot = 0; slot < buffers_.size(); ++slot)
            if (ready_buffers_[slot] && buffers_[slot]->simulation_time <= completed.simulation_time + 1.0e-9)
                ready_buffers_[slot] = false;
    }
    // Release the retired reader reference BEFORE waking the writer.
    previous.reset();
    refresh_state_locked_();
    buffer_released_.notify_all();

    SnapshotPtr published = std::atomic_load_explicit(&published_, std::memory_order_acquire);
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
    bool has_completed = false, same_as_completed = false;
    for (size_t slot = 0; slot < buffers_.size(); ++slot) if (ready_buffers_[slot]) {
        has_completed = true;
        same_as_completed |= config_ && buffers_[slot]->configuration_version == config_->version &&
            std::abs(buffers_[slot]->simulation_time - wanted_time) <= 1.0e-9;
    }
    const bool pending_target_differs = (has_latest_request_ && !same_as_latest) ||
        (build_in_progress_ && !same_as_building) || (has_completed && !same_as_completed);
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
        refresh_state_locked_();
        work_ready_.notify_one();
        buffer_released_.notify_all();
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
    transition_configuration(prepare_spectrum(cascades), nullptr, 0.0, 0.0, version);
}

void DynamicOceanAsyncPublisher::transition_configuration(SpectrumPtr source, SpectrumPtr target,
        double start_time, double duration, uint64_t version) {
    auto replacement = std::make_shared<ImmutableConfig>();
    replacement->source = std::move(source);
    replacement->target = std::move(target);
    replacement->start_time = start_time;
    replacement->duration = duration;
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
    refresh_state_locked_();
    work_ready_.notify_one();
    buffer_released_.notify_all();
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
                (has_latest_request_ && !build_in_progress_); });
            if (stopping_) return;
            if (!latest_request_requires_build_) {
                has_latest_request_ = false;
                refresh_state_locked_();
                continue;
            }
            auto active = std::atomic_load_explicit(&published_, std::memory_order_acquire);
            const uint64_t wait_started_ns = steady_now_ns_();
            for (;;) {
                if (stopping_) return;
                if (!latest_request_requires_build_) break;
                for (size_t slot = 0; slot < buffers_.size(); ++slot) {
                    if (!ready_buffers_[slot] && buffers_[slot].get() != active.get() && buffers_[slot].use_count() == 1) {
                        target_index = static_cast<int>(slot);
                        break;
                    }
                }
                if (target_index >= 0) break;
                buffer_released_.wait_for(lock, std::chrono::milliseconds(1));
                active = std::atomic_load_explicit(&published_, std::memory_order_acquire);
            }
            stats_.buffer_wait_us += (steady_now_ns_() - wait_started_ns) / 1000;
            // Consume the newest mailbox only after ownership is available.
            // A ready future field never prevents using the spare buffer.
            request = latest_request_;
            has_latest_request_ = false;
            latest_request_requires_build_ = false;
            if (target_index < 0) { refresh_state_locked_(); continue; }
            request_ = request;
            build_in_progress_ = true;
            refresh_state_locked_();
            ++stats_.builds_started;
            stats_.last_started_ns = steady_now_ns_();
        }

        const uint64_t started_ns = steady_now_ns_();
        auto &target = *buffers_[static_cast<size_t>(target_index)];
        const uint64_t previous_version = target.configuration_version;
        const double previous_alpha = target.weather_alpha;
        if (request.config && request.config->version != worker_configuration_version_) {
            for (auto &builder : builders_) builder.reset_phase_history();
            worker_configuration_version_ = request.config->version;
            std::lock_guard<std::mutex> lock(mutex_);
            ++stats_.configuration_phase_resets;
        }
        target.valid = false;
        target.physics_tick_id = request.tick_id;
        target.configuration_version = request.config ? request.config->version : 0;
        target.deadline_steady_ns = request.deadline_ns;
        target.simulation_time = request.simulation_time;
        target.requested_steady_ns = request.requested_ns;
        target.started_steady_ns = started_ns;
        target.finished_steady_ns = 0;
        const double alpha = request.config->target ? std::max(0.0, std::min(1.0,
            request.config->duration > 0.0 ? (request.simulation_time - request.config->start_time) /
                request.config->duration : 1.0)) : 0.0;
        target.weather_alpha = alpha;
        std::array<DynamicOceanPhysicsField *, 3> builder_ptrs{};
        std::array<const Cascade *, 3> cascade_ptrs{};
        std::array<std::array<std::vector<std::complex<double>>, DynamicOceanPhysicsField::FIELD_COUNT / 2> *, 3> packed_outputs{};
        std::array<WeatherBandContext, 3> weather_contexts{};
        std::array<DynamicOceanBandPreparation, 3> weather_preparations{};
        for (size_t band = 0; band < 3; ++band) {
            const auto &source = (*request.config->source)[band];
            const auto &destination = request.config->target ? (*request.config->target)[band] : source;
            auto &working = working_cascades_[band];
            // The lattice/dispersion is immutable. Only H0 and choppiness vary.
            // Round the shared H0 once to the renderer's upload format, then
            // consume exactly that representation in the CPU FFT.
            const bool interpolating = request.config->target && alpha > 0.0 && alpha < 1.0;
            if (interpolating || previous_version != request.config->version || previous_alpha != alpha) {
                weather_contexts[band] = {&working, &source, &destination, &target.production_h0[band], alpha, use_avx2_};
                weather_preparations[band] = {&prepare_weather_band, &weather_contexts[band]};
            }
            target.choppiness[band] = source.production_choppiness +
                (destination.production_choppiness - source.production_choppiness) * alpha;
            target.wind_x[band] = source.production_wind_x + (destination.production_wind_x - source.production_wind_x) * alpha;
            target.wind_z[band] = source.production_wind_z + (destination.production_wind_z - source.production_wind_z) * alpha;
            target.wind_speed[band] = source.production_wind_speed + (destination.production_wind_speed - source.production_wind_speed) * alpha;
            builder_ptrs[band] = &builders_[band];
            cascade_ptrs[band] = interpolating ? &working : (alpha >= 1.0 ? &destination : &source);
            packed_outputs[band] = &target.bands[band].packed_fields;
            target.bands[band].resolution = source.material_resolution;
            target.bands[band].domain_m = source.material_domain_m;
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
            packed_outputs, request.simulation_time, use_avx2_, &batch_profile, &weather_preparations);
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
            if (config_superseded || superseded_by_pause) {
                ++stats_.discarded_obsolete;
                ++stats_.obsolete_builds;
                if (!has_latest_request_ && config_) {
                    // A configuration may have changed without a time advance.
                    latest_request_.tick_id = request.tick_id;
                    latest_request_.simulation_time = request.simulation_time;
                    latest_request_.requested_ns = steady_now_ns_();
                    latest_request_.deadline_ns = latest_request_.requested_ns;
                    latest_request_.config = config_;
                    latest_request_.requires_build = true;
                    has_latest_request_ = true;
                    latest_request_requires_build_ = true;
                    ++stats_.requests;
                }
            } else if (built) {
                target.generation = stats_.publications + 2;
                target.finished_steady_ns = finished_ns;
                ready_buffers_[static_cast<size_t>(target_index)] = true;
            } else {
                ++stats_.discarded_obsolete;
                ++stats_.obsolete_builds;
            }
            refresh_state_locked_();
        }
        buffer_released_.notify_all();
    }
}

} // namespace oq
