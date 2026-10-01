// Translation unit AVX2 exclusivamente. SConstruct la compila con /arch:AVX2;
// no la llama el core hasta que CPUID + OSXSAVE + XGETBV confirman soporte.

#include "ocean_query_core.h"
#include "ocean_query_simd_avx2.h"

#include <immintrin.h>

#include <algorithm>
#include <chrono>
#include <cmath>

namespace oq {
namespace {

inline __m256d set4(const double *v) { return _mm256_loadu_pd(v); }

inline void store_points(std::vector<double> &dst, size_t p0, size_t p1, size_t p2, size_t p3, __m256d value) {
    alignas(32) double lanes[4];
    _mm256_store_pd(lanes, value);
    dst[p0] = lanes[0]; dst[p1] = lanes[1]; dst[p2] = lanes[2]; dst[p3] = lanes[3];
}

inline void store_points_raw(double *dst, size_t p0, size_t p1, size_t p2, size_t p3, __m256d value) {
    alignas(32) double lanes[4];
    _mm256_store_pd(lanes, value);
    dst[p0] = lanes[0]; dst[p1] = lanes[1]; dst[p2] = lanes[2]; dst[p3] = lanes[3];
}

inline __m256d sin_poly(__m256d x) {
    const __m256d z = _mm256_mul_pd(x, x);
    __m256d p = _mm256_set1_pd(1.6059043836821613e-10);       // +1/6227020800
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(-2.505210838544172e-8));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(2.7557319223985893e-6));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(-1.9841269841269841e-4));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(8.3333333333333332e-3));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(-1.6666666666666666e-1));
    return _mm256_fmadd_pd(_mm256_mul_pd(x, z), p, x);
}

inline __m256d cos_poly(__m256d x) {
    const __m256d z = _mm256_mul_pd(x, x);
    __m256d p = _mm256_set1_pd(-1.1470745597729725e-11);      // -1/87178291200
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(2.08767569878681e-9));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(-2.755731922398589e-7));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(2.48015873015873e-5));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(-1.388888888888889e-3));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(4.1666666666666664e-2));
    p = _mm256_fmadd_pd(z, p, _mm256_set1_pd(-0.5));
    return _mm256_fmadd_pd(z, p, _mm256_set1_pd(1.0));
}

