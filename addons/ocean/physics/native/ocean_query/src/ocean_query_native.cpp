// OceanQueryNative — GDExtension (Fase 2C). Implementación.

#include "ocean_query_native.h"
#include "production_spectrum.h"
#include "dynamic_ocean_contact.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <limits>
#include <cmath>
#include <chrono>
#include <algorithm>
#include <cstring>

using namespace godot;

namespace {

bool is_supported_query_band_mask(int mask) {
    return mask == oq::QUERY_BAND_LONG ||
           mask == (oq::QUERY_BAND_LONG | oq::QUERY_BAND_MID) ||
           mask == oq::QUERY_BAND_ALL;
}

std::array<oq::Cascade, 3> capture_dynamic_cascades(const std::vector<oq::Cascade> &source) {
    std::array<oq::Cascade, 3> result;
    for (size_t band = 0; band < result.size() && band < source.size(); ++band) result[band] = source[band];
    return result;
}

class ScopedQueryBandMask {
    oq::OceanQueryCore &core_;
    uint8_t previous_;
public:
    ScopedQueryBandMask(oq::OceanQueryCore &core, uint8_t mask)
        : core_(core), previous_(core.exchange_query_band_mask(mask)) {}
    ~ScopedQueryBandMask() { core_.exchange_query_band_mask(previous_); }
};

} // namespace

void OceanQueryNative::_bind_methods() {
    ClassDB::bind_integer_constant(get_class_static(), "QueryBandMask", "BAND_LONG", oq::QUERY_BAND_LONG, true);
    ClassDB::bind_integer_constant(get_class_static(), "QueryBandMask", "BAND_MID", oq::QUERY_BAND_MID, true);
    ClassDB::bind_integer_constant(get_class_static(), "QueryBandMask", "BAND_SHORT", oq::QUERY_BAND_SHORT, true);
    ClassDB::bind_integer_constant(get_class_static(), "QueryBandMask", "BAND_ALL", oq::QUERY_BAND_ALL, true);
    ClassDB::bind_method(D_METHOD("clear"), &OceanQueryNative::clear);
    ClassDB::bind_method(D_METHOD("set_sea_level", "sea_level"), &OceanQueryNative::set_sea_level);
    ClassDB::bind_method(D_METHOD("set_material_q_contract", "domain_size_m", "resolution"), &OceanQueryNative::set_material_q_contract);
    ClassDB::bind_method(D_METHOD("set_cascade_material_q_contract", "cascade_index", "domain_size_m", "resolution"), &OceanQueryNative::set_cascade_material_q_contract);
    ClassDB::bind_method(D_METHOD("material_q_to_fft_q", "qx", "qz"), &OceanQueryNative::material_q_to_fft_q);
    ClassDB::bind_method(D_METHOD("material_q_to_fft_q_for_band", "qx", "qz", "cascade_index"), &OceanQueryNative::material_q_to_fft_q_for_band);
    ClassDB::bind_method(D_METHOD("set_cascade_data",
                                  "cascade_index", "inv_n2",
                                  "kx", "ky", "omega",
                                  "a1", "a2", "c11", "c12", "c21", "c22",
                                  "parity", "weight",
                                  "h0_re", "h0_im", "h0n_re", "h0n_im"),
                         &OceanQueryNative::set_cascade_data);
    ClassDB::bind_method(D_METHOD("finalize_spectrum"), &OceanQueryNative::finalize_spectrum);
    ClassDB::bind_method(D_METHOD("set_production_spectrum", "snapshots"), &OceanQueryNative::set_production_spectrum);
    ClassDB::bind_method(D_METHOD("build_production_h0", "config", "seed"), &OceanQueryNative::build_production_h0);
    ClassDB::bind_method(D_METHOD("scale_production_h0", "bytes", "scale"), &OceanQueryNative::scale_production_h0);
    ClassDB::bind_method(D_METHOD("prepare_dynamic_spectrum"), &OceanQueryNative::prepare_dynamic_spectrum);
    ClassDB::bind_method(D_METHOD("prepare_production_spectrum", "snapshots"), &OceanQueryNative::prepare_production_spectrum);
    ClassDB::bind_method(D_METHOD("transition_dynamic_spectrum", "source", "target", "start_time", "duration"), &OceanQueryNative::transition_dynamic_spectrum);
    ClassDB::bind_method(D_METHOD("get_dynamic_snapshot_spectrum", "include_h0"), &OceanQueryNative::get_dynamic_snapshot_spectrum, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("set_coastal_long_weights", "pos", "neg"), &OceanQueryNative::set_coastal_long_weights);
    ClassDB::bind_method(D_METHOD("set_coastal_runtime", "field_origin_x", "field_origin_z", "field_extent_x", "field_extent_z", "field_width", "field_height", "shoaling", "field_valid", "warp_origin_x", "warp_origin_z", "warp_extent_x", "warp_extent_z", "warp_width", "warp_height", "warp_x", "warp_z", "det_j", "warp_valid", "detj_safe"), &OceanQueryNative::set_coastal_runtime);
    ClassDB::bind_method(D_METHOD("clear_coastal"), &OceanQueryNative::clear_coastal);
    ClassDB::bind_method(D_METHOD("sample_coastal_bake", "qx", "qz", "diagnostic_feather_texels"), &OceanQueryNative::sample_coastal_bake);
    ClassDB::bind_method(D_METHOD("set_coastal_profile_enabled", "enabled"), &OceanQueryNative::set_coastal_profile_enabled);
    ClassDB::bind_method(D_METHOD("reset_coastal_profile"), &OceanQueryNative::reset_coastal_profile);
    ClassDB::bind_method(D_METHOD("get_coastal_profile_us"), &OceanQueryNative::get_coastal_profile_us);
    ClassDB::bind_method(D_METHOD("get_coastal_profile_detail"), &OceanQueryNative::get_coastal_profile_detail);
    ClassDB::bind_method(D_METHOD("get_coastal_pair_counts"), &OceanQueryNative::get_coastal_pair_counts);
    ClassDB::bind_method(D_METHOD("set_batch_profile_enabled", "enabled"), &OceanQueryNative::set_batch_profile_enabled);
    ClassDB::bind_method(D_METHOD("get_last_batch_profile_us"), &OceanQueryNative::get_last_batch_profile_us);
    ClassDB::bind_method(D_METHOD("get_last_batch_diagnostics"), &OceanQueryNative::get_last_batch_diagnostics);
    ClassDB::bind_method(D_METHOD("ensure_prepared", "simulation_time"), &OceanQueryNative::ensure_prepared);
    ClassDB::bind_method(D_METHOD("prepare_breaker_time", "simulation_time"), &OceanQueryNative::prepare_breaker_time);
    ClassDB::bind_method(D_METHOD("set_crest_sharpen", "config"), &OceanQueryNative::set_crest_sharpen);
    ClassDB::bind_method(D_METHOD("sample_world", "wx", "wz", "simulation_time"), &OceanQueryNative::sample_world);
    ClassDB::bind_method(D_METHOD("debug_world_parity", "simulation_time", "positions", "point", "focused_only"), &OceanQueryNative::debug_world_parity, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("sample_world_with_material_q", "wx", "wz", "simulation_time"), &OceanQueryNative::sample_world_with_material_q);
    ClassDB::bind_method(D_METHOD("sample_material_q", "qx", "qz", "simulation_time"), &OceanQueryNative::sample_material_q);
    ClassDB::bind_method(D_METHOD("sample_material_q_batch", "simulation_time", "positions"), &OceanQueryNative::sample_material_q_batch);
    ClassDB::bind_method(D_METHOD("sample_world_with_band_mask", "wx", "wz", "simulation_time", "band_mask"), &OceanQueryNative::sample_world_with_band_mask);
    ClassDB::bind_method(D_METHOD("sample_batch_with_band_mask", "simulation_time", "positions", "band_mask"), &OceanQueryNative::sample_batch_with_band_mask);
    ClassDB::bind_method(D_METHOD("sample_material_q_with_band_mask", "qx", "qz", "simulation_time", "band_mask"), &OceanQueryNative::sample_material_q_with_band_mask);
    ClassDB::bind_method(D_METHOD("sample_material_q_batch_with_band_mask", "simulation_time", "positions", "band_mask"), &OceanQueryNative::sample_material_q_batch_with_band_mask);
    ClassDB::bind_method(D_METHOD("build_dynamic_physics_fields", "simulation_time"), &OceanQueryNative::build_dynamic_physics_fields);
    ClassDB::bind_method(D_METHOD("build_dynamic_physics_lite", "simulation_time", "resolutions"), &OceanQueryNative::build_dynamic_physics_lite);
    ClassDB::bind_method(D_METHOD("get_dynamic_lite_profile"), &OceanQueryNative::get_dynamic_lite_profile);
    ClassDB::bind_method(D_METHOD("sample_dynamic_lite_surface", "band", "world_x", "world_z", "sea_level", "interpolation_mode"), &OceanQueryNative::sample_dynamic_lite_surface, DEFVAL(0.0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("sample_dynamic_lite_contacts", "positions", "sea_level", "interpolation_modes"), &OceanQueryNative::sample_dynamic_lite_contacts, DEFVAL(0.0), DEFVAL(PackedInt32Array()));
    ClassDB::bind_method(D_METHOD("sample_dynamic_lite_bands", "positions", "interpolation_modes"), &OceanQueryNative::sample_dynamic_lite_bands, DEFVAL(PackedInt32Array()));
    ClassDB::bind_method(D_METHOD("sample_dynamic_spectrum_oracle", "band", "world_x", "world_z", "retained_only"), &OceanQueryNative::sample_dynamic_spectrum_oracle);
    ClassDB::bind_method(D_METHOD("sample_dynamic_spectrum_oracle_batch", "positions", "retained_only"), &OceanQueryNative::sample_dynamic_spectrum_oracle_batch);
    ClassDB::bind_method(D_METHOD("compare_dynamic_lite_to_full", "band", "sample_stride"), &OceanQueryNative::compare_dynamic_lite_to_full, DEFVAL(8));
    ClassDB::bind_method(D_METHOD("compare_dynamic_lite_combined_to_full", "sample_count"), &OceanQueryNative::compare_dynamic_lite_combined_to_full, DEFVAL(4096));
    ClassDB::bind_method(D_METHOD("compare_dynamic_lite_to_direct_spectrum", "band", "sample_count"), &OceanQueryNative::compare_dynamic_lite_to_direct_spectrum, DEFVAL(64));
    ClassDB::bind_method(D_METHOD("validate_dynamic_lite_single_modes", "band", "resolutions"), &OceanQueryNative::validate_dynamic_lite_single_modes);
    ClassDB::bind_method(D_METHOD("audit_dynamic_lite_bin_mapping", "band", "resolutions"), &OceanQueryNative::audit_dynamic_lite_bin_mapping);
    ClassDB::bind_method(D_METHOD("start_dynamic_async_fields", "initial_simulation_time", "initial_tick_id"), &OceanQueryNative::start_dynamic_async_fields);
    ClassDB::bind_method(D_METHOD("advance_dynamic_async", "tick_id", "current_time", "next_time", "wall_dt_seconds"), &OceanQueryNative::advance_dynamic_async);
    ClassDB::bind_method(D_METHOD("get_dynamic_async_stats"), &OceanQueryNative::get_dynamic_async_stats);
    ClassDB::bind_method(D_METHOD("get_dynamic_async_profile_us"), &OceanQueryNative::get_dynamic_async_profile_us);
    ClassDB::bind_method(D_METHOD("get_dynamic_async_build_id"), &OceanQueryNative::get_dynamic_async_build_id);
    ClassDB::bind_method(D_METHOD("get_dynamic_snapshot_info"), &OceanQueryNative::get_dynamic_snapshot_info);
    ClassDB::bind_method(D_METHOD("get_dynamic_snapshot_band_times"), &OceanQueryNative::get_dynamic_snapshot_band_times);
    ClassDB::bind_method(D_METHOD("run_dynamic_contention_us", "duration_us"), &OceanQueryNative::run_dynamic_contention_us);
    ClassDB::bind_method(D_METHOD("set_dynamic_worker_count", "count"), &OceanQueryNative::set_dynamic_worker_count);
    ClassDB::bind_method(D_METHOD("get_dynamic_worker_count"), &OceanQueryNative::get_dynamic_worker_count);
    ClassDB::bind_method(D_METHOD("get_dynamic_phase_recurrence_errors", "start_time", "delta_time"), &OceanQueryNative::get_dynamic_phase_recurrence_errors);
    ClassDB::bind_method(D_METHOD("sample_dynamic_material_q", "qx", "qz"), &OceanQueryNative::sample_dynamic_material_q);
    ClassDB::bind_method(D_METHOD("sample_dynamic_material_q_batch", "positions"), &OceanQueryNative::sample_dynamic_material_q_batch);
    ClassDB::bind_method(D_METHOD("sample_dynamic_world", "wx", "wz", "initial_qx", "initial_qz", "use_warm_start"), &OceanQueryNative::sample_dynamic_world);
    ClassDB::bind_method(D_METHOD("sample_dynamic_world_batch", "positions", "initial_q", "use_warm_start"), &OceanQueryNative::sample_dynamic_world_batch);
    ClassDB::bind_method(D_METHOD("sample_dynamic_contact", "wx", "wz", "previous"), &OceanQueryNative::sample_dynamic_contact);
    ClassDB::bind_method(D_METHOD("sample_dynamic_contact_batch", "positions", "previous"), &OceanQueryNative::sample_dynamic_contact_batch);
    ClassDB::bind_method(D_METHOD("sample_dynamic_band_material_q", "band", "qx", "qz"), &OceanQueryNative::sample_dynamic_band_material_q);
    ClassDB::bind_method(D_METHOD("get_dynamic_build_profile_us"), &OceanQueryNative::get_dynamic_build_profile_us);
    ClassDB::bind_method(D_METHOD("get_dynamic_field_info"), &OceanQueryNative::get_dynamic_field_info);
    ClassDB::bind_method(D_METHOD("get_dynamic_stage_profile_us"), &OceanQueryNative::get_dynamic_stage_profile_us);
    ClassDB::bind_method(D_METHOD("sample_prepared", "wx", "wz"), &OceanQueryNative::sample_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_prepared", "positions"), &OceanQueryNative::sample_batch_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_scalar_prepared", "positions"), &OceanQueryNative::sample_batch_scalar_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_avx2_scalar_trig_prepared", "positions"), &OceanQueryNative::sample_batch_avx2_scalar_trig_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch", "simulation_time", "positions"), &OceanQueryNative::sample_batch);
    ClassDB::bind_method(D_METHOD("sample_coastal_breaker_batch_prepared", "positions", "include_slope"), &OceanQueryNative::sample_coastal_breaker_batch_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_true_prepared", "positions"), &OceanQueryNative::sample_batch_true_prepared);
    ClassDB::bind_method(D_METHOD("sample_batch_warm_prepared", "positions", "initial_q"), &OceanQueryNative::sample_batch_warm_prepared);
    ClassDB::bind_method(D_METHOD("get_diag_non_converged"), &OceanQueryNative::get_diag_non_converged);
    ClassDB::bind_method(D_METHOD("get_diag_last_iterations"), &OceanQueryNative::get_diag_last_iterations);
    ClassDB::bind_method(D_METHOD("get_diag_last_residual"), &OceanQueryNative::get_diag_last_residual);
    ClassDB::bind_method(D_METHOD("get_diag_last_spectral_point_evaluations"), &OceanQueryNative::get_diag_last_spectral_point_evaluations);
    ClassDB::bind_method(D_METHOD("get_diag_last_newton_histogram"), &OceanQueryNative::get_diag_last_newton_histogram);
    ClassDB::bind_method(D_METHOD("get_cpu_supports_avx2"), &OceanQueryNative::get_cpu_supports_avx2);
    ClassDB::bind_method(D_METHOD("get_query_execution_backend"), &OceanQueryNative::get_query_execution_backend);
    ClassDB::bind_method(D_METHOD("set_force_scalar", "enabled"), &OceanQueryNative::set_force_scalar);
}

