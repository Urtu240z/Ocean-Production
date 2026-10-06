#include "dynamic_ocean_physics_field.h"
#include "dynamic_ocean_fft_avx2.h"

#include <algorithm>
#include <cmath>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace oq {
namespace {
constexpr double TAU = 6.283185307179586476925286766559;

struct CubicValueDerivative { double value; double derivative; };

CubicValueDerivative catmull_rom(const double p0, const double p1, const double p2,
        const double p3, const double t) {
    const double a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3;
    const double b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3;
    const double c = -0.5 * p0 + 0.5 * p2;
    return {((a * t + b) * t + c) * t + p1, (3.0 * a * t + 2.0 * b) * t + c};
}

int wrap_index(const int value, const int size) {
    const int remainder = value % size;
    return remainder < 0 ? remainder + size : remainder;
}

struct WorkBatch { std::mutex mutex; std::condition_variable ready; size_t remaining = 0; };
struct WorkTask { void (*function)(void *) = nullptr; void *context = nullptr; WorkBatch *batch = nullptr; };
struct PrepareContext {
    DynamicOceanPhysicsField *field;
    const Cascade *cascade;
    double time;
    bool use_avx2;
    DynamicOceanBandPreparation input;
};
using PackedFieldPairs = std::array<std::vector<std::complex<double>>, DynamicOceanPhysicsField::FIELD_COUNT / 2>;
struct TransformContext {
    DynamicOceanPhysicsField *field;
    size_t pair;
    bool use_avx2;
    std::vector<double> *output_fields;
    PackedFieldPairs *packed_output_fields;
};
using ProfileClock = std::chrono::steady_clock;

uint64_t elapsed_us(ProfileClock::time_point begin, ProfileClock::time_point end) {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(end - begin).count());
}

class PersistentFftPool {
public:
    PersistentFftPool() {
        unsigned int available = std::thread::hardware_concurrency();
        // Leave one physical core available for Godot/main-thread work and do
        // not treat SMT logical processors as full FFT workers.
        const unsigned int physical_estimate = available > 1 ? available / 2 : 1;
        const unsigned int worker_count = std::clamp(physical_estimate > 1 ? physical_estimate - 1 : 1, 1u, 6u);
        start_workers_(worker_count);
    }
    ~PersistentFftPool() {
        stop_workers_();
    }
    int set_worker_count(int count) {
        const unsigned int desired = static_cast<unsigned int>(std::clamp(count, 1, 6));
        if (desired == workers_.size()) return static_cast<int>(workers_.size());
        stop_workers_();
        start_workers_(desired);
        return static_cast<int>(workers_.size());
    }
    int worker_count() const { return static_cast<int>(workers_.size()); }
    void run(WorkTask *tasks, size_t count, uint64_t *queue_us = nullptr, uint64_t *barrier_us = nullptr) {
        if (count == 0) return;
        const auto enqueue_begin = ProfileClock::now();
        WorkBatch batch;
        batch.remaining = count;
        {
            std::unique_lock<std::mutex> lock(queue_mutex_);
            queue_space_.wait(lock, [&] { return queue_count_ + count <= queue_.size(); });
            for (size_t i = 0; i < count; ++i) {
                tasks[i].batch = &batch;
                queue_[queue_tail_] = tasks[i];
                queue_tail_ = (queue_tail_ + 1) % queue_.size();
                ++queue_count_;
            }
        }
        const auto queued = ProfileClock::now();
        if (queue_us != nullptr) *queue_us = elapsed_us(enqueue_begin, queued);
        queue_ready_.notify_all();
        std::unique_lock<std::mutex> lock(batch.mutex);
        batch.ready.wait(lock, [&] { return batch.remaining == 0; });
        if (barrier_us != nullptr) *barrier_us = elapsed_us(queued, ProfileClock::now());
    }
private:
    void start_workers_(unsigned int count) {
        {
            std::lock_guard<std::mutex> lock(queue_mutex_);
            stopping_ = false;
            queue_head_ = queue_tail_ = queue_count_ = 0;
        }
        workers_.reserve(count);
        for (unsigned int i = 0; i < count; ++i) workers_.emplace_back([this] { worker_(); });
    }
    void stop_workers_() {
        { std::lock_guard<std::mutex> lock(queue_mutex_); stopping_ = true; }
        queue_ready_.notify_all();
        for (auto &worker : workers_) if (worker.joinable()) worker.join();
        workers_.clear();
    }
    void worker_() {
        for (;;) {
            WorkTask task;
            {
                std::unique_lock<std::mutex> lock(queue_mutex_);
                queue_ready_.wait(lock, [&] { return stopping_ || queue_count_ > 0; });
                if (stopping_ && queue_count_ == 0) return;
                task = queue_[queue_head_];
                queue_head_ = (queue_head_ + 1) % queue_.size();
                --queue_count_;
            }
            queue_space_.notify_one();
            task.function(task.context);
            {
                std::lock_guard<std::mutex> lock(task.batch->mutex);
                --task.batch->remaining;
            }
            task.batch->ready.notify_one();
        }
    }
    std::array<WorkTask, 64> queue_{};
    std::vector<std::thread> workers_;
    std::mutex queue_mutex_;
    std::condition_variable queue_ready_, queue_space_;
    size_t queue_head_ = 0, queue_tail_ = 0, queue_count_ = 0;
    bool stopping_ = false;
};

PersistentFftPool &fft_pool() { static PersistentFftPool pool; return pool; }

inline double wrap_positive(double value, double period) {
    double wrapped = std::fmod(value, period);
    if (wrapped < 0.0) wrapped += period;
    return wrapped;
}
} // namespace

int DynamicOceanPhysicsField::set_worker_count(int count) { return fft_pool().set_worker_count(count); }
int DynamicOceanPhysicsField::worker_count() { return fft_pool().worker_count(); }