inline void sincos_vector(__m256d phi, __m256d &s, __m256d &c) {
    // Payne-Hanek no es necesario para el rango real del laboratorio
    // (|phi| << 1e6); split pi/2 mantiene el error de reducción bajo ese
    // límite. Fuera de él se usa la ruta scalar por lane en el llamador.
    const __m256d q = _mm256_round_pd(_mm256_mul_pd(phi, _mm256_set1_pd(0.63661977236758134308)),
                                      _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
    __m256d r = _mm256_sub_pd(phi, _mm256_mul_pd(q, _mm256_set1_pd(1.57079632679489655800)));
    r = _mm256_sub_pd(r, _mm256_mul_pd(q, _mm256_set1_pd(6.12323399573676603587e-17)));
    const __m256d sr = sin_poly(r);
    const __m256d cr = cos_poly(r);
    const __m256d q4 = _mm256_sub_pd(q, _mm256_mul_pd(_mm256_floor_pd(_mm256_mul_pd(q, _mm256_set1_pd(0.25))), _mm256_set1_pd(4.0)));
    const __m256d m1 = _mm256_cmp_pd(q4, _mm256_set1_pd(1.0), _CMP_EQ_OQ);
    const __m256d m2 = _mm256_cmp_pd(q4, _mm256_set1_pd(2.0), _CMP_EQ_OQ);
    const __m256d m3 = _mm256_cmp_pd(q4, _mm256_set1_pd(3.0), _CMP_EQ_OQ);
    s = _mm256_blendv_pd(sr, cr, m1);
    s = _mm256_blendv_pd(s, _mm256_sub_pd(_mm256_setzero_pd(), sr), m2);
    s = _mm256_blendv_pd(s, _mm256_sub_pd(_mm256_setzero_pd(), cr), m3);
    c = _mm256_blendv_pd(cr, _mm256_sub_pd(_mm256_setzero_pd(), sr), m1);
    c = _mm256_blendv_pd(c, _mm256_sub_pd(_mm256_setzero_pd(), cr), m2);
    c = _mm256_blendv_pd(c, sr, m3);
}

inline void sincos_lanes(__m256d phi, __m256d &s, __m256d &c) {
    alignas(32) double in[4], so[4], co[4];
    _mm256_store_pd(in, phi);
    for (int lane = 0; lane < 4; ++lane) { so[lane] = std::sin(in[lane]); co[lane] = std::cos(in[lane]); }
    s = set4(so); c = set4(co);
}

inline void sincos_safe(__m256d phi, __m256d &s, __m256d &c) {
    // La reducción vectorial está medida para el rango del océano; para
    // coordenadas extremas se mantiene corrección total por lane en vez de
    // degradar silenciosamente la fase con una reducción imprecisa.
    const __m256d sign = _mm256_set1_pd(-0.0);
    const __m256d abs_phi = _mm256_andnot_pd(sign, phi);
    const int large_lane = _mm256_movemask_pd(_mm256_cmp_pd(abs_phi, _mm256_set1_pd(1048576.0), _CMP_GT_OQ));
    if (large_lane != 0) { sincos_lanes(phi, s, c); }
    else { sincos_vector(phi, s, c); }
}

struct alignas(32) PhaseFactor4 { double s[4]; double c[4]; };

// Exact recurrence for a separable frequency lattice, including the small
// float32 rounding variation in adjacent k values. Step factors are derived
// from the actual stored kx/ky values, not from an idealized uniform delta-k.
struct PhaseRecurrence4 {
    bool active = false;
    int n = 0, x = 0, y = 0;
    const Cascade *source = nullptr;
    __m256d qx = _mm256_setzero_pd(), qz = _mm256_setzero_pd();
    __m256d s = _mm256_setzero_pd(), c = _mm256_setzero_pd();
    std::vector<PhaseFactor4> x_steps;

    bool initialize(const Cascade &cascade, __m256d qx, __m256d qz) {
        n = cascade.material_resolution;
        if (!cascade.separable_frequency_grid || n < 2 ||
            cascade.kx.size() != static_cast<size_t>(n) * static_cast<size_t>(n)) return false;
        this->source = &cascade; this->qx = qx; this->qz = qz;
        x_steps.resize(static_cast<size_t>(n - 1));
        const __m256d first_phi = _mm256_add_pd(_mm256_mul_pd(_mm256_set1_pd(cascade.kx[0]), qx),
                                                 _mm256_mul_pd(_mm256_set1_pd(cascade.ky[0]), qz));
        sincos_safe(first_phi, s, c);
        for (int edge = 0; edge < n - 1; ++edge) {
            const double delta_kx = cascade.kx[static_cast<size_t>(edge + 1)] - cascade.kx[static_cast<size_t>(edge)];
            const __m256d delta_phi = _mm256_mul_pd(_mm256_set1_pd(delta_kx), qx);
            __m256d step_s, step_c;
            sincos_safe(delta_phi, step_s, step_c);
            _mm256_store_pd(x_steps[static_cast<size_t>(edge)].s, step_s);
            _mm256_store_pd(x_steps[static_cast<size_t>(edge)].c, step_c);

        }
        active = true;
        return true;
    }

    void advance() {
        if (x + 1 < n) {
            const PhaseFactor4 &factor = x_steps[static_cast<size_t>(x)];
            const __m256d step_s = _mm256_load_pd(factor.s), step_c = _mm256_load_pd(factor.c);
            const __m256d next_s = _mm256_add_pd(_mm256_mul_pd(s, step_c), _mm256_mul_pd(c, step_s));
            c = _mm256_sub_pd(_mm256_mul_pd(c, step_c), _mm256_mul_pd(s, step_s));
            s = next_s;
            ++x;
        } else {
            x = 0; ++y;
            const __m256d row_phi = _mm256_add_pd(_mm256_mul_pd(_mm256_set1_pd(source->kx[0]), qx),
                                                   _mm256_mul_pd(_mm256_set1_pd(source->ky[static_cast<size_t>(y) * static_cast<size_t>(n)]), qz));
            sincos_safe(row_phi, s, c);
        }
    }
};

inline void scalar_tail(const Cascade &c, BatchWorkspace &batch, size_t p, bool displacement_only) {
    double fft_qx = 0.0, fft_qz = 0.0;
    c.material_q_to_fft_q(batch.qx[p], batch.qz[p], fft_qx, fft_qz);
    double h = 0.0, dx = 0.0, dz = 0.0, dhx = 0.0, dhz = 0.0;
    double dxx = 0.0, dxz = 0.0, dzx = 0.0, dzz = 0.0, vh = 0.0, vx = 0.0, vz = 0.0;
    for (size_t idx = 0; idx < c.kx.size(); ++idx) {
        const double phi = c.kx[idx] * fft_qx + c.ky[idx] * fft_qz;
        const double cp = std::cos(phi), sp = std::sin(phi);
        const double pre = c.ev_h_re[idx] * cp - c.ev_h_im[idx] * sp;
        const double pim = c.ev_h_re[idx] * sp + c.ev_h_im[idx] * cp;
        const double sig = c.parity[idx] * c.weight[idx];
        h += sig * pre; dx += sig * c.a1[idx] * pim; dz += sig * c.a2[idx] * pim;
        if (!displacement_only) {
            const double qre = c.ev_v_re[idx] * cp - c.ev_v_im[idx] * sp;
            const double qim = c.ev_v_re[idx] * sp + c.ev_v_im[idx] * cp;
            dhx += sig * -c.kx[idx] * pim; dhz += sig * -c.ky[idx] * pim;
            dxx += sig * c.c11[idx] * pre; dxz += sig * c.c12[idx] * pre;
            dzx += sig * c.c21[idx] * pre; dzz += sig * c.c22[idx] * pre;
            vh += sig * qre; vx += sig * c.a1[idx] * qim; vz += sig * c.a2[idx] * qim;
        }
    }
    batch.cascade_h[p] = h; batch.cascade_dx[p] = dx; batch.cascade_dz[p] = dz;
    if (!displacement_only) {
        batch.cascade_dhx[p] = dhx; batch.cascade_dhz[p] = dhz;
        batch.cascade_dxx[p] = dxx; batch.cascade_dxz[p] = dxz; batch.cascade_dzx[p] = dzx; batch.cascade_dzz[p] = dzz;
        batch.cascade_vh[p] = vh; batch.cascade_vx[p] = vx; batch.cascade_vz[p] = vz;
    }
}

} // namespace

void sincos_pd_avx2(const double *phi4, double *sin4, double *cos4) {
    const __m256d phi = set4(phi4);
    __m256d s, c;
    sincos_safe(phi, s, c);
    _mm256_storeu_pd(sin4, s);
    _mm256_storeu_pd(cos4, c);
}