OceanQueryNative::~OceanQueryNative() { clear(); }

void OceanQueryNative::clear() {
    auto publisher = std::atomic_exchange(&dynamic_async_,
        std::shared_ptr<oq::DynamicOceanAsyncPublisher>{});
    // Stop the producer before destroying the builders it references. A render
    // callback may still hold the publisher and its immutable snapshot safely.
    if (publisher) publisher->shutdown();
    prepared_dynamic_spectrum_.reset();
    core_.clear();
    dynamic_fields_ready_ = false;
    dynamic_lite_ready_ = false;
    dynamic_lite_resolutions_.fill(0);
}

bool OceanQueryNative::build_dynamic_physics_fields(double simulation_time) {
    if (dynamic_async_) return false;
    dynamic_fields_ready_ = false;
    dynamic_build_total_us_ = 0;
    std::array<oq::DynamicOceanPhysicsField *, 3> fields{};
    std::array<const oq::Cascade *, 3> cascades{};
    const auto begin = std::chrono::steady_clock::now();
    for (int band = 0; band < 3; ++band) {
        dynamic_build_us_[band] = 0;
        dynamic_evolution_us_[band] = 0;
        dynamic_transforms_us_[band] = 0;
        if (static_cast<size_t>(band) >= core_.cascades.size() || core_.cascades[band].kx.empty()) continue;
        if (!dynamic_fields_[band].configure(core_.cascades[band])) {
            return false;
        }
        fields[band] = &dynamic_fields_[band];
        cascades[band] = &core_.cascades[band];
    }
    const bool use_avx2 = core_.avx2_supported();
    if (!oq::DynamicOceanPhysicsField::build_all(fields, cascades, simulation_time, use_avx2)) return false;
    const auto end = std::chrono::steady_clock::now();
    dynamic_build_total_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(end - begin).count());
    for (int band = 0; band < 3; ++band) {
        if (fields[band] == nullptr) continue;
        dynamic_evolution_us_[band] = dynamic_fields_[band].evolution_us();
        dynamic_transforms_us_[band] = dynamic_fields_[band].transforms_us();
        dynamic_build_us_[band] = dynamic_evolution_us_[band] + dynamic_transforms_us_[band];
    }
    dynamic_field_time_ = simulation_time;
    dynamic_fields_ready_ = true;
    return true;
}

bool OceanQueryNative::build_dynamic_physics_lite(double simulation_time,
        const PackedInt32Array &resolutions) {
    if (dynamic_async_ || core_.cascades.size() != 3 || resolutions.size() != 3 ||
        !std::isfinite(simulation_time)) return false;
    if (dynamic_lite_ready_ && simulation_time + 1.0e-12 < dynamic_lite_time_)
        for (auto &field : dynamic_lite_fields_) field.reset_phase_history();
    dynamic_lite_ready_ = false;
    for (int band = 0; band < 3; ++band) {
        const int resolution = resolutions[band];
        if (resolution < 2 || (resolution & (resolution - 1)) != 0 ||
            resolution > core_.cascades[band].material_resolution) return false;
        if (dynamic_lite_resolutions_[band] != resolution || !dynamic_lite_fields_[band].ready()) {
            if (!dynamic_lite_fields_[band].configure_lite(core_.cascades[band], resolution)) return false;
            dynamic_lite_resolutions_[band] = resolution;
        }
    }
    const auto begin = std::chrono::steady_clock::now();
    const bool use_avx2 = core_.avx2_supported();
    for (int band = 0; band < 3; ++band) {
        const auto band_begin = std::chrono::steady_clock::now();
        if (!dynamic_lite_fields_[band].build_lite(simulation_time, use_avx2)) return false;
        const auto band_end = std::chrono::steady_clock::now();
        dynamic_lite_build_us_[band] = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(band_end - band_begin).count());
        dynamic_lite_evolution_us_[band] = dynamic_lite_fields_[band].profile().evolve_us;
        dynamic_lite_ifft_us_[band] = dynamic_lite_fields_[band].lite_ifft_us();
        dynamic_lite_publication_us_[band] = dynamic_lite_fields_[band].lite_publication_us();
    }
    const auto end = std::chrono::steady_clock::now();
    dynamic_lite_total_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(end - begin).count());
    dynamic_lite_time_ = simulation_time;
    dynamic_lite_ready_ = true;
    return true;
}

