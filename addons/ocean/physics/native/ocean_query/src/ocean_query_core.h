// OceanQuery core nativo (Fase 2C).
// Puerto EXACTO del hot path de OceanQueryReduced (GDScript 2B) a C++ plano,
// SIN godot-cpp, para validar matemática y medir velocidad real.
// No cambia ninguna fórmula; usa std::cos/std::sin estándar.

#pragma once

#include <vector>
#include <cstddef>
#include <cstdint>
#include <array>
#include "coastal_coverage.h"

namespace oq {

struct Cascade {
    std::vector<double> kx, ky, omega;
    // Exact centered-difference spectral multipliers sin(k*eps)/eps, prepared
    // once with the spectrum for the Coastal 1 cm and Newton 5 cm stencils.
    std::vector<double> fd01_kx, fd01_ky, fd05_kx, fd05_ky;
    std::vector<double> a1, a2, c11, c12, c21, c22;
    std::vector<double> parity, weight;
    std::vector<double> h0_re, h0_im, h0n_re, h0n_im;
    // 3B.3: pesos independientes de las mitades canónicas A=+k y B=-k.
    std::vector<double> coastal_weight_pos, coastal_weight_neg;
    std::vector<double> ev_h_re, ev_h_im, ev_v_re, ev_v_im;
    std::vector<double> ev_a_h_re, ev_a_h_im, ev_b_h_re, ev_b_h_im;
    std::vector<double> ev_a_v_re, ev_a_v_im, ev_b_v_re, ev_b_v_im;
    // 3B.3A: C = w( k) A + w(-k) B preparado una vez por instante. El
    // evaluador AVX2 reutiliza estas componentes durante el mismo phi de LONG.
    std::vector<double> ev_coastal_h_re, ev_coastal_h_im, ev_coastal_v_re, ev_coastal_v_im;
    // Factores geométricos sig*{1,a,k,c} invariables por espectro. Evitan
    // recomponerlos por modo/punto en los dos evaluadores coastal AVX2.
    std::vector<double> coastal_f_h, coastal_f_dx, coastal_f_dz, coastal_f_dhx, coastal_f_dhz;
    std::vector<double> coastal_f_dxx, coastal_f_dxz, coastal_f_dzx, coastal_f_dzz, coastal_f_vh, coastal_f_vx, coastal_f_vz;
    // Precomputed exp(i*k*0.01) factors used to derive exact Coastal stencil phases.
    std::vector<double> stencil_x_cos, stencil_x_sin, stencil_z_cos, stencil_z_sin;
    // Lista compacta exacta: sólo elimina pares con ambos pesos exactamente 0.
    std::vector<size_t> coastal_nonzero_indices;
    double inv_n2 = 0.0;
    double material_domain_m = 0.0;
    int material_resolution = 0;
    double production_choppiness = 0.0;
    double production_gravity = 9.81;
    double production_wind_x = 1.0, production_wind_z = 0.0, production_wind_speed = 0.0;
    double regular_frequency_step = 0.0;
    bool regular_frequency_grid = false;
    bool separable_frequency_grid = false;

    void material_q_to_fft_q(double material_qx, double material_qz,
                             double &fft_qx, double &fft_qz) const;
};

struct CoastalSample {
    bool in_field_coverage = false;
    double shoaling = 1.0, field_valid = 0.0;
    double warp_x = 0.0, warp_z = 0.0, warp_det_j = 0.0, warp_valid = 0.0;
    double confidence = 0.0;
    // Legacy CoastalSample members remain for the isolated native breaker
    // diagnostic API; the physical surface path uses the fields above.
    double deep_x = 0.0, deep_z = 0.0, effective_shoaling = 1.0;
    double j00 = 1.0, j01 = 0.0, j10 = 0.0, j11 = 1.0;
};

// Perfil temporal de diagnóstico 3B.3A. Se desactiva por defecto y sólo se
// usa para descomponer la implementación coastal durante el benchmark.
struct CoastalProfile {
    bool enabled = false;
    uint64_t base_us = 0;
    uint64_t sampler_us = 0;
    uint64_t cq_us = 0;
    uint64_t cdeep_us = 0;
    uint64_t combine_us = 0;
    uint64_t calls = 0;