void evaluate_batch_avx2(const std::vector<Cascade> &cascades, BatchWorkspace &batch,
                         const size_t *indices, size_t active_count, bool vector_sincos,
                         bool fuse_coastal_q, bool displacement_only,
                         bool coastal_only, double fd_epsilon,
                         CoastalProfile *profile, int profile_stage) {
    const __m256d zero = _mm256_setzero_pd();
    if (fd_epsilon > 0.0 && !displacement_only) {
        for (size_t ai = 0; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            batch.coastal_fd_dhx[p] = batch.coastal_fd_dxx[p] = batch.coastal_fd_dzx[p] = 0.0;
            batch.coastal_fd_dhz[p] = batch.coastal_fd_dxz[p] = batch.coastal_fd_dzz[p] = 0.0;
        }
    }
    const size_t cascade_count = coastal_only ? std::min<size_t>(1, cascades.size()) : cascades.size();
    for (size_t cascade_index = 0; cascade_index < cascade_count; ++cascade_index) {
        const Cascade &cascade = cascades[cascade_index];
        const bool profile_pass = profile != nullptr && profile_stage >= 0 && profile_stage < 5 && cascade_index < 3;
        const bool accumulate_coastal = fuse_coastal_q && cascade_index == 0;
        const std::vector<double> *fd_kx = nullptr, *fd_ky = nullptr;
        if (fd_epsilon > 0.0 && !displacement_only) {
            fd_kx = fd_epsilon < 0.02 ? &cascade.fd01_kx : &cascade.fd05_kx;
            fd_ky = fd_epsilon < 0.02 ? &cascade.fd01_ky : &cascade.fd05_ky;
        }
        size_t ai = 0;
        for (; ai + 4 <= active_count; ai += 4) {
            const size_t p0 = indices[ai], p1 = indices[ai + 1], p2 = indices[ai + 2], p3 = indices[ai + 3];
            const __m256i gather = _mm256_set_epi64x(static_cast<long long>(p3), static_cast<long long>(p2),
                                                       static_cast<long long>(p1), static_cast<long long>(p0));
            const __m256d qx = _mm256_i64gather_pd(batch.qx.data(), gather, 8);
            const __m256d qz = _mm256_i64gather_pd(batch.qz.data(), gather, 8);
            alignas(32) double material_qx[4], material_qz[4], fft_qx[4], fft_qz[4];
            _mm256_store_pd(material_qx, qx);
            _mm256_store_pd(material_qz, qz);
            for (int lane = 0; lane < 4; ++lane) {
                cascade.material_q_to_fft_q(material_qx[lane], material_qz[lane], fft_qx[lane], fft_qz[lane]);
            }
            const __m256d band_qx = _mm256_load_pd(fft_qx);
            const __m256d band_qz = _mm256_load_pd(fft_qz);
            __m256d h = zero, dx = zero, dz = zero, dhx = zero, dhz = zero;
            __m256d dxx = zero, dxz = zero, dzx = zero, dzz = zero, vh = zero, vx = zero, vz = zero;
            __m256d fd_hx = zero, fd_xx = zero, fd_zx = zero, fd_hz = zero, fd_xz = zero, fd_zz = zero;
            PhaseRecurrence4 phase;
            const bool use_phase_recurrence = vector_sincos && phase.initialize(cascade, band_qx, band_qz);
            if (profile_pass) {
                profile->mode_evaluations[static_cast<size_t>(profile_stage)][cascade_index] += cascade.kx.size() * 4;
                if (use_phase_recurrence) profile->vector_sincos_calls[static_cast<size_t>(profile_stage)] += 1 + 2 * static_cast<uint64_t>(phase.n - 1);
                else profile->direct_sincos_calls[static_cast<size_t>(profile_stage)] += cascade.kx.size();
            }
            const auto mode_start = profile_pass ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
            for (size_t idx = 0; idx < cascade.kx.size(); ++idx) {
                __m256d sp, cp;
                if (use_phase_recurrence) {
                    sp = phase.s;
                    cp = phase.c;
                } else {
                    const __m256d phi = _mm256_add_pd(_mm256_mul_pd(_mm256_set1_pd(cascade.kx[idx]), band_qx),
                                                       _mm256_mul_pd(_mm256_set1_pd(cascade.ky[idx]), band_qz));
                    if (vector_sincos) { sincos_safe(phi, sp, cp); } else { sincos_lanes(phi, sp, cp); }
                }
                const __m256d h_re = _mm256_set1_pd(cascade.ev_h_re[idx]);
                const __m256d h_im = _mm256_set1_pd(cascade.ev_h_im[idx]);
                const __m256d pre = _mm256_fnmadd_pd(h_im, sp, _mm256_mul_pd(h_re, cp));
                const __m256d pim = _mm256_fmadd_pd(h_re, sp, _mm256_mul_pd(h_im, cp));
                const double sig_value = cascade.parity[idx] * cascade.weight[idx];
                const __m256d sig = _mm256_set1_pd(sig_value);
                h = _mm256_fmadd_pd(sig, pre, h);
                dx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a1[idx]), pim, dx);
                dz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a2[idx]), pim, dz);
                if (fd_epsilon > 0.0 && !displacement_only) {
                    const double sx_value = (*fd_kx)[idx], sz_value = (*fd_ky)[idx];
                    fd_hx = _mm256_fnmadd_pd(_mm256_set1_pd(sig_value * sx_value), pim, fd_hx);
                    fd_xx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a1[idx] * sx_value), pre, fd_xx);
                    fd_zx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a2[idx] * sx_value), pre, fd_zx);
                    fd_hz = _mm256_fnmadd_pd(_mm256_set1_pd(sig_value * sz_value), pim, fd_hz);
                    fd_xz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a1[idx] * sz_value), pre, fd_xz);
                    fd_zz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a2[idx] * sz_value), pre, fd_zz);
                }
                if (!displacement_only) {
                    const __m256d v_re = _mm256_set1_pd(cascade.ev_v_re[idx]);
                    const __m256d v_im = _mm256_set1_pd(cascade.ev_v_im[idx]);
                    const __m256d qre = _mm256_fnmadd_pd(v_im, sp, _mm256_mul_pd(v_re, cp));
                    const __m256d qim = _mm256_fmadd_pd(v_re, sp, _mm256_mul_pd(v_im, cp));
                    dhx = _mm256_fmadd_pd(_mm256_set1_pd(-sig_value * cascade.kx[idx]), pim, dhx);
                    dhz = _mm256_fmadd_pd(_mm256_set1_pd(-sig_value * cascade.ky[idx]), pim, dhz);
                    dxx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.c11[idx]), pre, dxx);
                    dxz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.c12[idx]), pre, dxz);
                    dzx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.c21[idx]), pre, dzx);
                    dzz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.c22[idx]), pre, dzz);
                    vh = _mm256_fmadd_pd(sig, qre, vh);
                    vx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a1[idx]), qim, vx);
                    vz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a2[idx]), qim, vz);
                }
                if (use_phase_recurrence && idx + 1 < cascade.kx.size()) phase.advance();
            }
            if (profile_pass) {
                profile->band_mode_ns[static_cast<size_t>(profile_stage)][cascade_index] += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - mode_start).count());
            }
            const auto reduce_start = profile_pass ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
            store_points(batch.cascade_h, p0,p1,p2,p3,h); store_points(batch.cascade_dx,p0,p1,p2,p3,dx); store_points(batch.cascade_dz,p0,p1,p2,p3,dz);
            if (!displacement_only) {
                store_points(batch.cascade_dhx,p0,p1,p2,p3,dhx); store_points(batch.cascade_dhz,p0,p1,p2,p3,dhz);
                store_points(batch.cascade_dxx,p0,p1,p2,p3,dxx); store_points(batch.cascade_dxz,p0,p1,p2,p3,dxz);
                store_points(batch.cascade_dzx,p0,p1,p2,p3,dzx); store_points(batch.cascade_dzz,p0,p1,p2,p3,dzz);
                store_points(batch.cascade_vh,p0,p1,p2,p3,vh); store_points(batch.cascade_vx,p0,p1,p2,p3,vx); store_points(batch.cascade_vz,p0,p1,p2,p3,vz);
            }
            if (accumulate_coastal) {
                const __m256d inv = _mm256_set1_pd(cascade.inv_n2);
                store_points(batch.coastal_h,p0,p1,p2,p3,_mm256_mul_pd(h, inv)); store_points(batch.coastal_dx,p0,p1,p2,p3,_mm256_mul_pd(dx, inv)); store_points(batch.coastal_dz,p0,p1,p2,p3,_mm256_mul_pd(dz, inv));
                if (!displacement_only) {
                    store_points(batch.coastal_dhx,p0,p1,p2,p3,_mm256_mul_pd(dhx, inv)); store_points(batch.coastal_dhz,p0,p1,p2,p3,_mm256_mul_pd(dhz, inv));
                    store_points(batch.coastal_dxx,p0,p1,p2,p3,_mm256_mul_pd(dxx, inv)); store_points(batch.coastal_dxz,p0,p1,p2,p3,_mm256_mul_pd(dxz, inv));
                    store_points(batch.coastal_dzx,p0,p1,p2,p3,_mm256_mul_pd(dzx, inv)); store_points(batch.coastal_dzz,p0,p1,p2,p3,_mm256_mul_pd(dzz, inv));
                    store_points(batch.coastal_vh,p0,p1,p2,p3,_mm256_mul_pd(vh, inv)); store_points(batch.coastal_vx,p0,p1,p2,p3,_mm256_mul_pd(vx, inv)); store_points(batch.coastal_vz,p0,p1,p2,p3,_mm256_mul_pd(vz, inv));
                }
            }
            if (fd_epsilon > 0.0 && !displacement_only) {
                alignas(32) double lanes_hx[4], lanes_xx[4], lanes_zx[4], lanes_hz[4], lanes_xz[4], lanes_zz[4];
                const __m256d inv = _mm256_set1_pd(cascade.inv_n2);
                _mm256_store_pd(lanes_hx, _mm256_mul_pd(fd_hx, inv)); _mm256_store_pd(lanes_xx, _mm256_mul_pd(fd_xx, inv)); _mm256_store_pd(lanes_zx, _mm256_mul_pd(fd_zx, inv));
                _mm256_store_pd(lanes_hz, _mm256_mul_pd(fd_hz, inv)); _mm256_store_pd(lanes_xz, _mm256_mul_pd(fd_xz, inv)); _mm256_store_pd(lanes_zz, _mm256_mul_pd(fd_zz, inv));
                const size_t points[4] = {p0, p1, p2, p3};
                for (int lane = 0; lane < 4; ++lane) {
                    const size_t p = points[lane];
                    batch.coastal_fd_dhx[p] += lanes_hx[lane]; batch.coastal_fd_dxx[p] += lanes_xx[lane]; batch.coastal_fd_dzx[p] += lanes_zx[lane];
                    batch.coastal_fd_dhz[p] += lanes_hz[lane]; batch.coastal_fd_dxz[p] += lanes_xz[lane]; batch.coastal_fd_dzz[p] += lanes_zz[lane];
                }
            }
            if (profile_pass) {
                profile->band_reduce_ns[static_cast<size_t>(profile_stage)][cascade_index] += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - reduce_start).count());
            }
        }
        for (; ai < active_count; ++ai) {
            const size_t p = indices[ai];
            scalar_tail(cascade, batch, p, displacement_only);
            if (accumulate_coastal) {
                double fft_qx = 0.0, fft_qz = 0.0;
                cascade.material_q_to_fft_q(batch.qx[p], batch.qz[p], fft_qx, fft_qz);
                const double h = batch.cascade_h[p], dx = batch.cascade_dx[p], dz = batch.cascade_dz[p];
                batch.coastal_h[p] = h * cascade.inv_n2; batch.coastal_dx[p] = dx * cascade.inv_n2; batch.coastal_dz[p] = dz * cascade.inv_n2;
                if (!displacement_only) {
                    const double dhx = batch.cascade_dhx[p], dhz = batch.cascade_dhz[p], dxx = batch.cascade_dxx[p], dxz = batch.cascade_dxz[p];
                    const double dzx = batch.cascade_dzx[p], dzz = batch.cascade_dzz[p], vh = batch.cascade_vh[p], vx = batch.cascade_vx[p], vz = batch.cascade_vz[p];
                    batch.coastal_dhx[p] = dhx * cascade.inv_n2; batch.coastal_dhz[p] = dhz * cascade.inv_n2; batch.coastal_dxx[p] = dxx * cascade.inv_n2; batch.coastal_dxz[p] = dxz * cascade.inv_n2;
                    batch.coastal_dzx[p] = dzx * cascade.inv_n2; batch.coastal_dzz[p] = dzz * cascade.inv_n2; batch.coastal_vh[p] = vh * cascade.inv_n2; batch.coastal_vx[p] = vx * cascade.inv_n2; batch.coastal_vz[p] = vz * cascade.inv_n2;
                }
            }
        }
        for (size_t j = 0; j < active_count; ++j) {
            const size_t p = indices[j]; const double inv = cascade.inv_n2;
            batch.h[p] += batch.cascade_h[p] * inv; batch.dx[p] += batch.cascade_dx[p] * inv; batch.dz[p] += batch.cascade_dz[p] * inv;
            if (!displacement_only) {
                batch.dhx[p] += batch.cascade_dhx[p] * inv; batch.dhz[p] += batch.cascade_dhz[p] * inv;
                batch.dxx[p] += batch.cascade_dxx[p] * inv; batch.dxz[p] += batch.cascade_dxz[p] * inv;
                batch.dzx[p] += batch.cascade_dzx[p] * inv; batch.dzz[p] += batch.cascade_dzz[p] * inv;
                batch.vh[p] += batch.cascade_vh[p] * inv; batch.vx[p] += batch.cascade_vx[p] * inv; batch.vz[p] += batch.cascade_vz[p] * inv;
            }
        }
    }
}

