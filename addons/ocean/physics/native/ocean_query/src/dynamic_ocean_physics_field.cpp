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

struct WorkBatch { std::mutex mutex; std::condition_variable ready; size_t remaining = 0; };
struct WorkTask { void (*function)(void *) = nullptr; void *context = nullptr; WorkBatch *batch = nullptr; };
struct PrepareContext { DynamicOceanPhysicsField *field; const Cascade *cascade; double time; bool use_avx2; };
struct TransformContext { DynamicOceanPhysicsField *field; size_t pair; bool use_avx2; std::vector<double> *output_fields; };

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
    void run(WorkTask *tasks, size_t count) {
        if (count == 0) return;
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
        queue_ready_.notify_all();
        std::unique_lock<std::mutex> lock(batch.mutex);
        batch.ready.wait(lock, [&] { return batch.remaining == 0; });
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
    size_t twiddle_offset = 0;
    for (int stage = 0, length = 2; stage < stage_count_; ++stage, length <<= 1) {
        stage_offsets_[stage] = twiddle_offset;
        const int half = length >> 1;
        const double angle = TAU / static_cast<double>(length);
        for (int j = 0; j < half; ++j) {
            twiddle_real_[twiddle_offset + j] = std::cos(angle * j);
            twiddle_imag_[twiddle_offset + j] = std::sin(angle * j);
        }
        twiddle_offset += static_cast<size_t>(half);
    }
    for (size_t pair = 0; pair < spectra_.size(); ++pair) {
        spectra_[pair].resize(count);
        fft_scratch_[pair].resize(count);
    }
    ready_ = false;
    return true;
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
                                                const std::array<size_t, 32> &stage_offsets,
                                                int stage_count, bool use_avx2) {
    if (use_avx2) {
        for (int y = 0; y < n; ++y) inverse_fft_1d_avx2(values.data() + static_cast<size_t>(y) * n, n,
            bit_reverse.data(), twiddle_real.data(), twiddle_imag.data(), stage_offsets.data(), stage_count);
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
    // Transpose to make the second axis contiguous and cache-friendly.
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) scratch[static_cast<size_t>(x) * n + y] = values[static_cast<size_t>(y) * n + x];
    }
    if (use_avx2) {
        for (int y = 0; y < n; ++y) inverse_fft_1d_avx2(scratch.data() + static_cast<size_t>(y) * n, n,
            bit_reverse.data(), twiddle_real.data(), twiddle_imag.data(), stage_offsets.data(), stage_count);
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
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) values[static_cast<size_t>(y) * n + x] = scratch[static_cast<size_t>(x) * n + y];
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

void DynamicOceanPhysicsField::prepare_(const Cascade &cascade, double simulation_time, bool use_avx2) {
    ready_ = false;
    build_valid_ = false;
    const size_t count = static_cast<size_t>(n_) * n_;
    if (cascade.kx.size() != count || cascade.h0_re.size() != count || cascade.h0_im.size() != count ||
        cascade.h0n_re.size() != count || cascade.h0n_im.size() != count || cascade.omega.size() != count) {
        return;
    }

    using Clock = std::chrono::steady_clock;
    const auto evolution_begin = Clock::now();
    advance_phase_(cascade, simulation_time, use_avx2);
    if (use_avx2) {
        evolve_height_velocity_avx2(cascade.omega.data(), cascade.h0_re.data(), cascade.h0_im.data(),
            cascade.h0n_re.data(), cascade.h0n_im.data(), phase_cos_.data(), phase_sin_.data(),
            evolved_h_re_.data(), evolved_h_im_.data(), evolved_v_re_.data(), evolved_v_im_.data(), count);
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
        }
    }
    // Six complex transforms produce twelve real physics fields. Pairing
    // F+iG is valid because every requested output is a real Hermitian field.
    for (size_t i = 0; i < count; ++i) {
        const double hr = evolved_h_re_[i], hi = evolved_h_im_[i];
        const double vr = evolved_v_re_[i], vi = evolved_v_im_[i];
        const std::complex<double> h(hr, hi);
        const std::complex<double> v(vr, vi);
        const double kx = cascade.kx[i], kz = cascade.ky[i];
        const double a1 = cascade.a1[i], a2 = cascade.a2[i];
        const double parity = cascade.parity[i] * cascade.weight[i];
        const std::complex<double> values[FIELD_COUNT] = {
            h,
            multiply_i_(h, -a1),
            multiply_i_(h, -a2),
            // i*k*H; its real spatial value is -k*Im(H), matching the
            // direct authority's material derivative convention.
            multiply_i_(h, kx),
            multiply_i_(h, kz),
            h * cascade.c11[i], h * cascade.c12[i], h * cascade.c21[i], h * cascade.c22[i],
            v, multiply_i_(v, -a1), multiply_i_(v, -a2)
        };
        for (size_t pair = 0; pair < spectra_.size(); ++pair) {
            set_spectrum_(spectra_[pair][i], values[pair * 2] * parity, values[pair * 2 + 1] * parity);
        }
    }
    const auto evolution_end = Clock::now();
    evolution_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(evolution_end - evolution_begin).count());
    transform_pair_us_.fill(0);
    build_valid_ = true;
}

