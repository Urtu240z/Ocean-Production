// OceanQuery core nativo (Fase 2C) — implementación.
// Puerto EXACTO de OceanQueryReduced._accumulate / _sample_world / _prepare_time.
// La matemática NO cambia respecto a 2B (GDScript).

#include "ocean_query_core.h"
#include "ocean_query_simd_avx2.h"

#include <cmath>
#include <cstring>
#include <algorithm>
#include <chrono>

#if defined(_M_X64) || defined(_M_IX86)
#include <intrin.h>
#endif

namespace oq {

namespace {

inline double smoothstep01(double edge0, double edge1, double x) {
    if (edge1 <= edge0) { return x > edge0 ? 1.0 : 0.0; }
    const double t = std::max(0.0, std::min(1.0, (x - edge0) / (edge1 - edge0)));
    return t * t * (3.0 - 2.0 * t);
}

inline double bilinear(const std::vector<double> &values, size_t i00, size_t i10, size_t i01, size_t i11, double tx, double tz) {
    return (1.0 - tz) * ((1.0 - tx) * values[i00] + tx * values[i10]) + tz * ((1.0 - tx) * values[i01] + tx * values[i11]);
}

inline double bilinear_byte(const std::vector<uint8_t> &values, size_t i00, size_t i10, size_t i01, size_t i11, double tx, double tz) {
    return (1.0 - tz) * ((1.0 - tx) * static_cast<double>(values[i00]) + tx * static_cast<double>(values[i10])) + tz * ((1.0 - tx) * static_cast<double>(values[i01]) + tx * static_cast<double>(values[i11]));
}

inline double sample_gpu_linear(const std::vector<double> &values, int width, int height,
                                double u, double v) {
    if (width < 1 || height < 1 || values.size() != static_cast<size_t>(width) * static_cast<size_t>(height)) { return 0.0; }
    // repeat_disable + filter_linear: normalized UV addresses texel centers
    // at (i + 0.5) / size; coordinates outside the image clamp to edge.
    const double gx = std::max(0.0, std::min(static_cast<double>(width - 1), u * width - 0.5));
    const double gy = std::max(0.0, std::min(static_cast<double>(height - 1), v * height - 0.5));
    const int x0 = static_cast<int>(std::floor(gx));
    const int y0 = static_cast<int>(std::floor(gy));
    const int x1 = std::min(x0 + 1, width - 1);
    const int y1 = std::min(y0 + 1, height - 1);
    const double tx = gx - x0, ty = gy - y0;
    const size_t i00 = static_cast<size_t>(y0) * width + x0;
    const size_t i10 = static_cast<size_t>(y0) * width + x1;
    const size_t i01 = static_cast<size_t>(y1) * width + x0;
    const size_t i11 = static_cast<size_t>(y1) * width + x1;
    return bilinear(values, i00, i10, i01, i11, tx, ty);
}

// Compilado en la TU scalar: esta función no contiene AVX y es segura antes
// del dispatch. AVX requiere CPU, OSXSAVE y XMM/YMM habilitados por el SO.
bool detect_avx2_runtime() {
#if defined(_M_X64) || defined(_M_IX86)
    int regs[4] = {0, 0, 0, 0};
    __cpuidex(regs, 0, 0);
    if (regs[0] < 7) { return false; }
    __cpuidex(regs, 1, 0);
    const bool avx = (regs[2] & (1 << 28)) != 0;
    const bool osxsave = (regs[2] & (1 << 27)) != 0;
    if (!avx || !osxsave) { return false; }
    const unsigned __int64 xcr0 = _xgetbv(0);
    if ((xcr0 & 0x6) != 0x6) { return false; }
    __cpuidex(regs, 7, 0);
    return (regs[1] & (1 << 5)) != 0;
#else
    return false;
#endif
}

} // namespace

void Cascade::material_q_to_fft_q(double material_qx, double material_qz,
                                  double &fft_qx, double &fft_qz) const {
    if (material_domain_m <= 0.0 || material_resolution < 2) {
        fft_qx = material_qx;
        fft_qz = material_qz;
        return;
    }
    const double domain = material_domain_m;
    const double offset = domain * 0.5 - (domain / static_cast<double>(material_resolution)) * 0.5;
    const auto wrap_centered = [domain](double q) {
        double wrapped = std::fmod(q + domain * 0.5, domain);
        if (wrapped < 0.0) { wrapped += domain; }
        return wrapped - domain * 0.5;
    };
    fft_qx = wrap_centered(material_qx + offset);
    fft_qz = wrap_centered(material_qz + offset);
}

bool CoastalRuntime::sample(double qx, double qz, CoastalSample &out, double feather_texels) const {
    out = CoastalSample{};
    out.warp_x = qx; out.warp_z = qz;
    if (!enabled || field_width < 2 || field_height < 2 || warp_width < 2 || warp_height < 2 ||
        field_extent_x <= 0.0 || field_extent_z <= 0.0 || warp_extent_x <= 0.0 || warp_extent_z <= 0.0) { return false; }
    const double fu = (qx - field_origin_x) / field_extent_x;
    const double fv = (qz - field_origin_z) / field_extent_z;
    if (fu < 0.0 || fv < 0.0 || fu > 1.0 || fv > 1.0) { return false; }
    out.in_field_coverage = true;
    out.shoaling = sample_gpu_linear(shoaling, field_width, field_height, fu, fv);
    out.field_valid = sample_gpu_linear(field_valid, field_width, field_height, fu, fv);
    const double wu = std::max(0.0, std::min(1.0, (qx - warp_origin_x) / warp_extent_x));
    const double wv = std::max(0.0, std::min(1.0, (qz - warp_origin_z) / warp_extent_z));
    out.warp_x = sample_gpu_linear(warp_x, warp_width, warp_height, wu, wv);
    out.warp_z = sample_gpu_linear(warp_z, warp_width, warp_height, wu, wv);
    out.warp_det_j = sample_gpu_linear(det_j, warp_width, warp_height, wu, wv);
    out.warp_valid = sample_gpu_linear(warp_valid, warp_width, warp_height, wu, wv);
    out.confidence = out.field_valid * smoothstep01(0.0, detj_safe, out.warp_det_j) * out.warp_valid
        * coastal_coverage_edge_weight(fu, fv, field_width, field_height, feather_texels);
    out.deep_x = out.warp_x; out.deep_z = out.warp_z;
    out.effective_shoaling = 1.0 + (out.shoaling - 1.0) * out.confidence;
    return true;
}

void BatchWorkspace::ensure_capacity(size_t required) {
    if (required <= capacity) {
        return;
    }
    capacity = required;
    wx.resize(capacity); wz.resize(capacity); qx.resize(capacity); qz.resize(capacity);
    band_qx.resize(capacity); band_qz.resize(capacity);
    h.resize(capacity); dx.resize(capacity); dz.resize(capacity);
    dhx.resize(capacity); dhz.resize(capacity); dxx.resize(capacity); dxz.resize(capacity);
    dzx.resize(capacity); dzz.resize(capacity); vh.resize(capacity); vx.resize(capacity); vz.resize(capacity);
    cascade_h.resize(capacity); cascade_dx.resize(capacity); cascade_dz.resize(capacity);
    cascade_dhx.resize(capacity); cascade_dhz.resize(capacity); cascade_dxx.resize(capacity);
    cascade_dxz.resize(capacity); cascade_dzx.resize(capacity); cascade_dzz.resize(capacity);
    cascade_vh.resize(capacity); cascade_vx.resize(capacity); cascade_vz.resize(capacity);
    residual.resize(capacity);
    iterations.resize(capacity);
    done.resize(capacity);
    active_indices.resize(capacity);
    coastal_active_indices.resize(capacity);
    coastal_samples.resize(capacity);
    coastal_deep_x.resize(capacity); coastal_deep_z.resize(capacity);
    coastal_h.resize(capacity); coastal_dx.resize(capacity); coastal_dz.resize(capacity);
    coastal_dhx.resize(capacity); coastal_dhz.resize(capacity); coastal_dxx.resize(capacity); coastal_dxz.resize(capacity);
    coastal_dzx.resize(capacity); coastal_dzz.resize(capacity); coastal_vh.resize(capacity); coastal_vx.resize(capacity); coastal_vz.resize(capacity);
    coastal_deep_h.resize(capacity); coastal_deep_dx.resize(capacity); coastal_deep_dz.resize(capacity);
    coastal_deep_dhx.resize(capacity); coastal_deep_dhz.resize(capacity); coastal_deep_dxx.resize(capacity); coastal_deep_dxz.resize(capacity);
    coastal_deep_dzx.resize(capacity); coastal_deep_dzz.resize(capacity); coastal_deep_vh.resize(capacity); coastal_deep_vx.resize(capacity); coastal_deep_vz.resize(capacity);
    coastal_center_h.resize(capacity); coastal_center_dx.resize(capacity); coastal_center_dz.resize(capacity);
    coastal_center_vh.resize(capacity); coastal_center_vx.resize(capacity); coastal_center_vz.resize(capacity);
    coastal_stencil_h.resize(capacity); coastal_stencil_dx.resize(capacity); coastal_stencil_dz.resize(capacity);
    for (auto &values : coastal_open_stencil_h) values.resize(capacity);
    for (auto &values : coastal_open_stencil_dx) values.resize(capacity);
    for (auto &values : coastal_open_stencil_dz) values.resize(capacity);
    coastal_fd_dhx.resize(capacity); coastal_fd_dxx.resize(capacity); coastal_fd_dzx.resize(capacity);
    coastal_fd_dhz.resize(capacity); coastal_fd_dxz.resize(capacity); coastal_fd_dzz.resize(capacity);
    coastal_stencil_indices.resize(capacity);
    // 5R.1E: scratch del batch sharpened.
    sharpen_cdx.resize(capacity); sharpen_cdz.resize(capacity);
    sharpen_lqx.resize(capacity); sharpen_lqz.resize(capacity);
    sharpen_rqx.resize(capacity); sharpen_rqz.resize(capacity);
    band_l_c.resize(capacity); band_l_l.resize(capacity); band_l_r.resize(capacity);
    band_m_c.resize(capacity); band_m_l.resize(capacity); band_m_r.resize(capacity);
    jac_a.resize(capacity); jac_b.resize(capacity); jac_c.resize(capacity); jac_d.resize(capacity);
    fd_dx.resize(capacity); fd_dz.resize(capacity);
    fd_save_qx.resize(capacity); fd_save_qz.resize(capacity);
}

void OceanQueryCore::set_cascade_data(size_t cascade_index, double inv_n2,
                                      const double *kx, const double *ky, const double *omega,
                                      const double *a1, const double *a2,
                                      const double *c11, const double *c12,
                                      const double *c21, const double *c22,
                                      const double *parity, const double *weight,
                                      const double *h0_re, const double *h0_im,
                                      const double *h0n_re, const double *h0n_im,
                                      size_t count) {
    if (cascade_index >= cascades.size()) {
        cascades.resize(cascade_index + 1);
    }
    Cascade &c = cascades[cascade_index];
    c.inv_n2 = inv_n2;
    c.kx.assign(kx, kx + count);
    c.ky.assign(ky, ky + count);
    c.omega.assign(omega, omega + count);
    c.a1.assign(a1, a1 + count);
    c.a2.assign(a2, a2 + count);
    c.c11.assign(c11, c11 + count);
    c.c12.assign(c12, c12 + count);
    c.c21.assign(c21, c21 + count);
    c.c22.assign(c22, c22 + count);
    c.parity.assign(parity, parity + count);
    c.weight.assign(weight, weight + count);
    c.h0_re.assign(h0_re, h0_re + count);
    c.h0_im.assign(h0_im, h0_im + count);
    c.h0n_re.assign(h0n_re, h0n_re + count);
    c.h0n_im.assign(h0n_im, h0n_im + count);
    c.stencil_x_cos.resize(count); c.stencil_x_sin.resize(count);
    c.stencil_z_cos.resize(count); c.stencil_z_sin.resize(count);
    for (size_t i = 0; i < count; ++i) {
        const double px = c.kx[i] * 0.01, pz = c.ky[i] * 0.01;
        c.stencil_x_cos[i] = std::cos(px); c.stencil_x_sin[i] = std::sin(px);
        c.stencil_z_cos[i] = std::cos(pz); c.stencil_z_sin[i] = std::sin(pz);
    }
    prepared_valid = false;
    prepared_band_mask = 0;
    breaker_prepared_valid = false;
}

void OceanQueryCore::set_cascade_material_q_contract(size_t cascade_index, double domain_size_m, int resolution) {
    if (cascade_index >= cascades.size()) { cascades.resize(cascade_index + 1); }
    Cascade &c = cascades[cascade_index];
    c.material_domain_m = domain_size_m > 0.0 ? domain_size_m : 0.0;
    c.material_resolution = resolution >= 2 ? resolution : 0;
    c.regular_frequency_grid = false;
    c.separable_frequency_grid = false;
    c.regular_frequency_step = 0.0;
    if (c.material_domain_m <= 0.0 || c.material_resolution < 2 ||
        c.kx.size() != static_cast<size_t>(c.material_resolution) * static_cast<size_t>(c.material_resolution) ||
        c.ky.size() != c.kx.size()) { return; }
    const double step = 2.0 * 3.14159265358979323846 / c.material_domain_m;
    const int n = c.material_resolution;
    bool regular = true;
    bool separable = true;
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) {
            const size_t i = static_cast<size_t>(y) * static_cast<size_t>(n) + static_cast<size_t>(x);
            if (c.kx[i] != c.kx[static_cast<size_t>(x)] || c.ky[i] != c.ky[static_cast<size_t>(y) * static_cast<size_t>(n)]) {
                separable = false;
            }
            if (!regular) continue;
            const double expected_x = (static_cast<double>(x) - 0.5 * n) * step;
            const double expected_y = (static_cast<double>(y) - 0.5 * n) * step;
            const double tol_x = 1.0e-12 * (1.0 + std::abs(expected_x));
            const double tol_y = 1.0e-12 * (1.0 + std::abs(expected_y));
            if (std::abs(c.kx[i] - expected_x) > tol_x || std::abs(c.ky[i] - expected_y) > tol_y) {
                regular = false;
                break;
            }
        }
    }
    if (regular) {
        c.regular_frequency_grid = true;
        c.regular_frequency_step = step;
    }
    c.separable_frequency_grid = separable;
}