bool DynamicOceanPhysicsField::configure(const Cascade &cascade, bool allocate_spatial_fields) {
    const int resolution = cascade.material_resolution;
    if (resolution < 2 || (resolution & (resolution - 1)) != 0 ||
        cascade.material_domain_m <= 0.0 || cascade.kx.size() != static_cast<size_t>(resolution) * resolution ||
        cascade.h0_re.size() != cascade.kx.size() || cascade.h0n_re.size() != cascade.kx.size()) {
        ready_ = false;
        return false;
    }
    const bool same_shape = n_ == resolution && domain_m_ == cascade.material_domain_m &&
        phase_cos_.size() == cascade.kx.size();
    const size_t field_value_count = static_cast<size_t>(FIELD_COUNT) * static_cast<size_t>(resolution) * resolution;
    if (same_shape) {
        if (allocate_spatial_fields && fields_.size() != field_value_count) fields_.resize(field_value_count);
        return true;
    }
    n_ = resolution;
    domain_m_ = cascade.material_domain_m;
    const size_t count = static_cast<size_t>(n_) * n_;
    if (allocate_spatial_fields) fields_.resize(static_cast<size_t>(FIELD_COUNT) * count);
    else fields_.clear();
    phase_cos_.resize(count); phase_sin_.resize(count);
    rotor_cos_.resize(count); rotor_sin_.resize(count);
    evolved_h_re_.resize(count); evolved_h_im_.resize(count);
    evolved_v_re_.resize(count); evolved_v_im_.resize(count);
    phase_ready_ = false; rotor_ready_ = false;
    phase_updates_since_rebase_ = 0;
    bit_reverse_.resize(static_cast<size_t>(n_));
    stage_count_ = 0;
    int bits = 0;
    for (int value = n_; value > 1; value >>= 1) ++bits;
    if (bits >= static_cast<int>(stage_offsets_.size())) return false;
    for (uint32_t i = 0; i < static_cast<uint32_t>(n_); ++i) {
        uint32_t source = i, destination = 0;
        for (int bit = 0; bit < bits; ++bit) { destination = (destination << 1) | (source & 1u); source >>= 1; }
        bit_reverse_[i] = destination;
    }
    stage_count_ = bits;
    twiddle_real_.resize(static_cast<size_t>(n_ - 1));
    twiddle_imag_.resize(static_cast<size_t>(n_ - 1));
    twiddle_real_dup_.resize(static_cast<size_t>(n_ - 1) * 2);
    twiddle_imag_dup_.resize(static_cast<size_t>(n_ - 1) * 2);
    size_t twiddle_offset = 0;
    for (int stage = 0, length = 2; stage < stage_count_; ++stage, length <<= 1) {
        stage_offsets_[stage] = twiddle_offset;
        const int half = length >> 1;
        const double angle = TAU / static_cast<double>(length);
        for (int j = 0; j < half; ++j) {
            twiddle_real_[twiddle_offset + j] = std::cos(angle * j);
            twiddle_imag_[twiddle_offset + j] = std::sin(angle * j);
            twiddle_real_dup_[(twiddle_offset + j) * 2] = twiddle_real_[twiddle_offset + j];
            twiddle_real_dup_[(twiddle_offset + j) * 2 + 1] = twiddle_real_[twiddle_offset + j];
            twiddle_imag_dup_[(twiddle_offset + j) * 2] = twiddle_imag_[twiddle_offset + j];
            twiddle_imag_dup_[(twiddle_offset + j) * 2 + 1] = twiddle_imag_[twiddle_offset + j];
        }
        twiddle_offset += static_cast<size_t>(half);
    }
    for (size_t pair = 0; pair < spectra_.size(); ++pair) {
        if (lite_mode_ && pair != 0) {
            spectra_[pair].clear();
            fft_scratch_[pair].clear();
            lite_packed_output_[pair].clear();
            continue;
        }
        spectra_[pair].resize(count);
        fft_scratch_[pair].resize(count);
    }
    ready_ = false;
    return true;
}

bool DynamicOceanPhysicsField::configure_lite(const Cascade &source, int resolution) {
    const int source_n = source.material_resolution;
    if (resolution < 2 || (resolution & (resolution - 1)) != 0 ||
        source_n < resolution || (source_n & (source_n - 1)) != 0 ||
        source.material_domain_m <= 0.0) return false;
    const size_t source_count = static_cast<size_t>(source_n) * source_n;
    const std::vector<double> *source_arrays[] = {
        &source.kx, &source.ky, &source.omega, &source.a1, &source.a2,
        &source.c11, &source.c12, &source.c21, &source.c22, &source.parity,
        &source.weight, &source.h0_re, &source.h0_im, &source.h0n_re, &source.h0n_im
    };
    for (const auto *values : source_arrays) if (values->size() != source_count) return false;

    Cascade reduced;
    reduced.material_resolution = resolution;
    reduced.material_domain_m = source.material_domain_m;
    reduced.inv_n2 = 1.0 / (static_cast<double>(resolution) * resolution);
    reduced.production_choppiness = source.production_choppiness;
    reduced.production_gravity = source.production_gravity;
    reduced.production_wind_x = source.production_wind_x;
    reduced.production_wind_z = source.production_wind_z;
    reduced.production_wind_speed = source.production_wind_speed;
    reduced.regular_frequency_step = source.regular_frequency_step;
    reduced.regular_frequency_grid = source.regular_frequency_grid;
    reduced.separable_frequency_grid = source.separable_frequency_grid;
    const size_t count = static_cast<size_t>(resolution) * resolution;
    for (auto *values : {&reduced.kx, &reduced.ky, &reduced.omega, &reduced.a1, &reduced.a2,
                         &reduced.c11, &reduced.c12, &reduced.c21, &reduced.c22, &reduced.parity,
                         &reduced.weight, &reduced.h0_re, &reduced.h0_im, &reduced.h0n_re, &reduced.h0n_im})
        values->resize(count);

    // Production bins are centered in the 256² source. Keep identical signed
    // integer k bins. Excluding |k| == Nlite/2 avoids folding the distinct
    // source +Nyquist/-Nyquist bins onto one destination bin.
    const int source_center = source_n / 2;
    const int target_center = resolution / 2;
    const double coefficient_scale = static_cast<double>(resolution) * resolution /
        (static_cast<double>(source_n) * source_n);
    // The published grid is sampled at texel centers. Keep the world-space
    // sample origin fixed when texel spacing changes by rotating each retained
    // coefficient by k·(offset_source-offset_target).
    const double sample_origin_delta = source.material_domain_m *
        (0.5 / resolution - 0.5 / source_n);
    for (int y = 0; y < resolution; ++y) {
        const int ky_bin = y - target_center;
        if (std::abs(ky_bin) >= target_center) continue;
        const int source_y = source_center + ky_bin;
        for (int x = 0; x < resolution; ++x) {
            const int kx_bin = x - target_center;
            if (std::abs(kx_bin) >= target_center) continue;
            const int source_x = source_center + kx_bin;
            const size_t destination = static_cast<size_t>(y) * resolution + x;
            const size_t original = static_cast<size_t>(source_y) * source_n + source_x;
            const double angle = (source.kx[original] + source.ky[original]) * sample_origin_delta;
            const double cosine = std::cos(angle), sine = std::sin(angle);
            reduced.kx[destination] = source.kx[original];
            reduced.ky[destination] = source.ky[original];
            reduced.omega[destination] = source.omega[original];
            reduced.a1[destination] = source.a1[original];
            reduced.a2[destination] = source.a2[original];
            reduced.c11[destination] = source.c11[original];
            reduced.c12[destination] = source.c12[original];
            reduced.c21[destination] = source.c21[original];
            reduced.c22[destination] = source.c22[original];
            reduced.parity[destination] = source.parity[original];
            reduced.weight[destination] = source.weight[original];
            reduced.h0_re[destination] = (source.h0_re[original] * cosine - source.h0_im[original] * sine) * coefficient_scale;
            reduced.h0_im[destination] = (source.h0_re[original] * sine + source.h0_im[original] * cosine) * coefficient_scale;
            reduced.h0n_re[destination] = (source.h0n_re[original] * cosine - source.h0n_im[original] * sine) * coefficient_scale;
            reduced.h0n_im[destination] = (source.h0n_re[original] * sine + source.h0n_im[original] * cosine) * coefficient_scale;
        }
    }
    lite_mode_ = true;
    lite_cascade_ = std::move(reduced);
    return configure(lite_cascade_, false);
}