void evaluate_coastal_long_batch_avx2(const Cascade &cascade, BatchWorkspace &batch,
                                      const size_t *indices, size_t active_count, bool vector_sincos,
                                      bool displacement_only, CoastalProfile *profile, int profile_stage) {
    const __m256d zero = _mm256_setzero_pd();
    size_t ai = 0;
    for (; ai + 4 <= active_count; ai += 4) {
        const size_t p0 = indices[ai], p1 = indices[ai + 1], p2 = indices[ai + 2], p3 = indices[ai + 3];
        const __m256i gather = _mm256_set_epi64x(static_cast<long long>(p3), static_cast<long long>(p2), static_cast<long long>(p1), static_cast<long long>(p0));
        const __m256d qx = _mm256_i64gather_pd(batch.coastal_deep_x.data(), gather, 8);
        const __m256d qz = _mm256_i64gather_pd(batch.coastal_deep_z.data(), gather, 8);
        alignas(32) double material_qx[4], material_qz[4], fft_qx[4], fft_qz[4];
        _mm256_store_pd(material_qx, qx);
        _mm256_store_pd(material_qz, qz);
        for (int lane = 0; lane < 4; ++lane) {
            cascade.material_q_to_fft_q(material_qx[lane], material_qz[lane], fft_qx[lane], fft_qz[lane]);
        }
        const __m256d band_qx = _mm256_load_pd(fft_qx);
        const __m256d band_qz = _mm256_load_pd(fft_qz);
        const bool profile_pass = profile != nullptr && profile_stage >= 0 && profile_stage < 5;
        PhaseRecurrence4 phase;
        const bool use_phase_recurrence = vector_sincos && phase.initialize(cascade, band_qx, band_qz);
        if (profile_pass) {
            profile->deep_mode_evaluations[static_cast<size_t>(profile_stage)] += cascade.kx.size() * 4;
            if (use_phase_recurrence) profile->deep_vector_sincos_calls[static_cast<size_t>(profile_stage)] += 1 + 2 * static_cast<uint64_t>(phase.n - 1);
            else profile->deep_direct_sincos_calls[static_cast<size_t>(profile_stage)] += cascade.kx.size();
        }
        __m256d h = zero, dx = zero, dz = zero, dhx = zero, dhz = zero, dxx = zero, dxz = zero, dzx = zero, dzz = zero, vh = zero, vx = zero, vz = zero;
        const auto mode_start = profile_pass ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
        for (size_t idx = 0; idx < cascade.kx.size(); ++idx) {
            __m256d sp, cp;
            if (use_phase_recurrence) { sp = phase.s; cp = phase.c; }
            else {
                const __m256d phi = _mm256_add_pd(_mm256_mul_pd(_mm256_set1_pd(cascade.kx[idx]), band_qx), _mm256_mul_pd(_mm256_set1_pd(cascade.ky[idx]), band_qz));
                if (vector_sincos) { sincos_safe(phi, sp, cp); } else { sincos_lanes(phi, sp, cp); }
            }
            const __m256d h_re = _mm256_set1_pd(cascade.ev_h_re[idx]), h_im = _mm256_set1_pd(cascade.ev_h_im[idx]);
            const __m256d pre = _mm256_fnmadd_pd(h_im, sp, _mm256_mul_pd(h_re, cp));
            const __m256d pim = _mm256_fmadd_pd(h_re, sp, _mm256_mul_pd(h_im, cp));
            const double sig_value = cascade.parity[idx] * cascade.weight[idx];
            const __m256d sig = _mm256_set1_pd(sig_value);
            h = _mm256_fmadd_pd(sig, pre, h);
            dx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a1[idx]), pim, dx);
            dz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a2[idx]), pim, dz);
            if (!displacement_only) {
                const __m256d v_re = _mm256_set1_pd(cascade.ev_v_re[idx]), v_im = _mm256_set1_pd(cascade.ev_v_im[idx]);
                const __m256d qre = _mm256_fnmadd_pd(v_im, sp, _mm256_mul_pd(v_re, cp));
                const __m256d qim = _mm256_fmadd_pd(v_re, sp, _mm256_mul_pd(v_im, cp));
                dhx = _mm256_fmadd_pd(_mm256_set1_pd(-sig_value * cascade.kx[idx]), pim, dhx);
                dhz = _mm256_fmadd_pd(_mm256_set1_pd(-sig_value * cascade.ky[idx]), pim, dhz);
                dxx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.c11[idx]), pre, dxx);
                dxz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.c12[idx]), pre, dxz);
                dzx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.c21[idx]), pre, dzx);
                dzz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.c22[idx]), pre, dzz);
                vh = _mm256_fmadd_pd(sig, qre, vh);
                vx = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a1[idx]), qim, vx);
                vz = _mm256_fmadd_pd(_mm256_set1_pd(sig_value * cascade.a2[idx]), qim, vz);
            }
            if (use_phase_recurrence && idx + 1 < cascade.kx.size()) phase.advance();
        }
        if (profile_pass) profile->deep_mode_ns[static_cast<size_t>(profile_stage)] += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - mode_start).count());
        const auto reduce_start = profile_pass ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
        const __m256d inv = _mm256_set1_pd(cascade.inv_n2);
        store_points(batch.coastal_deep_h,p0,p1,p2,p3,_mm256_mul_pd(h, inv)); store_points(batch.coastal_deep_dx,p0,p1,p2,p3,_mm256_mul_pd(dx, inv)); store_points(batch.coastal_deep_dz,p0,p1,p2,p3,_mm256_mul_pd(dz, inv));
        if (!displacement_only) {
            store_points(batch.coastal_deep_dhx,p0,p1,p2,p3,_mm256_mul_pd(dhx, inv)); store_points(batch.coastal_deep_dhz,p0,p1,p2,p3,_mm256_mul_pd(dhz, inv)); store_points(batch.coastal_deep_dxx,p0,p1,p2,p3,_mm256_mul_pd(dxx, inv)); store_points(batch.coastal_deep_dxz,p0,p1,p2,p3,_mm256_mul_pd(dxz, inv)); store_points(batch.coastal_deep_dzx,p0,p1,p2,p3,_mm256_mul_pd(dzx, inv)); store_points(batch.coastal_deep_dzz,p0,p1,p2,p3,_mm256_mul_pd(dzz, inv));
            store_points(batch.coastal_deep_vh,p0,p1,p2,p3,_mm256_mul_pd(vh, inv)); store_points(batch.coastal_deep_vx,p0,p1,p2,p3,_mm256_mul_pd(vx, inv)); store_points(batch.coastal_deep_vz,p0,p1,p2,p3,_mm256_mul_pd(vz, inv));
        }
        if (profile_pass) {
            profile->deep_reduce_ns[static_cast<size_t>(profile_stage)] += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - reduce_start).count());
        }
    }
    for (; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        double fft_qx = 0.0, fft_qz = 0.0;
        cascade.material_q_to_fft_q(batch.coastal_deep_x[p], batch.coastal_deep_z[p], fft_qx, fft_qz);
        double h = 0.0, dx = 0.0, dz = 0.0, dhx = 0.0, dhz = 0.0, dxx = 0.0, dxz = 0.0, dzx = 0.0, dzz = 0.0, vh = 0.0, vx = 0.0, vz = 0.0;
        for (size_t idx = 0; idx < cascade.kx.size(); ++idx) {
            const double phi = cascade.kx[idx] * fft_qx + cascade.ky[idx] * fft_qz, cp = std::cos(phi), sp = std::sin(phi);
            const double pre = cascade.ev_h_re[idx] * cp - cascade.ev_h_im[idx] * sp, pim = cascade.ev_h_re[idx] * sp + cascade.ev_h_im[idx] * cp;
            const double sig = cascade.parity[idx] * cascade.weight[idx];
            h += sig * pre; dx += sig * cascade.a1[idx] * pim; dz += sig * cascade.a2[idx] * pim;
            if (!displacement_only) {
                const double qre = cascade.ev_v_re[idx] * cp - cascade.ev_v_im[idx] * sp, qim = cascade.ev_v_re[idx] * sp + cascade.ev_v_im[idx] * cp;
                dhx += sig * -cascade.kx[idx] * pim; dhz += sig * -cascade.ky[idx] * pim; dxx += sig * cascade.c11[idx] * pre; dxz += sig * cascade.c12[idx] * pre; dzx += sig * cascade.c21[idx] * pre; dzz += sig * cascade.c22[idx] * pre; vh += sig * qre; vx += sig * cascade.a1[idx] * qim; vz += sig * cascade.a2[idx] * qim;
            }
        }
        batch.coastal_deep_h[p] = h * cascade.inv_n2; batch.coastal_deep_dx[p] = dx * cascade.inv_n2; batch.coastal_deep_dz[p] = dz * cascade.inv_n2;
        if (!displacement_only) {
            batch.coastal_deep_dhx[p] = dhx * cascade.inv_n2; batch.coastal_deep_dhz[p] = dhz * cascade.inv_n2; batch.coastal_deep_dxx[p] = dxx * cascade.inv_n2; batch.coastal_deep_dxz[p] = dxz * cascade.inv_n2; batch.coastal_deep_dzx[p] = dzx * cascade.inv_n2; batch.coastal_deep_dzz[p] = dzz * cascade.inv_n2; batch.coastal_deep_vh[p] = vh * cascade.inv_n2; batch.coastal_deep_vx[p] = vx * cascade.inv_n2; batch.coastal_deep_vz[p] = vz * cascade.inv_n2;
        }
    }
}