    // PHYS-OPT-1: stage 0=center, 1=+X, 2=-X, 3=+Z, 4=-Z.
    // Per-stage timings and work counts are populated only while profiling is enabled.
    std::array<std::array<uint64_t, 3>, 5> band_mode_ns{};
    std::array<std::array<uint64_t, 3>, 5> band_reduce_ns{};
    std::array<uint64_t, 5> deep_mode_ns{};
    std::array<uint64_t, 5> deep_reduce_ns{};
    std::array<uint64_t, 5> sampler_stage_ns{};
    std::array<uint64_t, 5> combine_stage_ns{};
    std::array<std::array<uint64_t, 3>, 5> mode_evaluations{};
    std::array<uint64_t, 5> deep_mode_evaluations{};
    std::array<uint64_t, 5> vector_sincos_calls{};
    std::array<uint64_t, 5> direct_sincos_calls{};
    std::array<uint64_t, 5> deep_vector_sincos_calls{};
    std::array<uint64_t, 5> deep_direct_sincos_calls{};
    uint64_t fused_stencil_mode_ns = 0;
    uint64_t fused_stencil_mode_evaluations = 0;
    uint64_t fused_stencil_sincos_calls = 0;

    void reset() {
        base_us = sampler_us = cq_us = cdeep_us = combine_us = calls = 0;
        for (auto &row : band_mode_ns) row.fill(0);
        for (auto &row : band_reduce_ns) row.fill(0);
        deep_mode_ns.fill(0); deep_reduce_ns.fill(0);
        sampler_stage_ns.fill(0); combine_stage_ns.fill(0);
        for (auto &row : mode_evaluations) row.fill(0);
        deep_mode_evaluations.fill(0);
        vector_sincos_calls.fill(0); direct_sincos_calls.fill(0); deep_vector_sincos_calls.fill(0); deep_direct_sincos_calls.fill(0);
        fused_stencil_mode_ns = fused_stencil_mode_evaluations = fused_stencil_sincos_calls = 0;
    }
};

// Datos CPU horneados de 3B.2B. Se copian sólo al configurar/rebuild, nunca
// por query. El sampler replica filter_linear del shader para campos/máscaras.
struct CoastalRuntime {
    bool enabled = false;
    double field_origin_x = 0.0, field_origin_z = 0.0;
    double field_extent_x = 0.0, field_extent_z = 0.0;
    int field_width = 0, field_height = 0;
    double warp_origin_x = 0.0, warp_origin_z = 0.0;
    double warp_extent_x = 0.0, warp_extent_z = 0.0;
    int warp_width = 0, warp_height = 0;
    double detj_safe = 0.5;
    std::vector<double> shoaling, field_valid;
    std::vector<double> warp_x, warp_z, det_j, warp_valid;