void DynamicOceanPhysicsField::reset_phase_history() {
    phase_ready_ = false;
    rotor_ready_ = false;
    phase_updates_since_rebase_ = 0;
    phase_time_ = 0.0;
}

std::complex<double> DynamicOceanPhysicsField::multiply_i_(std::complex<double> value, double scale) {
    return {-value.imag() * scale, value.real() * scale};
}

void DynamicOceanPhysicsField::set_spectrum_(std::complex<double> &packed,
                                              std::complex<double> first,
                                              std::complex<double> second) {
    // Encode two Hermitian spectra F and G in one complex IFFT F + iG.
    packed = {first.real() - second.imag(), first.imag() + second.real()};
}

void DynamicOceanPhysicsField::inverse_fft_2d_(std::vector<std::complex<double>> &values, int n,
                                                std::vector<std::complex<double>> &scratch,
                                                const std::vector<uint32_t> &bit_reverse,
                                                const std::vector<double> &twiddle_real,
                                                const std::vector<double> &twiddle_imag,
                                                const std::vector<double> &twiddle_real_dup,
                                                const std::vector<double> &twiddle_imag_dup,
                                                const std::array<size_t, 32> &stage_offsets,
                                                int stage_count, bool use_avx2,
                                                std::array<uint64_t, 4> *stage_profile_us) {
    const auto row_x_begin = ProfileClock::now();
    if (use_avx2) {
        for (int y = 0; y < n; ++y) inverse_fft_1d_avx2(values.data() + static_cast<size_t>(y) * n, n,
            bit_reverse.data(), twiddle_real.data(), twiddle_imag.data(),
            twiddle_real_dup.data(), twiddle_imag_dup.data(),
            stage_offsets.data(), stage_count);
    } else {
        for (int y = 0; y < n; ++y) {
            auto *row = values.data() + static_cast<size_t>(y) * n;
            for (int i = 0; i < n; ++i) {
                const uint32_t j = bit_reverse[static_cast<size_t>(i)];
                if (static_cast<uint32_t>(i) < j) std::swap(row[i], row[j]);
            }
            for (int stage = 0, length = 2; stage < stage_count; ++stage, length <<= 1) {
                const int half = length >> 1;
                for (int base = 0; base < n; base += length) {
                    for (int j = 0; j < half; ++j) {
                        const size_t twiddle_index = stage_offsets[stage] + static_cast<size_t>(j);
                        const std::complex<double> twiddle(twiddle_real[twiddle_index], twiddle_imag[twiddle_index]);
                        const auto even = row[base + j];
                        const auto odd = row[base + j + half] * twiddle;
                        row[base + j] = even + odd;
                        row[base + j + half] = even - odd;
                    }
                }
            }
            const double scale = 1.0 / static_cast<double>(n);
            for (int i = 0; i < n; ++i) row[i] *= scale;
        }
    }
    const auto row_x_end = ProfileClock::now();
    const auto transpose_begin = row_x_end;
    // Cache-block the matrix transpose: the unblocked version walked one of
    // the two 256x256 buffers with a full-row stride on every store.
    constexpr int TRANSPOSE_TILE = 16;
    for (int y0 = 0; y0 < n; y0 += TRANSPOSE_TILE) {
        for (int x0 = 0; x0 < n; x0 += TRANSPOSE_TILE) {
            const int y_end = std::min(y0 + TRANSPOSE_TILE, n);
            const int x_end = std::min(x0 + TRANSPOSE_TILE, n);
            for (int y = y0; y < y_end; ++y) {
                const size_t source_row = static_cast<size_t>(y) * n;
                for (int x = x0; x < x_end; ++x)
                    scratch[static_cast<size_t>(x) * n + y] = values[source_row + x];
            }
        }
    }
    const auto transpose_end = ProfileClock::now();
    const auto row_z_begin = transpose_end;
    if (use_avx2) {
        for (int y = 0; y < n; ++y) inverse_fft_1d_avx2(scratch.data() + static_cast<size_t>(y) * n, n,
            bit_reverse.data(), twiddle_real.data(), twiddle_imag.data(),
            twiddle_real_dup.data(), twiddle_imag_dup.data(), stage_offsets.data(), stage_count);
    } else {
        for (int y = 0; y < n; ++y) {
            auto *row = scratch.data() + static_cast<size_t>(y) * n;
            for (int i = 0; i < n; ++i) {
                const uint32_t j = bit_reverse[static_cast<size_t>(i)];
                if (static_cast<uint32_t>(i) < j) std::swap(row[i], row[j]);
            }
            for (int stage = 0, length = 2; stage < stage_count; ++stage, length <<= 1) {
                const int half = length >> 1;
                for (int base = 0; base < n; base += length) {
                    for (int j = 0; j < half; ++j) {
                        const size_t twiddle_index = stage_offsets[stage] + static_cast<size_t>(j);
                        const std::complex<double> twiddle(twiddle_real[twiddle_index], twiddle_imag[twiddle_index]);
                        const auto even = row[base + j];
                        const auto odd = row[base + j + half] * twiddle;
                        row[base + j] = even + odd;
                        row[base + j + half] = even - odd;
                    }
                }
            }
            const double scale = 1.0 / static_cast<double>(n);
            for (int i = 0; i < n; ++i) row[i] *= scale;
        }
    }
    const auto row_z_end = ProfileClock::now();
    if (stage_profile_us != nullptr) {
        (*stage_profile_us)[0] += elapsed_us(row_x_begin, row_x_end);
        (*stage_profile_us)[1] += elapsed_us(transpose_begin, transpose_end);
        (*stage_profile_us)[2] += elapsed_us(row_z_begin, row_z_end);
        // The inverse is left in transposed scratch layout. Unpacking reads
        // scratch[x * N + y] directly into the canonical [y * N + x] fields,
        // so restoring the complex work array would only add a full copy pass.
        (*stage_profile_us)[3] += 0;
    }
}