void evaluate_coastal_open_stencil_batch_avx2(const Cascade &cascade, BatchWorkspace &batch,
                                              const size_t *indices, size_t active_count,
                                              bool vector_sincos, CoastalProfile *profile) {
    const bool profile_enabled = profile != nullptr;
    size_t ai = 0;
    for (; ai + 4 <= active_count; ai += 4) {
        const size_t points[4] = {indices[ai], indices[ai + 1], indices[ai + 2], indices[ai + 3]};
        const __m256i gather = _mm256_set_epi64x(static_cast<long long>(points[3]), static_cast<long long>(points[2]),
                                                  static_cast<long long>(points[1]), static_cast<long long>(points[0]));
        const __m256d qx = _mm256_i64gather_pd(batch.qx.data(), gather, 8);
        const __m256d qz = _mm256_i64gather_pd(batch.qz.data(), gather, 8);
        alignas(32) double material_qx[4], material_qz[4], fft_qx[4], fft_qz[4];
        _mm256_store_pd(material_qx, qx); _mm256_store_pd(material_qz, qz);
        for (int lane = 0; lane < 4; ++lane) cascade.material_q_to_fft_q(material_qx[lane], material_qz[lane], fft_qx[lane], fft_qz[lane]);
        const __m256d band_qx = _mm256_load_pd(fft_qx), band_qz = _mm256_load_pd(fft_qz);
        __m256d h[4] = {_mm256_setzero_pd(), _mm256_setzero_pd(), _mm256_setzero_pd(), _mm256_setzero_pd()};
        __m256d dx[4] = {_mm256_setzero_pd(), _mm256_setzero_pd(), _mm256_setzero_pd(), _mm256_setzero_pd()};
        __m256d dz[4] = {_mm256_setzero_pd(), _mm256_setzero_pd(), _mm256_setzero_pd(), _mm256_setzero_pd()};
        PhaseRecurrence4 phase;
        const bool use_phase_recurrence = vector_sincos && phase.initialize(cascade, band_qx, band_qz);
        if (profile_enabled) {
            profile->fused_stencil_mode_evaluations += cascade.kx.size() * 4 * 4;
            profile->fused_stencil_sincos_calls += use_phase_recurrence ? 1 + 2 * static_cast<uint64_t>(phase.n - 1) : cascade.kx.size();
        }
        const auto mode_start = profile_enabled ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
        for (size_t idx = 0; idx < cascade.kx.size(); ++idx) {
            __m256d sp, cp;
            if (use_phase_recurrence) { sp = phase.s; cp = phase.c; }
            else {
                const __m256d phi = _mm256_add_pd(_mm256_mul_pd(_mm256_set1_pd(cascade.kx[idx]), band_qx),
                                                   _mm256_mul_pd(_mm256_set1_pd(cascade.ky[idx]), band_qz));
                if (vector_sincos) sincos_safe(phi, sp, cp); else sincos_lanes(phi, sp, cp);
            }
            const __m256d h_re = _mm256_set1_pd(cascade.ev_h_re[idx]);
            const __m256d h_im = _mm256_set1_pd(cascade.ev_h_im[idx]);
            const double sig_value = cascade.parity[idx] * cascade.weight[idx];
            const __m256d sig = _mm256_set1_pd(sig_value);
            const __m256d ax = _mm256_set1_pd(cascade.stencil_x_cos[idx]);
            const __m256d bx = _mm256_set1_pd(cascade.stencil_x_sin[idx]);
            const __m256d az = _mm256_set1_pd(cascade.stencil_z_cos[idx]);
            const __m256d bz = _mm256_set1_pd(cascade.stencil_z_sin[idx]);
            const __m256d c[4] = {
                _mm256_fnmadd_pd(sp, bx, _mm256_mul_pd(cp, ax)),
                _mm256_fmadd_pd(sp, bx, _mm256_mul_pd(cp, ax)),
                _mm256_fnmadd_pd(sp, bz, _mm256_mul_pd(cp, az)),
                _mm256_fmadd_pd(sp, bz, _mm256_mul_pd(cp, az)),
            };
            const __m256d s[4] = {
                _mm256_fmadd_pd(sp, ax, _mm256_mul_pd(cp, bx)),
                _mm256_fnmadd_pd(cp, bx, _mm256_mul_pd(sp, ax)),
                _mm256_fmadd_pd(sp, az, _mm256_mul_pd(cp, bz)),
                _mm256_fnmadd_pd(cp, bz, _mm256_mul_pd(sp, az)),
            };
            const __m256d dx_factor = _mm256_set1_pd(sig_value * cascade.a1[idx]);
            const __m256d dz_factor = _mm256_set1_pd(sig_value * cascade.a2[idx]);
            for (int offset = 0; offset < 4; ++offset) {
                const __m256d pre = _mm256_fnmadd_pd(h_im, s[offset], _mm256_mul_pd(h_re, c[offset]));
                const __m256d pim = _mm256_fmadd_pd(h_re, s[offset], _mm256_mul_pd(h_im, c[offset]));
                h[offset] = _mm256_fmadd_pd(sig, pre, h[offset]);
                dx[offset] = _mm256_fmadd_pd(dx_factor, pim, dx[offset]);
                dz[offset] = _mm256_fmadd_pd(dz_factor, pim, dz[offset]);
            }
            if (use_phase_recurrence && idx + 1 < cascade.kx.size()) phase.advance();
        }
        if (profile_enabled) profile->fused_stencil_mode_ns += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - mode_start).count());
        const __m256d inv = _mm256_set1_pd(cascade.inv_n2);
        for (int offset = 0; offset < 4; ++offset) {
            store_points(batch.coastal_open_stencil_h[offset], points[0], points[1], points[2], points[3], _mm256_mul_pd(h[offset], inv));
            store_points(batch.coastal_open_stencil_dx[offset], points[0], points[1], points[2], points[3], _mm256_mul_pd(dx[offset], inv));
            store_points(batch.coastal_open_stencil_dz[offset], points[0], points[1], points[2], points[3], _mm256_mul_pd(dz[offset], inv));
        }
    }
    for (; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        double fft_qx = 0.0, fft_qz = 0.0;
        cascade.material_q_to_fft_q(batch.qx[p], batch.qz[p], fft_qx, fft_qz);
        double h[4] = {}, dx[4] = {}, dz[4] = {};
        for (size_t idx = 0; idx < cascade.kx.size(); ++idx) {
            const double phi = cascade.kx[idx] * fft_qx + cascade.ky[idx] * fft_qz;
            const double cp = std::cos(phi), sp = std::sin(phi);
            const double h_re = cascade.ev_h_re[idx], h_im = cascade.ev_h_im[idx];
            const double sig = cascade.parity[idx] * cascade.weight[idx];
            const double ax = cascade.stencil_x_cos[idx], bx = cascade.stencil_x_sin[idx];
            const double az = cascade.stencil_z_cos[idx], bz = cascade.stencil_z_sin[idx];
            const double c[4] = {cp * ax - sp * bx, cp * ax + sp * bx, cp * az - sp * bz, cp * az + sp * bz};
            const double s[4] = {sp * ax + cp * bx, sp * ax - cp * bx, sp * az + cp * bz, sp * az - cp * bz};
            for (int offset = 0; offset < 4; ++offset) {
                const double pre = h_re * c[offset] - h_im * s[offset];
                const double pim = h_re * s[offset] + h_im * c[offset];
                h[offset] += sig * pre; dx[offset] += sig * cascade.a1[idx] * pim; dz[offset] += sig * cascade.a2[idx] * pim;
            }
        }
        for (int offset = 0; offset < 4; ++offset) {
            batch.coastal_open_stencil_h[offset][p] = h[offset] * cascade.inv_n2;
            batch.coastal_open_stencil_dx[offset][p] = dx[offset] * cascade.inv_n2;
            batch.coastal_open_stencil_dz[offset][p] = dz[offset] * cascade.inv_n2;
        }
    }
}

