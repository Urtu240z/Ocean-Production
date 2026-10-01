#include "dynamic_ocean_physics_field.h"

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
struct PrepareContext { DynamicOceanPhysicsField *field; const Cascade *cascade; double time; };
struct TransformContext { DynamicOceanPhysicsField *field; size_t pair; };

class PersistentFftPool {
public:
    PersistentFftPool() {
        unsigned int available = std::thread::hardware_concurrency();
        // Leave one physical core available for Godot/main-thread work and do
        // not treat SMT logical processors as full FFT workers.
        const unsigned int physical_estimate = available > 1 ? available / 2 : 1;
        const unsigned int worker_count = std::clamp(physical_estimate > 1 ? physical_estimate - 1 : 1, 1u, 11u);
        workers_.reserve(worker_count);
        for (unsigned int i = 0; i < worker_count; ++i) workers_.emplace_back([this] { worker_(); });
    }
    ~PersistentFftPool() {
        { std::lock_guard<std::mutex> lock(queue_mutex_); stopping_ = true; }
        queue_ready_.notify_all();
        for (auto &worker : workers_) if (worker.joinable()) worker.join();
    }
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

bool DynamicOceanPhysicsField::configure(const Cascade &cascade) {
    const int resolution = cascade.material_resolution;
    if (resolution < 2 || (resolution & (resolution - 1)) != 0 ||
        cascade.material_domain_m <= 0.0 || cascade.kx.size() != static_cast<size_t>(resolution) * resolution ||
        cascade.h0_re.size() != cascade.kx.size() || cascade.h0n_re.size() != cascade.kx.size()) {
        ready_ = false;
        return false;
    }
    n_ = resolution;
    domain_m_ = cascade.material_domain_m;
    const size_t count = static_cast<size_t>(n_) * n_;
    fields_.resize(static_cast<size_t>(FIELD_COUNT) * count);
    for (size_t pair = 0; pair < spectra_.size(); ++pair) {
        spectra_[pair].resize(count);
        fft_scratch_[pair].resize(count);
    }
    ready_ = false;
    return true;
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

void DynamicOceanPhysicsField::inverse_fft_1d_(std::complex<double> *values, int n) {
    // Iterative radix-2 IFFT with positive twiddles, matching Stockham's sign.
    for (int i = 1, j = 0; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(values[i], values[j]);
    }
    for (int length = 2; length <= n; length <<= 1) {
        const double angle = TAU / static_cast<double>(length);
        const std::complex<double> root(std::cos(angle), std::sin(angle));
        for (int base = 0; base < n; base += length) {
            std::complex<double> twiddle(1.0, 0.0);
            const int half = length >> 1;
            for (int j = 0; j < half; ++j) {
                const auto even = values[base + j];
                const auto odd = values[base + j + half] * twiddle;
                values[base + j] = even + odd;
                values[base + j + half] = even - odd;
                twiddle *= root;
            }
        }
    }
    const double scale = 1.0 / static_cast<double>(n);
    for (int i = 0; i < n; ++i) values[i] *= scale;
}

void DynamicOceanPhysicsField::inverse_fft_2d_(std::vector<std::complex<double>> &values, int n,
                                                std::vector<std::complex<double>> &scratch) {
    for (int y = 0; y < n; ++y) inverse_fft_1d_(values.data() + static_cast<size_t>(y) * n, n);
    // Transpose to make the second axis contiguous and cache-friendly.
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) scratch[static_cast<size_t>(x) * n + y] = values[static_cast<size_t>(y) * n + x];
    }
    for (int y = 0; y < n; ++y) inverse_fft_1d_(scratch.data() + static_cast<size_t>(y) * n, n);
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) values[static_cast<size_t>(y) * n + x] = scratch[static_cast<size_t>(x) * n + y];
    }
}