void OceanQueryCore::material_q_to_fft_q(size_t cascade_index, double material_qx, double material_qz,
                                         double &fft_qx, double &fft_qz) const {
    if (cascade_index >= cascades.size()) {
        fft_qx = material_qx;
        fft_qz = material_qz;
        return;
    }
    cascades[cascade_index].material_q_to_fft_q(material_qx, material_qz, fft_qx, fft_qz);
}

void OceanQueryCore::finalize_spectrum() {
    for (Cascade &c : cascades) {
        const size_t count = c.kx.size();
        c.fd01_kx.resize(count); c.fd01_ky.resize(count);
        c.fd05_kx.resize(count); c.fd05_ky.resize(count);
        for (size_t idx = 0; idx < count; ++idx) {
            c.fd01_kx[idx] = std::sin(c.kx[idx] * 0.01) / 0.01;
            c.fd01_ky[idx] = std::sin(c.ky[idx] * 0.01) / 0.01;
            c.fd05_kx[idx] = std::sin(c.kx[idx] * 0.05) / 0.05;
            c.fd05_ky[idx] = std::sin(c.ky[idx] * 0.05) / 0.05;
        }
        c.ev_h_re.assign(count, 0.0);
        c.ev_h_im.assign(count, 0.0);
        c.ev_v_re.assign(count, 0.0);
        c.ev_v_im.assign(count, 0.0);
        c.ev_a_h_re.assign(count, 0.0); c.ev_a_h_im.assign(count, 0.0);
        c.ev_b_h_re.assign(count, 0.0); c.ev_b_h_im.assign(count, 0.0);
        c.ev_a_v_re.assign(count, 0.0); c.ev_a_v_im.assign(count, 0.0);
        c.ev_b_v_re.assign(count, 0.0); c.ev_b_v_im.assign(count, 0.0);
        c.ev_coastal_h_re.assign(count, 0.0); c.ev_coastal_h_im.assign(count, 0.0);
        c.ev_coastal_v_re.assign(count, 0.0); c.ev_coastal_v_im.assign(count, 0.0);
        c.coastal_f_h.assign(count, 0.0); c.coastal_f_dx.assign(count, 0.0); c.coastal_f_dz.assign(count, 0.0); c.coastal_f_dhx.assign(count, 0.0); c.coastal_f_dhz.assign(count, 0.0);
        c.coastal_f_dxx.assign(count, 0.0); c.coastal_f_dxz.assign(count, 0.0); c.coastal_f_dzx.assign(count, 0.0); c.coastal_f_dzz.assign(count, 0.0); c.coastal_f_vh.assign(count, 0.0); c.coastal_f_vx.assign(count, 0.0); c.coastal_f_vz.assign(count, 0.0);
    }
    prepared_valid = false;
    prepared_band_mask = 0;
    breaker_prepared_valid = false;
}

void OceanQueryCore::set_coastal_long_weights(const double *pos, const double *neg, size_t count) {
    if (cascades.empty()) { return; }
    Cascade &c = cascades[0];
    if (count != c.kx.size()) { coastal.clear(); return; }
    c.coastal_weight_pos.assign(pos, pos + count);
    c.coastal_weight_neg.assign(neg, neg + count);
    c.coastal_nonzero_indices.clear();
    c.coastal_nonzero_indices.reserve(count);
    for (size_t idx = 0; idx < count; ++idx) {
        if (pos[idx] != 0.0 || neg[idx] != 0.0) {
            c.coastal_nonzero_indices.push_back(idx);
        }
    }
}

void OceanQueryCore::set_coastal_runtime(double field_origin_x, double field_origin_z,
                                         double field_extent_x, double field_extent_z,
                                         int field_width, int field_height,
                                         const double *shoaling, const double *field_valid,
                                         double warp_origin_x, double warp_origin_z,
                                         double warp_extent_x, double warp_extent_z,
                                         int warp_width, int warp_height,
                                         const double *warp_x, const double *warp_z,
                                         const double *det_j, const double *warp_valid,
                                         double detj_safe) {
    if (field_width < 2 || field_height < 2 || warp_width < 2 || warp_height < 2 ||
        field_extent_x <= 0.0 || field_extent_z <= 0.0 || warp_extent_x <= 0.0 || warp_extent_z <= 0.0 ||
        shoaling == nullptr || field_valid == nullptr || warp_x == nullptr || warp_z == nullptr ||
        det_j == nullptr || warp_valid == nullptr) { coastal.clear(); return; }
    const size_t field_count = static_cast<size_t>(field_width) * static_cast<size_t>(field_height);
    const size_t warp_count = static_cast<size_t>(warp_width) * static_cast<size_t>(warp_height);
    coastal.field_origin_x = field_origin_x; coastal.field_origin_z = field_origin_z;
    coastal.field_extent_x = field_extent_x; coastal.field_extent_z = field_extent_z;
    coastal.field_width = field_width; coastal.field_height = field_height;
    coastal.warp_origin_x = warp_origin_x; coastal.warp_origin_z = warp_origin_z;
    coastal.warp_extent_x = warp_extent_x; coastal.warp_extent_z = warp_extent_z;
    coastal.warp_width = warp_width; coastal.warp_height = warp_height;
    coastal.detj_safe = detj_safe;
    coastal.shoaling.assign(shoaling, shoaling + field_count);
    coastal.field_valid.assign(field_valid, field_valid + field_count);
    coastal.warp_x.assign(warp_x, warp_x + warp_count);
    coastal.warp_z.assign(warp_z, warp_z + warp_count);
    coastal.det_j.assign(det_j, det_j + warp_count);
    coastal.warp_valid.assign(warp_valid, warp_valid + warp_count);
    coastal.enabled = true;
}

void OceanQueryCore::ensure_prepared(double simulation_time) {
    if (prepared_valid && prepared_time == simulation_time &&
        (prepared_band_mask & active_query_band_mask) == active_query_band_mask) {
        return;
    }
    if (!prepared_valid || prepared_time != simulation_time) {
        prepared_band_mask = 0;
        prepared_valid = true;
        prepared_time = simulation_time;
    }
    for (size_t cascade_index = 0; cascade_index < cascades.size(); ++cascade_index) {
        if ((active_query_band_mask & (1u << cascade_index)) == 0 ||
            (prepared_band_mask & (1u << cascade_index)) != 0) { continue; }
        Cascade &c = cascades[cascade_index];
        const size_t count = c.kx.size();
        for (size_t idx = 0; idx < count; ++idx) {
            const double wt = c.omega[idx] * simulation_time;
            const double cw = std::cos(wt);
            const double sw = std::sin(wt);
            // Public directions point toward propagation. With spatial
            // Re(H*e^{+ik.x}), evolve A with e^{-iwt} and B with e^{+iwt}.
            const double a_re = c.h0_re[idx] * cw + c.h0_im[idx] * sw;
            const double a_im = -c.h0_re[idx] * sw + c.h0_im[idx] * cw;
            const double b_re = c.h0n_re[idx] * cw - c.h0n_im[idx] * sw;
            const double b_im = c.h0n_re[idx] * sw + c.h0n_im[idx] * cw;
            c.ev_h_re[idx] = a_re + b_re;
            c.ev_h_im[idx] = a_im + b_im;
            c.ev_v_re[idx] = c.omega[idx] * (a_im - b_im);
            c.ev_v_im[idx] = c.omega[idx] * (-a_re + b_re);
            c.ev_a_h_re[idx] = a_re; c.ev_a_h_im[idx] = a_im;
            c.ev_b_h_re[idx] = b_re; c.ev_b_h_im[idx] = b_im;
            c.ev_a_v_re[idx] = c.omega[idx] * a_im; c.ev_a_v_im[idx] = -c.omega[idx] * a_re;
            c.ev_b_v_re[idx] = -c.omega[idx] * b_im; c.ev_b_v_im[idx] = c.omega[idx] * b_re;
            // Mantiene exactamente el orden de C original: peso*A + peso*B.
            if (idx < c.coastal_weight_pos.size() && idx < c.coastal_weight_neg.size()) {
                c.ev_coastal_h_re[idx] = c.coastal_weight_pos[idx] * a_re + c.coastal_weight_neg[idx] * b_re;
                c.ev_coastal_h_im[idx] = c.coastal_weight_pos[idx] * a_im + c.coastal_weight_neg[idx] * b_im;
                c.ev_coastal_v_re[idx] = c.coastal_weight_pos[idx] * c.ev_a_v_re[idx] + c.coastal_weight_neg[idx] * c.ev_b_v_re[idx];
                c.ev_coastal_v_im[idx] = c.coastal_weight_pos[idx] * c.ev_a_v_im[idx] + c.coastal_weight_neg[idx] * c.ev_b_v_im[idx];
                const double sig = c.parity[idx] * c.weight[idx];
                c.coastal_f_h[idx] = sig; c.coastal_f_dx[idx] = sig * c.a1[idx]; c.coastal_f_dz[idx] = sig * c.a2[idx];
                c.coastal_f_dhx[idx] = sig * -c.kx[idx]; c.coastal_f_dhz[idx] = sig * -c.ky[idx];
                c.coastal_f_dxx[idx] = sig * c.c11[idx]; c.coastal_f_dxz[idx] = sig * c.c12[idx];
                c.coastal_f_dzx[idx] = sig * c.c21[idx]; c.coastal_f_dzz[idx] = sig * c.c22[idx];
                c.coastal_f_vh[idx] = sig; c.coastal_f_vx[idx] = sig * c.a1[idx]; c.coastal_f_vz[idx] = sig * c.a2[idx];
            } else {
                c.ev_coastal_h_re[idx] = c.ev_coastal_h_im[idx] = 0.0;
                c.ev_coastal_v_re[idx] = c.ev_coastal_v_im[idx] = 0.0;
                c.coastal_f_h[idx] = c.coastal_f_dx[idx] = c.coastal_f_dz[idx] = c.coastal_f_dhx[idx] = c.coastal_f_dhz[idx] = 0.0;
                c.coastal_f_dxx[idx] = c.coastal_f_dxz[idx] = c.coastal_f_dzx[idx] = c.coastal_f_dzz[idx] = c.coastal_f_vh[idx] = c.coastal_f_vx[idx] = c.coastal_f_vz[idx] = 0.0;
            }
        }
        prepared_band_mask |= static_cast<uint8_t>(1u << cascade_index);
    }
}