Dictionary OceanQueryNative::get_dynamic_lite_profile() const {
    Dictionary result;
    PackedInt64Array build, phase, evolution, packing, ifft, row_x, transpose, row_z, publication, resolutions;
    build.resize(3); phase.resize(3); evolution.resize(3); packing.resize(3); ifft.resize(3);
    row_x.resize(3); transpose.resize(3); row_z.resize(3); publication.resize(3); resolutions.resize(3);
    int64_t memory = 0;
    for (int band = 0; band < 3; ++band) {
        build[band] = static_cast<int64_t>(dynamic_lite_build_us_[band]);
        phase[band] = static_cast<int64_t>(dynamic_lite_fields_[band].profile().phase_us);
        evolution[band] = static_cast<int64_t>(dynamic_lite_evolution_us_[band]);
        packing[band] = static_cast<int64_t>(dynamic_lite_fields_[band].profile().packing_us);
        ifft[band] = static_cast<int64_t>(dynamic_lite_ifft_us_[band]);
        row_x[band] = static_cast<int64_t>(dynamic_lite_fields_[band].lite_row_x_us());
        transpose[band] = static_cast<int64_t>(dynamic_lite_fields_[band].lite_transpose_us());
        row_z[band] = static_cast<int64_t>(dynamic_lite_fields_[band].lite_row_z_us());
        publication[band] = static_cast<int64_t>(dynamic_lite_publication_us_[band]);
        resolutions[band] = dynamic_lite_resolutions_[band];
        memory += static_cast<int64_t>(dynamic_lite_fields_[band].lite_memory_bytes());
    }
    result["valid"] = dynamic_lite_ready_;
    result["simulation_time"] = dynamic_lite_time_;
    result["update_us"] = static_cast<int64_t>(dynamic_lite_total_us_);
    result["band_build_us"] = build;
    result["phase_us"] = phase;
    result["spectrum_evolution_us"] = evolution;
    result["packing_us"] = packing;
    result["ifft_us"] = ifft;
    result["ifft_row_x_us"] = row_x;
    result["ifft_transpose_us"] = transpose;
    result["ifft_row_z_us"] = row_z;
    result["field_publication_us"] = publication;
    result["resolutions"] = resolutions;
    result["memory_bytes"] = memory;
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_lite_surface(int band, double world_x,
        double world_z, double sea_level, int interpolation_mode) const {
    PackedFloat64Array result;
    if (!dynamic_lite_ready_ || band < 0 || band >= 3) return result;
    double values[5]{};
    if (!dynamic_lite_fields_[band].sample_lite_surface(world_x, world_z, sea_level, values,
            interpolation_mode)) return result;
    result.resize(5);
    for (int i = 0; i < 5; ++i) result[i] = values[i];
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_lite_contacts(const PackedVector3Array &positions,
        double sea_level, const PackedInt32Array &interpolation_modes) const {
    PackedFloat64Array result;
    if (!dynamic_lite_ready_ || positions.is_empty() || !std::isfinite(sea_level)) return result;
    constexpr int ROW = 6;
    const int64_t count = positions.size();
    result.resize(1 + count * ROW);
    double *out = result.ptrw();
    const auto started = std::chrono::steady_clock::now();
    for (int64_t i = 0; i < count; ++i) {
        const Vector3 point = positions[i];
        double height = 0.0, velocity_y = 0.0, dh_dx = 0.0, dh_dz = 0.0;
        bool valid = std::isfinite(point.x) && std::isfinite(point.z);
        for (size_t band = 0; valid && band < dynamic_lite_fields_.size(); ++band) {
            double band_height = 0.0, band_vy = 0.0, band_dh_dx = 0.0, band_dh_dz = 0.0;
            valid = dynamic_lite_fields_[band].sample_lite_height_velocity_gradient(
                point.x, point.z, 0.0, &band_height, &band_vy, &band_dh_dx, &band_dh_dz,
                interpolation_modes.size() == 3 ? interpolation_modes[band] : 0);
            height += band_height;
            velocity_y += band_vy;
            dh_dx += band_dh_dx;
            dh_dz += band_dh_dz;
        }
        double *sample = out + 1 + i * ROW;
        sample[0] = valid ? 1.0 : 0.0;
        if (valid) {
            const double inverse_length = 1.0 / std::sqrt(dh_dx * dh_dx + 1.0 + dh_dz * dh_dz);
            sample[1] = sea_level + height;
            sample[2] = velocity_y;
            sample[3] = -dh_dx * inverse_length;
            sample[4] = inverse_length;
            sample[5] = -dh_dz * inverse_length;
        }
    }
    const auto ended = std::chrono::steady_clock::now();
    out[0] = static_cast<double>(std::chrono::duration_cast<std::chrono::microseconds>(ended - started).count());
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_spectrum_oracle(int band, double world_x,
        double world_z, bool retained_only) const {
    PackedFloat64Array result;
    if (band < 0 || band >= 3) return result;
    double values[4]{};
    const bool ok = retained_only ? dynamic_lite_ready_ &&
        dynamic_lite_fields_[band].sample_lite_direct_spectrum(world_x, world_z, values) :
        dynamic_fields_ready_ && band < static_cast<int>(core_.cascades.size()) &&
        dynamic_fields_[band].sample_direct_spectrum(core_.cascades[band], world_x, world_z, values);
    if (!ok) return result;
    result.resize(4);
    for (int i = 0; i < 4; ++i) result[i] = values[i];
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_lite_bands(const PackedVector3Array &positions,
        const PackedInt32Array &interpolation_modes) const {
    PackedFloat64Array result;
    if (!dynamic_lite_ready_ || positions.is_empty()) return result;
    constexpr int VALUES_PER_BAND = 4;
    constexpr int ROW = 1 + 3 * VALUES_PER_BAND;
    result.resize(1 + positions.size() * ROW);
    double *out = result.ptrw();
    const auto started = std::chrono::steady_clock::now();
    for (int64_t point_index = 0; point_index < positions.size(); ++point_index) {
        const Vector3 point = positions[point_index];
        double *row = out + 1 + point_index * ROW;
        bool valid = std::isfinite(point.x) && std::isfinite(point.z);
        for (int band = 0; valid && band < 3; ++band) {
            double *values = row + 1 + band * VALUES_PER_BAND;
            valid = dynamic_lite_fields_[band].sample_lite_height_velocity_gradient(
                point.x, point.z, 0.0, &values[0], &values[1], &values[2], &values[3],
                interpolation_modes.size() == 3 ? interpolation_modes[band] : 0);
        }
        row[0] = valid ? 1.0 : 0.0;
    }
    const auto ended = std::chrono::steady_clock::now();
    out[0] = static_cast<double>(std::chrono::duration_cast<std::chrono::microseconds>(ended - started).count());
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_spectrum_oracle_batch(
        const PackedVector3Array &positions, bool retained_only) const {
    PackedFloat64Array result;
    if ((retained_only && !dynamic_lite_ready_) || (!retained_only && !dynamic_fields_ready_) ||
        positions.is_empty()) return result;
    constexpr int VALUES_PER_BAND = 4;
    constexpr int ROW = 1 + 3 * VALUES_PER_BAND;
    result.resize(1 + positions.size() * ROW);
    double *out = result.ptrw();
    const auto started = std::chrono::steady_clock::now();
    for (int64_t point_index = 0; point_index < positions.size(); ++point_index) {
        const Vector3 point = positions[point_index];
        double *row = out + 1 + point_index * ROW;
        bool valid = std::isfinite(point.x) && std::isfinite(point.z);
        for (int band = 0; valid && band < 3; ++band) {
            double *values = row + 1 + band * VALUES_PER_BAND;
            if (retained_only) {
                valid = dynamic_lite_fields_[band].sample_lite_direct_spectrum(
                    point.x, point.z, values);
            } else {
                valid = band < static_cast<int>(core_.cascades.size()) &&
                    dynamic_fields_[band].sample_direct_spectrum(core_.cascades[band],
                        point.x, point.z, values);
            }
        }
        row[0] = valid ? 1.0 : 0.0;
    }
    const auto ended = std::chrono::steady_clock::now();
    out[0] = static_cast<double>(std::chrono::duration_cast<std::chrono::microseconds>(ended - started).count());
    return result;
}

Dictionary OceanQueryNative::compare_dynamic_lite_to_full(int band, int sample_stride) const {
    Dictionary result;
    if (!dynamic_lite_ready_ || !dynamic_fields_ready_ || band < 0 || band >= 3 ||
        !dynamic_fields_[band].ready()) return result;
    const int n = dynamic_lite_resolutions_[band];
    const double domain = dynamic_lite_fields_[band].domain_size_m();
    if (n <= 0 || domain <= 0.0) return result;
    const int comparison_resolution = 64 * std::max(1, sample_stride);
    const int stride = std::max(1, comparison_resolution / 64);
    std::array<std::vector<double>, 3> errors;
    for (auto &values : errors) values.reserve(4096);
    for (int z = 0; z < comparison_resolution; z += stride) for (int x = 0; x < comparison_resolution; x += stride) {
        const double wx = (x + 0.5) * domain / comparison_resolution - domain * 0.5;
        const double wz = (z + 0.5) * domain / comparison_resolution - domain * 0.5;
        double full[oq::DynamicOceanPhysicsField::FIELD_COUNT]{};
        double lite[5]{};
        if (!dynamic_fields_[band].sample_material_q(wx, wz, full) ||
            !dynamic_lite_fields_[band].sample_lite_surface(wx, wz, 0.0, lite)) return Dictionary();
        const double full_nx = -full[oq::DynamicOceanPhysicsField::HEIGHT_DX];
        const double full_nz = -full[oq::DynamicOceanPhysicsField::HEIGHT_DZ];
        const double inverse_length = 1.0 / std::sqrt(full_nx * full_nx + 1.0 + full_nz * full_nz);
        const double nx = full_nx * inverse_length, ny = inverse_length, nz = full_nz * inverse_length;
        errors[0].push_back(std::abs(lite[0] - full[oq::DynamicOceanPhysicsField::HEIGHT]));
        errors[1].push_back(std::abs(lite[1] - full[oq::DynamicOceanPhysicsField::VELOCITY_Y]));
        const double dot = std::clamp(lite[2] * nx + lite[3] * ny + lite[4] * nz, -1.0, 1.0);
        errors[2].push_back(std::acos(dot) * 180.0 / 3.14159265358979323846);
    }
    const char *names[] = {"height_error_m", "vertical_velocity_error_mps", "normal_angle_error_degrees"};
    for (size_t metric = 0; metric < errors.size(); ++metric) {
        auto &values = errors[metric];
        if (values.empty()) return Dictionary();
        double sum = 0.0, square_sum = 0.0;
        for (double value : values) { sum += value; square_sum += value * value; }
        std::sort(values.begin(), values.end());
        const size_t p95 = static_cast<size_t>(std::ceil(values.size() * 0.95)) - 1;
        const size_t p99 = static_cast<size_t>(std::ceil(values.size() * 0.99)) - 1;
        Dictionary stats;
        stats["count"] = static_cast<int64_t>(values.size());
        stats["mean"] = sum / values.size();
        stats["rms"] = std::sqrt(square_sum / values.size());
        stats["p95"] = values[p95]; stats["p99"] = values[p99]; stats["max"] = values.back();
        result[names[metric]] = stats;
    }
    double full_crest = -std::numeric_limits<double>::infinity();
    double lite_crest = full_crest;
    double full_trough = std::numeric_limits<double>::infinity();
    double lite_trough = full_trough;
    double full_crest_x = 0.0, lite_crest_x = 0.0, full_trough_x = 0.0, lite_trough_x = 0.0;
    for (int x = 0; x < n; ++x) {
        const double wx = (x + 0.5) * domain / n - domain * 0.5;
        double full[oq::DynamicOceanPhysicsField::FIELD_COUNT]{}, lite[5]{};
        if (!dynamic_fields_[band].sample_material_q(wx, 0.0, full) ||
            !dynamic_lite_fields_[band].sample_lite_surface(wx, 0.0, 0.0, lite)) return Dictionary();
        const double h_full = full[oq::DynamicOceanPhysicsField::HEIGHT];
        const double h_lite = lite[0];
        if (h_full > full_crest) { full_crest = h_full; full_crest_x = wx; }
        if (h_lite > lite_crest) { lite_crest = h_lite; lite_crest_x = wx; }
        if (h_full < full_trough) { full_trough = h_full; full_trough_x = wx; }
        if (h_lite < lite_trough) { lite_trough = h_lite; lite_trough_x = wx; }
    }
    constexpr int PROFILE_SAMPLES = 256;
    std::vector<double> full_profile(PROFILE_SAMPLES), lite_profile(PROFILE_SAMPLES);
    double full_mean = 0.0, lite_mean = 0.0;
    for (int i = 0; i < PROFILE_SAMPLES; ++i) {
        const double wx = (i + 0.5) * domain / PROFILE_SAMPLES - domain * 0.5;
        double full[oq::DynamicOceanPhysicsField::FIELD_COUNT]{}, lite[5]{};
        if (!dynamic_fields_[band].sample_material_q(wx, 0.0, full) ||
            !dynamic_lite_fields_[band].sample_lite_surface(wx, 0.0, 0.0, lite)) return Dictionary();
        full_profile[i] = full[oq::DynamicOceanPhysicsField::HEIGHT];
        lite_profile[i] = lite[0];
        full_mean += full_profile[i] / PROFILE_SAMPLES;
        lite_mean += lite_profile[i] / PROFILE_SAMPLES;
    }
    double full_variance = 0.0, lite_variance = 0.0, zero_covariance = 0.0;
    for (int i = 0; i < PROFILE_SAMPLES; ++i) {
        const double f = full_profile[i] - full_mean, l = lite_profile[i] - lite_mean;
        full_variance += f * f; lite_variance += l * l; zero_covariance += f * l;
    }
    const double denominator = std::sqrt(full_variance * lite_variance);
    const double zero_correlation = denominator > 0.0 ? zero_covariance / denominator : 0.0;
    double best_correlation = -std::numeric_limits<double>::infinity();
    int best_lag = 0;
    for (int lag = -PROFILE_SAMPLES / 4; lag <= PROFILE_SAMPLES / 4; ++lag) {
        double covariance = 0.0;
        for (int i = 0; i < PROFILE_SAMPLES; ++i) {
            int j = (i + lag) % PROFILE_SAMPLES;
            if (j < 0) j += PROFILE_SAMPLES;
            covariance += (full_profile[i] - full_mean) * (lite_profile[j] - lite_mean);
        }
        const double correlation = denominator > 0.0 ? covariance / denominator : 0.0;
        if (correlation > best_correlation) { best_correlation = correlation; best_lag = lag; }
    }
    struct ProfileExtremum { int index; bool crest; double amplitude; };
    std::vector<ProfileExtremum> full_extrema, lite_extrema;
    const double full_sigma = std::sqrt(full_variance / PROFILE_SAMPLES);
    const double lite_sigma = std::sqrt(lite_variance / PROFILE_SAMPLES);
    for (int i = 0; i < PROFILE_SAMPLES; ++i) {
        const int prev = (i + PROFILE_SAMPLES - 1) % PROFILE_SAMPLES;
        const int next = (i + 1) % PROFILE_SAMPLES;
        const double fv = full_profile[i], lv = lite_profile[i];
        if (fv >= full_profile[prev] && fv > full_profile[next] && fv - full_mean >= 0.25 * full_sigma)
            full_extrema.push_back({i, true, fv - full_mean});
        if (fv <= full_profile[prev] && fv < full_profile[next] && full_mean - fv >= 0.25 * full_sigma)
            full_extrema.push_back({i, false, full_mean - fv});
        if (lv >= lite_profile[prev] && lv > lite_profile[next] && lv - lite_mean >= 0.25 * lite_sigma)
            lite_extrema.push_back({i, true, lv - lite_mean});
        if (lv <= lite_profile[prev] && lv < lite_profile[next] && lite_mean - lv >= 0.25 * lite_sigma)
            lite_extrema.push_back({i, false, lite_mean - lv});
    }
    struct MatchPair { int full_index; int lite_index; int distance; double signed_distance_m; };
    std::vector<MatchPair> possible_matches;
    for (size_t fi = 0; fi < full_extrema.size(); ++fi) for (size_t li = 0; li < lite_extrema.size(); ++li) {
        if (full_extrema[fi].crest != lite_extrema[li].crest) continue;
        int signed_steps = lite_extrema[li].index - full_extrema[fi].index;
        if (signed_steps > PROFILE_SAMPLES / 2) signed_steps -= PROFILE_SAMPLES;
        if (signed_steps < -PROFILE_SAMPLES / 2) signed_steps += PROFILE_SAMPLES;
        possible_matches.push_back({static_cast<int>(fi), static_cast<int>(li), std::abs(signed_steps),
            signed_steps * domain / PROFILE_SAMPLES});
    }
    std::sort(possible_matches.begin(), possible_matches.end(), [](const MatchPair &a, const MatchPair &b) { return a.distance < b.distance; });
    std::vector<bool> full_matched(full_extrema.size(), false), lite_matched(lite_extrema.size(), false);
    std::vector<double> extrema_displacements;
    const int max_match_steps = PROFILE_SAMPLES / 8;
    for (const MatchPair &candidate : possible_matches) {
        if (candidate.distance > max_match_steps) break;
        if (full_matched[candidate.full_index] || lite_matched[candidate.lite_index]) continue;
        full_matched[candidate.full_index] = true; lite_matched[candidate.lite_index] = true;
        extrema_displacements.push_back(std::abs(candidate.signed_distance_m));
    }
    std::sort(extrema_displacements.begin(), extrema_displacements.end());
    Dictionary extrema_stats;
    extrema_stats["full_significant_count"] = static_cast<int64_t>(full_extrema.size());
    extrema_stats["reduced_significant_count"] = static_cast<int64_t>(lite_extrema.size());
    extrema_stats["matched_same_polarity_count"] = static_cast<int64_t>(extrema_displacements.size());
    extrema_stats["unmatched_full_count"] = static_cast<int64_t>(full_extrema.size() - extrema_displacements.size());
    extrema_stats["unmatched_reduced_count"] = static_cast<int64_t>(lite_extrema.size() - extrema_displacements.size());
    if (!extrema_displacements.empty()) {
        const size_t p95_index = static_cast<size_t>(std::ceil(extrema_displacements.size() * 0.95)) - 1;
        const size_t p99_index = static_cast<size_t>(std::ceil(extrema_displacements.size() * 0.99)) - 1;
        double squares = 0.0, sum = 0.0;
        for (double displacement : extrema_displacements) { sum += displacement; squares += displacement * displacement; }
        extrema_stats["displacement_mean_m"] = sum / extrema_displacements.size();
        extrema_stats["displacement_rms_m"] = std::sqrt(squares / extrema_displacements.size());
        extrema_stats["displacement_p95_m"] = extrema_displacements[p95_index];
        extrema_stats["displacement_p99_m"] = extrema_displacements[p99_index];
        extrema_stats["displacement_max_m"] = extrema_displacements.back();
    }
    Dictionary correlation;
    correlation["profile"] = "z=0 periodic world-X profile; mean centered; lag search +/- one quarter domain";
    correlation["normalized_zero_shift"] = zero_correlation;
    correlation["normalized_best_correlation"] = best_correlation;
    correlation["best_lag_samples"] = best_lag;
    correlation["best_translation_m"] = best_lag * domain / PROFILE_SAMPLES;
    correlation["sample_count"] = PROFILE_SAMPLES;
    result["spatial_correlation"] = correlation;
    result["significant_extrema_correspondence"] = extrema_stats;
    result["line_z_world_m"] = 0.0;
    result["crest_reference_x_m"] = full_crest_x;
    result["crest_lite_x_m"] = lite_crest_x;
    result["crest_offset_m"] = std::abs(full_crest_x - lite_crest_x);
    result["trough_reference_x_m"] = full_trough_x;
    result["trough_lite_x_m"] = lite_trough_x;
    result["trough_offset_m"] = std::abs(full_trough_x - lite_trough_x);
    result["reference"] = "synchronous full-resolution native Production spectrum fields";
    result["simulation_time"] = dynamic_lite_time_;
    result["band"] = band;
    result["sample_stride"] = stride;
    result["comparison_grid_resolution"] = comparison_resolution;
    return result;
}

Dictionary OceanQueryNative::compare_dynamic_lite_to_direct_spectrum(int band, int sample_count) const {
    Dictionary result;
    if (!dynamic_lite_ready_ || band < 0 || band >= 3 || sample_count <= 0) return result;
    const int n = dynamic_lite_resolutions_[band];
    const double domain = dynamic_lite_fields_[band].domain_size_m();
    // Each pattern is checked against a direct sum of the exact retained
    // spectrum. This separates grid interpolation from intentional low-pass
    // differences against the full Production spectrum.
    std::array<std::array<std::vector<double>, 3>, 5> errors;
    for (auto &pattern : errors) for (auto &metric : pattern) metric.reserve(static_cast<size_t>(sample_count));
    auto normalized_angle = [](const double *a, const double *b) {
        const double al = std::sqrt(a[0] * a[0] + 1.0 + a[1] * a[1]);
        const double bl = std::sqrt(b[0] * b[0] + 1.0 + b[1] * b[1]);
        const double dot = std::clamp((-a[0] * -b[0] + 1.0 + -a[1] * -b[1]) / (al * bl), -1.0, 1.0);
        return std::acos(dot) * 180.0 / 3.14159265358979323846;
    };
    auto record = [&](size_t pattern, double wx, double wz) {
        double grid[5]{}, direct[4]{};
        if (!dynamic_lite_fields_[band].sample_lite_surface(wx, wz, 0.0, grid) ||
            !dynamic_lite_fields_[band].sample_lite_direct_spectrum(wx, wz, direct)) return false;
        const double direct_gradient[] = {direct[2], direct[3]};
        const double grid_gradient[] = {-grid[2] / std::max(1.0e-12, grid[3]),
                                        -grid[4] / std::max(1.0e-12, grid[3])};
        errors[pattern][0].push_back(std::abs(grid[0] - direct[0]));
        errors[pattern][1].push_back(std::abs(grid[1] - direct[1]));
        errors[pattern][2].push_back(normalized_angle(grid_gradient, direct_gradient));
        return true;
    };
    for (int sample = 0; sample < sample_count; ++sample) {
        const uint32_t hash = static_cast<uint32_t>(sample + 1) * 2654435761u;
        const int x = static_cast<int>(hash % static_cast<uint32_t>(n));
        const int z = static_cast<int>((hash >> 11) % static_cast<uint32_t>(n));
        const double fx0 = static_cast<double>((hash >> 16) & 0xffffu) / 65536.0 - 0.5;
        const double fz0 = static_cast<double>((hash >> 3) & 0xffffu) / 65536.0 - 0.5;
        const double half_sign = (sample & 1) == 0 ? 0.5 : -0.5;
        const double quarter_sign = (sample & 1) == 0 ? 0.25 : -0.25;
        auto wx = [&](double fx) { return (x + 0.5 + fx) * domain / n - domain * 0.5; };
        auto wz = [&](double fz) { return (z + 0.5 + fz) * domain / n - domain * 0.5; };
        if (!record(0, wx(0.0), wz(0.0)) ||
            !record(1, wx(half_sign), wz(-half_sign)) ||
            !record(2, wx(quarter_sign), wz(-quarter_sign)) ||
            !record(3, wx(fx0), wz(fz0))) return Dictionary();
        const double epsilon = domain / n * 1.0e-5;
        const double edge_x = (sample & 1) == 0 ? domain * 0.5 - epsilon : -domain * 0.5 + epsilon;
        const double edge_z = (sample & 2) == 0 ? domain * 0.5 - epsilon : -domain * 0.5 + epsilon;
        if (!record(4, edge_x, edge_z)) return Dictionary();
    }
    auto stats = [](std::vector<double> &values) {
        Dictionary row;
        std::sort(values.begin(), values.end());
        double sum = 0.0, square = 0.0;
        for (double value : values) { sum += value; square += value * value; }
        const size_t p95 = static_cast<size_t>(std::ceil(values.size() * 0.95)) - 1;
        const size_t p99 = static_cast<size_t>(std::ceil(values.size() * 0.99)) - 1;
        row["count"] = static_cast<int64_t>(values.size());
        row["mean"] = sum / values.size();
        row["rms"] = std::sqrt(square / values.size());
        row["p95"] = values[p95]; row["p99"] = values[p99]; row["max"] = values.back();
        return row;
    };
    const char *metric_names[] = {"height_error_m", "vertical_velocity_error_mps", "normal_angle_error_degrees"};
    const char *pattern_names[] = {"texel_centers", "half_texel_offsets", "quarter_texel_offsets", "deterministic_random", "wrap_boundaries"};
    Dictionary pattern_results;
    for (size_t pattern = 0; pattern < errors.size(); ++pattern) {
        Dictionary metrics;
        for (size_t metric = 0; metric < errors[pattern].size(); ++metric)
            metrics[metric_names[metric]] = stats(errors[pattern][metric]);
        pattern_results[pattern_names[pattern]] = metrics;
    }
    const Dictionary center_metrics = pattern_results["texel_centers"];
    const Dictionary random_metrics = pattern_results["deterministic_random"];
    result["band"] = band;
    result["resolution"] = n;
    result["simulation_time"] = dynamic_lite_time_;
    result["oracle"] = "direct sum of evolved retained reduced-grid HEIGHT/VELOCITY spectra and analytic spectral height gradients";
    result["height_error_m"] = center_metrics["height_error_m"];
    result["vertical_velocity_error_mps"] = center_metrics["vertical_velocity_error_mps"];
    result["sampling_patterns"] = pattern_results;
    Dictionary arbitrary;
    arbitrary["coordinate_contract"] = "deterministic random fractional offsets inside texel cells; compares bilinear HEIGHT/VY and finite-difference NORMAL against direct retained-spectrum evaluation";
    arbitrary["height_error_m"] = random_metrics["height_error_m"];
    arbitrary["vertical_velocity_error_mps"] = random_metrics["vertical_velocity_error_mps"];
    arbitrary["normal_angle_error_degrees"] = random_metrics["normal_angle_error_degrees"];
    result["arbitrary_world_xz"] = arbitrary;
    return result;
}

Dictionary OceanQueryNative::compare_dynamic_lite_combined_to_full(int sample_count) const {
    Dictionary result;
    if (!dynamic_lite_ready_ || !dynamic_fields_ready_ || sample_count <= 0) return result;
    for (int band = 0; band < 3; ++band)
        if (!dynamic_fields_[band].ready() || !dynamic_lite_fields_[band].ready()) return result;
    const double domain = dynamic_fields_[0].domain_size_m();
    std::array<std::vector<double>, 3> errors;
    for (auto &values : errors) values.reserve(static_cast<size_t>(sample_count));
    auto angle_error = [](double ax, double az, double bx, double bz) {
        const double al = std::sqrt(ax * ax + 1.0 + az * az), bl = std::sqrt(bx * bx + 1.0 + bz * bz);
        return std::acos(std::clamp((ax * bx + 1.0 + az * bz) / (al * bl), -1.0, 1.0)) *
            180.0 / 3.14159265358979323846;
    };
    for (int sample = 0; sample < sample_count; ++sample) {
        const uint32_t hash_x = static_cast<uint32_t>(sample + 1) * 2654435761u;
        const uint32_t hash_z = static_cast<uint32_t>(sample + 3) * 2246822519u;
        const double wx = (static_cast<double>(hash_x) / 4294967296.0 - 0.5) * domain;
        const double wz = (static_cast<double>(hash_z) / 4294967296.0 - 0.5) * domain;
        double full_h = 0.0, full_v = 0.0, full_dx = 0.0, full_dz = 0.0;
        double lite_h = 0.0, lite_v = 0.0, lite_dx = 0.0, lite_dz = 0.0;
        for (int band = 0; band < 3; ++band) {
            double full[oq::DynamicOceanPhysicsField::FIELD_COUNT]{}, lite[5]{};
            if (!dynamic_fields_[band].sample_material_q(wx, wz, full) ||
                !dynamic_lite_fields_[band].sample_lite_surface(wx, wz, 0.0, lite)) return Dictionary();
            full_h += full[oq::DynamicOceanPhysicsField::HEIGHT];
            full_v += full[oq::DynamicOceanPhysicsField::VELOCITY_Y];
            full_dx += full[oq::DynamicOceanPhysicsField::HEIGHT_DX];
            full_dz += full[oq::DynamicOceanPhysicsField::HEIGHT_DZ];
            lite_h += lite[0]; lite_v += lite[1];
            lite_dx -= lite[2] / std::max(1.0e-12, lite[3]);
            lite_dz -= lite[4] / std::max(1.0e-12, lite[3]);
        }
        errors[0].push_back(std::abs(lite_h - full_h));
        errors[1].push_back(std::abs(lite_v - full_v));
        errors[2].push_back(angle_error(lite_dx, lite_dz, full_dx, full_dz));
    }
    const char *metric_names[] = {"height_error_m", "vertical_velocity_error_mps", "normal_angle_error_degrees"};
    Dictionary pointwise;
    for (size_t metric = 0; metric < errors.size(); ++metric) {
        auto &values = errors[metric];
        std::sort(values.begin(), values.end());
        double sum = 0.0, square = 0.0;
        for (double value : values) { sum += value; square += value * value; }
        Dictionary stats;
        stats["count"] = static_cast<int64_t>(values.size());
        stats["mean"] = sum / values.size();
        stats["rms"] = std::sqrt(square / values.size());
        stats["p95"] = values[static_cast<size_t>(std::ceil(values.size() * 0.95)) - 1];
        stats["p99"] = values[static_cast<size_t>(std::ceil(values.size() * 0.99)) - 1];
        stats["max"] = values.back();
        pointwise[metric_names[metric]] = stats;
    }
    result["pointwise_absolute_error"] = pointwise;
    constexpr int PROFILE_SAMPLES = 256;
    std::array<double, PROFILE_SAMPLES> full_profile{}, lite_profile{};
    double full_mean = 0.0, lite_mean = 0.0;
    for (int i = 0; i < PROFILE_SAMPLES; ++i) {
        const double wx = (i + 0.5) * domain / PROFILE_SAMPLES - domain * 0.5;
        for (int band = 0; band < 3; ++band) {
            double full[oq::DynamicOceanPhysicsField::FIELD_COUNT]{}, lite[5]{};
            if (!dynamic_fields_[band].sample_material_q(wx, 0.0, full) ||
                !dynamic_lite_fields_[band].sample_lite_surface(wx, 0.0, 0.0, lite)) return Dictionary();
            full_profile[i] += full[oq::DynamicOceanPhysicsField::HEIGHT];
            lite_profile[i] += lite[0];
        }
        full_mean += full_profile[i] / PROFILE_SAMPLES;
        lite_mean += lite_profile[i] / PROFILE_SAMPLES;
    }
    double full_variance = 0.0, lite_variance = 0.0, zero_covariance = 0.0;
    for (int i = 0; i < PROFILE_SAMPLES; ++i) {
        const double f = full_profile[i] - full_mean, l = lite_profile[i] - lite_mean;
        full_variance += f * f; lite_variance += l * l; zero_covariance += f * l;
    }
    const double denom = std::sqrt(full_variance * lite_variance);
    const double zero_corr = denom > 0.0 ? zero_covariance / denom : 0.0;
    double best_corr = -std::numeric_limits<double>::infinity();
    int best_lag = 0;
    for (int lag = -PROFILE_SAMPLES / 4; lag <= PROFILE_SAMPLES / 4; ++lag) {
        double covariance = 0.0;
        for (int i = 0; i < PROFILE_SAMPLES; ++i) {
            int j = (i + lag) % PROFILE_SAMPLES;
            if (j < 0) j += PROFILE_SAMPLES;
            covariance += (full_profile[i] - full_mean) * (lite_profile[j] - lite_mean);
        }
        const double corr = denom > 0.0 ? covariance / denom : 0.0;
        if (corr > best_corr) { best_corr = corr; best_lag = lag; }
    }
    Dictionary correlation;
    correlation["profile"] = "combined periodic z=0 world-X line; normalized mean-centered height; lag search +/- quarter LONG domain";
    correlation["normalized_zero_shift"] = zero_corr;
    correlation["normalized_best_correlation"] = best_corr;
    correlation["best_lag_samples"] = best_lag;
    correlation["best_translation_m"] = best_lag * domain / PROFILE_SAMPLES;
    result["spatial_correlation"] = correlation;
    result["sample_count"] = sample_count;
    result["simulation_time"] = dynamic_lite_time_;
    return result;
}

Array OceanQueryNative::validate_dynamic_lite_single_modes(int band, const PackedInt32Array &resolutions) const {
    Array results;
    if (band < 0 || band >= 3 || core_.cascades.size() != 3) return results;
    constexpr double TAU = 6.283185307179586476925286766559;
    constexpr double AMPLITUDE = 0.75;
    const oq::Cascade &production = core_.cascades[band];
    const int source_n = production.material_resolution;
    const int source_center = source_n / 2;
    const double domain = production.material_domain_m;
    if (source_n < 2 || domain <= 0.0) return results;

    for (int resolution_index = 0; resolution_index < resolutions.size(); ++resolution_index) {
        const int n = resolutions[resolution_index];
        if (n < 2 || n > source_n || (n & (n - 1)) != 0) continue;
        std::vector<std::array<int, 2>> modes{{1, 0}, {-1, 0}, {0, 3}, {0, -3}, {5, -7}, {-5, 7},
            {n / 2 - 1, 0}, {-(n / 2 - 1), 1}};
        const bool can_test_boundary = n < source_n;
        if (can_test_boundary) modes.push_back({n / 2, 0});
        for (const auto &mode : modes) {
            const int kx = mode[0], kz = mode[1];
            const bool source_representable = std::abs(kx) < source_center && std::abs(kz) < source_center;
            if (!source_representable) continue;
            const int sx = source_center + kx, sz = source_center + kz;
            const int nx = source_center - kx, nz = source_center - kz;
            const size_t source_index = static_cast<size_t>(sz) * source_n + sx;
            const size_t negative_index = static_cast<size_t>(nz) * source_n + nx;
            oq::Cascade synthetic = production;
            const size_t source_count = static_cast<size_t>(source_n) * source_n;
            std::fill(synthetic.h0_re.begin(), synthetic.h0_re.end(), 0.0);
            std::fill(synthetic.h0_im.begin(), synthetic.h0_im.end(), 0.0);
            std::fill(synthetic.h0n_re.begin(), synthetic.h0n_re.end(), 0.0);
            std::fill(synthetic.h0n_im.begin(), synthetic.h0n_im.end(), 0.0);
            std::fill(synthetic.omega.begin(), synthetic.omega.end(), 0.0);
            std::fill(synthetic.parity.begin(), synthetic.parity.end(), 1.0);
            std::fill(synthetic.weight.begin(), synthetic.weight.end(), 1.0);
            for (int z = 0; z < source_n; ++z) for (int x = 0; x < source_n; ++x) {
                const int signed_x = x - source_center, signed_z = z - source_center;
                const size_t i = static_cast<size_t>(z) * source_n + x;
                synthetic.kx[i] = TAU * signed_x / domain;
                synthetic.ky[i] = TAU * signed_z / domain;
            }
            const double coefficient = AMPLITUDE * 0.5 * source_n * source_n;
            synthetic.h0_re[source_index] = coefficient;
            synthetic.h0_re[negative_index] = coefficient;
            oq::DynamicOceanPhysicsField field;
            const bool configured = field.configure_lite(synthetic, n);
            const bool retained = std::abs(kx) < n / 2 && std::abs(kz) < n / 2;
            const bool built = configured && field.build_lite(0.0, false);
            double square_error = 0.0, maximum_error = 0.0;
            int samples = 0;
            if (built) for (int z = 0; z < n; ++z) for (int x = 0; x < n; ++x) {
                const double wx = (x + 0.5) * domain / n - domain * 0.5;
                const double wz = (z + 0.5) * domain / n - domain * 0.5;
                double actual[5]{};
                if (!field.sample_lite_surface(wx, wz, 0.0, actual)) { samples = -1; break; }
                const double expected = retained ? AMPLITUDE * std::cos(
                    TAU * kx * (wx + domain * 0.5 - domain / (2.0 * source_n)) / domain +
                    TAU * kz * (wz + domain * 0.5 - domain / (2.0 * source_n)) / domain) : 0.0;
                const double error = std::abs(actual[0] - expected);
                square_error += error * error;
                maximum_error = std::max(maximum_error, error);
                ++samples;
            }
            double direct_spectrum_error = -1.0;
            if (built) {
                const int x = 7 % n, z = 11 % n;
                const double wx = (x + 0.5) * domain / n - domain * 0.5;
                const double wz = (z + 0.5) * domain / n - domain * 0.5;
                double actual[5]{}, direct[4]{};
                if (field.sample_lite_surface(wx, wz, 0.0, actual) &&
                    field.sample_lite_direct_spectrum(wx, wz, direct))
                    direct_spectrum_error = std::abs(actual[0] - direct[0]);
            }
            Dictionary row;
            row["resolution"] = n; row["kx_signed"] = kx; row["kz_signed"] = kz;
            row["source_x_index"] = sx; row["source_z_index"] = sz;
            row["destination_x_index"] = n / 2 + kx; row["destination_z_index"] = n / 2 + kz;
            row["world_kx_rad_m"] = TAU * kx / domain; row["world_kz_rad_m"] = TAU * kz / domain;
            row["retained"] = retained; row["built"] = built; row["sample_count"] = samples;
            row["height_rms_error_m"] = samples > 0 ? std::sqrt(square_error / samples) : -1.0;
            row["height_max_error_m"] = maximum_error;
            row["direct_spectrum_sample_error_m"] = direct_spectrum_error;
            row["normalization_amplitude_m"] = AMPLITUDE;
            row["oracle"] = "analytical conjugate-pair cosine; direct reduced-spectrum sum also checked at every destination texel center";
            results.push_back(row);
        }
    }
    return results;
}

Array OceanQueryNative::audit_dynamic_lite_bin_mapping(int band, const PackedInt32Array &resolutions) const {
    Array results;
    if (band < 0 || band >= 3 || core_.cascades.size() != 3) return results;
    constexpr double TAU = 6.283185307179586476925286766559;
    const oq::Cascade &source = core_.cascades[band];
    const int source_n = source.material_resolution, source_center = source_n / 2;
    const double domain = source.material_domain_m;
    for (int ri = 0; ri < resolutions.size(); ++ri) {
        const int n = resolutions[ri];
        if (n < 2 || n > source_n || (n & (n - 1)) != 0) continue;
        oq::DynamicOceanPhysicsField field;
        if (!field.configure_lite(source, n)) continue;
        const oq::Cascade &destination = field.lite_cascade();
        const int center = n / 2;
        uint64_t retained = 0;
        double max_copy_error = 0.0, max_source_grid_error = 0.0;
        for (int z = 0; z < n; ++z) for (int x = 0; x < n; ++x) {
            const int kx = x - center, kz = z - center;
            if (std::abs(kx) >= center || std::abs(kz) >= center) continue;
            const size_t src = static_cast<size_t>(source_center + kz) * source_n + source_center + kx;
            const size_t dst = static_cast<size_t>(z) * n + x;
            max_copy_error = std::max(max_copy_error, std::abs(destination.kx[dst] - source.kx[src]));
            max_copy_error = std::max(max_copy_error, std::abs(destination.ky[dst] - source.ky[src]));
            max_copy_error = std::max(max_copy_error, std::abs(destination.omega[dst] - source.omega[src]));
            max_source_grid_error = std::max(max_source_grid_error,
                std::abs(source.kx[src] - TAU * kx / domain));
            max_source_grid_error = std::max(max_source_grid_error,
                std::abs(source.ky[src] - TAU * kz / domain));
            ++retained;
        }
        Array examples;
        std::vector<std::array<int, 2>> signed_examples{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {5, -7},
            {center - 1, 0}, {-(center - 1), 1}};
        for (const auto &mode : signed_examples) {
            const int kx = mode[0], kz = mode[1];
            if (std::abs(kx) >= center || std::abs(kz) >= center) continue;
            const int source_x = source_center + kx, source_z = source_center + kz;
            const int destination_x = center + kx, destination_z = center + kz;
            const size_t src = static_cast<size_t>(source_z) * source_n + source_x;
            const size_t dst = static_cast<size_t>(destination_z) * n + destination_x;
            Dictionary example;
            example["signed_kx"] = kx; example["signed_kz"] = kz;
            example["source_x_index"] = source_x; example["source_z_index"] = source_z;
            example["destination_x_index"] = destination_x; example["destination_z_index"] = destination_z;
            example["source_world_kx_rad_m"] = source.kx[src];
            example["destination_world_kx_rad_m"] = destination.kx[dst];
            example["source_world_kz_rad_m"] = source.ky[src];
            example["destination_world_kz_rad_m"] = destination.ky[dst];
            examples.push_back(example);
        }
        Dictionary row;
        row["band"] = band; row["source_resolution"] = source_n; row["destination_resolution"] = n;
        row["mapping"] = "source signed (kx,kz); source array (Ns/2+kx,Ns/2+kz) -> destination signed (kx,kz); destination array (N/2+kx,N/2+kz)";
        row["cutoff"] = "retain iff abs(kx)<N/2 and abs(kz)<N/2; both signed sides kept; Nyquist row/column excluded";
        row["retained_bin_count"] = static_cast<int64_t>(retained);
        row["excluded_bin_count"] = static_cast<int64_t>(static_cast<size_t>(n) * n - retained);
        row["max_copied_k_omega_error"] = max_copy_error;
        row["max_source_vs_signed_grid_k_error_rad_m"] = max_source_grid_error;
        row["dk_source_rad_m"] = TAU / domain;
        row["dk_destination_rad_m"] = TAU / domain;
        row["examples"] = examples;
        results.push_back(row);
    }
    return results;
}

bool OceanQueryNative::start_dynamic_async_fields(double initial_simulation_time, uint64_t initial_tick_id) {
    if (dynamic_async_) return false;
    if (core_.cascades.size() < 3) return false;
    if ((!dynamic_fields_ready_ || std::abs(dynamic_field_time_ - initial_simulation_time) > 1.0e-9) &&
        !build_dynamic_physics_fields(initial_simulation_time)) return false;
    const auto cascades = capture_dynamic_cascades(core_.cascades);
    auto publisher = std::make_shared<oq::DynamicOceanAsyncPublisher>(dynamic_fields_, cascades,
        initial_simulation_time, initial_tick_id, dynamic_configuration_version_, core_.avx2_supported());
    const bool valid = publisher->valid();
    std::atomic_store(&dynamic_async_, std::move(publisher));
    return valid;
}

PackedInt64Array OceanQueryNative::advance_dynamic_async(uint64_t tick_id, double current_time,
        double next_time, double wall_dt_seconds) {
    PackedInt64Array result;
    if (!dynamic_async_) return result;
    const auto tick = dynamic_async_->advance(tick_id, current_time, next_time, wall_dt_seconds);
    result.resize(8);
    result[0] = tick.published ? 1 : 0;
    result[1] = tick.scheduled ? 1 : 0;
    result[2] = tick.current_time_ready ? 1 : 0;
    result[3] = static_cast<int64_t>(tick.field_time * 1000000000.0);
    result[4] = static_cast<int64_t>(tick.field_tick);
    result[5] = static_cast<int64_t>(tick.field_age_ticks);
    result[6] = static_cast<int64_t>(tick.main_wait_us);
    result[7] = static_cast<int64_t>(std::llround(tick.field_age_ticks * 1000000.0));
    return result;
}

String OceanQueryNative::get_dynamic_async_build_id() const {
    return String("PHYS-OPT-2J-world-numerics-v2");
}

PackedInt64Array OceanQueryNative::get_dynamic_async_stats() const {
    PackedInt64Array result;
    if (!dynamic_async_) return result;
    const auto s = dynamic_async_->stats();
    result.resize(35);
    result[0] = static_cast<int64_t>(s.ticks);
    result[1] = static_cast<int64_t>(s.requests);
    result[2] = static_cast<int64_t>(s.builds_started);
    result[3] = static_cast<int64_t>(s.builds_finished);
    result[4] = static_cast<int64_t>(s.publications);
    result[5] = static_cast<int64_t>(s.ready_early);
    result[6] = static_cast<int64_t>(s.ready_on_time);
    result[7] = static_cast<int64_t>(s.missed_deadlines);
    result[8] = static_cast<int64_t>(s.max_missed_streak);
    result[9] = static_cast<int64_t>(s.stale_ticks);
    result[10] = static_cast<int64_t>(s.max_age_ticks);
    result[11] = static_cast<int64_t>(s.discarded_obsolete);
    result[12] = static_cast<int64_t>(s.swaps);
    result[13] = static_cast<int64_t>(s.wait_total_us);
    result[14] = static_cast<int64_t>(s.wait_max_us);
    result[15] = static_cast<int64_t>(s.build_total_us);
    result[16] = static_cast<int64_t>(s.build_max_us);
    result[17] = static_cast<int64_t>(s.last_requested_ns);
    result[18] = static_cast<int64_t>(s.last_started_ns);
    result[19] = static_cast<int64_t>(s.last_finished_ns);
    result[20] = static_cast<int64_t>(s.last_published_ns);
    result[21] = static_cast<int64_t>(s.configuration_version);
    result[22] = static_cast<int64_t>(s.worker_state);
    result[23] = static_cast<int64_t>(std::llround(s.last_age_ticks * 1000000.0));
    result[24] = static_cast<int64_t>(s.coalesced_requests);
    result[25] = static_cast<int64_t>(s.obsolete_builds);
    result[26] = static_cast<int64_t>(s.buffer_wait_us);
    result[27] = static_cast<int64_t>(s.last_long_evolution_us);
    result[28] = static_cast<int64_t>(s.last_mid_evolution_us);
    result[29] = static_cast<int64_t>(s.last_short_evolution_us);
    result[30] = static_cast<int64_t>(s.last_long_transform_us);
    result[31] = static_cast<int64_t>(s.last_mid_transform_us);
    result[32] = static_cast<int64_t>(s.last_short_transform_us);
    result[33] = static_cast<int64_t>(s.configuration_phase_resets);
    result[34] = static_cast<int64_t>(s.last_build_duration_us);
    return result;
}

PackedInt64Array OceanQueryNative::get_dynamic_async_profile_us() const {
    PackedInt64Array result;
    if (!dynamic_async_) return result;
    const auto profile = dynamic_async_->build_profile_us();
    result.resize(static_cast<int64_t>(profile.size()));
    for (size_t i = 0; i < profile.size(); ++i) result[static_cast<int64_t>(i)] = static_cast<int64_t>(profile[i]);
    return result;
}

PackedInt64Array OceanQueryNative::get_dynamic_snapshot_info() const {
    PackedInt64Array result;
    if (!dynamic_async_) return result;
    const auto snapshot = dynamic_async_->acquire_snapshot();
    result.resize(6);
    result[0] = snapshot && snapshot->valid ? 1 : 0;
    result[1] = snapshot ? static_cast<int64_t>(snapshot->simulation_time * 1000000000.0) : 0;
    result[2] = snapshot ? static_cast<int64_t>(snapshot->physics_tick_id) : 0;
    result[3] = snapshot ? static_cast<int64_t>(snapshot->configuration_version) : 0;
    result[4] = snapshot ? static_cast<int64_t>(snapshot->generation) : 0;
    result[5] = snapshot ? static_cast<int64_t>(std::llround(snapshot->weather_alpha * 1000000000.0)) : 0;
    return result;
}

PackedInt64Array OceanQueryNative::get_dynamic_snapshot_band_times() const {
    PackedInt64Array result;
    if (!dynamic_async_) return result;
    const auto snapshot = dynamic_async_->acquire_snapshot();
    result.resize(3);
    if (!snapshot || !snapshot->valid) return result;
    for (int band = 0; band < 3; ++band)
        result[band] = static_cast<int64_t>(snapshot->bands[static_cast<size_t>(band)].simulation_time * 1000000000.0);
    return result;
}

uint64_t OceanQueryNative::run_dynamic_contention_us(uint64_t duration_us) {
    const auto start = std::chrono::steady_clock::now();
    const auto deadline = start + std::chrono::microseconds(duration_us);
    double value = 0.123456789;
    do {
        for (int i = 0; i < 256; ++i) {
            value = value * 1.00000011920928955078125 + 0.00000095367431640625;
            value -= std::floor(value);
        }
    } while (std::chrono::steady_clock::now() < deadline);
    static volatile double sink = 0.0;
    sink = value;
    const auto end = std::chrono::steady_clock::now();
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(end - start).count());
}

int OceanQueryNative::set_dynamic_worker_count(int count) {
    return oq::DynamicOceanPhysicsField::set_worker_count(count);
}

int OceanQueryNative::get_dynamic_worker_count() const {
    return oq::DynamicOceanPhysicsField::worker_count();
}

PackedFloat64Array OceanQueryNative::get_dynamic_phase_recurrence_errors(double start_time, double delta_time) const {
    PackedFloat64Array result; result.resize(12);
    for (int band = 0; band < 3; ++band) {
        const std::array<double, 4> errors = dynamic_fields_[band].measure_phase_recurrence_error(
            core_.cascades[band], start_time, delta_time, core_.avx2_supported());
        for (int sample = 0; sample < 4; ++sample) result[band * 4 + sample] = errors[sample];
    }
    return result;
}

bool OceanQueryNative::sample_dynamic_band_(int band, double qx, double qz, double *out,
        const oq::DynamicOceanSnapshot *snapshot) const {
    if (band < 0 || band >= 3 || out == nullptr) return false;
    if (snapshot != nullptr) {
        const auto &b = snapshot->bands[static_cast<size_t>(band)];
        if (b.packed_fields_layout) return snapshot->valid && oq::DynamicOceanPhysicsField::sample_material_q_packed_from(
            b.packed_fields, b.resolution, b.domain_m, qx, qz, out);
        return snapshot->valid && oq::DynamicOceanPhysicsField::sample_material_q_from(
            b.fields, b.resolution, b.domain_m, qx, qz, out);
    }
    return dynamic_fields_[band].ready() && dynamic_fields_[band].sample_material_q(qx, qz, out);
}

void OceanQueryNative::sample_dynamic_material_q_(double qx, double qz, double *out,
        double *jacobian, const oq::DynamicOceanSnapshot *snapshot, bool displacement_only) const {
    if (out == nullptr) return;
    if ((snapshot != nullptr && !snapshot->valid) || (snapshot == nullptr && !dynamic_fields_ready_)) {
        std::fill(out, out + oq::S_STRIDE, 0.0); return;
    }
    double bands[3][oq::DynamicOceanPhysicsField::FIELD_COUNT] = {};
    for (int band = 0; band < 3; ++band) {
        sample_dynamic_band_(band, qx, qz, bands[band], snapshot);
    }
    auto sample_displacement = [&](double sx, double sz, double &h, double &dx, double &dz,
                                   double &vh, double &vx, double &vz) {
        double long_fields[oq::DynamicOceanPhysicsField::FIELD_COUNT] = {};
        double mid_fields[oq::DynamicOceanPhysicsField::FIELD_COUNT] = {};
        double short_fields[oq::DynamicOceanPhysicsField::FIELD_COUNT] = {};
        sample_dynamic_band_(0, sx, sz, long_fields, snapshot);
        sample_dynamic_band_(1, sx, sz, mid_fields, snapshot);
        sample_dynamic_band_(2, sx, sz, short_fields, snapshot);
        double coastal_h = long_fields[oq::DynamicOceanPhysicsField::HEIGHT];
        double coastal_dx = long_fields[oq::DynamicOceanPhysicsField::DISPLACE_X];
        double coastal_dz = long_fields[oq::DynamicOceanPhysicsField::DISPLACE_Z];
        double coastal_vh = long_fields[oq::DynamicOceanPhysicsField::VELOCITY_Y];
        double coastal_vx = long_fields[oq::DynamicOceanPhysicsField::VELOCITY_X];
        double coastal_vz = long_fields[oq::DynamicOceanPhysicsField::VELOCITY_Z];
        oq::CoastalSample sample;
        if (core_.coastal.sample(sx, sz, sample) && sample.confidence > 0.0) {
            double deep[oq::DynamicOceanPhysicsField::FIELD_COUNT] = {};
            if (sample_dynamic_band_(0, sample.warp_x, sample.warp_z, deep, snapshot)) {
                const double c = sample.confidence;
                const double shoal = 1.0 + (sample.shoaling - 1.0) * c;
                coastal_h = (coastal_h * (1.0 - c) + deep[oq::DynamicOceanPhysicsField::HEIGHT] * c) * shoal;
                coastal_dx = coastal_dx * (1.0 - c) + deep[oq::DynamicOceanPhysicsField::DISPLACE_X] * c;
                coastal_dz = coastal_dz * (1.0 - c) + deep[oq::DynamicOceanPhysicsField::DISPLACE_Z] * c;
                coastal_vh = (coastal_vh * (1.0 - c) + deep[oq::DynamicOceanPhysicsField::VELOCITY_Y] * c) * shoal;
                coastal_vx = coastal_vx * (1.0 - c) + deep[oq::DynamicOceanPhysicsField::VELOCITY_X] * c;
                coastal_vz = coastal_vz * (1.0 - c) + deep[oq::DynamicOceanPhysicsField::VELOCITY_Z] * c;
            }
        }
        h = coastal_h + mid_fields[oq::DynamicOceanPhysicsField::HEIGHT] + short_fields[oq::DynamicOceanPhysicsField::HEIGHT];
        dx = coastal_dx + mid_fields[oq::DynamicOceanPhysicsField::DISPLACE_X] + short_fields[oq::DynamicOceanPhysicsField::DISPLACE_X];
        dz = coastal_dz + mid_fields[oq::DynamicOceanPhysicsField::DISPLACE_Z] + short_fields[oq::DynamicOceanPhysicsField::DISPLACE_Z];
        vh = coastal_vh + mid_fields[oq::DynamicOceanPhysicsField::VELOCITY_Y] + short_fields[oq::DynamicOceanPhysicsField::VELOCITY_Y];
        vx = coastal_vx + mid_fields[oq::DynamicOceanPhysicsField::VELOCITY_X] + short_fields[oq::DynamicOceanPhysicsField::VELOCITY_X];
        vz = coastal_vz + mid_fields[oq::DynamicOceanPhysicsField::VELOCITY_Z] + short_fields[oq::DynamicOceanPhysicsField::VELOCITY_Z];
    };
    double h = bands[0][oq::DynamicOceanPhysicsField::HEIGHT];
    double dx = bands[0][oq::DynamicOceanPhysicsField::DISPLACE_X];
    double dz = bands[0][oq::DynamicOceanPhysicsField::DISPLACE_Z];
    double vh = bands[0][oq::DynamicOceanPhysicsField::VELOCITY_Y];
    double vx = bands[0][oq::DynamicOceanPhysicsField::VELOCITY_X];
    double vz = bands[0][oq::DynamicOceanPhysicsField::VELOCITY_Z];
    // Coastal LONG is a warped blend, while MID/SHORT remain at material q.
    sample_displacement(qx, qz, h, dx, dz, vh, vx, vz);

    if (displacement_only) {
        std::fill(out, out + oq::S_STRIDE, 0.0);
        out[oq::S_VALID] = 1.0; out[oq::S_HEIGHT] = core_.sea_level + h;
        out[oq::S_DX] = dx; out[oq::S_DY] = h; out[oq::S_DZ] = dz;
        out[oq::S_VX] = vx; out[oq::S_VY] = vh; out[oq::S_VZ] = vz;
        return;
    }

    double dhx = 0.0, dhz = 0.0, dxx = 0.0, dxz = 0.0, dzx = 0.0, dzz = 0.0;
    if (!core_.coastal.enabled) {
        for (int band = 0; band < 3; ++band) {
            dhx += bands[band][oq::DynamicOceanPhysicsField::HEIGHT_DX];
            dhz += bands[band][oq::DynamicOceanPhysicsField::HEIGHT_DZ];
            dxx += bands[band][oq::DynamicOceanPhysicsField::DISPLACE_XX];
            dxz += bands[band][oq::DynamicOceanPhysicsField::DISPLACE_XZ];
            dzx += bands[band][oq::DynamicOceanPhysicsField::DISPLACE_ZX];
            dzz += bands[band][oq::DynamicOceanPhysicsField::DISPLACE_ZZ];
        }
    } else {
        constexpr double eps = 0.01;
        double hp, dxp, dzp, vhp, vxp, vzp, hm, dxm, dzm, vhm, vxm, vzm;
        sample_displacement(qx + eps, qz, hp, dxp, dzp, vhp, vxp, vzp);
        sample_displacement(qx - eps, qz, hm, dxm, dzm, vhm, vxm, vzm);
        dhx = (hp - hm) / (2.0 * eps);
        dxx = (dxp - dxm) / (2.0 * eps);
        dzx = (dzp - dzm) / (2.0 * eps);
        sample_displacement(qx, qz + eps, hp, dxp, dzp, vhp, vxp, vzp);
        sample_displacement(qx, qz - eps, hm, dxm, dzm, vhm, vxm, vzm);
        dhz = (hp - hm) / (2.0 * eps);
        dxz = (dxp - dxm) / (2.0 * eps);
        dzz = (dzp - dzm) / (2.0 * eps);
    }
    double nx = dhz * dzx - (1.0 + dzz) * dhx;
    double ny = (1.0 + dzz) * (1.0 + dxx) - dxz * dzx;
    double nz = dxz * dhx - dhz * (1.0 + dxx);
    const double length = std::sqrt(nx * nx + ny * ny + nz * nz);
    if (length > 1e-12) { nx /= length; ny /= length; nz /= length; if (ny < 0.0) { nx = -nx; ny = -ny; nz = -nz; } }
    else { nx = 0.0; ny = 1.0; nz = 0.0; }
    const double determinant = (1.0 + dxx) * (1.0 + dzz) - dxz * dzx;
    if (jacobian != nullptr) {
        jacobian[0] = 1.0 + dxx; jacobian[1] = dxz;
        jacobian[2] = dzx; jacobian[3] = 1.0 + dzz;
    }
    out[oq::S_VALID] = 1.0; out[oq::S_HEIGHT] = core_.sea_level + h;
    out[oq::S_DX] = dx; out[oq::S_DY] = h; out[oq::S_DZ] = dz;
    out[oq::S_NX] = nx; out[oq::S_NY] = ny; out[oq::S_NZ] = nz;
    out[oq::S_VX] = vx; out[oq::S_VY] = vh; out[oq::S_VZ] = vz;
    out[oq::S_JACOBIAN_DET] = determinant; out[oq::S_FOLDOVER] = determinant <= 0.0 ? 1.0 : 0.0;
    out[oq::S_RESIDUAL] = 0.0; out[oq::S_ITERATIONS] = 0.0;
    (void)dynamic_field_time_;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_material_q(double qx, double qz) {
    PackedFloat64Array result; result.resize(oq::S_STRIDE);
    const auto snapshot = dynamic_async_ ? dynamic_async_->acquire_snapshot() : oq::DynamicOceanAsyncPublisher::SnapshotPtr{};
    sample_dynamic_material_q_(qx, qz, result.ptrw(), nullptr, snapshot.get());
    return result;
}

PackedFloat64Array OceanQueryNative::get_dynamic_build_profile_us() const {
    PackedFloat64Array result; result.resize(4);
    for (int i = 0; i < 3; ++i) result[i] = static_cast<double>(dynamic_build_us_[i]);
    result[3] = static_cast<double>(dynamic_build_total_us_);
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_band_material_q(int band, double qx, double qz) const {
    PackedFloat64Array result;
    const auto snapshot = dynamic_async_ ? dynamic_async_->acquire_snapshot() : oq::DynamicOceanAsyncPublisher::SnapshotPtr{};
    if (band < 0 || band >= 3 || (snapshot == nullptr && !dynamic_fields_[band].ready())) return result;
    result.resize(oq::DynamicOceanPhysicsField::FIELD_COUNT);
    sample_dynamic_band_(band, qx, qz, result.ptrw(), snapshot.get());
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_material_q_batch(const PackedVector3Array &positions) {
    PackedFloat64Array result;
    const int64_t count = positions.size();
    const auto snapshot = dynamic_async_ ? dynamic_async_->acquire_snapshot() : oq::DynamicOceanAsyncPublisher::SnapshotPtr{};
    if ((snapshot == nullptr && !dynamic_fields_ready_) || count <= 0) return result;
    result.resize(count * oq::S_STRIDE);
    double *out = result.ptrw();
    for (int64_t i = 0; i < count; ++i) {
        const Vector3 position = positions[i];
        sample_dynamic_material_q_(position.x, position.z, out + i * oq::S_STRIDE, nullptr, snapshot.get());
    }
    return result;
}

void OceanQueryNative::sample_dynamic_world_(double wx, double wz, double initial_qx,
        double initial_qz, bool use_warm_start, double *out,
        const oq::DynamicOceanSnapshot *snapshot) const {
    if (out == nullptr) return;
    double qx = use_warm_start ? initial_qx : wx;
    double qz = use_warm_start ? initial_qz : wz;
    double sample[oq::S_STRIDE] = {};
    double jacobian[4] = {};
    double residual = std::numeric_limits<double>::infinity();
    int iterations = 0;
    for (; iterations < 12; ++iterations) {
        sample_dynamic_material_q_(qx, qz, sample, nullptr, snapshot);
        const double rx = qx + sample[oq::S_DX] - wx;
        const double rz = qz + sample[oq::S_DZ] - wz;
        residual = std::hypot(rx, rz);
        if (residual <= oq::POSITION_TOLERANCE_M) break;
        constexpr double eps = 0.05;
        double xp[oq::S_STRIDE] = {}, xm[oq::S_STRIDE] = {}, zp[oq::S_STRIDE] = {}, zm[oq::S_STRIDE] = {};
        sample_dynamic_material_q_(qx + eps, qz, xp, nullptr, snapshot);
        sample_dynamic_material_q_(qx - eps, qz, xm, nullptr, snapshot);
        sample_dynamic_material_q_(qx, qz + eps, zp, nullptr, snapshot);
        sample_dynamic_material_q_(qx, qz - eps, zm, nullptr, snapshot);
        jacobian[0] = 1.0 + (xp[oq::S_DX] - xm[oq::S_DX]) / (2.0 * eps);
        jacobian[1] = (zp[oq::S_DX] - zm[oq::S_DX]) / (2.0 * eps);
        jacobian[2] = (xp[oq::S_DZ] - xm[oq::S_DZ]) / (2.0 * eps);
        jacobian[3] = 1.0 + (zp[oq::S_DZ] - zm[oq::S_DZ]) / (2.0 * eps);
        const double det = jacobian[0] * jacobian[3] - jacobian[1] * jacobian[2];
        if (!std::isfinite(det) || std::abs(det) < 1.0e-6) break;
        const double step_x = (jacobian[3] * rx - jacobian[1] * rz) / det;
        const double step_z = (-jacobian[2] * rx + jacobian[0] * rz) / det;
        if (!std::isfinite(step_x) || !std::isfinite(step_z)) break;
        // A full Newton step can cross a Coastal mask/warp transition and
        // increase the residual dramatically. Backtrack on the SAME sampled
        // surface; no displacement clamp, tolerance or field modification.
        double scale = 1.0;
        bool accepted = false;
        for (int trial = 0; trial < 10; ++trial) {
            const double tx = qx - step_x * scale;
            const double tz = qz - step_z * scale;
            double candidate[oq::S_STRIDE] = {};
            sample_dynamic_material_q_(tx, tz, candidate, nullptr, snapshot);
            const double candidate_residual = std::hypot(tx + candidate[oq::S_DX] - wx,
                                                         tz + candidate[oq::S_DZ] - wz);
            if (std::isfinite(candidate_residual) && candidate_residual < residual) {
                qx = tx; qz = tz; accepted = true; break;
            }
            scale *= 0.5;
        }
        if (!accepted) break;
    }
    sample_dynamic_material_q_(qx, qz, sample, nullptr, snapshot);
    residual = std::hypot(qx + sample[oq::S_DX] - wx, qz + sample[oq::S_DZ] - wz);
    for (int i = 0; i < oq::S_STRIDE; ++i) out[i] = sample[i];
    out[oq::S_RESIDUAL] = residual;
    out[oq::S_ITERATIONS] = iterations;
    out[oq::S_STRIDE] = qx;
    out[oq::S_STRIDE + 1] = qz;
    if (residual > oq::POSITION_TOLERANCE_M) out[oq::S_VALID] = 0.0;
    if (out[oq::S_VALID] < 0.5 && !use_warm_start) {
        // Cold starts near Coastal transitions can reach a local residual
        // minimum even when another material branch has a regular root.
        // Search deterministic alternate seeds ONLY on failure. Bilinear
        // samples are convex combinations of lattice displacements, and the
        // Coastal horizontal blend is convex too, so any root lies within
        // sum(max_band |D.xz|) of the target. No guessed metre radius or
        // physics clamp is used. This scan adds no steady-state build work.
        double bound = 0.0;
        for (size_t band = 0; band < 3; ++band) {
            if (snapshot == nullptr) {
                bound += dynamic_fields_[band].horizontal_displacement_bound();
                continue;
            }
            const auto &b = snapshot->bands[band];
            const size_t count = static_cast<size_t>(b.resolution) * b.resolution;
            double maximum_squared = 0.0;
            for (size_t i = 0; i < count; ++i) {
                const double x = b.packed_fields_layout ? b.packed_fields[0][i].imag() : b.fields[count + i];
                const double z = b.packed_fields_layout ? b.packed_fields[1][i].real() : b.fields[2 * count + i];
                maximum_squared = std::max(maximum_squared, x * x + z * z);
            }
            bound += std::sqrt(maximum_squared);
        }
        constexpr double diagonal = 0.7071067811865475244;
        constexpr double directions[8][2] = {{1,0},{-1,0},{0,1},{0,-1},
            {diagonal,diagonal},{diagonal,-diagonal},{-diagonal,diagonal},{-diagonal,-diagonal}};
        int total_iterations = iterations;
        for (double fraction : {0.125, 0.25, 0.5, 1.0}) for (const auto &direction : directions) {
            double alternative[oq::S_STRIDE + 2] = {};
            sample_dynamic_world_(wx, wz, wx + bound * fraction * direction[0],
                wz + bound * fraction * direction[1], true, alternative, snapshot);
            total_iterations += static_cast<int>(alternative[oq::S_ITERATIONS]);
            if (alternative[oq::S_RESIDUAL] < out[oq::S_RESIDUAL])
                std::copy(alternative, alternative + oq::S_STRIDE + 2, out);
            if (out[oq::S_VALID] > 0.5) { out[oq::S_ITERATIONS] = total_iterations; return; }
        }
        out[oq::S_ITERATIONS] = total_iterations;
    }
}

PackedFloat64Array OceanQueryNative::sample_dynamic_world(double wx, double wz, double initial_qx,
                                                           double initial_qz, bool use_warm_start) {
    PackedFloat64Array result; result.resize(oq::S_STRIDE + 2);
    const auto snapshot = dynamic_async_ ? dynamic_async_->acquire_snapshot() : oq::DynamicOceanAsyncPublisher::SnapshotPtr{};
    sample_dynamic_world_(wx, wz, initial_qx, initial_qz, use_warm_start, result.ptrw(), snapshot.get());
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_world_batch(const PackedVector3Array &positions,
                                                                 const PackedVector3Array &initial_q,
                                                                 bool use_warm_start) {
    PackedFloat64Array result;
    const int64_t count = positions.size();
    const auto snapshot = dynamic_async_ ? dynamic_async_->acquire_snapshot() : oq::DynamicOceanAsyncPublisher::SnapshotPtr{};
    if ((snapshot == nullptr && !dynamic_fields_ready_) || count <= 0 || (use_warm_start && initial_q.size() != count)) return result;
    constexpr int stride = oq::S_STRIDE + 2;
    result.resize(count * stride);
    double *out = result.ptrw();
    for (int64_t i = 0; i < count; ++i) {
        const Vector3 target = positions[i];
        const Vector3 warm = use_warm_start ? initial_q[i] : Vector3(target.x, 0.0, target.z);
        sample_dynamic_world_(target.x, target.z, warm.x, warm.z, use_warm_start, out + i * stride, snapshot.get());
    }
    return result;
}

PackedInt64Array OceanQueryNative::get_dynamic_field_info() const {
    PackedInt64Array result; result.resize(7);
    if (dynamic_async_) {
        const auto snapshot = dynamic_async_->acquire_snapshot();
        int64_t total_memory = 0;
        for (size_t band = 0; band < 3; ++band) {
            result[band] = snapshot && snapshot->valid ? snapshot->bands[band].resolution : 0;
            if (snapshot) total_memory += static_cast<int64_t>(snapshot->bands[band].fields.size() * sizeof(double));
        }
        result[3] = total_memory;
        result[4] = snapshot && snapshot->valid ? 1 : 0;
        result[5] = snapshot ? static_cast<int64_t>(snapshot->simulation_time * 1000000.0) : 0;
        result[6] = snapshot ? static_cast<int64_t>(snapshot->bands[0].fields.size() * sizeof(double)) : 0;
        return result;
    }
    int slot = 0; int64_t total_memory = 0;
    for (int i = 0; i < 3; ++i) {
        result[slot++] = dynamic_fields_[i].ready() ? dynamic_fields_[i].resolution() : 0;
        total_memory += static_cast<int64_t>(dynamic_fields_[i].memory_bytes());
    }
    result[slot++] = total_memory;
    result[slot++] = dynamic_fields_ready_ ? 1 : 0;
    result[slot++] = static_cast<int64_t>(dynamic_field_time_ * 1000000.0);
    result[slot] = static_cast<int64_t>(dynamic_fields_[0].memory_bytes());
    return result;
}

void OceanQueryNative::sample_dynamic_contact_(double wx, double wz, const double *previous,
        double *out, const oq::DynamicOceanSnapshot *snapshot) const {
    double lattice = std::numeric_limits<double>::infinity();
    for (size_t b = 0; b < 3; ++b) {
        const double domain = snapshot ? snapshot->bands[b].domain_m : core_.cascades[b].material_domain_m;
        const int n = snapshot ? snapshot->bands[b].resolution : core_.cascades[b].material_resolution;
        if (n > 0) lattice = std::min(lattice, domain / n);
    }
    if (!std::isfinite(lattice) || lattice <= 0.0) {
        std::fill(out, out + oq::C_STRIDE, 0.0); out[oq::C_STATUS] = oq::FAILED; return;
    }
    oq::continue_contact(wx, wz, previous, lattice,
        snapshot ? snapshot->simulation_time : dynamic_field_time_,
        snapshot ? static_cast<double>(snapshot->configuration_version) : static_cast<double>(dynamic_configuration_version_),
        snapshot ? static_cast<double>(snapshot->generation) : 0.0,
        [this, snapshot](double x, double z, double *r) { sample_dynamic_material_q_(x, z, r, nullptr, snapshot); },
        [this, snapshot](double x, double z, double *r) { sample_dynamic_material_q_(x, z, r, nullptr, snapshot, true); },
        [this, snapshot](double x, double z, double *r) { sample_dynamic_world_(x, z, x, z, false, r, snapshot); }, out);
}

PackedFloat64Array OceanQueryNative::sample_dynamic_contact(double wx, double wz, const PackedFloat64Array &previous) {
    PackedFloat64Array result; result.resize(oq::C_STRIDE);
    const auto snapshot = dynamic_async_ ? dynamic_async_->acquire_snapshot() : oq::DynamicOceanAsyncPublisher::SnapshotPtr{};
    if (!snapshot && !dynamic_fields_ready_) {
        std::fill(result.ptrw(), result.ptrw() + oq::C_STRIDE, 0.0); result[oq::C_STATUS] = oq::FAILED; return result;
    }
    sample_dynamic_contact_(wx, wz, previous.size() == oq::C_STRIDE ? previous.ptr() : nullptr, result.ptrw(), snapshot.get());
    return result;
}

PackedFloat64Array OceanQueryNative::sample_dynamic_contact_batch(const PackedVector3Array &positions,
        const PackedFloat64Array &previous) {
    PackedFloat64Array result;
    const auto snapshot = dynamic_async_ ? dynamic_async_->acquire_snapshot() : oq::DynamicOceanAsyncPublisher::SnapshotPtr{};
    if ((!snapshot && !dynamic_fields_ready_) || positions.is_empty()) return result;
    const int64_t count = positions.size();
    result.resize(count * oq::C_STRIDE);
    const bool history = previous.size() == count * oq::C_STRIDE;
    double *out = result.ptrw();
    for (int64_t i = 0; i < count; ++i) {
        const Vector3 p = positions[i];
        sample_dynamic_contact_(p.x, p.z, history ? previous.ptr() + i * oq::C_STRIDE : nullptr,
            out + i * oq::C_STRIDE, snapshot.get());
    }
    return result;
}

PackedInt64Array OceanQueryNative::get_dynamic_stage_profile_us() const {
    PackedInt64Array result; result.resize(9);
    int cursor = 0;
    for (int band = 0; band < 3; ++band) {
        result[cursor++] = static_cast<int64_t>(dynamic_evolution_us_[band]);
        result[cursor++] = static_cast<int64_t>(dynamic_transforms_us_[band]);
        result[cursor++] = static_cast<int64_t>(dynamic_build_us_[band]);
    }
    return result;
}

void OceanQueryNative::set_sea_level(double sea_level) {
    core_.sea_level = sea_level;
}

void OceanQueryNative::refresh_dynamic_async_configuration_() {
    if (dynamic_async_) {
        ++dynamic_configuration_version_;
        dynamic_async_->update_configuration(capture_dynamic_cascades(core_.cascades), dynamic_configuration_version_);
    }
}

void OceanQueryNative::set_material_q_contract(double domain_size_m, int resolution) {
    set_cascade_material_q_contract(0, domain_size_m, resolution);
}

void OceanQueryNative::set_cascade_material_q_contract(int cascade_index, double domain_size_m, int resolution) {
    if (cascade_index < 0) { return; }
    core_.set_cascade_material_q_contract(static_cast<size_t>(cascade_index), domain_size_m, resolution);
}

PackedFloat64Array OceanQueryNative::material_q_to_fft_q(double qx, double qz) const {
    return material_q_to_fft_q_for_band(qx, qz, 0);
}

PackedFloat64Array OceanQueryNative::material_q_to_fft_q_for_band(double qx, double qz, int cascade_index) const {
    const MaterialFFTQ fft_q = material_q_to_fft_q_(qx, qz, cascade_index);
    PackedFloat64Array result;
    result.resize(2);
    result[0] = fft_q.x;
    result[1] = fft_q.z;
    return result;
}

OceanQueryNative::MaterialFFTQ OceanQueryNative::material_q_to_fft_q_(double qx, double qz, int cascade_index) const {
    double fft_qx = qx, fft_qz = qz;
    if (cascade_index >= 0) {
        core_.material_q_to_fft_q(static_cast<size_t>(cascade_index), qx, qz, fft_qx, fft_qz);
    }
    return {fft_qx, fft_qz};
}

void OceanQueryNative::set_cascade_data(
    int cascade_index, double inv_n2,
    const PackedFloat64Array &kx, const PackedFloat64Array &ky, const PackedFloat64Array &omega,
    const PackedFloat64Array &a1, const PackedFloat64Array &a2,
    const PackedFloat64Array &c11, const PackedFloat64Array &c12,
    const PackedFloat64Array &c21, const PackedFloat64Array &c22,
    const PackedFloat64Array &parity, const PackedFloat64Array &weight,
    const PackedFloat64Array &h0_re, const PackedFloat64Array &h0_im,
    const PackedFloat64Array &h0n_re, const PackedFloat64Array &h0n_im) {
    const size_t count = static_cast<size_t>(kx.size());
    core_.set_cascade_data(
        static_cast<size_t>(cascade_index), inv_n2,
        kx.ptr(), ky.ptr(), omega.ptr(),
        a1.ptr(), a2.ptr(), c11.ptr(), c12.ptr(), c21.ptr(), c22.ptr(),
        parity.ptr(), weight.ptr(),
        h0_re.ptr(), h0_im.ptr(), h0n_re.ptr(), h0n_im.ptr(), count);
}

void OceanQueryNative::finalize_spectrum() {
    prepared_dynamic_spectrum_.reset();
    core_.finalize_spectrum();
    refresh_dynamic_async_configuration_();
}

bool OceanQueryNative::set_production_spectrum(const Array &snapshots) {
    return import_production_spectrum_(snapshots, false);
}

bool OceanQueryNative::prepare_production_spectrum(const Array &snapshots) {
    return !dynamic_async_ && import_production_spectrum_(snapshots, true) && prepare_dynamic_spectrum();
}

bool OceanQueryNative::import_production_spectrum_(const Array &snapshots, bool fft_only) {
    if (snapshots.size() != 3) return false;
    std::vector<oq::Cascade> replacement(3);
    for (int band = 0; band < 3; ++band) {
        if (snapshots[band].get_type() != Variant::DICTIONARY) return false;
        const Dictionary s = snapshots[band];
        const int n = s.get("resolution", 0);
        const double domain = s.get("domain_size_m", 0.0);
        const double gravity = s.get("gravity_mps2", 0.0);
        const double chop = s.get("choppiness", 0.0);
        const PackedByteArray bytes = s.get("h0_rgba32f", PackedByteArray());
        if (n < 2 || n > 4096 || (n & (n - 1)) != 0 || !std::isfinite(domain) || domain <= 0.0 ||
            !std::isfinite(gravity) || gravity <= 0.0 || !std::isfinite(chop) ||
            bytes.size() != static_cast<int64_t>(n) * n * 4 * sizeof(float)) return false;
        // A live worker owns a plan for the current lattice. Resolution,
        // domain, and dispersion changes require an explicit restart of it.
        if (dynamic_async_ && (core_.cascades.size() != 3 ||
            core_.cascades[band].material_resolution != n ||
            core_.cascades[band].material_domain_m != domain)) return false;
        auto &c = replacement[band];
        const size_t count = static_cast<size_t>(n) * n;
        c.material_resolution = n; c.material_domain_m = domain; c.inv_n2 = 1.0 / count;
        c.production_choppiness = chop; c.production_gravity = gravity;
        const Vector2 wind = s.get("wind_direction", Vector2(1, 0));
        c.production_wind_x = wind.x; c.production_wind_z = wind.y;
        c.production_wind_speed = s.get("wind_speed_mps", 0.0);
        for (auto *v : {&c.kx, &c.ky, &c.omega, &c.a1, &c.a2, &c.c11, &c.c12,
                       &c.c21, &c.c22, &c.parity, &c.weight, &c.h0_re, &c.h0_im,
                       &c.h0n_re, &c.h0n_im}) v->resize(count);
        const auto packed = bytes.to_float32_array();
        const float *values = packed.ptr();
        const double dk = 6.283185307179586476925286766559 / domain;
        for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
            const size_t i = static_cast<size_t>(y) * n + x;
            // Vector2 deliberately reproduces the float32 Production bridge's
            // k arithmetic. Physics still stores/evaluates in double precision.
            const Vector2 k = Vector2(x - n * 0.5, y - n * 0.5) * dk;
            const double length = k.length();
            const double ax = length > 0.000001 ? -chop * k.x / length : 0.0;
            const double az = length > 0.000001 ? -chop * k.y / length : 0.0;
            c.kx[i] = k.x; c.ky[i] = k.y; c.omega[i] = std::sqrt(gravity * length);
            if (dynamic_async_ && c.omega[i] != core_.cascades[band].omega[i]) return false;
            c.a1[i] = ax; c.a2[i] = az;
            c.c11[i] = ax * k.x; c.c12[i] = ax * k.y;
            c.c21[i] = az * k.x; c.c22[i] = az * k.y;
            const double origin = ((x + y - n) & 1) ? -1.0 : 1.0;
            c.parity[i] = ((x + y) & 1) ? -1.0 : 1.0; c.weight[i] = 1.0;
            c.h0_re[i] = values[4 * i] * origin; c.h0_im[i] = values[4 * i + 1] * origin;
            c.h0n_re[i] = values[4 * i + 2] * origin; c.h0n_im[i] = values[4 * i + 3] * origin;
            if (!std::isfinite(c.h0_re[i]) || !std::isfinite(c.h0_im[i]) ||
                !std::isfinite(c.h0n_re[i]) || !std::isfinite(c.h0n_im[i])) return false;
        }
    }
    core_.cascades = std::move(replacement);
    prepared_dynamic_spectrum_.reset();
    for (size_t band = 0; band < 3; ++band)
        core_.set_cascade_material_q_contract(band, core_.cascades[band].material_domain_m,
                                              core_.cascades[band].material_resolution);
    if (!fft_only) finalize_spectrum();
    return true;
}

bool OceanQueryNative::prepare_dynamic_spectrum() {
    if (dynamic_async_ || core_.cascades.size() != 3) return false;
    prepared_dynamic_spectrum_ = oq::DynamicOceanAsyncPublisher::prepare_spectrum(core_.cascades);
    return static_cast<bool>(prepared_dynamic_spectrum_);
}

Dictionary OceanQueryNative::build_production_h0(const Dictionary &config, int64_t seed) const {
    return godot::build_production_h0(config, static_cast<uint32_t>(seed));
}

PackedByteArray OceanQueryNative::scale_production_h0(const PackedByteArray &bytes, double scale) const {
    if (bytes.size() % sizeof(float) != 0 || !std::isfinite(scale)) return {};
    auto values = bytes.to_float32_array();
    float *out = values.ptrw();
    for (int64_t i = 0; i < values.size(); ++i) out[i] = static_cast<float>(static_cast<double>(out[i]) * scale);
    return values.to_byte_array();
}

bool OceanQueryNative::transition_dynamic_spectrum(const Ref<OceanQueryNative> &source,
        const Ref<OceanQueryNative> &target, double start_time, double duration) {
    if (!dynamic_async_ || source.is_null() || target.is_null() ||
        !source->prepared_dynamic_spectrum_ || !target->prepared_dynamic_spectrum_ ||
        !std::isfinite(start_time) || !std::isfinite(duration) || duration < 0.0) return false;
    for (size_t band = 0; band < 3; ++band) {
        const auto &a = (*source->prepared_dynamic_spectrum_)[band];
        const auto &b = (*target->prepared_dynamic_spectrum_)[band];
        const auto &c = core_.cascades[band];
        if (a.material_resolution != c.material_resolution || b.material_resolution != c.material_resolution ||
            a.material_domain_m != c.material_domain_m || b.material_domain_m != c.material_domain_m ||
            a.production_gravity != c.production_gravity || b.production_gravity != c.production_gravity)
            return false;
    }
    ++dynamic_configuration_version_;
    dynamic_async_->transition_configuration(source->prepared_dynamic_spectrum_, target->prepared_dynamic_spectrum_,
        start_time, duration, dynamic_configuration_version_);
    return true;
}

Array OceanQueryNative::get_dynamic_snapshot_spectrum(bool include_h0) const {
    Array result;
    const auto publisher = std::atomic_load(&dynamic_async_);
    if (!publisher) return result;
    const auto snapshot = publisher->acquire_snapshot();
    if (!snapshot || !snapshot->valid || snapshot->production_h0[0].empty()) return result;
    for (int band = 0; band < 3; ++band) {
        const auto &raw = snapshot->production_h0[band];
        Dictionary s;
        s["band"] = band == 0 ? "LONG" : band == 1 ? "MID" : "SHORT";
        s["resolution"] = snapshot->bands[band].resolution;
        s["domain_size_m"] = snapshot->bands[band].domain_m;
        s["gravity_mps2"] = snapshot->gravity[band];
        s["choppiness"] = snapshot->choppiness[band];
        s["wind_direction"] = Vector2(snapshot->wind_x[band], snapshot->wind_z[band]).normalized();
        s["wind_speed_mps"] = snapshot->wind_speed[band];
        if (include_h0) {
            PackedByteArray bytes; bytes.resize(static_cast<int64_t>(raw.size() * sizeof(float)));
            std::memcpy(bytes.ptrw(), raw.data(), raw.size() * sizeof(float));
            s["h0_rgba32f"] = bytes;
        }
        s["configuration_version"] = static_cast<int64_t>(snapshot->configuration_version);
        s["generation"] = static_cast<int64_t>(snapshot->generation);
        s["wave_time"] = snapshot->simulation_time;
        s["weather_alpha"] = snapshot->weather_alpha;
        s["weather_alpha_dot"] = snapshot->weather_alpha_dot;
        s["weather_start_time"] = snapshot->weather_start_time;
        s["weather_duration"] = snapshot->weather_duration;
        s["choppiness_dot"] = snapshot->choppiness_dot[band];
        result.push_back(s);
    }
    return result;
}

void OceanQueryNative::set_coastal_long_weights(const PackedFloat64Array &pos, const PackedFloat64Array &neg) {
    if (pos.size() != neg.size()) { core_.clear_coastal(); return; }
    core_.set_coastal_long_weights(pos.ptr(), neg.ptr(), static_cast<size_t>(pos.size()));
}

void OceanQueryNative::set_coastal_profile_enabled(bool enabled) { core_.set_coastal_profile_enabled(enabled); }

void OceanQueryNative::reset_coastal_profile() { core_.reset_coastal_profile(); }

PackedInt64Array OceanQueryNative::get_coastal_profile_us() const {
    PackedInt64Array values;
    values.resize(6);
    values[0] = static_cast<int64_t>(core_.coastal_profile.base_us);
    values[1] = static_cast<int64_t>(core_.coastal_profile.sampler_us);
    values[2] = static_cast<int64_t>(core_.coastal_profile.cq_us);
    values[3] = static_cast<int64_t>(core_.coastal_profile.cdeep_us);
    values[4] = static_cast<int64_t>(core_.coastal_profile.combine_us);
    values[5] = static_cast<int64_t>(core_.coastal_profile.calls);
    return values;
}

PackedInt64Array OceanQueryNative::get_coastal_profile_detail() const {
    PackedInt64Array values;
    values.resize(93);
    int64_t cursor = 0;
    const auto append_matrix = [&](const auto &matrix) {
        for (const auto &row : matrix) for (uint64_t value : row) values[cursor++] = static_cast<int64_t>(value);
    };
    const auto append_vector = [&](const auto &vector) {
        for (uint64_t value : vector) values[cursor++] = static_cast<int64_t>(value);
    };
    append_matrix(core_.coastal_profile.band_mode_ns);       // 15
    append_matrix(core_.coastal_profile.band_reduce_ns);     // 15
    append_vector(core_.coastal_profile.deep_mode_ns);       // 5
    append_vector(core_.coastal_profile.deep_reduce_ns);     // 5
    append_vector(core_.coastal_profile.sampler_stage_ns);   // 5
    append_vector(core_.coastal_profile.combine_stage_ns);   // 5
    append_matrix(core_.coastal_profile.mode_evaluations);   // 15
    append_vector(core_.coastal_profile.deep_mode_evaluations); // 5
    append_vector(core_.coastal_profile.vector_sincos_calls);   // 5
    append_vector(core_.coastal_profile.direct_sincos_calls);   // 5
    append_vector(core_.coastal_profile.deep_vector_sincos_calls); // 5
    append_vector(core_.coastal_profile.deep_direct_sincos_calls); // 5
    values[cursor++] = static_cast<int64_t>(core_.coastal_profile.fused_stencil_mode_ns);
    values[cursor++] = static_cast<int64_t>(core_.coastal_profile.fused_stencil_mode_evaluations);
    values[cursor++] = static_cast<int64_t>(core_.coastal_profile.fused_stencil_sincos_calls);
    return values;
}

PackedInt64Array OceanQueryNative::get_coastal_pair_counts() const {
    PackedInt64Array values;
    values.resize(2);
    values[0] = static_cast<int64_t>(core_.coastal_nonzero_pair_count());
    values[1] = static_cast<int64_t>(core_.coastal_pair_count());
    return values;
}

void OceanQueryNative::set_batch_profile_enabled(bool enabled) {
    batch_profile_enabled_ = enabled;
    reset_batch_profile_();
}

void OceanQueryNative::reset_batch_profile_() {
    batch_prepare_us_ = 0;
    batch_input_copy_us_ = 0;
    batch_core_us_ = 0;
    batch_output_copy_us_ = 0;
}

PackedInt64Array OceanQueryNative::get_last_batch_profile_us() const {
    PackedInt64Array values;
    values.resize(4);
    values[0] = static_cast<int64_t>(batch_prepare_us_);
    values[1] = static_cast<int64_t>(batch_input_copy_us_);
    values[2] = static_cast<int64_t>(batch_core_us_);
    values[3] = static_cast<int64_t>(batch_output_copy_us_);
    return values;
}

PackedInt32Array OceanQueryNative::get_last_batch_diagnostics() const {
    PackedInt32Array values;
    values.resize(3 + oq::NEWTON_HISTOGRAM_SIZE);
    values[0] = core_.diag_last_material_batch_avx2 ? 1 : 0;
    values[1] = core_.diag_last_world_batch_avx2 ? 1 : 0;
    values[2] = core_.diag_last_coastal_deep_avx2 ? 1 : 0;
    for (int i = 0; i < oq::NEWTON_HISTOGRAM_SIZE; ++i) { values[3 + i] = core_.diag_last_newton_histogram[i]; }
    return values;
}

void OceanQueryNative::set_coastal_runtime(double field_origin_x, double field_origin_z,
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
                                           double detj_safe) {
    const size_t field_count = static_cast<size_t>(field_width) * static_cast<size_t>(field_height);
    const size_t warp_count = static_cast<size_t>(warp_width) * static_cast<size_t>(warp_height);
    if (field_width < 2 || field_height < 2 || warp_width < 2 || warp_height < 2 ||
        shoaling.size() != static_cast<int64_t>(field_count) || field_valid.size() != static_cast<int64_t>(field_count) ||
        warp_x.size() != static_cast<int64_t>(warp_count) || warp_z.size() != static_cast<int64_t>(warp_count) ||
        det_j.size() != static_cast<int64_t>(warp_count) || warp_valid.size() != static_cast<int64_t>(warp_count)) {
        core_.clear_coastal(); return;
    }
    const auto copy_f32 = [](const PackedFloat32Array &src, size_t count) {
        std::vector<double> dst(count);
        const float *in = src.ptr();
        for (size_t i = 0; i < count; ++i) { dst[i] = static_cast<double>(in[i]); }
        return dst;
    };
    const auto copy_mask = [](const PackedByteArray &src, size_t count) {
        std::vector<double> dst(count);
        const uint8_t *in = reinterpret_cast<const uint8_t *>(src.ptr());
        for (size_t i = 0; i < count; ++i) { dst[i] = in[i] == 0 ? 0.0 : 1.0; }
        return dst;
    };
    const std::vector<double> sh = copy_f32(shoaling, field_count);
    const std::vector<double> fv = copy_mask(field_valid, field_count);
    const std::vector<double> wx = copy_f32(warp_x, warp_count);
    const std::vector<double> wz = copy_f32(warp_z, warp_count);
    const std::vector<double> dj = copy_f32(det_j, warp_count);
    const std::vector<double> wv = copy_mask(warp_valid, warp_count);
    core_.set_coastal_runtime(field_origin_x, field_origin_z, field_extent_x, field_extent_z,
                              field_width, field_height, sh.data(), fv.data(),
                              warp_origin_x, warp_origin_z, warp_extent_x, warp_extent_z,
                              warp_width, warp_height, wx.data(), wz.data(), dj.data(), wv.data(), detj_safe);
}

void OceanQueryNative::clear_coastal() { core_.clear_coastal(); }

PackedFloat64Array OceanQueryNative::sample_coastal_bake(double qx, double qz, double diagnostic_feather_texels) const {
    oq::CoastalSample sample;
    const bool covered = core_.coastal.sample(qx, qz, sample, diagnostic_feather_texels);
    PackedFloat64Array result; result.resize(8);
    result[0] = sample.shoaling; result[1] = sample.field_valid;
    result[2] = sample.warp_x; result[3] = sample.warp_z;
    result[4] = sample.warp_det_j; result[5] = sample.warp_valid;
    result[6] = sample.confidence;
    result[7] = covered ? oq::coastal_coverage_edge_weight(
        (qx - core_.coastal.field_origin_x) / core_.coastal.field_extent_x,
        (qz - core_.coastal.field_origin_z) / core_.coastal.field_extent_z,
        core_.coastal.field_width, core_.coastal.field_height, diagnostic_feather_texels) : 0.0;
    return result;
}

void OceanQueryNative::ensure_prepared(double simulation_time) {
    core_.ensure_prepared(simulation_time);
}

void OceanQueryNative::prepare_breaker_time(double simulation_time) {
    core_.ensure_breaker_prepared(simulation_time);
}

void OceanQueryNative::set_crest_sharpen(const Dictionary &config) {
    core_.set_crest_sharpen(
        config.get("strength", 1.0),
        config.get("threshold", 0.15),
        config.get("max_gain", 0.30),
        config.get("long_weight", 1.0),
        config.get("mid_weight", 0.5),
        config.get("direction_x", 1.0),
        config.get("direction_z", 0.0),
        config.get("eps", 1.92),
        config.get("local_hs", 0.5));
}

PackedFloat64Array OceanQueryNative::sample_to_packed_(const double *out) {
    PackedFloat64Array result;
    result.resize(oq::S_STRIDE);
    for (int i = 0; i < oq::S_STRIDE; ++i) {
        result[i] = out[i];
    }
    return result;
}

void OceanQueryNative::copy_positions_xz_(const PackedVector3Array &positions, std::vector<double> &out_xz) {
    const size_t n = static_cast<size_t>(positions.size());
    out_xz.resize(n * 2);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        out_xz[i * 2] = p.x;
        out_xz[i * 2 + 1] = p.z;
    }
}

PackedFloat64Array OceanQueryNative::pack_batch_output_(size_t value_count) {
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(value_count));
    for (size_t i = 0; i < value_count; ++i) { result[static_cast<int64_t>(i)] = batch_out_[i]; }
    return result;
}

PackedFloat64Array OceanQueryNative::run_world_batch_prepared_(const PackedVector3Array &positions,
                                                                const PackedVector3Array *initial_q) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    const auto input_start = batch_profile_enabled_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    copy_positions_xz_(positions, batch_xz_);
    const bool has_seed = initial_q != nullptr && initial_q->size() == positions.size();
    if (initial_q != nullptr) {
        batch_warm_q_.resize(n * 2);
        for (size_t i = 0; i < n; ++i) {
            const Vector3 p = has_seed ? (*initial_q)[static_cast<int64_t>(i)] : positions[static_cast<int64_t>(i)];
            batch_warm_q_[i * 2] = p.x;
            batch_warm_q_[i * 2 + 1] = p.z;
        }
    }
    if (batch_profile_enabled_) {
        batch_input_copy_us_ += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - input_start).count());
    }
    batch_out_.resize(n * (initial_q != nullptr ? oq::TRUE_BATCH_WARM_STRIDE : oq::S_STRIDE));
    const auto core_start = batch_profile_enabled_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    if (initial_q != nullptr) {
        core_.sample_batch_warm_prepared(batch_xz_.data(), batch_warm_q_.data(), n, batch_out_.data());
    } else {
        core_.sample_batch_prepared(batch_xz_.data(), n, batch_out_.data());
    }
    if (batch_profile_enabled_) {
        batch_core_us_ += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - core_start).count());
    }
    const auto output_start = batch_profile_enabled_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    PackedFloat64Array result = pack_batch_output_(batch_out_.size());
    if (batch_profile_enabled_) {
        batch_output_copy_us_ += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - output_start).count());
    }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_world(double wx, double wz, double simulation_time) {
    double out[oq::S_STRIDE + 2] = {};
    sample_world_material_q_(wx, wz, simulation_time, out, false);
    PackedFloat64Array result;
    result.resize(oq::S_STRIDE);
    for (int field = 0; field < oq::S_STRIDE; ++field) { result[field] = out[field]; }
    return result;
}

