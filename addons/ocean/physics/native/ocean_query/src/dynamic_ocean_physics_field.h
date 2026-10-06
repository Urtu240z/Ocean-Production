#pragma once

#include "ocean_query_core.h"

#include <array>
#include <complex>
#include <cstdint>
#include <vector>

namespace oq {

struct DynamicOceanBuildProfile {
    uint64_t phase_us = 0;
    uint64_t evolve_us = 0;
    uint64_t packing_us = 0;
    uint64_t frequency_prepare_us = 0;
    uint64_t row_x_us = 0;
    uint64_t transpose_to_columns_us = 0;
    uint64_t row_z_us = 0;
    uint64_t transpose_back_us = 0;
    uint64_t unpack_us = 0;
};

struct DynamicOceanBatchProfile {
    uint64_t prepare_queue_us = 0;
    uint64_t prepare_barrier_us = 0;
    uint64_t transform_queue_us = 0;
    uint64_t transform_barrier_us = 0;
};

// Optional private native input work, run by the same persistent band job
// immediately before spectrum evolution. The caller owns the context until
// build_all_packed_into returns; no Godot API or heap task allocation is used.
struct DynamicOceanEvolutionBuffers {
    const double *phase_cos, *phase_sin;
    double *height_re, *height_im, *velocity_re, *velocity_im;
};

struct DynamicOceanWeatherDelta {
    std::vector<double> h0_re, h0_im, h0n_re, h0n_im, a1, a2;
};

struct DynamicOceanBandPreparation {
    void (*function)(void *) = nullptr;
    void *context = nullptr;
    // Borrowed versioned deltas are immutable during the native batch.
    // Zero outside the open interval of the authored linear weather ramp.
    const DynamicOceanWeatherDelta *weather_delta = nullptr;
    double weather_alpha_dot = 0.0;
};

struct DynamicOceanBandSnapshot {
    std::vector<double> fields;
    std::array<std::vector<std::complex<double>>, 6> packed_fields;
    int resolution = 0;
    double domain_m = 0.0;
    double simulation_time = 0.0;
    bool packed_fields_layout = false;
};

struct DynamicOceanSnapshot {
    std::array<DynamicOceanBandSnapshot, 3> bands;
    double simulation_time = 0.0;
    uint64_t physics_tick_id = 0;
    uint64_t configuration_version = 0;
    uint64_t generation = 0;
    uint64_t requested_steady_ns = 0;
    uint64_t started_steady_ns = 0;
    uint64_t finished_steady_ns = 0;
    uint64_t deadline_steady_ns = 0;
    // Exact float32 H0 uploaded by the runtime weather adapter. Allocated once
    // per buffer, produced alongside the same coherent spatial snapshot.
    std::array<std::vector<float>, 3> production_h0;
    std::array<double, 3> choppiness{};
    std::array<double, 3> gravity{};
    std::array<double, 3> wind_x{}, wind_z{}, wind_speed{};
    double weather_alpha = 0.0;
    double weather_alpha_dot = 0.0;
    double weather_start_time = 0.0, weather_duration = 0.0;
    std::array<double, 3> choppiness_dot{};
    bool valid = false;
};

// Synchronous CPU mirror of one Production Stockham FFT band. This prototype
// owns a periodic material field and never accesses RenderingDevice/Godot APIs.
class DynamicOceanPhysicsField {
public:
    enum Field : size_t {
        HEIGHT = 0, DISPLACE_X, DISPLACE_Z, HEIGHT_DX, HEIGHT_DZ,
        DISPLACE_XX, DISPLACE_XZ, DISPLACE_ZX, DISPLACE_ZZ,
        VELOCITY_Y, VELOCITY_X, VELOCITY_Z, FIELD_COUNT
    };

