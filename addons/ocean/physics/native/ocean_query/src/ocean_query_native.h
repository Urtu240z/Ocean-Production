// OceanQueryNative — GDExtension (Fase 2C).
// Envoltorio godot-cpp sobre el core C++ portátil (ocean_query_core.h).
// NO reimplementa la matemática: delega en OceanQueryCore (puerto exacto de
// OceanQueryReduced GDScript 2B). El pairing canónico/Nyquist/importance se
// construye en GDScript; aquí sólo se reciben los arrays compactos.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <vector>

#include "ocean_query_core.h"

namespace godot {

class OceanQueryNative : public RefCounted {
    GDCLASS(OceanQueryNative, RefCounted)

private:
    struct MaterialFFTQ { double x = 0.0; double z = 0.0; };
    oq::OceanQueryCore core_;
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
    MaterialFFTQ material_q_to_fft_q_(double qx, double qz, int cascade_index = 0) const;
    void sample_world_material_q_(double wx, double wz, double simulation_time, double *out, bool include_material_q);

public:
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
};

} // namespace godot