void OceanQueryCore::ensure_breaker_prepared(double simulation_time) {
    if (breaker_prepared_valid && breaker_prepared_time == simulation_time) {
        return;
    }
    breaker_prepared_valid = false;
    if (cascades.empty()) {
        return;
    }
    Cascade &c = cascades[0];
    const size_t count = c.kx.size();
    for (size_t idx = 0; idx < count; ++idx) {
        const double wt = c.omega[idx] * simulation_time;
        const double cw = std::cos(wt);
        const double sw = std::sin(wt);
        c.ev_a_h_re[idx] = c.h0_re[idx] * cw + c.h0_im[idx] * sw;
        c.ev_a_h_im[idx] = -c.h0_re[idx] * sw + c.h0_im[idx] * cw;
        c.ev_b_h_re[idx] = c.h0n_re[idx] * cw - c.h0n_im[idx] * sw;
        c.ev_b_h_im[idx] = c.h0n_re[idx] * sw + c.h0n_im[idx] * cw;
    }
    // Breaker sampling only visits the exact non-zero coastal support. Build
    // the A/B coastal combination once per time; the point hot path then only
    // evaluates phi/sin/cos and the requested height or slope terms.
    for (size_t idx : c.coastal_nonzero_indices) {
        c.ev_coastal_h_re[idx] = c.coastal_weight_pos[idx] * c.ev_a_h_re[idx] +
                                 c.coastal_weight_neg[idx] * c.ev_b_h_re[idx];
        c.ev_coastal_h_im[idx] = c.coastal_weight_pos[idx] * c.ev_a_h_im[idx] +
                                 c.coastal_weight_neg[idx] * c.ev_b_h_im[idx];
    }
    breaker_prepared_time = simulation_time;
    breaker_prepared_valid = true;
}

void OceanQueryCore::accumulate_breaker_long_height_(double qx, double qz, double &h) const {
    h = 0.0;
    if (cascades.empty()) {
        return;
    }
    const Cascade &c = cascades[0];
    double fft_qx = 0.0, fft_qz = 0.0;
    c.material_q_to_fft_q(qx, qz, fft_qx, fft_qz);
    for (size_t idx : c.coastal_nonzero_indices) {
        const double h_re = c.ev_coastal_h_re[idx];
        const double h_im = c.ev_coastal_h_im[idx];
        const double phi = c.kx[idx] * fft_qx + c.ky[idx] * fft_qz;
        const double cp = std::cos(phi);
        const double sp = std::sin(phi);
        const double sig = c.parity[idx] * c.weight[idx];
        h += sig * (h_re * cp - h_im * sp);
    }
    h *= c.inv_n2;
}

void OceanQueryCore::accumulate_breaker_long_slope_(double qx, double qz, double &h,
                                                     double &dhx, double &dhz) const {
    h = dhx = dhz = 0.0;
    if (cascades.empty()) {
        return;
    }
    const Cascade &c = cascades[0];
    double fft_qx = 0.0, fft_qz = 0.0;
    c.material_q_to_fft_q(qx, qz, fft_qx, fft_qz);
    for (size_t idx : c.coastal_nonzero_indices) {
        const double h_re = c.ev_coastal_h_re[idx];
        const double h_im = c.ev_coastal_h_im[idx];
        const double phi = c.kx[idx] * fft_qx + c.ky[idx] * fft_qz;
        const double cp = std::cos(phi);
        const double sp = std::sin(phi);
        const double p_im = h_re * sp + h_im * cp;
        const double sig = c.parity[idx] * c.weight[idx];
        h += sig * (h_re * cp - h_im * sp);
        dhx += sig * -c.kx[idx] * p_im;
        dhz += sig * -c.ky[idx] * p_im;
    }
    h *= c.inv_n2;
    dhx *= c.inv_n2;
    dhz *= c.inv_n2;
}

void OceanQueryCore::sample_coastal_breaker_prepared(const double *positions_xz, size_t n,
                                                      double *out, bool include_slope) const {
    if (!breaker_prepared_valid || cascades.empty() || !coastal.enabled) {
        for (size_t i = 0; i < n; ++i) {
            double *dst = out + i * S_STRIDE;
            for (int field = 0; field < S_STRIDE; ++field) dst[field] = 0.0;
        }
        return;
    }
    for (size_t i = 0; i < n; ++i) {
        const double qx = positions_xz[2 * i];
        const double qz = positions_xz[2 * i + 1];
        CoastalSample sample;
        double *dst = out + i * S_STRIDE;
        for (int field = 0; field < S_STRIDE; ++field) dst[field] = 0.0;
        if (!coastal.sample(qx, qz, sample)) {
            continue;
        }
        double open_h = 0.0, open_dhx = 0.0, open_dhz = 0.0;
        if (include_slope) {
            accumulate_breaker_long_slope_(qx, qz, open_h, open_dhx, open_dhz);
        } else {
            accumulate_breaker_long_height_(qx, qz, open_h);
        }
        double composed_h = open_h;
        double composed_dhx = open_dhx;
        double composed_dhz = open_dhz;
        if (sample.confidence > 0.0) {
            double deep_h = 0.0, deep_dhx = 0.0, deep_dhz = 0.0;
            if (include_slope) {
                accumulate_breaker_long_slope_(sample.deep_x, sample.deep_z, deep_h, deep_dhx, deep_dhz);
            } else {
                accumulate_breaker_long_height_(sample.deep_x, sample.deep_z, deep_h);
            }
            const double scaled_open = sample.effective_shoaling * (1.0 - sample.confidence);
            const double scaled_deep = sample.effective_shoaling * sample.confidence;
            composed_h = scaled_open * open_h + scaled_deep * deep_h - open_h;
            if (include_slope) {
                composed_dhx = scaled_open * open_dhx + scaled_deep * (sample.j00 * deep_dhx + sample.j10 * deep_dhz) - open_dhx;
                composed_dhz = scaled_open * open_dhz + scaled_deep * (sample.j01 * deep_dhx + sample.j11 * deep_dhz) - open_dhz;
            }
        }
        dst[S_VALID] = 1.0;
        dst[S_HEIGHT] = sea_level + composed_h;
        dst[S_NX] = 0.0; dst[S_NY] = 1.0; dst[S_NZ] = 0.0;
        dst[S_JACOBIAN_DET] = 1.0;
        if (include_slope) {
            double nx = -composed_dhx, ny = 1.0, nz = -composed_dhz;
            const double length = std::sqrt(nx * nx + ny * ny + nz * nz);
            if (length > 1.0e-8) {
                nx /= length; ny /= length; nz /= length;
            }
            dst[S_NX] = nx; dst[S_NY] = ny; dst[S_NZ] = nz;
        }
        // Displacement, velocity, foldover, residual and Newton iterations are
        // deliberately zero/identity: this contract is height/slope-only.
    }
}

size_t OceanQueryCore::coastal_nonzero_pair_count() const {
    return cascades.empty() ? 0 : cascades[0].coastal_nonzero_indices.size();
}


void OceanQueryCore::set_crest_sharpen(double strength, double threshold, double max_gain,
                                       double long_weight, double mid_weight,
                                       double dir_x, double dir_z, double eps, double local_hs) {
    crest_sharpen_enabled = strength > 0.0;
    crest_sharpen_strength = strength;
    crest_sharpen_threshold = threshold;
    crest_sharpen_max_gain = max_gain;
    crest_sharpen_long_weight = long_weight;
    crest_sharpen_mid_weight = mid_weight;
    crest_sharpen_dir_x = dir_x;
    crest_sharpen_dir_z = dir_z;
    crest_sharpen_eps = eps;
    crest_sharpen_local_hs = local_hs;
}


double OceanQueryCore::band_height_(size_t band_index, double qx, double qz) const {
    // 5R1D: altura de UNA banda (LONG=0, MID=1) en q, con espectro prepared.
    const Cascade &c = cascades[band_index];
    double fft_qx = 0.0, fft_qz = 0.0;
    c.material_q_to_fft_q(qx, qz, fft_qx, fft_qz);
    const size_t count = c.kx.size();
    double total = 0.0;
    for (size_t idx = 0; idx < count; ++idx) {
        const double phi = c.kx[idx] * fft_qx + c.ky[idx] * fft_qz;
        const double cp = std::cos(phi);
        const double sp = std::sin(phi);
        const double p_re = c.ev_h_re[idx] * cp - c.ev_h_im[idx] * sp;
        const double sig = c.parity[idx] * c.weight[idx];
        total += sig * p_re;
    }
    return total * c.inv_n2;
}


void OceanQueryCore::apply_crest_sharpen_(double qx, double qz, double &h, double &dx, double &dz) const {
    // 5R1D: misma matemática 5R.1C del shader (sobre FFT base, no recursiva).
    if (!crest_sharpen_enabled || cascades.size() < 2) return;
    const double local_hs = std::max(crest_sharpen_local_hs, 0.05);
    const double eps = crest_sharpen_eps;
    const double dirx = crest_sharpen_dir_x, dirz = crest_sharpen_dir_z;
    const double l_c = band_height_(0, qx, qz);
    const double l_l = band_height_(0, qx - dirx * eps, qz - dirz * eps);
    const double l_r = band_height_(0, qx + dirx * eps, qz + dirz * eps);
    const bool include_mid = (active_query_band_mask & QUERY_BAND_MID) != 0;
    const double m_c = include_mid ? band_height_(1, qx, qz) : 0.0;
    const double m_l = include_mid ? band_height_(1, qx - dirx * eps, qz - dirz * eps) : 0.0;
    const double m_r = include_mid ? band_height_(1, qx + dirx * eps, qz + dirz * eps) : 0.0;
    const double curv_long = l_l - 2.0 * l_c + l_r;
    const double curv_mid = m_l - 2.0 * m_c + m_r;
    const double crest_long = std::clamp(-curv_long / local_hs, 0.0, 2.0) * crest_sharpen_long_weight;
    const double crest_mid = std::clamp(-curv_mid / std::max(local_hs * 0.4, 0.02), 0.0, 2.0) * crest_sharpen_mid_weight;
    const double crestness = crest_long + crest_mid;
    const double face_slope = std::abs(l_r - l_l) / (2.0 * eps);
    const double compression = smoothstep01(0.03, 0.22, face_slope);
    const double sharpen = smoothstep01(crest_sharpen_threshold, crest_sharpen_threshold + 0.25, crestness)
        * compression * crest_sharpen_strength;
    const double delta_y = sharpen * crest_sharpen_max_gain * local_hs;
    const double h_scale = 1.0 + sharpen * crest_sharpen_max_gain * 0.35;
    h += delta_y;
    dx *= h_scale;
    dz *= h_scale;
}