void DynamicOceanPhysicsField::advance_phase_(const Cascade &cascade, double simulation_time, bool use_avx2) {
    const size_t count = static_cast<size_t>(n_) * n_;
    if (!phase_ready_ || simulation_time < phase_time_ || simulation_time - phase_time_ > 0.25) {
        if (use_avx2) {
            initialize_phase_avx2(cascade.omega.data(), simulation_time, phase_cos_.data(), phase_sin_.data(), count);
        } else {
            for (size_t i = 0; i < count; ++i) {
                const double angle = cascade.omega[i] * simulation_time;
                phase_cos_[i] = std::cos(angle); phase_sin_[i] = std::sin(angle);
            }
        }
        phase_time_ = simulation_time;
        phase_updates_since_rebase_ = 0;
        phase_ready_ = true;
        rotor_ready_ = false;
        return;
    }
    const double delta = simulation_time - phase_time_;
    if (delta <= 1.0e-12) return;
    if (!rotor_ready_ || std::abs(delta - rotor_dt_) > 1.0e-10) {
        if (use_avx2) {
            build_rotor_avx2(cascade.omega.data(), delta, rotor_cos_.data(), rotor_sin_.data(), count);
        } else {
            for (size_t i = 0; i < count; ++i) {
                const double angle = cascade.omega[i] * delta;
                rotor_cos_[i] = std::cos(angle); rotor_sin_[i] = std::sin(angle);
            }
        }
        rotor_dt_ = delta;
        rotor_ready_ = true;
    }
    if (use_avx2) {
        advance_phase_avx2(phase_cos_.data(), phase_sin_.data(), rotor_cos_.data(), rotor_sin_.data(), count);
    } else {
        for (size_t i = 0; i < count; ++i) {
            const double c = phase_cos_[i], s = phase_sin_[i];
            phase_cos_[i] = c * rotor_cos_[i] - s * rotor_sin_[i];
            phase_sin_[i] = c * rotor_sin_[i] + s * rotor_cos_[i];
        }
    }
    phase_time_ = simulation_time;
    if (++phase_updates_since_rebase_ >= 600) {
        if (use_avx2) {
            initialize_phase_avx2(cascade.omega.data(), simulation_time, phase_cos_.data(), phase_sin_.data(), count);
        } else {
            for (size_t i = 0; i < count; ++i) {
                const double angle = cascade.omega[i] * simulation_time;
                phase_cos_[i] = std::cos(angle); phase_sin_[i] = std::sin(angle);
            }
        }
        phase_updates_since_rebase_ = 0;
    }
}

void DynamicOceanPhysicsField::prepare_(const Cascade &cascade, double simulation_time, bool use_avx2,
        const DynamicOceanBandPreparation &input) {
    profile_ = {};
    ready_ = false;
    build_valid_ = false;
    const size_t count = static_cast<size_t>(n_) * n_;
    if (cascade.kx.size() != count || cascade.h0_re.size() != count || cascade.h0_im.size() != count ||
        cascade.h0n_re.size() != count || cascade.h0n_im.size() != count || cascade.omega.size() != count) {
        return;
    }

    using Clock = std::chrono::steady_clock;
    const auto evolution_begin = Clock::now();
    auto stage_begin = Clock::now();
    advance_phase_(cascade, simulation_time, use_avx2);
    auto stage_end = Clock::now();
    profile_.phase_us = elapsed_us(stage_begin, stage_end);
    stage_begin = stage_end;
    if (use_avx2) {
        evolve_height_velocity_avx2(cascade.omega.data(), cascade.h0_re.data(), cascade.h0_im.data(),
            cascade.h0n_re.data(), cascade.h0n_im.data(), phase_cos_.data(), phase_sin_.data(),
            evolved_h_re_.data(), evolved_h_im_.data(), evolved_v_re_.data(), evolved_v_im_.data(), count,
            input.weather_delta, input.weather_alpha_dot);
    } else {
        for (size_t i = 0; i < count; ++i) {
            const double cw = phase_cos_[i], sw = phase_sin_[i];
            const double ar = cascade.h0_re[i] * cw + cascade.h0_im[i] * sw;
            const double ai = -cascade.h0_re[i] * sw + cascade.h0_im[i] * cw;
            const double br = cascade.h0n_re[i] * cw - cascade.h0n_im[i] * sw;
            const double bi = cascade.h0n_re[i] * sw + cascade.h0n_im[i] * cw;
            evolved_h_re_[i] = ar + br;
            evolved_h_im_[i] = ai + bi;
            evolved_v_re_[i] = cascade.omega[i] * (ai - bi);
            evolved_v_im_[i] = cascade.omega[i] * (-ar + br);
            if (input.weather_alpha_dot != 0.0) {
                const auto &d = *input.weather_delta;
                const double dr = d.h0_re[i], di = d.h0_im[i];
                const double nr = d.h0n_re[i], ni = d.h0n_im[i];
                evolved_v_re_[i] += ((dr + nr) * cw + (di - ni) * sw) * input.weather_alpha_dot;
                evolved_v_im_[i] += ((di + ni) * cw + (nr - dr) * sw) * input.weather_alpha_dot;
            }
        }
    }
    stage_end = Clock::now();
    profile_.evolve_us = elapsed_us(stage_begin, stage_end);
    stage_begin = stage_end;
    if (lite_mode_) {
        // The scalar HEIGHT and VERTICAL_VELOCITY spectra are each Hermitian.
        // Packing H+iV therefore produces two independent real spatial fields
        // in one complex IFFT: IFFT(H+iV) = IFFT(H) + i*IFFT(V).
        for (size_t i = 0; i < count; ++i) {
            const std::complex<double> h(evolved_h_re_[i], evolved_h_im_[i]);
            const std::complex<double> v(evolved_v_re_[i], evolved_v_im_[i]);
            const double parity = cascade.parity[i] * cascade.weight[i];
            set_spectrum_(spectra_[0][i], h * parity, v * parity);
        }
    } else {
        // Six complex transforms produce twelve real physics fields. Pairing
        // F+iG is valid because every requested output is a real Hermitian field.
        std::complex<double> *packed[6];
        for (size_t pair = 0; pair < spectra_.size(); ++pair) packed[pair] = spectra_[pair].data();
        const DynamicOceanEvolutionBuffers evolution{phase_cos_.data(), phase_sin_.data(),
            evolved_h_re_.data(), evolved_h_im_.data(), evolved_v_re_.data(), evolved_v_im_.data()};
        const size_t prefix = use_avx2 ? prepare_physics_spectra_avx2(cascade, evolution, packed,
            input.weather_delta, input.weather_alpha_dot, count) : 0;
        for (size_t i = prefix; i < count; ++i) {
        const std::complex<double> h(evolved_h_re_[i], evolved_h_im_[i]);
        const std::complex<double> v(evolved_v_re_[i], evolved_v_im_[i]);
        const double kx = cascade.kx[i], kz = cascade.ky[i];
        const double a1 = cascade.a1[i], a2 = cascade.a2[i];
        const double parity = cascade.parity[i] * cascade.weight[i];
        const double ax_dot = input.weather_alpha_dot != 0.0 ?
            input.weather_delta->a1[i] * input.weather_alpha_dot : 0.0;
        const double az_dot = input.weather_alpha_dot != 0.0 ?
            input.weather_delta->a2[i] * input.weather_alpha_dot : 0.0;
        const std::complex<double> values[FIELD_COUNT] = {
            h, multiply_i_(h, -a1), multiply_i_(h, -a2),
            multiply_i_(h, kx), multiply_i_(h, kz),
            h * cascade.c11[i], h * cascade.c12[i], h * cascade.c21[i], h * cascade.c22[i],
            v, multiply_i_(v, -a1) + multiply_i_(h, -ax_dot), multiply_i_(v, -a2) + multiply_i_(h, -az_dot)
        };
        for (size_t pair = 0; pair < spectra_.size(); ++pair)
            set_spectrum_(spectra_[pair][i], values[pair * 2] * parity, values[pair * 2 + 1] * parity);
        }
    }
    stage_end = Clock::now();
    profile_.packing_us = elapsed_us(stage_begin, stage_end);
    profile_.frequency_prepare_us = elapsed_us(stage_begin, stage_end);
    const auto evolution_end = Clock::now();
    evolution_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(evolution_end - evolution_begin).count());
    transform_pair_us_.fill(0);
    build_valid_ = true;
}

