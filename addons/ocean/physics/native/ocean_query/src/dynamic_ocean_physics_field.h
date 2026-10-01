#pragma once

#include "ocean_query_core.h"

#include <array>
#include <complex>
#include <cstdint>
#include <vector>

namespace oq {

// Synchronous CPU mirror of one Production Stockham FFT band. This prototype
// owns a periodic material field and never accesses RenderingDevice/Godot APIs.
class DynamicOceanPhysicsField {
public:
    enum Field : size_t {
        HEIGHT = 0, DISPLACE_X, DISPLACE_Z, HEIGHT_DX, HEIGHT_DZ,
        DISPLACE_XX, DISPLACE_XZ, DISPLACE_ZX, DISPLACE_ZZ,
        VELOCITY_Y, VELOCITY_X, VELOCITY_Z, FIELD_COUNT
    };

    bool configure(const Cascade &cascade);
    bool build(const Cascade &cascade, double simulation_time);
    static bool build_all(const std::array<DynamicOceanPhysicsField *, 3> &fields,
                          const std::array<const Cascade *, 3> &cascades,
                          double simulation_time, bool use_avx2 = false);
    static int set_worker_count(int count);
    static int worker_count();
    bool sample_material_q(double material_qx, double material_qz, double *out) const;
    bool ready() const { return ready_; }
    int resolution() const { return n_; }
    double domain_size_m() const { return domain_m_; }
    double simulation_time() const { return simulation_time_; }
    size_t memory_bytes() const { return fields_.size() * sizeof(double); }
    uint64_t evolution_us() const { return evolution_us_; }
    uint64_t transforms_us() const { return transforms_us_; }
    std::array<double, 4> measure_phase_recurrence_error(const Cascade &cascade,
                                                        double start_time, double delta_time,
                                                        bool use_avx2) const;

private:
    static void inverse_fft_2d_(std::vector<std::complex<double>> &values, int n,
                                std::vector<std::complex<double>> &scratch,
                                const std::vector<uint32_t> &bit_reverse,
                                const std::vector<double> &twiddle_real,
                                const std::vector<double> &twiddle_imag,
                                const std::array<size_t, 32> &stage_offsets,
                                int stage_count, bool use_avx2);
    static std::complex<double> multiply_i_(std::complex<double> value, double scale);
    static void set_spectrum_(std::complex<double> &packed,
                              std::complex<double> first, std::complex<double> second);
    void prepare_(const Cascade &cascade, double simulation_time, bool use_avx2);
    void advance_phase_(const Cascade &cascade, double simulation_time, bool use_avx2);
    void transform_pair_(size_t pair_index, bool use_avx2);
    void finish_build_(double simulation_time);
    static void prepare_task_(void *context);
    static void transform_task_(void *context);
    double sample_field_(Field field, double fft_qx, double fft_qz) const;

    int n_ = 0;
    double domain_m_ = 0.0;
    double simulation_time_ = 0.0;
    bool ready_ = false;
    uint64_t evolution_us_ = 0;
    uint64_t transforms_us_ = 0;
    std::vector<double> fields_;
    std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> spectra_;
    std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> fft_scratch_;
    std::vector<double> phase_cos_, phase_sin_, rotor_cos_, rotor_sin_;
    std::vector<double> evolved_h_re_, evolved_h_im_, evolved_v_re_, evolved_v_im_;
    double phase_time_ = 0.0, rotor_dt_ = 0.0;
    uint64_t phase_updates_since_rebase_ = 0;
    bool phase_ready_ = false, rotor_ready_ = false;
    std::vector<uint32_t> bit_reverse_;
    std::vector<double> twiddle_real_, twiddle_imag_;
    std::array<size_t, 32> stage_offsets_{};
    int stage_count_ = 0;
    std::array<uint64_t, FIELD_COUNT / 2> transform_pair_us_{};
    const Cascade *build_cascade_ = nullptr;
    bool build_valid_ = false;
};

} // namespace oq