void OceanQueryCore::finite_jacobian_(double qx, double qz, double &ja, double &jb, double &jc, double &jd) {
    // 5R1D-hotfix: Jacobian 2D de q + final_dx/dz por diferencias finitas centrales.
    const double d = 0.05;
    double h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
    double xp_x, xp_z, xm_x, xm_z, zp_x, zp_z, zm_x, zm_z;

    accumulate_(qx + d, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx + d, qz, h, dx, dz);
    xp_x = dx; xp_z = dz;
    accumulate_(qx - d, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx - d, qz, h, dx, dz);
    xm_x = dx; xm_z = dz;
    accumulate_(qx, qz + d, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx, qz + d, h, dx, dz);
    zp_x = dx; zp_z = dz;
    accumulate_(qx, qz - d, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx, qz - d, h, dx, dz);
    zm_x = dx; zm_z = dz;

    ja = 1.0 + (xp_x - xm_x) / (2.0 * d);
    jb = (zp_x - zm_x) / (2.0 * d);
    jc = (xp_z - xm_z) / (2.0 * d);
    jd = 1.0 + (zp_z - zm_z) / (2.0 * d);
}


size_t OceanQueryCore::coastal_pair_count() const {
    return cascades.empty() ? 0 : cascades[0].kx.size();
}

void OceanQueryCore::accumulate_open_(double qx, double qz, bool use_prepared, double sim_time,
                                 double &h, double &dx, double &dz,
                                 double &dhx, double &dhz,
                                 double &dxx, double &dxz, double &dzx, double &dzz,
                                 double &vh, double &vx, double &vz) {
    double total_h = 0.0, total_dx = 0.0, total_dz = 0.0;
    double total_dhx = 0.0, total_dhz = 0.0;
    double total_dxx = 0.0, total_dxz = 0.0, total_dzx = 0.0, total_dzz = 0.0;
    double total_vh = 0.0, total_vx = 0.0, total_vz = 0.0;

    for (size_t cascade_index = 0; cascade_index < cascades.size(); ++cascade_index) {
        if ((active_query_band_mask & (1u << cascade_index)) == 0) { continue; }
        const Cascade &c = cascades[cascade_index];
        double fft_qx = 0.0, fft_qz = 0.0;
        c.material_q_to_fft_q(qx, qz, fft_qx, fft_qz);
        const double inv_n2 = c.inv_n2;
        const size_t count = c.kx.size();
        double lh = 0.0, ldx = 0.0, ldz = 0.0;
        double ldhx = 0.0, ldhz = 0.0;
        double ldxx = 0.0, ldxz = 0.0, ldzx = 0.0, ldzz = 0.0;
        double lvh = 0.0, lvx = 0.0, lvz = 0.0;
        for (size_t idx = 0; idx < count; ++idx) {
            double h_re, h_im, v_re, v_im;
            if (use_prepared) {
                h_re = c.ev_h_re[idx];
                h_im = c.ev_h_im[idx];
                v_re = c.ev_v_re[idx];
                v_im = c.ev_v_im[idx];
            } else {
                const double wt = c.omega[idx] * sim_time;
                const double cw = std::cos(wt);
                const double sw = std::sin(wt);
                const double a_re = c.h0_re[idx] * cw + c.h0_im[idx] * sw;
                const double a_im = -c.h0_re[idx] * sw + c.h0_im[idx] * cw;
                const double b_re = c.h0n_re[idx] * cw - c.h0n_im[idx] * sw;
                const double b_im = c.h0n_re[idx] * sw + c.h0n_im[idx] * cw;
                h_re = a_re + b_re;
                h_im = a_im + b_im;
                v_re = c.omega[idx] * (a_im - b_im);
                v_im = c.omega[idx] * (-a_re + b_re);
            }
            const double phi = c.kx[idx] * fft_qx + c.ky[idx] * fft_qz;
            const double cp = std::cos(phi);
            const double sp = std::sin(phi);
            const double p_re = h_re * cp - h_im * sp;
            const double p_im = h_re * sp + h_im * cp;
            const double q_re = v_re * cp - v_im * sp;
            const double q_im = v_re * sp + v_im * cp;
            const double sig = c.parity[idx] * c.weight[idx];
            lh += sig * p_re;
            ldx += sig * c.a1[idx] * p_im;
            ldz += sig * c.a2[idx] * p_im;
            ldhx += sig * -c.kx[idx] * p_im;
            ldhz += sig * -c.ky[idx] * p_im;
            ldxx += sig * c.c11[idx] * p_re;
            ldxz += sig * c.c12[idx] * p_re;
            ldzx += sig * c.c21[idx] * p_re;
            ldzz += sig * c.c22[idx] * p_re;
            lvh += sig * q_re;
            lvx += sig * c.a1[idx] * q_im;
            lvz += sig * c.a2[idx] * q_im;
        }
        total_h += lh * inv_n2;
        total_dx += ldx * inv_n2;
        total_dz += ldz * inv_n2;
        total_dhx += ldhx * inv_n2;
        total_dhz += ldhz * inv_n2;
        total_dxx += ldxx * inv_n2;
        total_dxz += ldxz * inv_n2;
        total_dzx += ldzx * inv_n2;
        total_dzz += ldzz * inv_n2;
        total_vh += lvh * inv_n2;
        total_vx += lvx * inv_n2;
        total_vz += lvz * inv_n2;
    }

    h = total_h;
    dx = total_dx;
    dz = total_dz;
    dhx = total_dhx;
    dhz = total_dhz;
    dxx = total_dxx;
    dxz = total_dxz;
    dzx = total_dzx;
    dzz = total_dzz;
    vh = total_vh;
    vx = total_vx;
    vz = total_vz;
}

void OceanQueryCore::evaluate_long_(double qx, double qz, bool use_prepared, double sim_time,
                                    double &h, double &dx, double &dz,
                                    double &vh, double &vx, double &vz) const {
    h = dx = dz = vh = vx = vz = 0.0;
    if (cascades.empty()) { return; }
    const Cascade &c = cascades[0];
    double fft_qx = 0.0, fft_qz = 0.0;
    c.material_q_to_fft_q(qx, qz, fft_qx, fft_qz);
    double lh = 0.0, ldx = 0.0, ldz = 0.0, lvh = 0.0, lvx = 0.0, lvz = 0.0;
    for (size_t idx = 0; idx < c.kx.size(); ++idx) {
        double h_re, h_im, v_re, v_im;
        if (use_prepared) {
            h_re = c.ev_h_re[idx]; h_im = c.ev_h_im[idx];
            v_re = c.ev_v_re[idx]; v_im = c.ev_v_im[idx];
        } else {
            const double wt = c.omega[idx] * sim_time, cw = std::cos(wt), sw = std::sin(wt);
            const double ar = c.h0_re[idx] * cw + c.h0_im[idx] * sw;
            const double ai = -c.h0_re[idx] * sw + c.h0_im[idx] * cw;
            const double br = c.h0n_re[idx] * cw - c.h0n_im[idx] * sw;
            const double bi = c.h0n_re[idx] * sw + c.h0n_im[idx] * cw;
            h_re = ar + br; h_im = ai + bi;
            v_re = c.omega[idx] * (ai - bi); v_im = c.omega[idx] * (-ar + br);
        }
        const double phi = c.kx[idx] * fft_qx + c.ky[idx] * fft_qz, cp = std::cos(phi), sp = std::sin(phi);
        const double pre = h_re * cp - h_im * sp, pim = h_re * sp + h_im * cp;
        const double qre = v_re * cp - v_im * sp, qim = v_re * sp + v_im * cp;
        const double sig = c.parity[idx] * c.weight[idx];
        lh += sig * pre; ldx += sig * c.a1[idx] * pim; ldz += sig * c.a2[idx] * pim;
        lvh += sig * qre; lvx += sig * c.a1[idx] * qim; lvz += sig * c.a2[idx] * qim;
    }
    h = lh * c.inv_n2; dx = ldx * c.inv_n2; dz = ldz * c.inv_n2;
    vh = lvh * c.inv_n2; vx = lvx * c.inv_n2; vz = lvz * c.inv_n2;
}

void OceanQueryCore::accumulate_displacement_(double qx, double qz, bool use_prepared, double sim_time,
                                              double &h, double &dx, double &dz,
                                              double &vh, double &vx, double &vz) {
    double dhx, dhz, dxx, dxz, dzx, dzz;
    accumulate_open_(qx, qz, use_prepared, sim_time, h, dx, dz, dhx, dhz,
                     dxx, dxz, dzx, dzz, vh, vx, vz);
    CoastalSample s;
    if (!coastal.sample(qx, qz, s) || s.confidence <= 0.0) { return; }
    double open_h, open_dx, open_dz, open_vh, open_vx, open_vz;
    double warp_h, warp_dx, warp_dz, warp_vh, warp_vx, warp_vz;
    evaluate_long_(qx, qz, use_prepared, sim_time, open_h, open_dx, open_dz, open_vh, open_vx, open_vz);
    evaluate_long_(s.warp_x, s.warp_z, use_prepared, sim_time, warp_h, warp_dx, warp_dz, warp_vh, warp_vx, warp_vz);
    const double confidence = s.confidence;
    const double shoaling_scale = 1.0 + (s.shoaling - 1.0) * confidence;
    const double coastal_h = (open_h * (1.0 - confidence) + warp_h * confidence) * shoaling_scale;
    const double coastal_dx = open_dx * (1.0 - confidence) + warp_dx * confidence;
    const double coastal_dz = open_dz * (1.0 - confidence) + warp_dz * confidence;
    const double coastal_vh = (open_vh * (1.0 - confidence) + warp_vh * confidence) * shoaling_scale;
    const double coastal_vx = open_vx * (1.0 - confidence) + warp_vx * confidence;
    const double coastal_vz = open_vz * (1.0 - confidence) + warp_vz * confidence;
    h += coastal_h - open_h;
    dx += coastal_dx - open_dx;
    dz += coastal_dz - open_dz;
    vh += coastal_vh - open_vh;
    vx += coastal_vx - open_vx;
    vz += coastal_vz - open_vz;
}

void OceanQueryCore::accumulate_(double qx, double qz, bool use_prepared, double sim_time,
                                 double &h, double &dx, double &dz,
                                 double &dhx, double &dhz,
                                 double &dxx, double &dxz, double &dzx, double &dzz,
                                 double &vh, double &vx, double &vz) {
    accumulate_open_(qx, qz, use_prepared, sim_time, h, dx, dz, dhx, dhz,
                     dxx, dxz, dzx, dzz, vh, vx, vz);
    CoastalSample sample;
    if (!coastal.sample(qx, qz, sample) || sample.confidence <= 0.0) { return; }

    // The baked field is bilinear and the shader mixes through its sampled
    // confidence/warp/shoaling values. Differentiate the final displacement
    // with a fixed centered 1 cm stencil so normals/Newton use that same field.
    constexpr double epsilon = 0.01;
    double hp, dxp, dzp, vhp, vxp, vzp;
    double hm, dxm, dzm, vhm, vxm, vzm;
    // Keep the returned center sample on the same Coastal-modified surface as
    // the derivative stencil. The open-ocean accumulation above is only the
    // base used when constructing this final field.
    accumulate_displacement_(qx, qz, use_prepared, sim_time,
                             h, dx, dz, vh, vx, vz);
    accumulate_displacement_(qx + epsilon, qz, use_prepared, sim_time, hp, dxp, dzp, vhp, vxp, vzp);
    accumulate_displacement_(qx - epsilon, qz, use_prepared, sim_time, hm, dxm, dzm, vhm, vxm, vzm);
    dhx = (hp - hm) / (2.0 * epsilon);
    dxx = (dxp - dxm) / (2.0 * epsilon);
    dzx = (dzp - dzm) / (2.0 * epsilon);
    accumulate_displacement_(qx, qz + epsilon, use_prepared, sim_time, hp, dxp, dzp, vhp, vxp, vzp);
    accumulate_displacement_(qx, qz - epsilon, use_prepared, sim_time, hm, dxm, dzm, vhm, vxm, vzm);
    dhz = (hp - hm) / (2.0 * epsilon);
    dxz = (dxp - dxm) / (2.0 * epsilon);
    dzz = (dzp - dzm) / (2.0 * epsilon);
}