    void clear() { enabled = false; }
    bool sample(double qx, double qz, CoastalSample &out,
                double feather_texels = COASTAL_COVERAGE_FEATHER_TEXELS) const;
};

// Stride del buffer de salida (mismo contrato que la API nativa GDExtension).
enum SampleIndex {
    S_VALID = 0,
    S_HEIGHT,
    S_DX,
    S_DY,
    S_DZ,
    S_NX,
    S_NY,
    S_NZ,
    S_VX,
    S_VY,
    S_VZ,
    S_JACOBIAN_DET,
    S_FOLDOVER,
    S_RESIDUAL,
    S_ITERATIONS,
    S_STRIDE,
};

const int MAX_ITERATIONS = 3;
// Coastal bake warps are piecewise bilinear and can have stronger spatial
// compression than the open-ocean spectral map. Keep the PHYS-2 solver limit
// untouched and give only Coastal-enabled world inversion additional Newton
// iterations before declaring a valid point unresolved.
const int MAX_COASTAL_ITERATIONS = 12;
const int NEWTON_HISTOGRAM_SIZE = MAX_COASTAL_ITERATIONS + 2; // Iterations 0..12 plus non-converged.
const double POSITION_TOLERANCE_M = 1.0e-3;
const double JACOBIAN_EPSILON = 1.0e-6;
const int TRUE_BATCH_WARM_STRIDE = S_STRIDE + 2;

// Explicit physical-query band selection. Existing APIs keep the full-band
// default; production consumers can scope one query to LONG or LONG+MID.
enum QueryBandMask : uint8_t {
    QUERY_BAND_LONG = 1u << 0,
    QUERY_BAND_MID = 1u << 1,
    QUERY_BAND_SHORT = 1u << 2,
    QUERY_BAND_ALL = QUERY_BAND_LONG | QUERY_BAND_MID | QUERY_BAND_SHORT,
};

// SoA reutilizable para la ruta TRUE_BATCH. Sólo crece cuando la capacidad
// solicitada aumenta; nunca crea objetos por punto durante una consulta.
struct BatchWorkspace {
    size_t capacity = 0;
    std::vector<double> wx, wz, qx, qz, band_qx, band_qz;
    std::vector<double> h, dx, dz, dhx, dhz, dxx, dxz, dzx, dzz, vh, vx, vz;
    std::vector<double> cascade_h, cascade_dx, cascade_dz;
    std::vector<double> cascade_dhx, cascade_dhz, cascade_dxx, cascade_dxz, cascade_dzx, cascade_dzz;
    std::vector<double> cascade_vh, cascade_vx, cascade_vz;
    std::vector<double> residual;
    std::vector<int> iterations;
    std::vector<uint8_t> done, cold_initial_seed;
    std::vector<size_t> active_indices;
    std::vector<size_t> coastal_active_indices;
    std::vector<CoastalSample> coastal_samples;
    std::vector<double> coastal_deep_x, coastal_deep_z;
    // C(q), fusionado dentro del pase LONG existente.
    std::vector<double> coastal_h, coastal_dx, coastal_dz, coastal_dhx, coastal_dhz;
    std::vector<double> coastal_dxx, coastal_dxz, coastal_dzx, coastal_dzz, coastal_vh, coastal_vx, coastal_vz;
    // C(F(q)), evaluado por lote sólo para puntos coastal activos.
    std::vector<double> coastal_deep_h, coastal_deep_dx, coastal_deep_dz, coastal_deep_dhx, coastal_deep_dhz;
    std::vector<double> coastal_deep_dxx, coastal_deep_dxz, coastal_deep_dzx, coastal_deep_dzz, coastal_deep_vh, coastal_deep_vx, coastal_deep_vz;
    // Center values and +X stencil values for the exact Coastal 1 cm Jacobian.
    std::vector<double> coastal_center_h, coastal_center_dx, coastal_center_dz;
    std::vector<double> coastal_center_vh, coastal_center_vx, coastal_center_vz;
    std::vector<double> coastal_stencil_h, coastal_stencil_dx, coastal_stencil_dz;
    std::array<std::vector<double>, 4> coastal_open_stencil_h;
    std::array<std::vector<double>, 4> coastal_open_stencil_dx;
    std::array<std::vector<double>, 4> coastal_open_stencil_dz;
    std::vector<double> coastal_fd_dhx, coastal_fd_dxx, coastal_fd_dzx;
    std::vector<double> coastal_fd_dhz, coastal_fd_dxz, coastal_fd_dzz;
    std::vector<size_t> coastal_stencil_indices;
    // 5R.1E: scratch del batch sharpened. Los campos base (h/dx/dz/derivadas)
    // siguen viviendo arriba; aquí se guarda el estado transitorio del solver.
    std::vector<double> sharpen_cdx, sharpen_cdz;       // dx/dz FINAL del centro (Newton).
    std::vector<double> sharpen_lqx, sharpen_lqz;       // offset -dir*eps (band height).
    std::vector<double> sharpen_rqx, sharpen_rqz;       // offset +dir*eps (band height).
    std::vector<double> band_l_c, band_l_l, band_l_r;   // altura banda LONG c/l/r.
    std::vector<double> band_m_c, band_m_l, band_m_r;   // altura banda MID c/l/r.
    std::vector<double> jac_a, jac_b, jac_c, jac_d;     // Jacobian finito 2x2.
    std::vector<double> fd_dx, fd_dz;                   // dx/dz FINAL del offset actual.
    std::vector<double> fd_save_qx, fd_save_qz;         // save/restore q en offset eval.
    void ensure_capacity(size_t required);
};

class OceanQueryCore {
public:
    // Validation-only trace; the normal query path has no trace allocations.
    using WorldTraceRow = std::array<double, 24>;
    struct WorldParityDebug {
        std::vector<WorldTraceRow> scalar_trace, batch_trace;
        std::vector<double> scalar, batch;
        std::vector<std::vector<double>> same_q_fields;
        size_t cold_failure_replays = 0;
    };
    WorldParityDebug debug_world_parity(const double *positions_xz, size_t n, size_t point, bool focused_only = false);
    std::vector<Cascade> cascades;
    uint8_t active_query_band_mask = QUERY_BAND_ALL;
    CoastalRuntime coastal;
    double sea_level = 0.0;
    bool prepared_valid = false;
    uint8_t prepared_band_mask = 0;
    double prepared_time = 0.0;
    bool breaker_prepared_valid = false;
    double breaker_prepared_time = 0.0;
    int diag_non_converged = 0;
    size_t diag_last_cold_failure_replays = 0;
    // 5R1D: crest sharpening (paridad render/query, world-space).
    bool crest_sharpen_enabled = false;
    double crest_sharpen_strength = 1.0;
    double crest_sharpen_threshold = 0.15;
    double crest_sharpen_max_gain = 0.30;
    double crest_sharpen_long_weight = 1.0;
    double crest_sharpen_mid_weight = 0.5;
    double crest_sharpen_dir_x = 1.0;
    double crest_sharpen_dir_z = 0.0;
    double crest_sharpen_eps = 1.92;
    double crest_sharpen_local_hs = 0.5;
    // Diagnóstico de la última operación TRUE_BATCH: una evaluación equivale
    // a evaluar todos los modos de las cascadas para un punto activo.
    size_t diag_last_spectral_point_evaluations = 0;
    int diag_last_newton_histogram[NEWTON_HISTOGRAM_SIZE] = {};
    bool diag_last_material_batch_avx2 = false;
    bool diag_last_world_batch_avx2 = false;
    bool diag_last_coastal_deep_avx2 = false;
    mutable CoastalProfile coastal_profile;