Dictionary OceanQueryNative::debug_world_parity(double simulation_time,
        const PackedVector3Array &positions, int point, bool focused_only) {
    Dictionary result;
    if (positions.size() < 4 || point < 0 || point >= positions.size()) { return result; }
    core_.ensure_prepared(simulation_time);
    copy_positions_xz_(positions, batch_xz_);
    auto state = [this]() {
        Array sources;
        for (const auto &c : core_.cascades) {
            Dictionary band;
            band["h0_address"] = int64_t(reinterpret_cast<uintptr_t>(c.h0_re.data()));
            band["evolved_address"] = int64_t(reinterpret_cast<uintptr_t>(c.ev_h_re.data()));
            band["mode_count"] = int64_t(c.kx.size());
            band["domain"] = c.material_domain_m;
            band["resolution"] = c.material_resolution;
            band["choppiness"] = c.production_choppiness;
            sources.append(band);
        }
        Dictionary s;
        s["core_address"] = int64_t(reinterpret_cast<uintptr_t>(&core_));
        s["prepared_time"] = core_.prepared_time;
        s["config_version"] = int64_t(dynamic_configuration_version_);
        s["sources"] = sources;
        s["coastal_field_address"] = int64_t(reinterpret_cast<uintptr_t>(core_.coastal.shoaling.data()));
        s["coastal_warp_address"] = int64_t(reinterpret_cast<uintptr_t>(core_.coastal.warp_x.data()));
        s["ownership"] = "legacy direct core: one prepared state; no asynchronous field acquisition";
        return s;
    };
    result["state_before"] = state();
    const auto debug = core_.debug_world_parity(batch_xz_.data(), positions.size(), size_t(point), focused_only);
    result["focused_only"] = focused_only;
    result["focus_point"] = point;
    result["state_after"] = state();
    auto pack = [](const std::vector<double> &data) {
        PackedFloat64Array a; a.resize(data.size());
        std::copy(data.begin(), data.end(), a.ptrw());
        return a;
    };
    auto trace = [](const std::vector<oq::OceanQueryCore::WorldTraceRow> &rows) {
        Array a;
        for (const auto &row : rows) {
            PackedFloat64Array p; p.resize(row.size());
            std::copy(row.begin(), row.end(), p.ptrw()); a.append(p);
        }
        return a;
    };
    result["scalar_native"] = pack(debug.scalar);
    result["batch_native"] = pack(debug.batch);
    result["scalar_trace"] = trace(debug.scalar_trace);
    result["batch_trace"] = trace(debug.batch_trace);
    result["cold_failure_replays"] = static_cast<int64_t>(debug.cold_failure_replays);
    Array fields;
    for (const auto &row : debug.same_q_fields) { fields.append(pack(row)); }
    result["same_q_fields"] = fields;
    result["same_q_fields_layout"] = "scalar physical12 + NewtonJacobian4; AVX2 requested5cm12 + NewtonJacobian4; four offsets each scalar(h,dx,dz), AVX2full(h,dx,dz), AVX2CoastalCorrection(h,dx,dz); scalar open NewtonJacobian4; unwrapped Fourier stencil Jacobian4";
    result["trace_columns"] = "iteration,active_count,qx,qz,h,dx,dz,fx,fz,residual,ja,jb,jc,jd,det,delta_x,delta_z,damping,accepted_qx,accepted_qz,reason,prepared_time,band_mask,coastal";
    result["reason_codes"] = "0=Newton step; 1=accepted residual; 2=iteration limit; 3=singular";
    return result;
}