void DynamicOceanPhysicsField::transform_pair_(size_t pair_index, bool use_avx2, std::vector<double> &output_fields) {
    if (!build_valid_ || pair_index >= spectra_.size()) return;
    using Clock = std::chrono::steady_clock;
    const auto begin = Clock::now();
    inverse_fft_2d_(spectra_[pair_index], n_, fft_scratch_[pair_index], bit_reverse_,
                    twiddle_real_, twiddle_imag_, stage_offsets_, stage_count_, use_avx2);
    const size_t count = static_cast<size_t>(n_) * n_;
    const size_t f0 = pair_index * 2, f1 = f0 + 1;
    for (int y = 0; y < n_; ++y) {
        for (int x = 0; x < n_; ++x) {
            const size_t index = static_cast<size_t>(y) * n_ + x;
            const double checkerboard = ((x + y) & 1) == 0 ? 1.0 : -1.0;
            output_fields[f0 * count + index] = spectra_[pair_index][index].real() * checkerboard;
            output_fields[f1 * count + index] = spectra_[pair_index][index].imag() * checkerboard;
        }
    }
    transform_pair_us_[pair_index] = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - begin).count());
}

void DynamicOceanPhysicsField::finish_build_(double simulation_time) {
    transforms_us_ = 0;
    for (uint64_t elapsed : transform_pair_us_) transforms_us_ += elapsed;
    simulation_time_ = simulation_time;
    ready_ = true;
}

void DynamicOceanPhysicsField::prepare_task_(void *context) {
    auto *task = static_cast<PrepareContext *>(context);
    task->field->prepare_(*task->cascade, task->time, task->use_avx2);
}

void DynamicOceanPhysicsField::transform_task_(void *context) {
    auto *task = static_cast<TransformContext *>(context);
    task->field->transform_pair_(task->pair, task->use_avx2, *task->output_fields);
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
                                               double simulation_time, bool use_avx2) {
    std::array<PrepareContext, 3> prepare_contexts{};
    std::array<WorkTask, 3> prepare_tasks{};
    std::array<TransformContext, 18> transform_contexts{};
    std::array<WorkTask, 18> transform_tasks{};
    size_t prepare_count = 0, transform_count = 0;
    for (size_t band = 0; band < fields.size(); ++band) {
        if (fields[band] == nullptr || cascades[band] == nullptr) continue;
        if (output_fields[band] == nullptr) return false;
        if (!fields[band]->configure(*cascades[band], output_fields[band] == &fields[band]->fields_)) return false;
        fields[band]->ready_ = false;
        prepare_contexts[prepare_count] = {fields[band], cascades[band], simulation_time, use_avx2};
        prepare_tasks[prepare_count] = {&DynamicOceanPhysicsField::prepare_task_, &prepare_contexts[prepare_count], nullptr};
        ++prepare_count;
        for (size_t pair = 0; pair < FIELD_COUNT / 2; ++pair) {
            transform_contexts[transform_count] = {fields[band], pair, use_avx2, output_fields[band]};
            transform_tasks[transform_count] = {&DynamicOceanPhysicsField::transform_task_, &transform_contexts[transform_count], nullptr};
            ++transform_count;
        }
    }
    if (prepare_count == 0) return false;
    fft_pool().run(prepare_tasks.data(), prepare_count);
    for (size_t i = 0; i < prepare_count; ++i) {
        if (!prepare_contexts[i].field->build_valid_) return false;
    }
    fft_pool().run(transform_tasks.data(), transform_count);
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

} // namespace oq
