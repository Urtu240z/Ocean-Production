#pragma once

#include <complex>
#include <cstddef>
#include <cstdint>

namespace oq {

// AVX2-only translation unit. Caller must first verify CPUID + OS state.
void inverse_fft_1d_avx2(std::complex<double> *values, int n,
                         const uint32_t *bit_reverse,
                         const double *twiddle_real, const double *twiddle_imag,
                         const size_t *stage_offsets, int stage_count);
void initialize_phase_avx2(const double *omega, double time, double *phase_cos,
                           double *phase_sin, size_t count);
void build_rotor_avx2(const double *omega, double delta_time, double *rotor_cos,
                      double *rotor_sin, size_t count);
void advance_phase_avx2(double *phase_cos, double *phase_sin,
                        const double *rotor_cos, const double *rotor_sin,
                        size_t count);
void evolve_height_velocity_avx2(const double *omega,
                                 const double *h0_re, const double *h0_im,
                                 const double *h0n_re, const double *h0n_im,
                                 const double *phase_cos, const double *phase_sin,
                                 double *height_re, double *height_im,
                                 double *velocity_re, double *velocity_im,
                                 size_t count);

} // namespace oq