    // La detección vive en el objeto scalar: ninguna instrucción AVX2 se
    // ejecuta antes de decidir llamar a la translation unit AVX2 aislada.
    bool force_scalar = false;

    void clear() { cascades.clear(); coastal.clear(); prepared_valid = false; prepared_band_mask = 0; breaker_prepared_valid = false; active_query_band_mask = QUERY_BAND_ALL; }
    uint8_t exchange_query_band_mask(uint8_t mask) {
        const uint8_t previous = active_query_band_mask;
        active_query_band_mask = mask;
        return previous;
    }

    void set_cascade_data(size_t cascade_index, double inv_n2,
                          const double *kx, const double *ky, const double *omega,
                          const double *a1, const double *a2,
                          const double *c11, const double *c12, const double *c21, const double *c22,
                          const double *parity, const double *weight,
                          const double *h0_re, const double *h0_im,
                          const double *h0n_re, const double *h0n_im,
                          size_t count);
    void set_cascade_material_q_contract(size_t cascade_index, double domain_size_m, int resolution);
    void material_q_to_fft_q(size_t cascade_index, double material_qx, double material_qz,
                             double &fft_qx, double &fft_qz) const;

    void finalize_spectrum();

    void set_coastal_long_weights(const double *pos, const double *neg, size_t count);
    void set_coastal_runtime(double field_origin_x, double field_origin_z,
                             double field_extent_x, double field_extent_z,
                             int field_width, int field_height,
                             const double *shoaling, const double *field_valid,
                             double warp_origin_x, double warp_origin_z,
                             double warp_extent_x, double warp_extent_z,
                             int warp_width, int warp_height,
                             const double *warp_x, const double *warp_z,
                             const double *det_j, const double *warp_valid,
                             double detj_safe);
    void clear_coastal() { coastal.clear(); }
    void set_coastal_profile_enabled(bool enabled) { coastal_profile.enabled = enabled; }
    void reset_coastal_profile() { coastal_profile.reset(); }
    size_t coastal_nonzero_pair_count() const;
    size_t coastal_pair_count() const;