void OceanQueryCore::apply_coastal_correction_(double qx, double qz, bool use_prepared, double sim_time,
                                               double &h, double &dx, double &dz,
                                               double &dhx, double &dhz,
                                               double &dxx, double &dxz, double &dzx, double &dzz,
                                               double &vh, double &vx, double &vz) {
    accumulate_(qx, qz, use_prepared, sim_time, h, dx, dz, dhx, dhz,
                dxx, dxz, dzx, dzz, vh, vx, vz);
}

void OceanQueryCore::sample_prepared_(double wx, double wz, double *out,
                                     double *material_q_x, double *material_q_z) {
    // Newton world_xz -> q usando el displacement FINAL (base + crest sharpening).
    double qx = wx, qz = wz;
    double h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
    const int max_iterations = coastal.enabled ? MAX_COASTAL_ITERATIONS : MAX_ITERATIONS;
    int iterations = 0;
    bool converged = false;
    double residual = 0.0;
    while (true) {
        accumulate_(qx, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
        apply_crest_sharpen_(qx, qz, h, dx, dz);
        const double fx = qx + dx - wx;
        const double fz = qz + dz - wz;
        residual = std::sqrt(fx * fx + fz * fz);
        if (residual <= POSITION_TOLERANCE_M || iterations >= max_iterations) {
            converged = residual <= POSITION_TOLERANCE_M;
            break;
        }
        double ja, jb, jc, jd;
        finite_jacobian_(qx, qz, ja, jb, jc, jd);
        const double det = ja * jd - jb * jc;
        if (std::abs(det) <= JACOBIAN_EPSILON) {
            break;
        }
        const double inv = 1.0 / det;
        qx -= inv * (jd * fx - jb * fz);
        qz -= inv * (-jc * fx + ja * fz);
        iterations += 1;
    }
    // Re-evalúa la superficie FINAL en q resuelto (no aplicar sharpening 2 veces).
    accumulate_(qx, qz, true, prepared_time, h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz);
    apply_crest_sharpen_(qx, qz, h, dx, dz);
    if (!converged) {
        diag_non_converged += 1;
    }
    if (material_q_x) { *material_q_x = qx; }
    if (material_q_z) { *material_q_z = qz; }

    // Construcción del sample (mismo orden que GDScript _build_sample).
    double disp[3] = {dx, h, dz};
    double tangent_x[3] = {1.0 + dxx, dhx, dzx};
    double tangent_z[3] = {dxz, dhz, 1.0 + dzz};
    double normal[3];
    normal[0] = tangent_z[1] * tangent_x[2] - tangent_z[2] * tangent_x[1];
    normal[1] = tangent_z[2] * tangent_x[0] - tangent_z[0] * tangent_x[2];
    normal[2] = tangent_z[0] * tangent_x[1] - tangent_z[1] * tangent_x[0];
    double len2 = normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2];
    if (len2 > 1.0e-14) {
        double len = std::sqrt(len2);
        normal[0] /= len;
        normal[1] /= len;
        normal[2] /= len;
        if (normal[1] < 0.0) {
            normal[0] = -normal[0];
            normal[1] = -normal[1];
            normal[2] = -normal[2];
        }
    } else {
        normal[0] = 0.0;
        normal[1] = 1.0;
        normal[2] = 0.0;
    }
    const double det_j = (1.0 + dxx) * (1.0 + dzz) - dxz * dzx;

    // Escribe el contrato (stride S_STRIDE).
    out[S_VALID] = converged ? 1.0 : 0.0;
    out[S_HEIGHT] = sea_level + h;
    out[S_DX] = disp[0];
    out[S_DY] = disp[1];
    out[S_DZ] = disp[2];
    out[S_NX] = normal[0];
    out[S_NY] = normal[1];
    out[S_NZ] = normal[2];
    out[S_VX] = vx;
    out[S_VY] = vh;
    out[S_VZ] = vz;
    out[S_JACOBIAN_DET] = det_j;
    out[S_FOLDOVER] = det_j <= 0.0 ? 1.0 : 0.0;
    out[S_RESIDUAL] = residual;
    out[S_ITERATIONS] = static_cast<double>(iterations);
}

void OceanQueryCore::sample_world(double wx, double wz, double simulation_time, double *out) {
    ensure_prepared(simulation_time);
    sample_prepared_(wx, wz, out);
}

void OceanQueryCore::sample_world_with_material_q(double wx, double wz, double simulation_time,
                                                  double *out, double *material_q_x, double *material_q_z) {
    ensure_prepared(simulation_time);
    sample_prepared_(wx, wz, out, material_q_x, material_q_z);
}

void OceanQueryCore::sample_material_q(double qx, double qz, double simulation_time, double *out) {
    ensure_prepared(simulation_time);
    sample_material_q_prepared_(qx, qz, out);
}

void OceanQueryCore::sample_material_q_prepared_(double qx, double qz, double *out) {
    double h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
    accumulate_(qx, qz, true, prepared_time, h, dx, dz, dhx, dhz,
                dxx, dxz, dzx, dzz, vh, vx, vz);

    // Geometric normal from the analytic spectral derivatives, with Y-up.
    double nx = dhz * dzx - (1.0 + dzz) * dhx;
    double ny = (1.0 + dzz) * (1.0 + dxx) - dxz * dzx;
    double nz = dxz * dhx - dhz * (1.0 + dxx);
    const double len2 = nx * nx + ny * ny + nz * nz;
    if (len2 > 1.0e-14) {
        const double inv_len = 1.0 / std::sqrt(len2);
        nx *= inv_len; ny *= inv_len; nz *= inv_len;
        if (ny < 0.0) { nx = -nx; ny = -ny; nz = -nz; }
    } else {
        nx = 0.0; ny = 1.0; nz = 0.0;
    }
    const double det_j = (1.0 + dxx) * (1.0 + dzz) - dxz * dzx;
    out[S_VALID] = 1.0;
    out[S_HEIGHT] = sea_level + h;
    out[S_DX] = dx; out[S_DY] = h; out[S_DZ] = dz;
    out[S_NX] = nx; out[S_NY] = ny; out[S_NZ] = nz;
    out[S_VX] = vx; out[S_VY] = vh; out[S_VZ] = vz;
    out[S_JACOBIAN_DET] = det_j;
    out[S_FOLDOVER] = det_j <= 0.0 ? 1.0 : 0.0;
    out[S_RESIDUAL] = 0.0;
    out[S_ITERATIONS] = 0.0;
}

void OceanQueryCore::sample_material_q_batch_prepared(const double *positions_xz, size_t n, double *out) {
    diag_last_material_batch_avx2 = false;
    diag_last_world_batch_avx2 = false;
    diag_last_coastal_deep_avx2 = false;
    diag_last_spectral_point_evaluations = 0;
    diag_non_converged = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    if (n == 0) { return; }
    if (!avx2_supported() || force_scalar || n < 4) {
        for (size_t p = 0; p < n; ++p) {
            sample_material_q_prepared_(positions_xz[2 * p], positions_xz[2 * p + 1], out + p * S_STRIDE);
        }
        return;
    }

    batch_.ensure_capacity(n);
    for (size_t p = 0; p < n; ++p) {
        batch_.qx[p] = positions_xz[2 * p];
        batch_.qz[p] = positions_xz[2 * p + 1];
        batch_.residual[p] = 0.0;
        batch_.iterations[p] = 0;
        batch_.active_indices[p] = p;
    }
    evaluate_avx2_batch_(batch_.active_indices.data(), n, true);
    diag_last_material_batch_avx2 = true;
    for (size_t p = 0; p < n; ++p) {
        build_sample_from_fields_(p, true, out + p * S_STRIDE);
    }
}

void OceanQueryCore::sample_batch_prepared(const double *positions_xz, size_t n, double *out) {
    diag_last_material_batch_avx2 = false;
    diag_last_world_batch_avx2 = false;
    diag_last_coastal_deep_avx2 = false;
    diag_non_converged = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    if (n == 0) { return; }
    if (crest_sharpen_enabled) {
        // 5R.1E: con sharpening la inversión usa displacement FINAL + Jacobian
        // finito. Ahora existe una ruta AVX2 específica (misma matemática del
        // hotfix); scalar queda como fallback para CPUs sin AVX2, force_scalar
        // y batches pequeños.
        if (avx2_supported() && !force_scalar && n >= 4) {
            batch_.ensure_capacity(n);
            for (size_t p = 0; p < n; ++p) {
                batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
                batch_.qx[p] = batch_.wx[p]; batch_.qz[p] = batch_.wz[p];
            }
            solve_avx2_batch_sharpened_(n, out, true);
            diag_last_world_batch_avx2 = true;
            return;
        }
        sample_batch_scalar_prepared(positions_xz, n, out);
        return;
    }
    if (avx2_supported() && !force_scalar && n >= 4) {
        batch_.ensure_capacity(n);
        for (size_t p = 0; p < n; ++p) {
            batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
            batch_.qx[p] = batch_.wx[p]; batch_.qz[p] = batch_.wz[p];
        }
        solve_avx2_batch_(n, out, true);
        diag_last_world_batch_avx2 = true;
        return;
    }
    sample_batch_scalar_prepared(positions_xz, n, out);
}

void OceanQueryCore::sample_batch_scalar_prepared(const double *positions_xz, size_t n, double *out) {
    for (size_t i = 0; i < n; ++i) {
        sample_prepared_(positions_xz[2 * i], positions_xz[2 * i + 1], out + i * S_STRIDE);
    }
}

void OceanQueryCore::sample_batch_avx2_scalar_trig_prepared(const double *positions_xz, size_t n, double *out) {
    diag_last_material_batch_avx2 = false;
    diag_last_world_batch_avx2 = false;
    diag_last_coastal_deep_avx2 = false;
    diag_non_converged = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    if (!avx2_supported() || force_scalar || n < 4) { sample_batch_scalar_prepared(positions_xz, n, out); return; }
    batch_.ensure_capacity(n);
    for (size_t p = 0; p < n; ++p) {
        batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
        batch_.qx[p] = batch_.wx[p]; batch_.qz[p] = batch_.wz[p];
    }
    solve_avx2_batch_(n, out, false);
    diag_last_world_batch_avx2 = true;
}

bool OceanQueryCore::avx2_supported() const { return detect_avx2_runtime(); }

const char *OceanQueryCore::query_execution_backend() const {
    return avx2_supported() && !force_scalar ? "AVX2" : "SCALAR";
}