void DynamicOceanPhysicsField::transform_pair_(size_t pair_index, bool use_avx2,
        std::vector<double> *output_fields, std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> *packed_output_fields) {
    if (!build_valid_ || pair_index >= spectra_.size()) return;
    using Clock = std::chrono::steady_clock;
    const auto begin = Clock::now();
    const size_t count = static_cast<size_t>(n_) * n_;
    // The packed publisher swaps this scratch vector with the destination.
    // Re-establish the transform's exact working size before every reuse: the
    // previous destination may have had a different capacity/size.
    fft_scratch_[pair_index].resize(count);
    std::array<uint64_t, 4> stage_profile{};
    inverse_fft_2d_(spectra_[pair_index], n_, fft_scratch_[pair_index], bit_reverse_,
                    twiddle_real_, twiddle_imag_, twiddle_real_dup_, twiddle_imag_dup_,
                    stage_offsets_, stage_count_, use_avx2, &stage_profile);
    if (packed_output_fields != nullptr) {
        // Keep the IFFT result transposed in its existing scratch allocation
        // and swap ownership into the immutable snapshot. No unpack/copy pass.
        const auto publish_begin = Clock::now();
        (*packed_output_fields)[pair_index].swap(fft_scratch_[pair_index]);
        transform_stage_us_[pair_index] = {stage_profile[0], stage_profile[1], stage_profile[2],
            stage_profile[3], elapsed_us(publish_begin, Clock::now())};
        transform_pair_us_[pair_index] = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - begin).count());
        return;
    }
    if (output_fields == nullptr) return;
    const size_t f0 = pair_index * 2, f1 = f0 + 1;
    const auto unpack_begin = Clock::now();
    constexpr int TILE = 16;
    const auto &transformed = fft_scratch_[pair_index];
    for (int y0 = 0; y0 < n_; y0 += TILE) {
        for (int x0 = 0; x0 < n_; x0 += TILE) {
            const int y_end = std::min(y0 + TILE, n_);
            const int x_end = std::min(x0 + TILE, n_);
            // Tile the transposed source while keeping destination stores in
            // canonical row-major order; this fuses the old return transpose
            // with the real/imaginary unpack pass.
            for (int y = y0; y < y_end; ++y) {
                for (int x = x0; x < x_end; ++x) {
                    const size_t index = static_cast<size_t>(y) * n_ + x;
                    const size_t source = static_cast<size_t>(x) * n_ + y;
                    const double checkerboard = ((x + y) & 1) == 0 ? 1.0 : -1.0;
                    (*output_fields)[f0 * count + index] = transformed[source].real() * checkerboard;
                    (*output_fields)[f1 * count + index] = transformed[source].imag() * checkerboard;
                }
            }
        }
    }
    const auto unpack_end = Clock::now();
    transform_stage_us_[pair_index] = {stage_profile[0], stage_profile[1], stage_profile[2],
        stage_profile[3], elapsed_us(unpack_begin, unpack_end)};
    transform_pair_us_[pair_index] = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - begin).count());
}

void DynamicOceanPhysicsField::finish_build_(double simulation_time) {
    transforms_us_ = 0;
    profile_.row_x_us = profile_.transpose_to_columns_us = profile_.row_z_us = 0;
    profile_.transpose_back_us = profile_.unpack_us = 0;
    for (size_t pair = 0; pair < transform_pair_us_.size(); ++pair) {
        transforms_us_ += transform_pair_us_[pair];
        profile_.row_x_us += transform_stage_us_[pair][0];
        profile_.transpose_to_columns_us += transform_stage_us_[pair][1];
        profile_.row_z_us += transform_stage_us_[pair][2];
        profile_.transpose_back_us += transform_stage_us_[pair][3];
        profile_.unpack_us += transform_stage_us_[pair][4];
    }
    simulation_time_ = simulation_time;
    ready_ = true;
}

void DynamicOceanPhysicsField::prepare_task_(void *context) {
    auto *task = static_cast<PrepareContext *>(context);
    if (task->input.function != nullptr) task->input.function(task->input.context);
    task->field->prepare_(*task->cascade, task->time, task->use_avx2, task->input);
}

void DynamicOceanPhysicsField::transform_task_(void *context) {
    auto *task = static_cast<TransformContext *>(context);
    task->field->transform_pair_(task->pair, task->use_avx2, task->output_fields, task->packed_output_fields);
}

bool DynamicOceanPhysicsField::build_all(const std::array<DynamicOceanPhysicsField *, 3> &fields,
                                         const std::array<const Cascade *, 3> &cascades,
                                         double simulation_time, bool use_avx2) {
    std::array<std::vector<double> *, 3> outputs{};
    for (size_t band = 0; band < fields.size(); ++band) {
        if (fields[band] != nullptr) outputs[band] = &fields[band]->fields_;
    }
    return build_all_into(fields, cascades, outputs, simulation_time, use_avx2);
}

bool DynamicOceanPhysicsField::build_all_into(const std::array<DynamicOceanPhysicsField *, 3> &fields,
                                               const std::array<const Cascade *, 3> &cascades,
                                               const std::array<std::vector<double> *, 3> &output_fields,
                                               double simulation_time, bool use_avx2,
                                               DynamicOceanBatchProfile *batch_profile) {
    std::array<std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> *, 3> packed_outputs{};
    return build_all_outputs_(fields, cascades, output_fields, packed_outputs,
        simulation_time, use_avx2, batch_profile);
}

bool DynamicOceanPhysicsField::build_all_packed_into(const std::array<DynamicOceanPhysicsField *, 3> &fields,
        const std::array<const Cascade *, 3> &cascades,
        const std::array<std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> *, 3> &packed_outputs,
        double simulation_time, bool use_avx2, DynamicOceanBatchProfile *batch_profile,
        const std::array<DynamicOceanBandPreparation, 3> *band_preparations) {
    std::array<std::vector<double> *, 3> outputs{};
    return build_all_outputs_(fields, cascades, outputs, packed_outputs,
        simulation_time, use_avx2, batch_profile, band_preparations);
}

