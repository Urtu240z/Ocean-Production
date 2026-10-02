// OceanQueryNative — GDExtension (Fase 2C).
// Envoltorio godot-cpp sobre el core C++ portátil (ocean_query_core.h).
// NO reimplementa la matemática: delega en OceanQueryCore (puerto exacto de
// OceanQueryReduced GDScript 2B). El pairing canónico/Nyquist/importance se
// construye en GDScript; aquí sólo se reciben los arrays compactos.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <vector>
#include <array>
#include <chrono>

#include "ocean_query_core.h"
#include "dynamic_ocean_async.h"
#include "dynamic_ocean_physics_field.h"

namespace godot {

class OceanQueryNative : public RefCounted {
    GDCLASS(OceanQueryNative, RefCounted)

private:
    struct MaterialFFTQ { double x = 0.0; double z = 0.0; };
    oq::OceanQueryCore core_;
    std::array<oq::DynamicOceanPhysicsField, 3> dynamic_fields_;
    // The render-thread spectrum reader retains this publisher independently
    // of main-thread clear/shutdown. Writers publish/reset it atomically.
    std::shared_ptr<oq::DynamicOceanAsyncPublisher> dynamic_async_;
    oq::DynamicOceanAsyncPublisher::SpectrumPtr prepared_dynamic_spectrum_;
    uint64_t dynamic_configuration_version_ = 1;
    double dynamic_field_time_ = 0.0;
    bool dynamic_fields_ready_ = false;
    uint64_t dynamic_build_us_[3] = {};
    uint64_t dynamic_evolution_us_[3] = {};
    uint64_t dynamic_transforms_us_[3] = {};
    uint64_t dynamic_build_total_us_ = 0;
    // Buffers C++ contiguos reutilizados; sólo crecen con la capacidad batch.
    std::vector<double> batch_xz_;
    std::vector<double> batch_warm_q_;
    std::vector<double> batch_out_;
    bool batch_profile_enabled_ = false;
    uint64_t batch_prepare_us_ = 0;
    uint64_t batch_input_copy_us_ = 0;
    uint64_t batch_core_us_ = 0;
    uint64_t batch_output_copy_us_ = 0;

    static void _bind_methods();

    // Convierte un sample del core (double out[oq::S_STRIDE]) a PackedFloat64Array.
    PackedFloat64Array sample_to_packed_(const double *out);
    PackedFloat64Array run_world_batch_prepared_(const PackedVector3Array &positions,
                                                 const PackedVector3Array *initial_q);
    void copy_positions_xz_(const PackedVector3Array &positions, std::vector<double> &out_xz);
    PackedFloat64Array pack_batch_output_(size_t value_count);
    void reset_batch_profile_();
    void sample_dynamic_material_q_(double qx, double qz, double *out, double *jacobian = nullptr,
                                    const oq::DynamicOceanSnapshot *snapshot = nullptr) const;
    bool sample_dynamic_band_(int band, double qx, double qz, double *out,
                              const oq::DynamicOceanSnapshot *snapshot) const;
    void sample_dynamic_world_(double wx, double wz, double initial_qx, double initial_qz,
                               bool use_warm_start, double *out,
                               const oq::DynamicOceanSnapshot *snapshot = nullptr) const;
    void refresh_dynamic_async_configuration_();
    bool import_production_spectrum_(const Array &snapshots, bool fft_only);
    MaterialFFTQ material_q_to_fft_q_(double qx, double qz, int cascade_index = 0) const;
    void sample_world_material_q_(double wx, double wz, double simulation_time, double *out, bool include_material_q);

public:
    ~OceanQueryNative();
    void clear();
    void set_sea_level(double sea_level);
    // Production material-q to FFT-q contract for the active PHYS-1 band.
    void set_material_q_contract(double domain_size_m, int resolution);
    // PHYS-2: independent Production material coordinate contract per FFT band.
    void set_cascade_material_q_contract(int cascade_index, double domain_size_m, int resolution);
    PackedFloat64Array material_q_to_fft_q(double qx, double qz) const;
    PackedFloat64Array material_q_to_fft_q_for_band(double qx, double qz, int cascade_index) const;

    void set_cascade_data(
        int cascade_index, double inv_n2,
        const PackedFloat64Array &kx, const PackedFloat64Array &ky, const PackedFloat64Array &omega,
        const PackedFloat64Array &a1, const PackedFloat64Array &a2,
        const PackedFloat64Array &c11, const PackedFloat64Array &c12,
        const PackedFloat64Array &c21, const PackedFloat64Array &c22,
        const PackedFloat64Array &parity, const PackedFloat64Array &weight,
        const PackedFloat64Array &h0_re, const PackedFloat64Array &h0_im,
        const PackedFloat64Array &h0n_re, const PackedFloat64Array &h0n_im);