      bool configure(const Cascade &cascade, bool allocate_spatial_fields = true);
      // Validation-only scalar height/vertical-velocity field. The source
      // Cascade remains the exact Production spectrum; configure_lite crops
      // its centered bins without changing the world-space domain.
      bool configure_lite(const Cascade &source, int resolution);
      bool build_lite(double simulation_time, bool use_avx2 = false);
      bool sample_lite_surface(double world_x, double world_z, double sea_level,
                               double *out_height_vy_normal, int interpolation_mode = 0) const;
      bool sample_lite_height_velocity_gradient(double world_x, double world_z, double sea_level,
                               double *out_height, double *out_vertical_velocity,
                               double *out_dh_dx, double *out_dh_dz, int interpolation_mode = 0) const;
      size_t lite_memory_bytes() const;
      uint64_t lite_ifft_us() const;
      uint64_t lite_publication_us() const;
      uint64_t lite_row_x_us() const;
      uint64_t lite_transpose_us() const;
      uint64_t lite_row_z_us() const;
      bool sample_lite_direct_spectrum(double world_x, double world_z, double *out_height_vy) const;
      bool sample_direct_spectrum(const Cascade &cascade, double world_x, double world_z,
                                  double *out_height_vy_gradient) const;
      const std::vector<std::complex<double>> &lite_packed_field() const { return lite_packed_output_[0]; }
      const Cascade &lite_cascade() const { return lite_cascade_; }
      void reset_phase_history();
    bool build(const Cascade &cascade, double simulation_time);
    static bool build_all(const std::array<DynamicOceanPhysicsField *, 3> &fields,
                          const std::array<const Cascade *, 3> &cascades,
                          double simulation_time, bool use_avx2 = false);
    static bool build_all_into(const std::array<DynamicOceanPhysicsField *, 3> &builders,
                               const std::array<const Cascade *, 3> &cascades,
                               const std::array<std::vector<double> *, 3> &output_fields,
                               double simulation_time, bool use_avx2 = false,
                               DynamicOceanBatchProfile *batch_profile = nullptr);
    static bool build_all_packed_into(const std::array<DynamicOceanPhysicsField *, 3> &builders,
                                      const std::array<const Cascade *, 3> &cascades,
                                      const std::array<std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> *, 3> &output_fields,
                                      double simulation_time, bool use_avx2 = false,
                                      DynamicOceanBatchProfile *batch_profile = nullptr,
                                      const std::array<DynamicOceanBandPreparation, 3> *band_preparations = nullptr);
    static int set_worker_count(int count);
    static int worker_count();
    bool sample_material_q(double material_qx, double material_qz, double *out) const;
    bool ready() const { return ready_; }
    int resolution() const { return n_; }
    double domain_size_m() const { return domain_m_; }
    double simulation_time() const { return simulation_time_; }
    double horizontal_displacement_bound() const;
    size_t memory_bytes() const { return fields_.size() * sizeof(double); }
    std::vector<double> take_spatial_fields() { return std::move(fields_); }
    static bool sample_material_q_from(const std::vector<double> &fields, int resolution,
                                       double domain_m, double material_qx, double material_qz,
                                       double *out);
    static bool sample_material_q_packed_from(
        const std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> &fields,
        int resolution, double domain_m, double material_qx, double material_qz, double *out);
    uint64_t evolution_us() const { return evolution_us_; }
    uint64_t transforms_us() const { return transforms_us_; }
    const DynamicOceanBuildProfile &profile() const { return profile_; }
    std::array<double, 4> measure_phase_recurrence_error(const Cascade &cascade,
                                                        double start_time, double delta_time,
                                                        bool use_avx2) const;

private:
    static void inverse_fft_2d_(std::vector<std::complex<double>> &values, int n,
                                std::vector<std::complex<double>> &scratch,
                                const std::vector<uint32_t> &bit_reverse,
                                const std::vector<double> &twiddle_real,
                                const std::vector<double> &twiddle_imag,
                                const std::vector<double> &twiddle_real_dup,
                                const std::vector<double> &twiddle_imag_dup,
                                const std::array<size_t, 32> &stage_offsets,
                                int stage_count, bool use_avx2,
                                std::array<uint64_t, 4> *stage_profile_us);
    static std::complex<double> multiply_i_(std::complex<double> value, double scale);
    static void set_spectrum_(std::complex<double> &packed,
                              std::complex<double> first, std::complex<double> second);
    void prepare_(const Cascade &cascade, double simulation_time, bool use_avx2,
                  const DynamicOceanBandPreparation &input);
    void advance_phase_(const Cascade &cascade, double simulation_time, bool use_avx2);
    void transform_pair_(size_t pair_index, bool use_avx2, std::vector<double> *output_fields,
                         std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> *packed_output_fields);
    void finish_build_(double simulation_time);
    static void prepare_task_(void *context);
    static void transform_task_(void *context);
    static bool build_all_outputs_(const std::array<DynamicOceanPhysicsField *, 3> &builders,
                                   const std::array<const Cascade *, 3> &cascades,
                                   const std::array<std::vector<double> *, 3> &output_fields,
                                   const std::array<std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> *, 3> &packed_output_fields,
                                   double simulation_time, bool use_avx2,
                                   DynamicOceanBatchProfile *batch_profile,
                                   const std::array<DynamicOceanBandPreparation, 3> *band_preparations = nullptr);
    double sample_field_(Field field, double fft_qx, double fft_qz) const;
    static double sample_field_from_(const std::vector<double> &fields, int resolution,
                                     double domain_m, Field field, double fft_qx, double fft_qz);

    int n_ = 0;
    double domain_m_ = 0.0;
    double simulation_time_ = 0.0;
    bool ready_ = false;
    uint64_t evolution_us_ = 0;
    uint64_t transforms_us_ = 0;
      std::vector<double> fields_;
      std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> spectra_;
      std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> fft_scratch_;
      Cascade lite_cascade_;
      std::array<std::vector<std::complex<double>>, FIELD_COUNT / 2> lite_packed_output_;
      bool lite_mode_ = false;
    std::vector<double> phase_cos_, phase_sin_, rotor_cos_, rotor_sin_;
    std::vector<double> evolved_h_re_, evolved_h_im_, evolved_v_re_, evolved_v_im_;
    double phase_time_ = 0.0, rotor_dt_ = 0.0;
    uint64_t phase_updates_since_rebase_ = 0;
    bool phase_ready_ = false, rotor_ready_ = false;
    std::vector<uint32_t> bit_reverse_;
    std::vector<double> twiddle_real_, twiddle_imag_;
    std::vector<double> twiddle_real_dup_, twiddle_imag_dup_;
    std::array<size_t, 32> stage_offsets_{};
    int stage_count_ = 0;
    std::array<uint64_t, FIELD_COUNT / 2> transform_pair_us_{};
    std::array<std::array<uint64_t, 5>, FIELD_COUNT / 2> transform_stage_us_{};
    DynamicOceanBuildProfile profile_{};
    bool build_valid_ = false;
};

} // namespace oq