bool DynamicOceanPhysicsField::build_all_outputs_(const std::array<DynamicOceanPhysicsField *, 3> &fields,
        const std::array<const Cascade *, 3> &cascades,
        const std::array<std::vector<double> *, 3> &output_fields,
        const std::array<std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> *, 3> &packed_output_fields,
        double simulation_time, bool use_avx2, DynamicOceanBatchProfile *batch_profile,
        const std::array<DynamicOceanBandPreparation, 3> *band_preparations) {
    std::array<PrepareContext, 3> prepare_contexts{};
    std::array<WorkTask, 3> prepare_tasks{};
    std::array<TransformContext, 18> transform_contexts{};
    std::array<WorkTask, 18> transform_tasks{};
    size_t prepare_count = 0, transform_count = 0;
    for (size_t band = 0; band < fields.size(); ++band) {
        if (fields[band] == nullptr || cascades[band] == nullptr) continue;
        const bool has_double_output = output_fields[band] != nullptr;
        const bool has_packed_output = packed_output_fields[band] != nullptr;
        if (has_double_output == has_packed_output) return false;
        if (!fields[band]->configure(*cascades[band], has_double_output && output_fields[band] == &fields[band]->fields_)) return false;
        fields[band]->ready_ = false;
        prepare_contexts[prepare_count] = {fields[band], cascades[band], simulation_time, use_avx2,
            band_preparations != nullptr ? (*band_preparations)[band] : DynamicOceanBandPreparation{}};
        prepare_tasks[prepare_count] = {&DynamicOceanPhysicsField::prepare_task_, &prepare_contexts[prepare_count], nullptr};
        ++prepare_count;
        for (size_t pair = 0; pair < FIELD_COUNT / 2; ++pair) {
            transform_contexts[transform_count] = {fields[band], pair, use_avx2,
                output_fields[band], packed_output_fields[band]};
            transform_tasks[transform_count] = {&DynamicOceanPhysicsField::transform_task_, &transform_contexts[transform_count], nullptr};
            ++transform_count;
        }
    }
    if (prepare_count == 0) return false;
    if (batch_profile != nullptr) *batch_profile = {};
    fft_pool().run(prepare_tasks.data(), prepare_count,
        batch_profile != nullptr ? &batch_profile->prepare_queue_us : nullptr,
        batch_profile != nullptr ? &batch_profile->prepare_barrier_us : nullptr);
    for (size_t i = 0; i < prepare_count; ++i) {
        if (!prepare_contexts[i].field->build_valid_) return false;
    }
    fft_pool().run(transform_tasks.data(), transform_count,
        batch_profile != nullptr ? &batch_profile->transform_queue_us : nullptr,
        batch_profile != nullptr ? &batch_profile->transform_barrier_us : nullptr);
    for (size_t i = 0; i < prepare_count; ++i) prepare_contexts[i].field->finish_build_(simulation_time);
    return true;
}

bool DynamicOceanPhysicsField::build(const Cascade &cascade, double simulation_time) {
    if (n_ != cascade.material_resolution || domain_m_ != cascade.material_domain_m) {
        if (!configure(cascade)) return false;
    }
    std::array<DynamicOceanPhysicsField *, 3> fields{this, nullptr, nullptr};
    std::array<const Cascade *, 3> cascades{&cascade, nullptr, nullptr};
    return build_all(fields, cascades, simulation_time, false);
}

bool DynamicOceanPhysicsField::build_lite(double simulation_time, bool use_avx2) {
    if (!lite_mode_ || !std::isfinite(simulation_time)) return false;
    ready_ = false;
    prepare_(lite_cascade_, simulation_time, use_avx2, DynamicOceanBandPreparation{});
    if (!build_valid_) return false;
    transform_pair_(0, use_avx2, nullptr, &lite_packed_output_);
    finish_build_(simulation_time);
    return ready_ && lite_packed_output_[0].size() == static_cast<size_t>(n_) * n_;
}

bool DynamicOceanPhysicsField::sample_lite_surface(double world_x, double world_z,
        double sea_level, double *out, int interpolation_mode) const {
    if (out == nullptr) return false;
    double height = 0.0, vy = 0.0, dhx = 0.0, dhz = 0.0;
    if (!sample_lite_height_velocity_gradient(world_x, world_z, sea_level,
            &height, &vy, &dhx, &dhz, interpolation_mode)) return false;
    const double inverse_length = 1.0 / std::sqrt(dhx * dhx + 1.0 + dhz * dhz);
    out[0] = height;
    out[1] = vy;
    out[2] = -dhx * inverse_length;
    out[3] = inverse_length;
    out[4] = -dhz * inverse_length;
    return true;
}

bool DynamicOceanPhysicsField::sample_lite_height_velocity_gradient(double world_x, double world_z,
        double sea_level, double *out_height, double *out_vertical_velocity,
        double *out_dh_dx, double *out_dh_dz, int interpolation_mode) const {
    if (!ready_ || !lite_mode_ || out_height == nullptr || out_vertical_velocity == nullptr ||
        out_dh_dx == nullptr || out_dh_dz == nullptr || !std::isfinite(world_x) ||
        !std::isfinite(world_z) || !std::isfinite(sea_level) ||
        lite_packed_output_[0].size() != static_cast<size_t>(n_) * n_) return false;
    const double offset = domain_m_ * 0.5 - domain_m_ / (2.0 * n_);
    const double gx = wrap_positive(world_x + offset, domain_m_) * n_ / domain_m_;
    const double gy = wrap_positive(world_z + offset, domain_m_) * n_ / domain_m_;
    const double floor_x = std::floor(gx), floor_y = std::floor(gy);
    const int x0 = static_cast<int>(floor_x) % n_;
    const int y0 = static_cast<int>(floor_y) % n_;
    const int x1 = (x0 + 1) % n_, y1 = (y0 + 1) % n_;
    const double u = gx - floor_x, v = gy - floor_y;
    auto at = [&](int x, int y) {
        const size_t index = static_cast<size_t>(x) * n_ + y;
        const double sign = ((x + y) & 1) == 0 ? 1.0 : -1.0;
        return lite_packed_output_[0][index] * sign;
    };
    const auto p00 = at(x0, y0), p10 = at(x1, y0);
    const auto p01 = at(x0, y1), p11 = at(x1, y1);
    const double h00 = p00.real(), h10 = p10.real(), h01 = p01.real(), h11 = p11.real();
    const double v00 = p00.imag(), v10 = p10.imag(), v01 = p01.imag(), v11 = p11.imag();
    const double one_minus_u = 1.0 - u, one_minus_v = 1.0 - v;
    if (interpolation_mode == 1) {
        double height_rows[4]{}, velocity_rows[4]{}, dx_rows[4]{};
        for (int row = 0; row < 4; ++row) {
            const int y = wrap_index(y0 + row - 1, n_);
            double h[4]{}, vy[4]{};
            for (int column = 0; column < 4; ++column) {
                const auto packed = at(wrap_index(x0 + column - 1, n_), y);
                h[column] = packed.real();
                vy[column] = packed.imag();
            }
            const CubicValueDerivative h_x = catmull_rom(h[0], h[1], h[2], h[3], u);
            const CubicValueDerivative v_x = catmull_rom(vy[0], vy[1], vy[2], vy[3], u);
            height_rows[row] = h_x.value;
            dx_rows[row] = h_x.derivative;
            velocity_rows[row] = v_x.value;
        }
        const CubicValueDerivative h_z = catmull_rom(height_rows[0], height_rows[1], height_rows[2], height_rows[3], v);
        const CubicValueDerivative vy_z = catmull_rom(velocity_rows[0], velocity_rows[1], velocity_rows[2], velocity_rows[3], v);
        const CubicValueDerivative dx_z = catmull_rom(dx_rows[0], dx_rows[1], dx_rows[2], dx_rows[3], v);
        const double spacing = domain_m_ / n_;
        *out_height = sea_level + h_z.value;
        *out_vertical_velocity = vy_z.value;
        *out_dh_dx = dx_z.value / spacing;
        *out_dh_dz = h_z.derivative / spacing;
        return true;
    }
    const double h0 = h00 * one_minus_u + h10 * u;
    const double h1 = h01 * one_minus_u + h11 * u;
    const double vy0 = v00 * one_minus_u + v10 * u;
    const double vy1 = v01 * one_minus_u + v11 * u;
    const double spacing = domain_m_ / n_;
    *out_height = sea_level + h0 * one_minus_v + h1 * v;
    *out_vertical_velocity = vy0 * one_minus_v + vy1 * v;
    *out_dh_dx = (one_minus_v * (h10 - h00) + v * (h11 - h01)) / spacing;
    *out_dh_dz = (one_minus_u * (h01 - h00) + u * (h11 - h10)) / spacing;
    return true;
}