void OceanQueryCore::evaluate_true_batch_(const size_t *indices, size_t active_count) {
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.h[p] = batch_.dx[p] = batch_.dz[p] = 0.0;
        batch_.dhx[p] = batch_.dhz[p] = 0.0;
        batch_.dxx[p] = batch_.dxz[p] = batch_.dzx[p] = batch_.dzz[p] = 0.0;
        batch_.vh[p] = batch_.vx[p] = batch_.vz[p] = 0.0;
    }

    // Orden mode-major. Dentro de cada punto se mantiene exactamente el mismo
    // orden de sumas de modos y de reducción por cascada que DIRECT_SCALAR.
    for (size_t cascade_index = 0; cascade_index < cascades.size(); ++cascade_index) {
        if ((active_query_band_mask & (1u << cascade_index)) == 0) { continue; }
        const Cascade &c = cascades[cascade_index];
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            c.material_q_to_fft_q(batch_.qx[p], batch_.qz[p], batch_.band_qx[p], batch_.band_qz[p]);
        }
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            batch_.cascade_h[p] = batch_.cascade_dx[p] = batch_.cascade_dz[p] = 0.0;
            batch_.cascade_dhx[p] = batch_.cascade_dhz[p] = 0.0;
            batch_.cascade_dxx[p] = batch_.cascade_dxz[p] = 0.0;
            batch_.cascade_dzx[p] = batch_.cascade_dzz[p] = 0.0;
            batch_.cascade_vh[p] = batch_.cascade_vx[p] = batch_.cascade_vz[p] = 0.0;
        }
        const size_t count = c.kx.size();
        for (size_t idx = 0; idx < count; ++idx) {
            const double h_re = c.ev_h_re[idx];
            const double h_im = c.ev_h_im[idx];
            const double v_re = c.ev_v_re[idx];
            const double v_im = c.ev_v_im[idx];
            const double sig = c.parity[idx] * c.weight[idx];
            for (size_t ai = 0; ai < active_count; ++ai) {
                const size_t p = indices[ai];
                const double phi = c.kx[idx] * batch_.band_qx[p] + c.ky[idx] * batch_.band_qz[p];
                const double cp = std::cos(phi);
                const double sp = std::sin(phi);
                const double p_re = h_re * cp - h_im * sp;
                const double p_im = h_re * sp + h_im * cp;
                const double q_re = v_re * cp - v_im * sp;
                const double q_im = v_re * sp + v_im * cp;
                batch_.cascade_h[p] += sig * p_re;
                batch_.cascade_dx[p] += sig * c.a1[idx] * p_im;
                batch_.cascade_dz[p] += sig * c.a2[idx] * p_im;
                batch_.cascade_dhx[p] += sig * -c.kx[idx] * p_im;
                batch_.cascade_dhz[p] += sig * -c.ky[idx] * p_im;
                batch_.cascade_dxx[p] += sig * c.c11[idx] * p_re;
                batch_.cascade_dxz[p] += sig * c.c12[idx] * p_re;
                batch_.cascade_dzx[p] += sig * c.c21[idx] * p_re;
                batch_.cascade_dzz[p] += sig * c.c22[idx] * p_re;
                batch_.cascade_vh[p] += sig * q_re;
                batch_.cascade_vx[p] += sig * c.a1[idx] * q_im;
                batch_.cascade_vz[p] += sig * c.a2[idx] * q_im;
            }
        }
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            const double inv_n2 = c.inv_n2;
            batch_.h[p] += batch_.cascade_h[p] * inv_n2;
            batch_.dx[p] += batch_.cascade_dx[p] * inv_n2;
            batch_.dz[p] += batch_.cascade_dz[p] * inv_n2;
            batch_.dhx[p] += batch_.cascade_dhx[p] * inv_n2;
            batch_.dhz[p] += batch_.cascade_dhz[p] * inv_n2;
            batch_.dxx[p] += batch_.cascade_dxx[p] * inv_n2;
            batch_.dxz[p] += batch_.cascade_dxz[p] * inv_n2;
            batch_.dzx[p] += batch_.cascade_dzx[p] * inv_n2;
            batch_.dzz[p] += batch_.cascade_dzz[p] * inv_n2;
            batch_.vh[p] += batch_.cascade_vh[p] * inv_n2;
            batch_.vx[p] += batch_.cascade_vx[p] * inv_n2;
            batch_.vz[p] += batch_.cascade_vz[p] * inv_n2;
        }
    }
    // Coastal se evalúa por punto (sampler escalar) después del kernel base.
    // La suma base permanece mode-major; sólo C(q), C(F(q)) es adicional.
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        apply_coastal_correction_(batch_.qx[p], batch_.qz[p], true, prepared_time,
                                  batch_.h[p], batch_.dx[p], batch_.dz[p], batch_.dhx[p], batch_.dhz[p],
                                  batch_.dxx[p], batch_.dxz[p], batch_.dzx[p], batch_.dzz[p],
                                  batch_.vh[p], batch_.vx[p], batch_.vz[p]);
    }
    diag_last_spectral_point_evaluations += active_count;
}

void OceanQueryCore::evaluate_avx2_batch_(const size_t *indices, size_t active_count, bool vector_sincos,
                                          bool compute_coastal_stencil, double coastal_stencil_epsilon,
                                          bool displacement_only, bool coastal_only, int profile_stage,
                                          bool skip_base_spectrum) {
    if (active_count < 4) { evaluate_true_batch_(indices, active_count); return; }
    diag_last_coastal_deep_avx2 = false;
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.h[p] = batch_.dx[p] = batch_.dz[p] = 0.0;
        batch_.dhx[p] = batch_.dhz[p] = 0.0;
        batch_.dxx[p] = batch_.dxz[p] = batch_.dzx[p] = batch_.dzz[p] = 0.0;
        batch_.vh[p] = batch_.vx[p] = batch_.vz[p] = 0.0;
    }
    const size_t coastal_active_count = sample_coastal_batch_(indices, active_count, profile_stage);
    const bool fuse_coastal_q = coastal_active_count > 0;
    const size_t stencil_count = coastal_stencil_epsilon > 0.01 ? active_count : coastal_active_count;
    const bool use_fourier_stencil = compute_coastal_stencil && !crest_sharpen_enabled &&
        active_count >= 4 && active_count % 4 == 0 && stencil_count >= 4 && stencil_count % 4 == 0 &&
        (fuse_coastal_q || coastal_stencil_epsilon > 0.01);
    if (skip_base_spectrum && profile_stage >= 1 && profile_stage <= 4) {
        const size_t slot = static_cast<size_t>(profile_stage - 1);
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            batch_.h[p] = batch_.coastal_h[p] = batch_.coastal_open_stencil_h[slot][p];
            batch_.dx[p] = batch_.coastal_dx[p] = batch_.coastal_open_stencil_dx[slot][p];
            batch_.dz[p] = batch_.coastal_dz[p] = batch_.coastal_open_stencil_dz[slot][p];
        }
    } else {
        const auto base_start = coastal_profile.enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
        evaluate_batch_avx2(cascades, batch_, indices, active_count, vector_sincos, fuse_coastal_q, displacement_only,
                            coastal_only, use_fourier_stencil ? coastal_stencil_epsilon : 0.0,
                            coastal_profile.enabled ? &coastal_profile : nullptr, profile_stage,
                            active_query_band_mask);
        if (coastal_profile.enabled) {
            coastal_profile.base_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - base_start).count());
        }
    }
    if (fuse_coastal_q) {
        const auto deep_start = coastal_profile.enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
        diag_last_coastal_deep_avx2 = coastal_active_count >= 4;
        evaluate_coastal_long_batch_avx2(cascades[0], batch_, batch_.coastal_active_indices.data(), coastal_active_count, vector_sincos,
                                         displacement_only, coastal_profile.enabled ? &coastal_profile : nullptr, profile_stage);
        if (coastal_profile.enabled) {
            coastal_profile.cdeep_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - deep_start).count());
        }
        apply_coastal_batch_(batch_.coastal_active_indices.data(), coastal_active_count, displacement_only, profile_stage);
    }
    if (coastal_only) {
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            if (batch_.coastal_samples[p].confidence > 0.0) {
                batch_.h[p] -= batch_.coastal_h[p];
                batch_.dx[p] -= batch_.coastal_dx[p];
                batch_.dz[p] -= batch_.coastal_dz[p];
            } else {
                batch_.h[p] = batch_.dx[p] = batch_.dz[p] = 0.0;
            }
        }
    }
    if (compute_coastal_stencil && !crest_sharpen_enabled &&
        (fuse_coastal_q || coastal_stencil_epsilon > 0.01)) {
            const double epsilon = coastal_stencil_epsilon;
            const bool fused_open_stencil = use_fourier_stencil && std::abs(epsilon - 0.01) < 1.0e-12;
            if (fused_open_stencil) {
                evaluate_coastal_open_stencil_batch_avx2(cascades[0], batch_, indices, active_count, vector_sincos,
                                                          coastal_profile.enabled ? &coastal_profile : nullptr);
            }
            for (size_t ai = 0; ai < stencil_count; ++ai) {
                const size_t p = epsilon > 0.01 ? indices[ai] : batch_.coastal_active_indices[ai];
                batch_.coastal_stencil_indices[ai] = p;
                if (!use_fourier_stencil) {
                    batch_.coastal_fd_dhx[p] = batch_.coastal_fd_dxx[p] = batch_.coastal_fd_dzx[p] = 0.0;
                    batch_.coastal_fd_dhz[p] = batch_.coastal_fd_dxz[p] = batch_.coastal_fd_dzz[p] = 0.0;
                }
                batch_.fd_save_qx[p] = batch_.qx[p]; batch_.fd_save_qz[p] = batch_.qz[p];
                batch_.coastal_center_h[p] = batch_.h[p]; batch_.coastal_center_dx[p] = batch_.dx[p]; batch_.coastal_center_dz[p] = batch_.dz[p];
                batch_.coastal_center_vh[p] = batch_.vh[p]; batch_.coastal_center_vx[p] = batch_.vx[p]; batch_.coastal_center_vz[p] = batch_.vz[p];
                batch_.qx[p] += epsilon;
            }
            const size_t *stencil_indices = batch_.coastal_stencil_indices.data();
            const bool coastal_offset_only = use_fourier_stencil;
                evaluate_avx2_batch_(stencil_indices, stencil_count, vector_sincos, false, epsilon,
                                     true, coastal_offset_only, 1, fused_open_stencil);
            for (size_t ai = 0; ai < stencil_count; ++ai) {
                const size_t p = stencil_indices[ai];
                batch_.coastal_stencil_h[p] = batch_.h[p]; batch_.coastal_stencil_dx[p] = batch_.dx[p]; batch_.coastal_stencil_dz[p] = batch_.dz[p];
                batch_.qx[p] -= 2.0 * epsilon;
            }
                evaluate_avx2_batch_(stencil_indices, stencil_count, vector_sincos, false, epsilon,
                                     true, coastal_offset_only, 2, fused_open_stencil);
            for (size_t ai = 0; ai < stencil_count; ++ai) {
                const size_t p = stencil_indices[ai];
                batch_.coastal_fd_dhx[p] += (batch_.coastal_stencil_h[p] - batch_.h[p]) / (2.0 * epsilon);
                batch_.coastal_fd_dxx[p] += (batch_.coastal_stencil_dx[p] - batch_.dx[p]) / (2.0 * epsilon);
                batch_.coastal_fd_dzx[p] += (batch_.coastal_stencil_dz[p] - batch_.dz[p]) / (2.0 * epsilon);
                batch_.qx[p] = batch_.fd_save_qx[p]; batch_.qz[p] = batch_.fd_save_qz[p] + epsilon;
            }
                evaluate_avx2_batch_(stencil_indices, stencil_count, vector_sincos, false, epsilon,
                                     true, coastal_offset_only, 3, fused_open_stencil);
            for (size_t ai = 0; ai < stencil_count; ++ai) {
                const size_t p = stencil_indices[ai];
                batch_.coastal_stencil_h[p] = batch_.h[p]; batch_.coastal_stencil_dx[p] = batch_.dx[p]; batch_.coastal_stencil_dz[p] = batch_.dz[p];
                batch_.qz[p] -= 2.0 * epsilon;
            }
                evaluate_avx2_batch_(stencil_indices, stencil_count, vector_sincos, false, epsilon,
                                     true, coastal_offset_only, 4, fused_open_stencil);
            for (size_t ai = 0; ai < stencil_count; ++ai) {
                const size_t p = stencil_indices[ai];
                batch_.dhx[p] = batch_.coastal_fd_dhx[p];
                batch_.dxx[p] = batch_.coastal_fd_dxx[p];
                batch_.dzx[p] = batch_.coastal_fd_dzx[p];
                batch_.dhz[p] = batch_.coastal_fd_dhz[p] + (batch_.coastal_stencil_h[p] - batch_.h[p]) / (2.0 * epsilon);
                batch_.dxz[p] = batch_.coastal_fd_dxz[p] + (batch_.coastal_stencil_dx[p] - batch_.dx[p]) / (2.0 * epsilon);
                batch_.dzz[p] = batch_.coastal_fd_dzz[p] + (batch_.coastal_stencil_dz[p] - batch_.dz[p]) / (2.0 * epsilon);
                batch_.qx[p] = batch_.fd_save_qx[p]; batch_.qz[p] = batch_.fd_save_qz[p];
                batch_.h[p] = batch_.coastal_center_h[p]; batch_.dx[p] = batch_.coastal_center_dx[p]; batch_.dz[p] = batch_.coastal_center_dz[p];
                batch_.vh[p] = batch_.coastal_center_vh[p]; batch_.vx[p] = batch_.coastal_center_vx[p]; batch_.vz[p] = batch_.coastal_center_vz[p];
            }
    }
    diag_last_spectral_point_evaluations += active_count;
}