    void ensure_prepared(double simulation_time);
    // Breaker Specialized Query: prepara sólo LONG A/B para height/slope coastal.
    void ensure_breaker_prepared(double simulation_time);
    void sample_coastal_breaker_prepared(const double *positions_xz, size_t n,
                                         double *out, bool include_slope) const;

    // 5R1D: configura el crest sharpening (misma matemática que render).
    void set_crest_sharpen(double strength, double threshold, double max_gain,
                           double long_weight, double mid_weight,
                           double dir_x, double dir_z, double eps, double local_hs);

    // Evalúa una posición world y escribe el sample en out (S_STRIDE doubles).
    // Si out == nullptr, sólo mide tiempo.
    void sample_world(double wx, double wz, double simulation_time, double *out);
    void sample_world_with_material_q(double wx, double wz, double simulation_time,
                                      double *out, double *material_q_x, double *material_q_z);

    // Pure spectral evaluator: qx/qz are Fourier-space coordinates. The
    // Production material-q convention is adapted at the GDExtension boundary.
    void sample_material_q(double qx, double qz, double simulation_time, double *out);
    void sample_material_q_batch_prepared(const double *positions_xz, size_t n, double *out);

    // Igual que sample_world pero asume ensure_prepared ya llamado.
    void sample_prepared(double wx, double wz, double *out) { sample_prepared_(wx, wz, out); }

    void accumulate_breaker_long_height_(double qx, double qz, double &h) const;
    void accumulate_breaker_long_slope_(double qx, double qz, double &h,
                                        double &dhx, double &dhz) const;

    // Batch: evalúa n posiciones; out debe tener n*S_STRIDE doubles.
    // Producción: dispatch AVX2 si está disponible; scalar siempre fallback.
    void sample_batch_prepared(const double *positions_xz, size_t n, double *out);

    // Referencia explícita para tests, benchmark y CPUs sin AVX2.
    void sample_batch_scalar_prepared(const double *positions_xz, size_t n, double *out);

    // Subtest aislado: AVX2 en aritmética, std::sin/cos por lane.
    void sample_batch_avx2_scalar_trig_prepared(const double *positions_xz, size_t n, double *out);

    // TRUE_BATCH mode-major: reutiliza Workspace SoA y resuelve Newton de
    // forma colectiva. out tiene n*S_STRIDE doubles.
    void sample_batch_true_prepared(const double *positions_xz, size_t n, double *out);

    // Variante temporal. initial_q_xz contiene la predicción q de cada punto;
    // si un valor no es finito se usa world_xz. out tiene n*(S_STRIDE + 2):
    // el contrato normal seguido de qx,qz resueltos para el siguiente tick.
    void sample_batch_warm_prepared(const double *positions_xz, const double *initial_q_xz,
                                    size_t n, double *out);

    bool avx2_supported() const;
    const char *query_execution_backend() const;

