#pragma once
// Diagnostic copies only. One immutable slow IFFT per band, no producer allocation/I/O.
#include <array>
#include <atomic>
#include <complex>
#include <cstdint>
#include <cstring>
#if defined(_M_X64) || defined(__x86_64__)
#include <immintrin.h>
#endif
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif
namespace oq {
inline uint32_t perf3_mxcsr() {
#if defined(_M_X64) || defined(__x86_64__)
    return _mm_getcsr(); // Do not clear flags or change rounding, FTZ or DAZ.
#else
    return UINT32_MAX;
#endif
}
inline uint32_t perf3_cpu() {
#ifdef _WIN32
    PROCESSOR_NUMBER n{};GetCurrentProcessorNumberEx(&n);return (uint32_t(n.Group)<<16)|n.Number;
#else
    return UINT32_MAX;
#endif
}
struct Perf3FftHeader {
    uint32_t magic=0x3346514f,version=1,n=0,band=0,pair=0,stages=0,mxcsr_before=0,mxcsr_after=0;
    int64_t frame=-1,tick=-1;
    double simulation_time=0;
    uint64_t ifft_us=0,input_copy_us=0,begin_qpc=0,end_qpc=0;
    uint32_t cpu_before=UINT32_MAX,cpu_after=UINT32_MAX;
};
static_assert(sizeof(Perf3FftHeader)==96,"PERF-3 binary header layout");
struct Perf3FftProbe {
    static constexpr size_t MAX_N=128,MAX_COUNT=MAX_N*MAX_N;
    std::atomic<bool> ready{false};
    std::atomic<bool> exported{false};
    Perf3FftHeader header;
    uint64_t minimum_us=1500;
    uint64_t warmup_builds=0; // Independent of the periodic phase rebase counter.
    std::array<std::complex<double>,MAX_COUNT> input{},output{};
    std::array<uint32_t,MAX_N> bit_reverse{};
    std::array<double,MAX_N> real{},imag{};
    std::array<double,MAX_N*2> real_dup{},imag_dup{};
    std::array<size_t,32> offsets{};
};
}