    void finalize_spectrum();
    // Atomic three-band import of the exact Production upload bytes. Replaces
    // the slow per-mode GDScript bridge without regenerating any spectrum.
    bool set_production_spectrum(const Array &snapshots);
    Dictionary build_production_h0(const Dictionary &config, int64_t seed) const;
    PackedByteArray scale_production_h0(const PackedByteArray &bytes, double scale) const;
    bool prepare_dynamic_spectrum();
    bool prepare_production_spectrum(const Array &snapshots);
    bool transition_dynamic_spectrum(const Ref<OceanQueryNative> &source,
                                     const Ref<OceanQueryNative> &target,
                                     double start_time, double duration);
    Array get_dynamic_snapshot_spectrum(bool include_h0 = true) const;
    void set_coastal_long_weights(const PackedFloat64Array &pos, const PackedFloat64Array &neg);
    void set_coastal_runtime(double field_origin_x, double field_origin_z,
                             double field_extent_x, double field_extent_z,
                             int field_width, int field_height,
                             const PackedFloat32Array &shoaling,
                             const PackedByteArray &field_valid,
                             double warp_origin_x, double warp_origin_z,
                             double warp_extent_x, double warp_extent_z,
                             int warp_width, int warp_height,
                             const PackedFloat32Array &warp_x,
                             const PackedFloat32Array &warp_z,
                             const PackedFloat32Array &det_j,
                             const PackedByteArray &warp_valid,
                             double detj_safe);
    void clear_coastal();
    void set_coastal_profile_enabled(bool enabled);
    void reset_coastal_profile();
    PackedInt64Array get_coastal_profile_us() const;
    PackedInt64Array get_coastal_profile_detail() const;
    PackedInt64Array get_coastal_pair_counts() const;
    void set_batch_profile_enabled(bool enabled);
    PackedInt64Array get_last_batch_profile_us() const;
    PackedInt32Array get_last_batch_diagnostics() const;
    void ensure_prepared(double simulation_time);
    void prepare_breaker_time(double simulation_time);
    void set_crest_sharpen(const Dictionary &config);

    // Production-facing world query. Newton remains in material-q space.
    PackedFloat64Array sample_world(double wx, double wz, double simulation_time);
    PackedFloat64Array sample_world_with_material_q(double wx, double wz, double simulation_time);
    PackedFloat64Array sample_material_q(double qx, double qz, double simulation_time);
    PackedFloat64Array sample_material_q_batch(double simulation_time, const PackedVector3Array &positions);
    // Explicit per-call band selection; legacy methods above always use all bands.
    PackedFloat64Array sample_world_with_band_mask(double wx, double wz, double simulation_time, int band_mask);
    PackedFloat64Array sample_batch_with_band_mask(double simulation_time, const PackedVector3Array &positions, int band_mask);
    PackedFloat64Array sample_material_q_with_band_mask(double qx, double qz, double simulation_time, int band_mask);
    PackedFloat64Array sample_material_q_batch_with_band_mask(double simulation_time, const PackedVector3Array &positions, int band_mask);
    PackedFloat64Array sample_prepared(double wx, double wz);
    // Referencia escalar estable.
    PackedFloat64Array sample_batch_prepared(const PackedVector3Array &positions);
    PackedFloat64Array sample_batch_scalar_prepared(const PackedVector3Array &positions);
    PackedFloat64Array sample_batch_avx2_scalar_trig_prepared(const PackedVector3Array &positions);
    PackedFloat64Array sample_batch(double simulation_time, const PackedVector3Array &positions);
    PackedFloat64Array sample_coastal_breaker_batch_prepared(const PackedVector3Array &positions,
                                                             bool include_slope);
    // Ruta experimental 2C.1B TRUE_BATCH. warm devuelve stride 17: los 15
    // campos normales y qx,qz resueltos para alimentar el tick siguiente.
    PackedFloat64Array sample_batch_true_prepared(const PackedVector3Array &positions);
    PackedFloat64Array sample_batch_warm_prepared(const PackedVector3Array &positions,
                                                  const PackedVector3Array &initial_q);

    int get_diag_non_converged() const;
    int get_diag_last_iterations() const;
    double get_diag_last_residual() const;
    int get_diag_last_spectral_point_evaluations() const;
    PackedInt32Array get_diag_last_newton_histogram() const;
    bool get_cpu_supports_avx2() const;
    String get_query_execution_backend() const;
    void set_force_scalar(bool enabled);

    // PHYS-OPT-2 synchronous CPU FFT mirror prototype. Uses the already
    // configured Production H0-derived Cascade data; no GPU resource access.
    bool build_dynamic_physics_fields(double simulation_time);
    bool start_dynamic_async_fields(double initial_simulation_time, uint64_t initial_tick_id);
    PackedInt64Array advance_dynamic_async(uint64_t tick_id, double current_time,
                                          double next_time, double wall_dt_seconds);
    PackedInt64Array get_dynamic_async_stats() const;
    PackedInt64Array get_dynamic_async_profile_us() const;
    String get_dynamic_async_build_id() const;
    PackedInt64Array get_dynamic_snapshot_info() const;
    PackedInt64Array get_dynamic_snapshot_band_times() const;
    uint64_t run_dynamic_contention_us(uint64_t duration_us);
    int set_dynamic_worker_count(int count);
    int get_dynamic_worker_count() const;
    PackedFloat64Array get_dynamic_phase_recurrence_errors(double start_time, double delta_time) const;
    PackedFloat64Array sample_dynamic_material_q(double qx, double qz);
    PackedFloat64Array sample_dynamic_material_q_batch(const PackedVector3Array &positions);
    PackedFloat64Array sample_dynamic_world(double wx, double wz, double initial_qx, double initial_qz, bool use_warm_start);
    PackedFloat64Array sample_dynamic_world_batch(const PackedVector3Array &positions, const PackedVector3Array &initial_q, bool use_warm_start);
    PackedFloat64Array sample_dynamic_band_material_q(int band, double qx, double qz) const;
    PackedFloat64Array get_dynamic_build_profile_us() const;
    PackedInt64Array get_dynamic_field_info() const;
    PackedInt64Array get_dynamic_stage_profile_us() const;
};

} // namespace godot