size_t DynamicOceanPhysicsField::lite_memory_bytes() const {
    size_t bytes = 0;
    auto add = [&](const std::vector<double> &values) { bytes += values.capacity() * sizeof(double); };
    auto add_complex = [&](const std::vector<std::complex<double>> &values) { bytes += values.capacity() * sizeof(std::complex<double>); };
    for (const auto *values : {&lite_cascade_.kx, &lite_cascade_.ky, &lite_cascade_.omega,
            &lite_cascade_.a1, &lite_cascade_.a2, &lite_cascade_.c11, &lite_cascade_.c12,
            &lite_cascade_.c21, &lite_cascade_.c22, &lite_cascade_.parity, &lite_cascade_.weight,
            &lite_cascade_.h0_re, &lite_cascade_.h0_im, &lite_cascade_.h0n_re, &lite_cascade_.h0n_im}) add(*values);
    for (const auto *values : {&phase_cos_, &phase_sin_, &rotor_cos_, &rotor_sin_,
            &evolved_h_re_, &evolved_h_im_, &evolved_v_re_, &evolved_v_im_,
            &twiddle_real_, &twiddle_imag_, &twiddle_real_dup_, &twiddle_imag_dup_}) add(*values);
    for (const auto &values : spectra_) add_complex(values);
    for (const auto &values : fft_scratch_) add_complex(values);
    add_complex(lite_packed_output_[0]);
    bytes += bit_reverse_.capacity() * sizeof(uint32_t);
    return bytes;
}

uint64_t DynamicOceanPhysicsField::lite_ifft_us() const {
    const auto &stages = transform_stage_us_[0];
    return stages[0] + stages[1] + stages[2] + stages[3];
}

uint64_t DynamicOceanPhysicsField::lite_publication_us() const {
    return transform_stage_us_[0][4];
}

uint64_t DynamicOceanPhysicsField::lite_row_x_us() const { return transform_stage_us_[0][0]; }
uint64_t DynamicOceanPhysicsField::lite_transpose_us() const { return transform_stage_us_[0][1]; }
uint64_t DynamicOceanPhysicsField::lite_row_z_us() const { return transform_stage_us_[0][2]; }

bool DynamicOceanPhysicsField::sample_lite_direct_spectrum(double world_x, double world_z,
        double *out_height_vy) const {
    return sample_direct_spectrum(lite_cascade_, world_x, world_z, out_height_vy);
}

bool DynamicOceanPhysicsField::sample_direct_spectrum(const Cascade &cascade, double world_x,
        double world_z, double *out_height_vy) const {
    if (!ready_ || out_height_vy == nullptr || !std::isfinite(world_x) ||
        !std::isfinite(world_z)) return false;
    const size_t count = static_cast<size_t>(cascade.material_resolution) * cascade.material_resolution;
    if (cascade.kx.size() != count || cascade.ky.size() != count || cascade.omega.size() != count ||
        cascade.parity.size() != count || cascade.weight.size() != count ||
        evolved_h_re_.size() != count || evolved_h_im_.size() != count ||
        evolved_v_re_.size() != count || evolved_v_im_.size() != count) return false;
    const double offset = cascade.material_domain_m * 0.5 -
        cascade.material_domain_m / (2.0 * cascade.material_resolution);
    const double px = world_x + offset, pz = world_z + offset;
    double height = 0.0, velocity = 0.0, gradient_x = 0.0, gradient_z = 0.0;
    for (size_t i = 0; i < count; ++i) {
        const double phase = cascade.kx[i] * px + cascade.ky[i] * pz;
        const double cosine = std::cos(phase), sine = std::sin(phase);
        const double scale = cascade.parity[i] * cascade.weight[i] * cascade.inv_n2;
        const double mode_height = (evolved_h_re_[i] * cosine - evolved_h_im_[i] * sine) * scale;
        const double mode_imaginary = (evolved_h_re_[i] * sine + evolved_h_im_[i] * cosine) * scale;
        height += mode_height;
        velocity += (evolved_v_re_[i] * cosine - evolved_v_im_[i] * sine) * scale;
        gradient_x -= cascade.kx[i] * mode_imaginary;
        gradient_z -= cascade.ky[i] * mode_imaginary;
    }
    out_height_vy[0] = height;
    out_height_vy[1] = velocity;
    out_height_vy[2] = gradient_x;
    out_height_vy[3] = gradient_z;
    return true;
}

