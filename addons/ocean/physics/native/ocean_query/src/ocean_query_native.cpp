// OceanQueryNative — GDExtension (Fase 2C). Implementación.

#include "ocean_query_native.h"

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

using namespace godot;

void OceanQueryNative::_bind_methods() {
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
    ClassDB::bind_method(D_METHOD("set_coastal_long_weights", "pos", "neg"), &OceanQueryNative::set_coastal_long_weights);
    ClassDB::bind_method(D_METHOD("set_coastal_runtime", "field_origin_x", "field_origin_z", "field_extent_x", "field_extent_z", "field_width", "field_height", "shoaling", "field_valid", "warp_origin_x", "warp_origin_z", "warp_extent_x", "warp_extent_z", "warp_width", "warp_height", "warp_x", "warp_z", "det_j", "warp_valid", "detj_safe"), &OceanQueryNative::set_coastal_runtime);
    ClassDB::bind_method(D_METHOD("clear_coastal"), &OceanQueryNative::clear_coastal);
    ClassDB::bind_method(D_METHOD("set_coastal_profile_enabled", "enabled"), &OceanQueryNative::set_coastal_profile_enabled);
    ClassDB::bind_method(D_METHOD("reset_coastal_profile"), &OceanQueryNative::reset_coastal_profile);
    ClassDB::bind_method(D_METHOD("get_coastal_profile_us"), &OceanQueryNative::get_coastal_profile_us);
    ClassDB::bind_method(D_METHOD("get_coastal_pair_counts"), &OceanQueryNative::get_coastal_pair_counts);
    ClassDB::bind_method(D_METHOD("ensure_prepared", "simulation_time"), &OceanQueryNative::ensure_prepared);
    ClassDB::bind_method(D_METHOD("prepare_breaker_time", "simulation_time"), &OceanQueryNative::prepare_breaker_time);
    ClassDB::bind_method(D_METHOD("set_crest_sharpen", "config"), &OceanQueryNative::set_crest_sharpen);
    ClassDB::bind_method(D_METHOD("sample_world", "wx", "wz", "simulation_time"), &OceanQueryNative::sample_world);
    ClassDB::bind_method(D_METHOD("sample_world_with_material_q", "wx", "wz", "simulation_time"), &OceanQueryNative::sample_world_with_material_q);
    ClassDB::bind_method(D_METHOD("sample_material_q", "qx", "qz", "simulation_time"), &OceanQueryNative::sample_material_q);
    ClassDB::bind_method(D_METHOD("sample_material_q_batch", "simulation_time", "positions"), &OceanQueryNative::sample_material_q_batch);
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

void OceanQueryNative::clear() {
    core_.clear();
}

void OceanQueryNative::set_sea_level(double sea_level) {
    core_.sea_level = sea_level;
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
    core_.finalize_spectrum();
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

PackedInt64Array OceanQueryNative::get_coastal_pair_counts() const {
    PackedInt64Array values;
    values.resize(2);
    values[0] = static_cast<int64_t>(core_.coastal_nonzero_pair_count());
    values[1] = static_cast<int64_t>(core_.coastal_pair_count());
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

PackedFloat64Array OceanQueryNative::sample_world(double wx, double wz, double simulation_time) {
    double out[oq::S_STRIDE + 2] = {};
    sample_world_material_q_(wx, wz, simulation_time, out, false);
    PackedFloat64Array result;
    result.resize(oq::S_STRIDE);
    for (int field = 0; field < oq::S_STRIDE; ++field) { result[field] = out[field]; }
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
    core_.ensure_prepared(simulation_time);
    batch_out_.resize(n * oq::S_STRIDE);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        core_.sample_material_q(p.x, p.z, simulation_time, batch_out_.data() + i * oq::S_STRIDE);
    }
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) { result[static_cast<int64_t>(i)] = batch_out_[i]; }
    return result;
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
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) {
        return PackedFloat64Array();
    }
    batch_out_.resize(n * oq::S_STRIDE);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        sample_world_material_q_(p.x, p.z, core_.prepared_time, batch_out_.data() + i * oq::S_STRIDE, false);
    }
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(n) * oq::S_STRIDE);
    for (size_t i = 0; i < n * oq::S_STRIDE; ++i) {
        result[static_cast<int64_t>(i)] = batch_out_[i];
    }
    return result;
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

PackedFloat64Array OceanQueryNative::sample_batch_true_prepared(const PackedVector3Array &positions) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    batch_out_.resize(n * oq::S_STRIDE);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        sample_world_material_q_(p.x, p.z, core_.prepared_time, batch_out_.data() + i * oq::S_STRIDE, false);
    }
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) { result[static_cast<int64_t>(i)] = batch_out_[i]; }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch_warm_prepared(const PackedVector3Array &positions,
                                                                  const PackedVector3Array &initial_q) {
    const size_t n = static_cast<size_t>(positions.size());
    if (n == 0) { return PackedFloat64Array(); }
    batch_out_.resize(n * oq::TRUE_BATCH_WARM_STRIDE);
    for (size_t i = 0; i < n; ++i) {
        const Vector3 p = positions[static_cast<int64_t>(i)];
        sample_world_material_q_(p.x, p.z, core_.prepared_time, batch_out_.data() + i * oq::TRUE_BATCH_WARM_STRIDE, true);
    }
    PackedFloat64Array result;
    result.resize(static_cast<int64_t>(batch_out_.size()));
    for (size_t i = 0; i < batch_out_.size(); ++i) { result[static_cast<int64_t>(i)] = batch_out_[i]; }
    return result;
}

PackedFloat64Array OceanQueryNative::sample_batch(double simulation_time, const PackedVector3Array &positions) {
    ensure_prepared(simulation_time);
    return sample_batch_prepared(positions);
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
    for (int i = 0; i < 5; ++i) { result[i] = core_.diag_last_newton_histogram[i]; }
    return result;
}

bool OceanQueryNative::get_cpu_supports_avx2() const { return core_.avx2_supported(); }

String OceanQueryNative::get_query_execution_backend() const { return String(core_.query_execution_backend()); }

void OceanQueryNative::set_force_scalar(bool enabled) { core_.force_scalar = enabled; }
