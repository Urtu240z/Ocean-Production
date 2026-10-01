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
                          double simulation_time);
    bool sample_material_q(double material_qx, double material_qz, double *out) const;
    bool ready() const { return ready_; }
    int resolution() const { return n_; }
    double domain_size_m() const { return domain_m_; }
    double simulation_time() const { return simulation_time_; }
    size_t memory_bytes() const { return fields_.size() * sizeof(double); }
    uint64_t evolution_us() const { return evolution_us_; }
    uint64_t transforms_us() const { return transforms_us_; }

private:
    static void inverse_fft_1d_(std::complex<double> *values, int n);
    static void inverse_fft_2d_(std::vector<std::complex<double>> &values, int n,
                                std::vector<std::complex<double>> &scratch);
    static std::complex<double> multiply_i_(std::complex<double> value, double scale);
    static void set_spectrum_(std::complex<double> &packed,
                              std::complex<double> first, std::complex<double> second);
    void prepare_(const Cascade &cascade, double simulation_time);
    void transform_pair_(size_t pair_index);
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
    std::array<uint64_t, FIELD_COUNT / 2> transform_pair_us_{};
    const Cascade *build_cascade_ = nullptr;
    bool build_valid_ = false;
};

} // namespace oq