PackedFloat64Array OceanQueryNative::sample_world_with_material_q(double wx, double wz, double simulation_time) {
    double out[oq::S_STRIDE + 2] = {};
    sample_world_material_q_(wx, wz, simulation_time, out, true);
    PackedFloat64Array result;
    result.resize(oq::S_STRIDE + 2);
    for (int field = 0; field < oq::S_STRIDE + 2; ++field) { result[field] = out[field]; }
    return result;
}

void OceanQueryNative::sample_world_material_q_(double wx, double wz, double simulation_time, double *out, bool include_material_q) {
    double qx = wx;
    double qz = wz;
    core_.sample_world_with_material_q(wx, wz, simulation_time, out, &qx, &qz);
    if (include_material_q) {
        out[oq::S_STRIDE] = qx;
        out[oq::S_STRIDE + 1] = qz;
    }
}

PackedFloat64Array OceanQueryNative::sample_material_q(double qx, double qz, double simulation_time) {
    double out[oq::S_STRIDE];
    core_.sample_material_q(qx, qz, simulation_time, out);
    return sample_to_packed_(out);
}

PackedFloat64Array OceanQueryNative::sample_material_q_batch(double simulation_time, const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    reset_batch_profile_();
    const auto prepare_start = batch_profile_enabled_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    core_.ensure_prepared(simulation_time);
    if (batch_profile_enabled_) {
        batch_prepare_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - prepare_start).count());
    }
    const auto input_start = batch_profile_enabled_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    copy_positions_xz_(positions, batch_xz_);
    batch_out_.resize(n * oq::S_STRIDE);
    if (batch_profile_enabled_) {
        batch_input_copy_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - input_start).count());
    }
    const auto core_start = batch_profile_enabled_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    core_.sample_material_q_batch_prepared(batch_xz_.data(), n, batch_out_.data());
    if (batch_profile_enabled_) {
        batch_core_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - core_start).count());
    }
    const auto output_start = batch_profile_enabled_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    PackedFloat64Array result = pack_batch_output_(batch_out_.size());
    if (batch_profile_enabled_) {
        batch_output_copy_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - output_start).count());
    }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_material_q_with_band_mask(double qx, double qz,
                                                                       double simulation_time, int band_mask) {
    if (!is_supported_query_band_mask(band_mask)) { return PackedFloat64Array(); }
    ScopedQueryBandMask scope(core_, static_cast<uint8_t>(band_mask));
    return sample_material_q(qx, qz, simulation_time);
}