void DynamicOceanPhysicsField::prepare_(const Cascade &cascade, double simulation_time) {
    ready_ = false;
    build_valid_ = false;
    const size_t count = static_cast<size_t>(n_) * n_;
    if (cascade.kx.size() != count || cascade.h0_re.size() != count || cascade.h0_im.size() != count ||
        cascade.h0n_re.size() != count || cascade.h0n_im.size() != count || cascade.omega.size() != count) {
        return;
    }

    using Clock = std::chrono::steady_clock;
    const auto evolution_begin = Clock::now();
    // Six complex transforms produce twelve real physics fields. Pairing
    // F+iG is valid because every requested output is a real Hermitian field.
    for (size_t i = 0; i < count; ++i) {
        const double wt = cascade.omega[i] * simulation_time;
        const double cw = std::cos(wt), sw = std::sin(wt);
        const double ar = cascade.h0_re[i] * cw + cascade.h0_im[i] * sw;
        const double ai = -cascade.h0_re[i] * sw + cascade.h0_im[i] * cw;
        const double br = cascade.h0n_re[i] * cw - cascade.h0n_im[i] * sw;
        const double bi = cascade.h0n_re[i] * sw + cascade.h0n_im[i] * cw;
        const std::complex<double> h(ar + br, ai + bi);
        const double omega = cascade.omega[i];
        const std::complex<double> v(omega * (ai - bi), omega * (-ar + br));
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

void DynamicOceanPhysicsField::transform_pair_(size_t pair_index) {
    if (!build_valid_ || pair_index >= spectra_.size()) return;
    using Clock = std::chrono::steady_clock;
    const auto begin = Clock::now();
    inverse_fft_2d_(spectra_[pair_index], n_, fft_scratch_[pair_index]);
    const size_t count = static_cast<size_t>(n_) * n_;
    const size_t f0 = pair_index * 2, f1 = f0 + 1;
    for (int y = 0; y < n_; ++y) {
        for (int x = 0; x < n_; ++x) {
            const size_t index = static_cast<size_t>(y) * n_ + x;
            const double checkerboard = ((x + y) & 1) == 0 ? 1.0 : -1.0;
            fields_[f0 * count + index] = spectra_[pair_index][index].real() * checkerboard;
            fields_[f1 * count + index] = spectra_[pair_index][index].imag() * checkerboard;
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
    task->field->prepare_(*task->cascade, task->time);
}

void DynamicOceanPhysicsField::transform_task_(void *context) {
    auto *task = static_cast<TransformContext *>(context);
    task->field->transform_pair_(task->pair);
}

bool DynamicOceanPhysicsField::build_all(const std::array<DynamicOceanPhysicsField *, 3> &fields,
                                         const std::array<const Cascade *, 3> &cascades,
                                         double simulation_time) {
    std::array<PrepareContext, 3> prepare_contexts{};
    std::array<WorkTask, 3> prepare_tasks{};
    std::array<TransformContext, 18> transform_contexts{};
    std::array<WorkTask, 18> transform_tasks{};
    size_t prepare_count = 0, transform_count = 0;
    for (size_t band = 0; band < fields.size(); ++band) {
        if (fields[band] == nullptr || cascades[band] == nullptr) continue;
        if (fields[band]->n_ != cascades[band]->material_resolution ||
            fields[band]->domain_m_ != cascades[band]->material_domain_m) {
            if (!fields[band]->configure(*cascades[band])) return false;
        }
        fields[band]->ready_ = false;
        prepare_contexts[prepare_count] = {fields[band], cascades[band], simulation_time};
        prepare_tasks[prepare_count] = {&DynamicOceanPhysicsField::prepare_task_, &prepare_contexts[prepare_count], nullptr};
        ++prepare_count;
        for (size_t pair = 0; pair < FIELD_COUNT / 2; ++pair) {
            transform_contexts[transform_count] = {fields[band], pair};
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
    return build_all(fields, cascades, simulation_time);
}

double DynamicOceanPhysicsField::sample_field_(Field field, double fft_qx, double fft_qz) const {
    const double gx = wrap_positive(fft_qx, domain_m_) * n_ / domain_m_;
    const double gy = wrap_positive(fft_qz, domain_m_) * n_ / domain_m_;
    const int x0 = static_cast<int>(std::floor(gx)) % n_;
    const int y0 = static_cast<int>(std::floor(gy)) % n_;
    const int x1 = (x0 + 1) % n_, y1 = (y0 + 1) % n_;
    const double fx = gx - std::floor(gx), fy = gy - std::floor(gy);
    const size_t count = static_cast<size_t>(n_) * n_;
    const size_t base = static_cast<size_t>(field) * count;
    const double a = fields_[base + static_cast<size_t>(y0) * n_ + x0];
    const double b = fields_[base + static_cast<size_t>(y0) * n_ + x1];
    const double c = fields_[base + static_cast<size_t>(y1) * n_ + x0];
    const double d = fields_[base + static_cast<size_t>(y1) * n_ + x1];
    return (a + (b - a) * fx) * (1.0 - fy) + (c + (d - c) * fx) * fy;
}

bool DynamicOceanPhysicsField::sample_material_q(double material_qx, double material_qz, double *out) const {
    if (!ready_ || out == nullptr) return false;
    double fft_qx = 0.0, fft_qz = 0.0;
    // Apply the canonical Production material-Q -> FFT-Q conversion once.
    const double offset = domain_m_ * 0.5 - domain_m_ / (2.0 * n_);
    fft_qx = wrap_positive(material_qx + offset, domain_m_);
    fft_qz = wrap_positive(material_qz + offset, domain_m_);
    for (size_t f = 0; f < FIELD_COUNT; ++f) out[f] = sample_field_(static_cast<Field>(f), fft_qx, fft_qz);
    return true;
}

} // namespace oq