    // Exposición pública de accumulate_ para diagnósticos del PATCH (2C.1A):
    // permite verificar que un nodo del grid reproduce EXACTAMENTE la suma del
    // core DIRECT en ese q (recurrencia de fase vs sin/cos directos).
    void accumulate_public(double qx, double qz, bool use_prepared, double sim_time,
                           double &h, double &dx, double &dz,
                           double &dhx, double &dhz,
                           double &dxx, double &dxz, double &dzx, double &dzz,
                           double &vh, double &vx, double &vz) {
        accumulate_(qx, qz, use_prepared, sim_time, h, dx, dz, dhx, dhz,
                    dxx, dxz, dzx, dzz, vh, vx, vz);
    }

private:
    BatchWorkspace batch_;
    std::vector<WorldTraceRow> *world_trace_ = nullptr;
    size_t world_trace_point_ = 0;
    void trace_world_(size_t point, int iteration, size_t active_count,
                      double qx, double qz, double h, double dx, double dz,
                      double fx, double fz, double ja, double jb, double jc, double jd,
                      double next_qx, double next_qz, int reason);

    void accumulate_(double qx, double qz, bool use_prepared, double sim_time,
                     double &h, double &dx, double &dz,
                     double &dhx, double &dhz,
                     double &dxx, double &dxz, double &dzx, double &dzz,
                     double &vh, double &vx, double &vz);
    void accumulate_open_(double qx, double qz, bool use_prepared, double sim_time,
                          double &h, double &dx, double &dz,
                          double &dhx, double &dhz,
                          double &dxx, double &dxz, double &dzx, double &dzz,
                          double &vh, double &vx, double &vz);
    void accumulate_displacement_(double qx, double qz, bool use_prepared, double sim_time,
                                  double &h, double &dx, double &dz,
                                  double &vh, double &vx, double &vz);
    void apply_coastal_correction_(double qx, double qz, bool use_prepared, double sim_time,
                                   double &h, double &dx, double &dz,
                                   double &dhx, double &dhz,
                                   double &dxx, double &dxz, double &dzx, double &dzz,
                                   double &vh, double &vx, double &vz);
    void evaluate_long_(double qx, double qz, bool use_prepared, double sim_time,
                        double &h, double &dx, double &dz,
                        double &vh, double &vx, double &vz) const;

    void sample_prepared_(double wx, double wz, double *out,
                          double *material_q_x = nullptr, double *material_q_z = nullptr);
    void sample_material_q_prepared_(double qx, double qz, double *out);
    double band_height_(size_t band_index, double qx, double qz) const;
    void apply_crest_sharpen_(double qx, double qz, double &h, double &dx, double &dz) const;
    void finite_jacobian_(double qx, double qz, double &ja, double &jb, double &jc, double &jd);

    void evaluate_true_batch_(const size_t *indices, size_t active_count);
    void evaluate_avx2_batch_(const size_t *indices, size_t active_count, bool vector_sincos,
                              bool compute_coastal_stencil = true,
                              double coastal_stencil_epsilon = 0.01,
                              bool displacement_only = false,
                              bool coastal_only = false,
                              int profile_stage = 0,
                              bool skip_base_spectrum = false);
    size_t sample_coastal_batch_(const size_t *indices, size_t active_count, int profile_stage = -1);
    void apply_coastal_batch_(const size_t *indices, size_t active_count, bool displacement_only = false, int profile_stage = -1);
    void build_sample_from_fields_(size_t point_index, bool converged, double *out) const;
    void solve_true_batch_(size_t n, double *out, bool append_solved_q);
    void solve_avx2_batch_(size_t n, double *out, bool vector_sincos, bool append_solved_q = false);

    // 5R.1E: batch sharpened (crest sharpening ON) — misma matemática del hotfix
    // scalar, vectorizada. solve_avx2_batch_sharpened_ es el análogo de
    // solve_avx2_batch_ con Jacobian finito sobre el displacement FINAL.
    void apply_crest_sharpen_batch_(const size_t *indices, size_t active_count, bool vector_sincos);
    void evaluate_center_sharpened_(const size_t *indices, size_t active_count, bool vector_sincos);
    void evaluate_offset_final_(const size_t *indices, size_t active_count, double ox, double oz, bool vector_sincos);
    void compute_finite_jacobian_batch_(const size_t *indices, size_t active_count, bool vector_sincos);
    void solve_avx2_batch_sharpened_(size_t n, double *out, bool vector_sincos);
};

} // namespace oq