PackedFloat64Array OceanQueryNative::sample_material_q_batch_with_band_mask(double simulation_time,
                                                                             const PackedVector3Array &positions,
                                                                             int band_mask) {
    if (!is_supported_query_band_mask(band_mask)) { return PackedFloat64Array(); }
    ScopedQueryBandMask scope(core_, static_cast<uint8_t>(band_mask));
    return sample_material_q_batch(simulation_time, positions);
}

PackedFloat64Array OceanQueryNative::sample_world_with_band_mask(double wx, double wz,
                                                                  double simulation_time, int band_mask) {
    if (!is_supported_query_band_mask(band_mask)) { return PackedFloat64Array(); }
    ScopedQueryBandMask scope(core_, static_cast<uint8_t>(band_mask));
    return sample_world(wx, wz, simulation_time);
}

PackedFloat64Array OceanQueryNative::sample_batch_with_band_mask(double simulation_time,
                                                                  const PackedVector3Array &positions,
                                                                  int band_mask) {
    if (!is_supported_query_band_mask(band_mask)) { return PackedFloat64Array(); }
    ScopedQueryBandMask scope(core_, static_cast<uint8_t>(band_mask));
    return sample_batch(simulation_time, positions);
}

PackedFloat64Array OceanQueryNative::sample_prepared(double wx, double wz) {
    double out[oq::S_STRIDE + 2] = {};
    sample_world_material_q_(wx, wz, core_.prepared_time, out, false);
    PackedFloat64Array result;
    result.resize(oq::S_STRIDE);
    for (int field = 0; field < oq::S_STRIDE; ++field) { result[field] = out[field]; }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch_prepared(const PackedVector3Array &positions) {
    reset_batch_profile_();
    return run_world_batch_prepared_(positions, nullptr);
}

PackedFloat64Array OceanQueryNative::sample_batch_scalar_prepared(const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    batch_out_.resize(n * oq::S_STRIDE);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        sample_world_material_q_(p.x, p.z, core_.prepared_time, batch_out_.data() + i * oq::S_STRIDE, false);
    }
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) result[static_cast<int64_t>(i)] = batch_out_[i];
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch_avx2_scalar_trig_prepared(const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    copy_positions_xz_(positions, batch_xz_);
    batch_out_.resize(n * oq::S_STRIDE);
    core_.sample_batch_avx2_scalar_trig_prepared(batch_xz_.data(), n, batch_out_.data());
    return pack_batch_output_(batch_out_.size());
}