std::array<double, 4> DynamicOceanPhysicsField::measure_phase_recurrence_error(
        const Cascade &cascade, double start_time, double delta_time, bool use_avx2) const {
    constexpr std::array<int, 4> checkpoints{1, 60, 600, 3600};
    std::array<double, 4> maximum_h_error{};
    const size_t count = cascade.omega.size();
    std::vector<double> phase_cos(count), phase_sin(count), rotor_cos(count), rotor_sin(count);
    if (use_avx2) {
        initialize_phase_avx2(cascade.omega.data(), start_time, phase_cos.data(), phase_sin.data(), count);
        build_rotor_avx2(cascade.omega.data(), delta_time, rotor_cos.data(), rotor_sin.data(), count);
    } else {
        for (size_t i = 0; i < count; ++i) {
            const double start_angle = cascade.omega[i] * start_time;
            const double step_angle = cascade.omega[i] * delta_time;
            phase_cos[i] = std::cos(start_angle); phase_sin[i] = std::sin(start_angle);
            rotor_cos[i] = std::cos(step_angle); rotor_sin[i] = std::sin(step_angle);
        }
    }
    size_t checkpoint = 0;
    for (int frame = 1; frame <= checkpoints.back(); ++frame) {
        if (use_avx2) advance_phase_avx2(phase_cos.data(), phase_sin.data(), rotor_cos.data(), rotor_sin.data(), count);
        else for (size_t i = 0; i < count; ++i) {
                const double c = phase_cos[i], s = phase_sin[i];
                phase_cos[i] = c * rotor_cos[i] - s * rotor_sin[i];
                phase_sin[i] = c * rotor_sin[i] + s * rotor_cos[i];
            }
        if (frame % 600 == 0) {
            const double absolute_time = start_time + delta_time * frame;
            if (use_avx2) initialize_phase_avx2(cascade.omega.data(), absolute_time, phase_cos.data(), phase_sin.data(), count);
            else for (size_t i = 0; i < count; ++i) {
                    const double angle = cascade.omega[i] * absolute_time;
                    phase_cos[i] = std::cos(angle); phase_sin[i] = std::sin(angle);
                }
        }
        if (checkpoint >= checkpoints.size() || frame != checkpoints[checkpoint]) continue;
        const double absolute_time = start_time + delta_time * frame;
        for (size_t i = 0; i < count; ++i) {
            const double angle = cascade.omega[i] * absolute_time;
            const double c = std::cos(angle), s = std::sin(angle);
            const double ar = cascade.h0_re[i] * c + cascade.h0_im[i] * s;
            const double ai = -cascade.h0_re[i] * s + cascade.h0_im[i] * c;
            const double br = cascade.h0n_re[i] * c - cascade.h0n_im[i] * s;
            const double bi = cascade.h0n_re[i] * s + cascade.h0n_im[i] * c;
            const double rr = cascade.h0_re[i] * phase_cos[i] + cascade.h0_im[i] * phase_sin[i];
            const double ri = -cascade.h0_re[i] * phase_sin[i] + cascade.h0_im[i] * phase_cos[i];
            const double sr = cascade.h0n_re[i] * phase_cos[i] - cascade.h0n_im[i] * phase_sin[i];
            const double si = cascade.h0n_re[i] * phase_sin[i] + cascade.h0n_im[i] * phase_cos[i];
            const double error = std::hypot((rr + sr) - (ar + br), (ri + si) - (ai + bi));
            maximum_h_error[checkpoint] = std::max(maximum_h_error[checkpoint], error);
        }
        ++checkpoint;
    }
    return maximum_h_error;
}

double DynamicOceanPhysicsField::sample_field_(Field field, double fft_qx, double fft_qz) const {
    return sample_field_from_(fields_, n_, domain_m_, field, fft_qx, fft_qz);
}

double DynamicOceanPhysicsField::sample_field_from_(const std::vector<double> &fields, int resolution,
                                                      double domain_m, Field field, double fft_qx, double fft_qz) {
    const double gx = wrap_positive(fft_qx, domain_m) * resolution / domain_m;
    const double gy = wrap_positive(fft_qz, domain_m) * resolution / domain_m;
    const int x0 = static_cast<int>(std::floor(gx)) % resolution;
    const int y0 = static_cast<int>(std::floor(gy)) % resolution;
    const int x1 = (x0 + 1) % resolution, y1 = (y0 + 1) % resolution;
    const double fx = gx - std::floor(gx), fy = gy - std::floor(gy);
    const size_t count = static_cast<size_t>(resolution) * resolution;
    const size_t base = static_cast<size_t>(field) * count;
    const double a = fields[base + static_cast<size_t>(y0) * resolution + x0];
    const double b = fields[base + static_cast<size_t>(y0) * resolution + x1];
    const double c = fields[base + static_cast<size_t>(y1) * resolution + x0];
    const double d = fields[base + static_cast<size_t>(y1) * resolution + x1];
    return (a + (b - a) * fx) * (1.0 - fy) + (c + (d - c) * fx) * fy;
}

bool DynamicOceanPhysicsField::sample_material_q(double material_qx, double material_qz, double *out) const {
    if (!ready_ || out == nullptr) return false;
    return sample_material_q_from(fields_, n_, domain_m_, material_qx, material_qz, out);
}

double DynamicOceanPhysicsField::horizontal_displacement_bound() const {
    const size_t count = static_cast<size_t>(n_) * n_;
    if (fields_.size() != FIELD_COUNT * count) return 0.0;
    double maximum_squared = 0.0;
    for (size_t i = 0; i < count; ++i) {
        const double x = fields_[DISPLACE_X * count + i];
        const double z = fields_[DISPLACE_Z * count + i];
        maximum_squared = std::max(maximum_squared, x * x + z * z);
    }
    return std::sqrt(maximum_squared);
}

bool DynamicOceanPhysicsField::sample_material_q_from(const std::vector<double> &fields, int resolution,
                                                        double domain_m, double material_qx,
                                                        double material_qz, double *out) {
    if (out == nullptr || resolution <= 0 || domain_m <= 0.0 ||
        fields.size() != static_cast<size_t>(FIELD_COUNT) * resolution * resolution) return false;
    double fft_qx = 0.0, fft_qz = 0.0;
    // Apply the canonical Production material-Q -> FFT-Q conversion once.
    const double offset = domain_m * 0.5 - domain_m / (2.0 * resolution);
    fft_qx = wrap_positive(material_qx + offset, domain_m);
    fft_qz = wrap_positive(material_qz + offset, domain_m);
    for (size_t f = 0; f < FIELD_COUNT; ++f)
        out[f] = sample_field_from_(fields, resolution, domain_m, static_cast<Field>(f), fft_qx, fft_qz);
    return true;
}

bool DynamicOceanPhysicsField::sample_material_q_packed_from(
        const std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> &fields,
        int resolution, double domain_m, double material_qx, double material_qz, double *out) {
    if (out == nullptr || resolution <= 0 || domain_m <= 0.0) return false;
    const size_t count = static_cast<size_t>(resolution) * resolution;
    for (const auto &pair : fields) if (pair.size() != count) return false;
    const double offset = domain_m * 0.5 - domain_m / (2.0 * resolution);
    const double fft_qx = wrap_positive(material_qx + offset, domain_m);
    const double fft_qz = wrap_positive(material_qz + offset, domain_m);
    const double gx = fft_qx * resolution / domain_m;
    const double gy = fft_qz * resolution / domain_m;
    const int x0 = static_cast<int>(std::floor(gx)) % resolution;
    const int y0 = static_cast<int>(std::floor(gy)) % resolution;
    const int x1 = (x0 + 1) % resolution, y1 = (y0 + 1) % resolution;
    const double fx = gx - std::floor(gx), fy = gy - std::floor(gy);
    for (size_t pair_index = 0; pair_index < fields.size(); ++pair_index) {
        auto value = [&](int x, int y) {
            const double sign = ((x + y) & 1) == 0 ? 1.0 : -1.0;
            return fields[pair_index][static_cast<size_t>(x) * resolution + y] * sign;
        };
        const auto a = value(x0, y0), b = value(x1, y0);
        const auto c = value(x0, y1), d = value(x1, y1);
        const std::complex<double> interpolated =
            (a + (b - a) * fx) * (1.0 - fy) + (c + (d - c) * fx) * fy;
        out[pair_index * 2] = interpolated.real();
        out[pair_index * 2 + 1] = interpolated.imag();
    }
    return true;
}

} // namespace oq