void evaluate_band_height_avx2(const Cascade &cascade, const double *qx, const double *qz,
                               const size_t *indices, size_t active_count,
                               double *out_h, bool vector_sincos) {
    const __m256d zero = _mm256_setzero_pd();
    size_t ai = 0;
    for (; ai + 4 <= active_count; ai += 4) {
        const size_t p0 = indices[ai], p1 = indices[ai + 1], p2 = indices[ai + 2], p3 = indices[ai + 3];
        const __m256i gather = _mm256_set_epi64x(static_cast<long long>(p3), static_cast<long long>(p2),
                                                   static_cast<long long>(p1), static_cast<long long>(p0));
        const __m256d vqx = _mm256_i64gather_pd(qx, gather, 8);
        const __m256d vqz = _mm256_i64gather_pd(qz, gather, 8);
        alignas(32) double material_qx[4], material_qz[4], fft_qx[4], fft_qz[4];
        _mm256_store_pd(material_qx, vqx);
        _mm256_store_pd(material_qz, vqz);
        for (int lane = 0; lane < 4; ++lane) {
            cascade.material_q_to_fft_q(material_qx[lane], material_qz[lane], fft_qx[lane], fft_qz[lane]);
        }
        const __m256d band_qx = _mm256_load_pd(fft_qx);
        const __m256d band_qz = _mm256_load_pd(fft_qz);
        __m256d h = zero;
        for (size_t idx = 0; idx < cascade.kx.size(); ++idx) {
            const __m256d phi = _mm256_add_pd(_mm256_mul_pd(_mm256_set1_pd(cascade.kx[idx]), band_qx),
                                               _mm256_mul_pd(_mm256_set1_pd(cascade.ky[idx]), band_qz));
            __m256d sp, cp;
            if (vector_sincos) { sincos_safe(phi, sp, cp); } else { sincos_lanes(phi, sp, cp); }
            const __m256d h_re = _mm256_set1_pd(cascade.ev_h_re[idx]);
            const __m256d h_im = _mm256_set1_pd(cascade.ev_h_im[idx]);
            const __m256d pre = _mm256_sub_pd(_mm256_mul_pd(h_re, cp), _mm256_mul_pd(h_im, sp));
            const __m256d sig = _mm256_set1_pd(cascade.parity[idx] * cascade.weight[idx]);
            h = _mm256_add_pd(h, _mm256_mul_pd(sig, pre));
        }
        const __m256d inv = _mm256_set1_pd(cascade.inv_n2);
        store_points_raw(out_h, p0, p1, p2, p3, _mm256_mul_pd(h, inv));
    }
    for (; ai < active_count; ++ai) {
        const size_t p = indices[ai];
        double fft_qx = 0.0, fft_qz = 0.0;
        cascade.material_q_to_fft_q(qx[p], qz[p], fft_qx, fft_qz);
        double h = 0.0;
        for (size_t idx = 0; idx < cascade.kx.size(); ++idx) {
            const double phi = cascade.kx[idx] * fft_qx + cascade.ky[idx] * fft_qz;
            const double cp = std::cos(phi), sp = std::sin(phi);
            const double pre = cascade.ev_h_re[idx] * cp - cascade.ev_h_im[idx] * sp;
            h += cascade.parity[idx] * cascade.weight[idx] * pre;
        }
        out_h[p] = h * cascade.inv_n2;
    }
}

} // namespace oq