size_t OceanQueryCore::sample_coastal_batch_(const size_t *indices, size_t active_count, int profile_stage) {
    if (!coastal.enabled || cascades.empty()) { return 0; }
    const auto start = coastal_profile.enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    size_t count = 0;
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.coastal_samples[p] = CoastalSample{};
        CoastalSample sample;
        if (!coastal.sample(batch_.qx[p], batch_.qz[p], sample) || sample.confidence <= 0.0) { continue; }
        batch_.coastal_samples[p] = sample;
        batch_.coastal_deep_x[p] = sample.deep_x;
        batch_.coastal_deep_z[p] = sample.deep_z;
        batch_.coastal_active_indices[count++] = p;
    }
    if (coastal_profile.enabled) {
        coastal_profile.sampler_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count());
        if (profile_stage >= 0 && profile_stage < 5) coastal_profile.sampler_stage_ns[static_cast<size_t>(profile_stage)] += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start).count());
    }
    return count;
}

void OceanQueryCore::apply_coastal_batch_(const size_t *indices, size_t active_count, bool displacement_only, int profile_stage) {
    const auto start = coastal_profile.enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        const CoastalSample &s = batch_.coastal_samples[p];
        const double confidence = s.confidence;
        const double shoaling_scale = 1.0 + (s.shoaling - 1.0) * confidence;
        const double open = 1.0 - confidence, deep = confidence;
        batch_.h[p] += (open * batch_.coastal_h[p] + deep * batch_.coastal_deep_h[p]) * shoaling_scale - batch_.coastal_h[p];
        batch_.dx[p] += open * batch_.coastal_dx[p] + deep * batch_.coastal_deep_dx[p] - batch_.coastal_dx[p];
        batch_.dz[p] += open * batch_.coastal_dz[p] + deep * batch_.coastal_deep_dz[p] - batch_.coastal_dz[p];
        if (!displacement_only) {
            batch_.vh[p] += (open * batch_.coastal_vh[p] + deep * batch_.coastal_deep_vh[p]) * shoaling_scale - batch_.coastal_vh[p];
            batch_.vx[p] += open * batch_.coastal_vx[p] + deep * batch_.coastal_deep_vx[p] - batch_.coastal_vx[p];
            batch_.vz[p] += open * batch_.coastal_vz[p] + deep * batch_.coastal_deep_vz[p] - batch_.coastal_vz[p];
            batch_.dhx[p] += open * batch_.coastal_dhx[p] + deep * batch_.coastal_deep_dhx[p] - batch_.coastal_dhx[p];
            batch_.dhz[p] += open * batch_.coastal_dhz[p] + deep * batch_.coastal_deep_dhz[p] - batch_.coastal_dhz[p];
            batch_.dxx[p] += open * batch_.coastal_dxx[p] + deep * batch_.coastal_deep_dxx[p] - batch_.coastal_dxx[p];
            batch_.dxz[p] += open * batch_.coastal_dxz[p] + deep * batch_.coastal_deep_dxz[p] - batch_.coastal_dxz[p];
            batch_.dzx[p] += open * batch_.coastal_dzx[p] + deep * batch_.coastal_deep_dzx[p] - batch_.coastal_dzx[p];
            batch_.dzz[p] += open * batch_.coastal_dzz[p] + deep * batch_.coastal_deep_dzz[p] - batch_.coastal_dzz[p];
        }
    }
    if (coastal_profile.enabled) {
        coastal_profile.combine_us += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count());
        coastal_profile.calls += active_count;
        if (profile_stage >= 0 && profile_stage < 5) coastal_profile.combine_stage_ns[static_cast<size_t>(profile_stage)] += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start).count());
    }
}

void OceanQueryCore::build_sample_from_fields_(size_t p, bool converged, double *out) const {
    const double dx = batch_.dx[p], dz = batch_.dz[p];
    const double dxx = batch_.dxx[p], dxz = batch_.dxz[p];
    const double dzx = batch_.dzx[p], dzz = batch_.dzz[p];
    const double dhx = batch_.dhx[p], dhz = batch_.dhz[p];
    double normal[3];
    normal[0] = dhz * dzx - (1.0 + dzz) * dhx;
    normal[1] = (1.0 + dzz) * (1.0 + dxx) - dxz * dzx;
    normal[2] = dxz * dhx - dhz * (1.0 + dxx);
    const double len2 = normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2];
    if (len2 > 1.0e-14) {
        const double len = std::sqrt(len2);
        normal[0] /= len; normal[1] /= len; normal[2] /= len;
        if (normal[1] < 0.0) { normal[0] = -normal[0]; normal[1] = -normal[1]; normal[2] = -normal[2]; }
    } else {
        normal[0] = 0.0; normal[1] = 1.0; normal[2] = 0.0;
    }
    const double det_j = (1.0 + dxx) * (1.0 + dzz) - dxz * dzx;
    out[S_VALID] = converged ? 1.0 : 0.0;
    out[S_HEIGHT] = sea_level + batch_.h[p];
    out[S_DX] = dx; out[S_DY] = batch_.h[p]; out[S_DZ] = dz;
    out[S_NX] = normal[0]; out[S_NY] = normal[1]; out[S_NZ] = normal[2];
    out[S_VX] = batch_.vx[p]; out[S_VY] = batch_.vh[p]; out[S_VZ] = batch_.vz[p];
    out[S_JACOBIAN_DET] = det_j;
    out[S_FOLDOVER] = det_j <= 0.0 ? 1.0 : 0.0;
    out[S_RESIDUAL] = batch_.residual[p];
    out[S_ITERATIONS] = static_cast<double>(batch_.iterations[p]);
}

void OceanQueryCore::solve_true_batch_(size_t n, double *out, bool append_solved_q) {
    diag_last_spectral_point_evaluations = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    size_t active_count = n;
    for (size_t p = 0; p < n; ++p) {
        batch_.iterations[p] = 0;
        batch_.active_indices[p] = p;
    }
    evaluate_true_batch_(batch_.active_indices.data(), active_count);

    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = batch_.active_indices[ai];
        const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
        const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
        batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
    }

    const int minimum_iterations = 0;
    for (size_t p = 0; p < n; ++p) {
        batch_.done[p] = (batch_.residual[p] <= POSITION_TOLERANCE_M && minimum_iterations == 0) ? 1 : 0;
    }
    size_t next_count = 0;
    for (size_t p = 0; p < n; ++p) if (!batch_.done[p]) batch_.active_indices[next_count++] = p;
    active_count = next_count;

    const int max_iterations = coastal.enabled ? MAX_COASTAL_ITERATIONS : MAX_ITERATIONS;
    for (int iteration = 0; iteration < max_iterations && active_count > 0; ++iteration) {
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double det_j = (1.0 + batch_.dxx[p]) * (1.0 + batch_.dzz[p]) - batch_.dxz[p] * batch_.dzx[p];
            if (std::abs(det_j) <= JACOBIAN_EPSILON) {
                continue;
            }
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            const double inv_det = 1.0 / det_j;
            batch_.qx[p] -= inv_det * ((1.0 + batch_.dzz[p]) * fx - batch_.dxz[p] * fz);
            batch_.qz[p] -= inv_det * (-batch_.dzx[p] * fx + (1.0 + batch_.dxx[p]) * fz);
            batch_.active_indices[next_count++] = p;
        }
        active_count = next_count;
        if (active_count == 0) { break; }
        evaluate_true_batch_(batch_.active_indices.data(), active_count);
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
            batch_.iterations[p] = iteration + 1;
            if (batch_.residual[p] <= POSITION_TOLERANCE_M && batch_.iterations[p] >= minimum_iterations) {
                batch_.done[p] = 1;
            } else {
                batch_.active_indices[next_count++] = p;
            }
        }
        active_count = next_count;
    }

    for (size_t p = 0; p < n; ++p) {
        const bool is_converged = batch_.done[p] != 0;
        if (is_converged) {
            const int bucket = std::min(batch_.iterations[p], NEWTON_HISTOGRAM_SIZE - 2);
            ++diag_last_newton_histogram[bucket];
        } else {
            ++diag_last_newton_histogram[NEWTON_HISTOGRAM_SIZE - 1];
            ++diag_non_converged;
        }
        double *sample = out + p * (append_solved_q ? TRUE_BATCH_WARM_STRIDE : S_STRIDE);
        build_sample_from_fields_(p, is_converged, sample);
        if (append_solved_q) {
            sample[S_STRIDE] = batch_.qx[p];
            sample[S_STRIDE + 1] = batch_.qz[p];
        }
    }
}

void OceanQueryCore::solve_avx2_batch_(size_t n, double *out, bool vector_sincos, bool append_solved_q) {
    diag_last_spectral_point_evaluations = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    size_t active_count = n;
    for (size_t p = 0; p < n; ++p) {
        batch_.iterations[p] = 0;
        batch_.active_indices[p] = p;
    }
    evaluate_avx2_batch_(batch_.active_indices.data(), active_count, vector_sincos, true, 0.05);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = batch_.active_indices[ai];
        const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
        const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
        batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
        batch_.done[p] = batch_.residual[p] <= POSITION_TOLERANCE_M ? 1 : 0;
    }
    size_t next_count = 0;
    for (size_t p = 0; p < n; ++p) if (!batch_.done[p]) batch_.active_indices[next_count++] = p;
    active_count = next_count;
    const int max_iterations = coastal.enabled ? MAX_COASTAL_ITERATIONS : MAX_ITERATIONS;
    for (int iteration = 0; iteration < max_iterations && active_count > 0; ++iteration) {
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double det_j = (1.0 + batch_.dxx[p]) * (1.0 + batch_.dzz[p]) - batch_.dxz[p] * batch_.dzx[p];
            if (std::abs(det_j) <= JACOBIAN_EPSILON) { continue; }
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            const double inv_det = 1.0 / det_j;
            batch_.qx[p] -= inv_det * ((1.0 + batch_.dzz[p]) * fx - batch_.dxz[p] * fz);
            batch_.qz[p] -= inv_det * (-batch_.dzx[p] * fx + (1.0 + batch_.dxx[p]) * fz);
            batch_.active_indices[next_count++] = p;
        }
        active_count = next_count;
        if (active_count == 0) { break; }
        // Para conjuntos activos pequeños el evaluador cae a scalar; evita
        // pagar gathers y setup AVX2 cuando quedan menos de cuatro puntos.
        evaluate_avx2_batch_(batch_.active_indices.data(), active_count, vector_sincos, true, 0.05);
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
            batch_.iterations[p] = iteration + 1;
            if (batch_.residual[p] <= POSITION_TOLERANCE_M) { batch_.done[p] = 1; }
            else { batch_.active_indices[next_count++] = p; }
        }
        active_count = next_count;
    }
    for (size_t p = 0; p < n; ++p) { batch_.active_indices[p] = p; }
    evaluate_avx2_batch_(batch_.active_indices.data(), n, vector_sincos, true, 0.01);
    for (size_t p = 0; p < n; ++p) {
        const bool converged = batch_.done[p] != 0;
        if (converged) {
            const int bucket = std::min(batch_.iterations[p], NEWTON_HISTOGRAM_SIZE - 2);
            ++diag_last_newton_histogram[bucket];
        } else { ++diag_last_newton_histogram[NEWTON_HISTOGRAM_SIZE - 1]; ++diag_non_converged; }
        double *sample = out + p * (append_solved_q ? TRUE_BATCH_WARM_STRIDE : S_STRIDE);
        build_sample_from_fields_(p, converged, sample);
        if (append_solved_q) {
            sample[S_STRIDE] = batch_.qx[p];
            sample[S_STRIDE + 1] = batch_.qz[p];
        }
    }
}