PackedFloat64Array OceanQueryNative::sample_batch_true_prepared(const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    copy_positions_xz_(positions, batch_xz_);
    batch_out_.resize(n * oq::S_STRIDE);
    core_.sample_batch_true_prepared(batch_xz_.data(), n, batch_out_.data());
    return pack_batch_output_(batch_out_.size());
}

PackedFloat64Array OceanQueryNative::sample_batch_warm_prepared(const PackedVector3Array &positions,
                                                                  const PackedVector3Array &initial_q) {
    reset_batch_profile_();
    return run_world_batch_prepared_(positions, &initial_q);
}

PackedFloat64Array OceanQueryNative::sample_batch(double simulation_time, const PackedVector3Array &positions) {
    reset_batch_profile_();
    const auto prepare_start = batch_profile_enabled_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    ensure_prepared(simulation_time);
    if (batch_profile_enabled_) {
        batch_prepare_us_ = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - prepare_start).count());
    }
    return run_world_batch_prepared_(positions, nullptr);
}

PackedFloat64Array OceanQueryNative::sample_coastal_breaker_batch_prepared(const PackedVector3Array &positions,
                                                                            bool include_slope) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    batch_xz_.resize(2 * n);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        batch_xz_[2 * i] = p.x;
        batch_xz_[2 * i + 1] = p.z;
    }
    batch_out_.resize(n * oq::S_STRIDE);
    core_.sample_coastal_breaker_prepared(batch_xz_.data(), n, batch_out_.data(), include_slope);
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) { result[static_cast<int64_t>(i)] = batch_out_[i]; }
    return result;
}

int OceanQueryNative::get_diag_non_converged() const {
    return core_.diag_non_converged;
}

int OceanQueryNative::get_diag_last_iterations() const {
    return 0;
}

double OceanQueryNative::get_diag_last_residual() const {
    return 0.0;
}

int OceanQueryNative::get_diag_last_spectral_point_evaluations() const {
    return static_cast<int>(core_.diag_last_spectral_point_evaluations);
}

PackedInt32Array OceanQueryNative::get_diag_last_newton_histogram() const {
    PackedInt32Array result;
    result.resize(5);
    for (int i = 0; i < 4; ++i) { result[i] = core_.diag_last_newton_histogram[i]; }
    for (int i = 4; i < oq::NEWTON_HISTOGRAM_SIZE; ++i) { result[4] += core_.diag_last_newton_histogram[i]; }
    return result;
}

bool OceanQueryNative::get_cpu_supports_avx2() const { return core_.avx2_supported(); }

String OceanQueryNative::get_query_execution_backend() const { return String(core_.query_execution_backend()); }

void OceanQueryNative::set_force_scalar(bool enabled) { core_.force_scalar = enabled; }
