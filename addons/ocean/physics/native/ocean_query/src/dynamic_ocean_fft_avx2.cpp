// AVX2 radix-2 IFFT butterflies. Compiled in the isolated AVX2 translation
// unit; the caller dispatches here only after the existing runtime CPU check.
#include "dynamic_ocean_fft_avx2.h"
#include "ocean_query_simd_avx2.h"
#include "ocean_query_core.h"
#include "dynamic_ocean_physics_field.h"

#include <immintrin.h>
#include <cmath>

namespace oq {

size_t compose_weather_band_avx2(Cascade &working, const Cascade &source,
                                const Cascade &target, float *h0, double alpha) {
    const double *src_h[4] = {source.h0_re.data(), source.h0_im.data(), source.h0n_re.data(), source.h0n_im.data()};
    const double *dst_h[4] = {target.h0_re.data(), target.h0_im.data(), target.h0n_re.data(), target.h0n_im.data()};
    double *out_h[4] = {working.h0_re.data(), working.h0_im.data(), working.h0n_re.data(), working.h0n_im.data()};
    const double *src_c[6] = {source.a1.data(), source.a2.data(), source.c11.data(), source.c12.data(), source.c21.data(), source.c22.data()};
    const double *dst_c[6] = {target.a1.data(), target.a2.data(), target.c11.data(), target.c12.data(), target.c21.data(), target.c22.data()};
    double *out_c[6] = {working.a1.data(), working.a2.data(), working.c11.data(), working.c12.data(), working.c21.data(), working.c22.data()};
    const __m256d amount = _mm256_set1_pd(alpha);
    size_t i = 0;
    for (; i + 4 <= source.kx.size(); i += 4) {
        const __m256d sign = _mm256_loadu_pd(source.parity.data() + i);
        __m128 channels[4];
        for (size_t channel = 0; channel < 4; ++channel) {
            const __m256d a = _mm256_loadu_pd(src_h[channel] + i);
            const __m256d b = _mm256_loadu_pd(dst_h[channel] + i);
            // Preserve scalar operation order and exact endpoint selection.
            const __m256d mixed = alpha <= 0.0 ? a : alpha >= 1.0 ? b :
                _mm256_add_pd(a, _mm256_mul_pd(_mm256_sub_pd(b, a), amount));
            channels[channel] = _mm256_cvtpd_ps(_mm256_mul_pd(mixed, sign));
            _mm256_storeu_pd(out_h[channel] + i,
                _mm256_mul_pd(_mm256_cvtps_pd(channels[channel]), sign));
        }
        _MM_TRANSPOSE4_PS(channels[0], channels[1], channels[2], channels[3]);
        for (size_t row = 0; row < 4; ++row) _mm_storeu_ps(h0 + 4 * (i + row), channels[row]);
        for (size_t coefficient = 0; coefficient < 6; ++coefficient) {
            const __m256d a = _mm256_loadu_pd(src_c[coefficient] + i);
            const __m256d b = _mm256_loadu_pd(dst_c[coefficient] + i);
            _mm256_storeu_pd(out_c[coefficient] + i,
                _mm256_add_pd(a, _mm256_mul_pd(_mm256_sub_pd(b, a), amount)));
        }
    }
    return i;
}

// Pack F+iG with the same separate parity multiplication as scalar code.
static inline void store_field_pair(std::complex<double> *out, __m256d fr, __m256d fi,
        __m256d gr, __m256d gi, __m256d parity) {
    const __m256d re = _mm256_sub_pd(_mm256_mul_pd(fr, parity), _mm256_mul_pd(gi, parity));
    const __m256d im = _mm256_add_pd(_mm256_mul_pd(fi, parity), _mm256_mul_pd(gr, parity));
    const __m256d lo = _mm256_unpacklo_pd(re, im), high = _mm256_unpackhi_pd(re, im);
    double *values = reinterpret_cast<double *>(out);
    _mm256_storeu_pd(values, _mm256_permute2f128_pd(lo, high, 0x20));
    _mm256_storeu_pd(values + 4, _mm256_permute2f128_pd(lo, high, 0x31));
}

size_t prepare_physics_spectra_avx2(const Cascade &cascade,
        const DynamicOceanEvolutionBuffers &evolution, std::complex<double> *const packed[6],
        const DynamicOceanWeatherDelta *weather_delta, double alpha_dot, size_t count) {
    const __m256d zero = _mm256_setzero_pd(), dot = _mm256_set1_pd(alpha_dot);
    size_t i = 0;
    for (; i + 4 <= count; i += 4) {
        const __m256d hr = _mm256_loadu_pd(evolution.height_re + i), hi = _mm256_loadu_pd(evolution.height_im + i);
        const __m256d vr = _mm256_loadu_pd(evolution.velocity_re + i), vi = _mm256_loadu_pd(evolution.velocity_im + i);
        const __m256d ax = _mm256_loadu_pd(cascade.a1.data() + i), az = _mm256_loadu_pd(cascade.a2.data() + i);
        const __m256d kx = _mm256_loadu_pd(cascade.kx.data() + i), kz = _mm256_loadu_pd(cascade.ky.data() + i);
        const __m256d p = _mm256_mul_pd(_mm256_loadu_pd(cascade.parity.data() + i), _mm256_loadu_pd(cascade.weight.data() + i));
        const __m256d nax = _mm256_sub_pd(zero, ax), naz = _mm256_sub_pd(zero, az);
        store_field_pair(packed[0] + i, hr, hi, _mm256_mul_pd(hi, ax), _mm256_mul_pd(hr, nax), p);
        store_field_pair(packed[1] + i, _mm256_mul_pd(hi, az), _mm256_mul_pd(hr, naz),
            _mm256_mul_pd(_mm256_sub_pd(zero, hi), kx), _mm256_mul_pd(hr, kx), p);
        const __m256d c11 = _mm256_loadu_pd(cascade.c11.data() + i);
        store_field_pair(packed[2] + i, _mm256_mul_pd(_mm256_sub_pd(zero, hi), kz), _mm256_mul_pd(hr, kz),
            _mm256_mul_pd(hr, c11), _mm256_mul_pd(hi, c11), p);
        const __m256d c12 = _mm256_loadu_pd(cascade.c12.data() + i), c21 = _mm256_loadu_pd(cascade.c21.data() + i);
        store_field_pair(packed[3] + i, _mm256_mul_pd(hr, c12), _mm256_mul_pd(hi, c12),
            _mm256_mul_pd(hr, c21), _mm256_mul_pd(hi, c21), p);
        const __m256d c22 = _mm256_loadu_pd(cascade.c22.data() + i);
        store_field_pair(packed[4] + i, _mm256_mul_pd(hr, c22), _mm256_mul_pd(hi, c22), vr, vi, p);
        __m256d vxr = _mm256_mul_pd(vi, ax), vxi = _mm256_mul_pd(vr, nax);
        __m256d vzr = _mm256_mul_pd(vi, az), vzi = _mm256_mul_pd(vr, naz);
        if (alpha_dot != 0.0) {
            const __m256d dax = _mm256_mul_pd(_mm256_loadu_pd(weather_delta->a1.data() + i), dot);
            const __m256d daz = _mm256_mul_pd(_mm256_loadu_pd(weather_delta->a2.data() + i), dot);
            vxr = _mm256_add_pd(vxr, _mm256_mul_pd(hi, dax));
            vxi = _mm256_add_pd(vxi, _mm256_mul_pd(hr, _mm256_sub_pd(zero, dax)));
            vzr = _mm256_add_pd(vzr, _mm256_mul_pd(hi, daz));
            vzi = _mm256_add_pd(vzi, _mm256_mul_pd(hr, _mm256_sub_pd(zero, daz)));
        }
        store_field_pair(packed[5] + i, vxr, vxi, vzr, vzi, p);
    }
    return i;
}


void initialize_phase_avx2(const double *omega, double time, double *phase_cos,
                           double *phase_sin, size_t count) {
    const __m256d scale = _mm256_set1_pd(time);
    alignas(32) double angles[4], sin_values[4], cos_values[4];
    size_t i = 0;
    for (; i + 4 <= count; i += 4) {
        _mm256_store_pd(angles, _mm256_mul_pd(_mm256_loadu_pd(omega + i), scale));
        sincos_pd_avx2(angles, sin_values, cos_values);
        _mm256_storeu_pd(phase_cos + i, _mm256_load_pd(cos_values));
        _mm256_storeu_pd(phase_sin + i, _mm256_load_pd(sin_values));
    }
    for (; i < count; ++i) {
        phase_cos[i] = std::cos(omega[i] * time);
        phase_sin[i] = std::sin(omega[i] * time);
    }
}

void build_rotor_avx2(const double *omega, double delta_time, double *rotor_cos,
                      double *rotor_sin, size_t count) {
    initialize_phase_avx2(omega, delta_time, rotor_cos, rotor_sin, count);
}

void advance_phase_avx2(double *phase_cos, double *phase_sin,
                        const double *rotor_cos, const double *rotor_sin,
                        size_t count) {
    size_t i = 0;
    for (; i + 4 <= count; i += 4) {
        const __m256d c = _mm256_loadu_pd(phase_cos + i);
        const __m256d s = _mm256_loadu_pd(phase_sin + i);
        const __m256d rc = _mm256_loadu_pd(rotor_cos + i);
        const __m256d rs = _mm256_loadu_pd(rotor_sin + i);
        const __m256d next_c = _mm256_sub_pd(_mm256_mul_pd(c, rc), _mm256_mul_pd(s, rs));
        const __m256d next_s = _mm256_add_pd(_mm256_mul_pd(c, rs), _mm256_mul_pd(s, rc));
        _mm256_storeu_pd(phase_cos + i, next_c);
        _mm256_storeu_pd(phase_sin + i, next_s);
    }
    for (; i < count; ++i) {
        const double c = phase_cos[i], s = phase_sin[i];
        phase_cos[i] = c * rotor_cos[i] - s * rotor_sin[i];
        phase_sin[i] = c * rotor_sin[i] + s * rotor_cos[i];
    }
}

void evolve_height_velocity_avx2(const double *omega,
                                 const double *h0_re, const double *h0_im,
                                 const double *h0n_re, const double *h0n_im,
                                 const double *phase_cos, const double *phase_sin,
                                 double *height_re, double *height_im,
                                 double *velocity_re, double *velocity_im,
                                 size_t count, const DynamicOceanWeatherDelta *weather_delta, double alpha_dot) {
    size_t i = 0;
    for (; i + 4 <= count; i += 4) {
        const __m256d c = _mm256_loadu_pd(phase_cos + i);
        const __m256d s = _mm256_loadu_pd(phase_sin + i);
        const __m256d a_re = _mm256_loadu_pd(h0_re + i);
        const __m256d a_im = _mm256_loadu_pd(h0_im + i);
        const __m256d b_re = _mm256_loadu_pd(h0n_re + i);
        const __m256d b_im = _mm256_loadu_pd(h0n_im + i);
        const __m256d ar = _mm256_add_pd(_mm256_mul_pd(a_re, c), _mm256_mul_pd(a_im, s));
        const __m256d ai = _mm256_add_pd(_mm256_mul_pd(_mm256_sub_pd(_mm256_setzero_pd(), a_re), s), _mm256_mul_pd(a_im, c));
        const __m256d br = _mm256_sub_pd(_mm256_mul_pd(b_re, c), _mm256_mul_pd(b_im, s));
        const __m256d bi = _mm256_add_pd(_mm256_mul_pd(b_re, s), _mm256_mul_pd(b_im, c));
        const __m256d omega_v = _mm256_loadu_pd(omega + i);
        _mm256_storeu_pd(height_re + i, _mm256_add_pd(ar, br));
        _mm256_storeu_pd(height_im + i, _mm256_add_pd(ai, bi));
        _mm256_storeu_pd(velocity_re + i, _mm256_mul_pd(omega_v, _mm256_sub_pd(ai, bi)));
        _mm256_storeu_pd(velocity_im + i, _mm256_mul_pd(omega_v, _mm256_add_pd(_mm256_sub_pd(_mm256_setzero_pd(), ar), br)));
        if (alpha_dot != 0.0) {
            const __m256d dr = _mm256_loadu_pd(weather_delta->h0_re.data() + i);
            const __m256d di = _mm256_loadu_pd(weather_delta->h0_im.data() + i);
            const __m256d nr = _mm256_loadu_pd(weather_delta->h0n_re.data() + i);
            const __m256d ni = _mm256_loadu_pd(weather_delta->h0n_im.data() + i);
            const __m256d dot = _mm256_set1_pd(alpha_dot);
            const __m256d er = _mm256_mul_pd(_mm256_add_pd(_mm256_mul_pd(_mm256_add_pd(dr, nr), c),
                _mm256_mul_pd(_mm256_sub_pd(di, ni), s)), dot);
            const __m256d ei = _mm256_mul_pd(_mm256_add_pd(_mm256_mul_pd(_mm256_add_pd(di, ni), c),
                _mm256_mul_pd(_mm256_sub_pd(nr, dr), s)), dot);
            _mm256_storeu_pd(velocity_re + i, _mm256_add_pd(_mm256_loadu_pd(velocity_re + i), er));
            _mm256_storeu_pd(velocity_im + i, _mm256_add_pd(_mm256_loadu_pd(velocity_im + i), ei));
        }
    }
    for (; i < count; ++i) {
        const double c = phase_cos[i], s = phase_sin[i];
        const double ar = h0_re[i] * c + h0_im[i] * s;
        const double ai = -h0_re[i] * s + h0_im[i] * c;
        const double br = h0n_re[i] * c - h0n_im[i] * s;
        const double bi = h0n_re[i] * s + h0n_im[i] * c;
        height_re[i] = ar + br;
        height_im[i] = ai + bi;
        velocity_re[i] = omega[i] * (ai - bi);
        velocity_im[i] = omega[i] * (-ar + br);
        if (alpha_dot != 0.0) {
            const double dr = weather_delta->h0_re[i], di = weather_delta->h0_im[i];
            const double nr = weather_delta->h0n_re[i], ni = weather_delta->h0n_im[i];
            velocity_re[i] += ((dr + nr) * c + (di - ni) * s) * alpha_dot;
            velocity_im[i] += ((di + ni) * c + (nr - dr) * s) * alpha_dot;
        }
    }
}

void inverse_fft_1d_avx2(std::complex<double> *values, int n,
                         const uint32_t *bit_reverse,
                         const double *twiddle_real, const double *twiddle_imag,
                         const double *twiddle_real_dup, const double *twiddle_imag_dup,
                         const size_t *stage_offsets, int stage_count) {
    for (int i = 0; i < n; ++i) {
        const uint32_t j = bit_reverse[i];
        if (static_cast<uint32_t>(i) < j) {
            const std::complex<double> temp = values[i];
            values[i] = values[j];
            values[j] = temp;
        }
    }

    double *data = reinterpret_cast<double *>(values);
    int length = 2;
    for (int stage = 0; stage < stage_count; ++stage, length <<= 1) {
        const int half = length >> 1;
        const size_t twiddle_base = stage_offsets[stage];
        for (int base = 0; base < n; base += length) {
            int j = 0;
            for (; j + 1 < half; j += 2) {
                const size_t even_index = static_cast<size_t>(base + j) * 2;
                const size_t odd_index = static_cast<size_t>(base + j + half) * 2;
                const __m256d even = _mm256_loadu_pd(data + even_index);
                const __m256d odd = _mm256_loadu_pd(data + odd_index);
                const size_t packed_twiddle_index = (twiddle_base + static_cast<size_t>(j)) * 2;
                const __m256d twiddle_real_pair = _mm256_loadu_pd(twiddle_real_dup + packed_twiddle_index);
                const __m256d twiddle_imag_pair = _mm256_loadu_pd(twiddle_imag_dup + packed_twiddle_index);
                const __m256d odd_swapped = _mm256_permute_pd(odd, 0x5);
                const __m256d product = _mm256_addsub_pd(
                    _mm256_mul_pd(odd, twiddle_real_pair),
                    _mm256_mul_pd(odd_swapped, twiddle_imag_pair));
                _mm256_storeu_pd(data + even_index, _mm256_add_pd(even, product));
                _mm256_storeu_pd(data + odd_index, _mm256_sub_pd(even, product));
            }
            for (; j < half; ++j) {
                const size_t even_index = static_cast<size_t>(base + j) * 2;
                const size_t odd_index = static_cast<size_t>(base + j + half) * 2;
                const double wr = twiddle_real[twiddle_base + j];
                const double wi = twiddle_imag[twiddle_base + j];
                const double or_ = data[odd_index];
                const double oi = data[odd_index + 1];
                const double pr = or_ * wr - oi * wi;
                const double pi = or_ * wi + oi * wr;
                const double er = data[even_index], ei = data[even_index + 1];
                data[even_index] = er + pr; data[even_index + 1] = ei + pi;
                data[odd_index] = er - pr; data[odd_index + 1] = ei - pi;
            }
        }
    }

    const __m256d scale = _mm256_set1_pd(1.0 / static_cast<double>(n));
    for (int i = 0; i + 1 < n; i += 2) {
        const size_t index = static_cast<size_t>(i) * 2;
        _mm256_storeu_pd(data + index, _mm256_mul_pd(_mm256_loadu_pd(data + index), scale));
    }
    if ((n & 1) != 0) values[n - 1] *= 1.0 / static_cast<double>(n);
}

} // namespace oq