// --- 5R.1E: batch sharpened (crest sharpening ON) ----------------------------
// Replica EXACTAMENTE la matemática del hotfix scalar (sample_prepared_ y
// finite_jacobian_) pero procesando lanes en AVX2. La base FFT + coastal se
// reutiliza de evaluate_avx2_batch_; el crest sharpening se vectoriza con
// evaluate_band_height_avx2 (LONG/MID × center/left/right). El Jacobian finito
// evalúa el displacement FINAL en 4 offsets (±0.05 m) por diferencias centrales.

void OceanQueryCore::apply_crest_sharpen_batch_(const size_t *indices, size_t active_count, bool vector_sincos) {
    if (!crest_sharpen_enabled || cascades.size() < 2 || active_count == 0) { return; }
    const double local_hs = std::max(crest_sharpen_local_hs, 0.05);
    const double eps = crest_sharpen_eps;
    const double dirx = crest_sharpen_dir_x, dirz = crest_sharpen_dir_z;
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        const double qx = batch_.qx[p], qz = batch_.qz[p];
        batch_.sharpen_lqx[p] = qx - dirx * eps;
        batch_.sharpen_lqz[p] = qz - dirz * eps;
        batch_.sharpen_rqx[p] = qx + dirx * eps;
        batch_.sharpen_rqz[p] = qz + dirz * eps;
    }
    evaluate_band_height_avx2(cascades[0], batch_.qx.data(), batch_.qz.data(), indices, active_count, batch_.band_l_c.data(), vector_sincos);
    evaluate_band_height_avx2(cascades[0], batch_.sharpen_lqx.data(), batch_.sharpen_lqz.data(), indices, active_count, batch_.band_l_l.data(), vector_sincos);
    evaluate_band_height_avx2(cascades[0], batch_.sharpen_rqx.data(), batch_.sharpen_rqz.data(), indices, active_count, batch_.band_l_r.data(), vector_sincos);
    if ((active_query_band_mask & QUERY_BAND_MID) != 0) {
        evaluate_band_height_avx2(cascades[1], batch_.qx.data(), batch_.qz.data(), indices, active_count, batch_.band_m_c.data(), vector_sincos);
        evaluate_band_height_avx2(cascades[1], batch_.sharpen_lqx.data(), batch_.sharpen_lqz.data(), indices, active_count, batch_.band_m_l.data(), vector_sincos);
        evaluate_band_height_avx2(cascades[1], batch_.sharpen_rqx.data(), batch_.sharpen_rqz.data(), indices, active_count, batch_.band_m_r.data(), vector_sincos);
    } else {
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            batch_.band_m_c[p] = batch_.band_m_l[p] = batch_.band_m_r[p] = 0.0;
        }
    }
    const double strength = crest_sharpen_strength;
    const double threshold = crest_sharpen_threshold;
    const double max_gain = crest_sharpen_max_gain;
    const double long_w = crest_sharpen_long_weight, mid_w = crest_sharpen_mid_weight;
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        const double curv_long = batch_.band_l_l[p] - 2.0 * batch_.band_l_c[p] + batch_.band_l_r[p];
        const double curv_mid = batch_.band_m_l[p] - 2.0 * batch_.band_m_c[p] + batch_.band_m_r[p];
        const double crest_long = std::clamp(-curv_long / local_hs, 0.0, 2.0) * long_w;
        const double crest_mid = std::clamp(-curv_mid / std::max(local_hs * 0.4, 0.02), 0.0, 2.0) * mid_w;
        const double crestness = crest_long + crest_mid;
        const double face_slope = std::abs(batch_.band_l_r[p] - batch_.band_l_l[p]) / (2.0 * eps);
        const double compression = smoothstep01(0.03, 0.22, face_slope);
        const double sharpen = smoothstep01(threshold, threshold + 0.25, crestness)
            * compression * strength;
        const double delta_y = sharpen * max_gain * local_hs;
        const double h_scale = 1.0 + sharpen * max_gain * 0.35;
        batch_.h[p] += delta_y;
        batch_.dx[p] *= h_scale;
        batch_.dz[p] *= h_scale;
    }
}

void OceanQueryCore::evaluate_center_sharpened_(const size_t *indices, size_t active_count, bool vector_sincos) {
    evaluate_avx2_batch_(indices, active_count, vector_sincos);
    apply_crest_sharpen_batch_(indices, active_count, vector_sincos);
    // Guarda el dx/dz FINAL del centro: el Jacobian finito sobrescribe batch_.dx/dz
    // y el paso de Newton necesita el residual del centro.
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.sharpen_cdx[p] = batch_.dx[p];
        batch_.sharpen_cdz[p] = batch_.dz[p];
    }
}

void OceanQueryCore::evaluate_offset_final_(const size_t *indices, size_t active_count, double ox, double oz, bool vector_sincos) {
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.fd_save_qx[p] = batch_.qx[p];
        batch_.fd_save_qz[p] = batch_.qz[p];
        batch_.qx[p] += ox;
        batch_.qz[p] += oz;
    }
    evaluate_avx2_batch_(indices, active_count, vector_sincos);
    apply_crest_sharpen_batch_(indices, active_count, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.fd_dx[p] = batch_.dx[p];
        batch_.fd_dz[p] = batch_.dz[p];
        batch_.qx[p] = batch_.fd_save_qx[p];
        batch_.qz[p] = batch_.fd_save_qz[p];
    }
}

void OceanQueryCore::compute_finite_jacobian_batch_(const size_t *indices, size_t active_count, bool vector_sincos) {
    const double d = 0.05;
    const double inv_2d = 1.0 / (2.0 * d);
    evaluate_offset_final_(indices, active_count, d, 0.0, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.jac_a[p] = 1.0 + batch_.fd_dx[p] * inv_2d;
        batch_.jac_c[p] = batch_.fd_dz[p] * inv_2d;
    }
    evaluate_offset_final_(indices, active_count, -d, 0.0, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.jac_a[p] -= batch_.fd_dx[p] * inv_2d;
        batch_.jac_c[p] -= batch_.fd_dz[p] * inv_2d;
    }
    evaluate_offset_final_(indices, active_count, 0.0, d, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.jac_b[p] = batch_.fd_dx[p] * inv_2d;
        batch_.jac_d[p] = 1.0 + batch_.fd_dz[p] * inv_2d;
    }
    evaluate_offset_final_(indices, active_count, 0.0, -d, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        batch_.jac_b[p] -= batch_.fd_dx[p] * inv_2d;
        batch_.jac_d[p] -= batch_.fd_dz[p] * inv_2d;
    }
}

void OceanQueryCore::solve_avx2_batch_sharpened_(size_t n, double *out, bool vector_sincos) {
    diag_last_spectral_point_evaluations = 0;
    for (int &count : diag_last_newton_histogram) { count = 0; }
    size_t active_count = n;
    for (size_t p = 0; p < n; ++p) {
        batch_.iterations[p] = 0;
        batch_.active_indices[p] = p;
    }
    evaluate_center_sharpened_(batch_.active_indices.data(), active_count, vector_sincos);
    for (size_t ai = 0; ai < active_count; ++ai) {
        const size_t p = batch_.active_indices[ai];
        const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
        const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
        batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
        batch_.done[p] = batch_.residual[p] <= POSITION_TOLERANCE_M ? 1 : 0;
    }
    size_t next_count = 0;
    for (size_t p = 0; p < n; ++p) if (!batch_.done[p]) batch_.active_indices[next_count++] = p;
    active_count = next_count;

    const int max_iterations = coastal.enabled ? MAX_COASTAL_ITERATIONS : MAX_ITERATIONS;
    for (int iteration = 0; iteration < max_iterations && active_count > 0; ++iteration) {
        compute_finite_jacobian_batch_(batch_.active_indices.data(), active_count, vector_sincos);
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double det = batch_.jac_a[p] * batch_.jac_d[p] - batch_.jac_b[p] * batch_.jac_c[p];
            if (std::abs(det) <= JACOBIAN_EPSILON) { continue; }
            const double fx = batch_.qx[p] + batch_.sharpen_cdx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.sharpen_cdz[p] - batch_.wz[p];
            const double inv = 1.0 / det;
            batch_.qx[p] -= inv * (batch_.jac_d[p] * fx - batch_.jac_b[p] * fz);
            batch_.qz[p] -= inv * (-batch_.jac_c[p] * fx + batch_.jac_a[p] * fz);
            batch_.active_indices[next_count++] = p;
        }
        active_count = next_count;
        if (active_count == 0) { break; }
        evaluate_center_sharpened_(batch_.active_indices.data(), active_count, vector_sincos);
        next_count = 0;
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = batch_.active_indices[ai];
            const double fx = batch_.qx[p] + batch_.dx[p] - batch_.wx[p];
            const double fz = batch_.qz[p] + batch_.dz[p] - batch_.wz[p];
            batch_.residual[p] = std::sqrt(fx * fx + fz * fz);
            batch_.iterations[p] = iteration + 1;
            if (batch_.residual[p] <= POSITION_TOLERANCE_M) { batch_.done[p] = 1; }
            else { batch_.active_indices[next_count++] = p; }
        }
        active_count = next_count;
    }

    for (size_t p = 0; p < n; ++p) {
        const bool converged = batch_.done[p] != 0;
        if (converged) {
            const int bucket = std::min(batch_.iterations[p], NEWTON_HISTOGRAM_SIZE - 2);
            ++diag_last_newton_histogram[bucket];
        } else { ++diag_last_newton_histogram[NEWTON_HISTOGRAM_SIZE - 1]; ++diag_non_converged; }
        build_sample_from_fields_(p, converged, out + p * S_STRIDE);
    }
}

void OceanQueryCore::sample_batch_true_prepared(const double *positions_xz, size_t n, double *out) {
    diag_last_material_batch_avx2 = false;
    diag_last_world_batch_avx2 = false;
    diag_last_coastal_deep_avx2 = false;
    diag_non_converged = 0;
    if (n == 0) { return; }
    batch_.ensure_capacity(n);
    for (size_t p = 0; p < n; ++p) {
        batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
        batch_.qx[p] = batch_.wx[p]; batch_.qz[p] = batch_.wz[p];
    }
    solve_true_batch_(n, out, false);
}

void OceanQueryCore::sample_batch_warm_prepared(const double *positions_xz, const double *initial_q_xz,
                                                size_t n, double *out) {
    diag_last_material_batch_avx2 = false;
    diag_last_world_batch_avx2 = false;
    diag_last_coastal_deep_avx2 = false;
    diag_non_converged = 0;
    if (n == 0) { return; }
    batch_.ensure_capacity(n);
    for (size_t p = 0; p < n; ++p) {
        batch_.wx[p] = positions_xz[2 * p]; batch_.wz[p] = positions_xz[2 * p + 1];
        const double qx = initial_q_xz[2 * p], qz = initial_q_xz[2 * p + 1];
        const bool valid_guess = std::isfinite(qx) && std::isfinite(qz);
        batch_.qx[p] = valid_guess ? qx : batch_.wx[p];
        batch_.qz[p] = valid_guess ? qz : batch_.wz[p];
    }
    if (avx2_supported() && !force_scalar && n >= 4) {
        solve_avx2_batch_(n, out, true, true);
        diag_last_world_batch_avx2 = true;
        return;
    }
    solve_true_batch_(n, out, true);
}

} // namespace oq
