#pragma once

#include "ocean_query_core.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace oq {

// Caller-owned row. The first S_STRIDE values preserve the physical sample
// contract. Reuse this complete row for that contact's next query; clear VALID
// on loss/teleport/re-entry. No contact IDs or histories live in the ocean.
enum ContactSlot {
    C_QX = S_STRIDE, C_QZ, C_STATUS, C_WORLD_X, C_WORLD_Z, C_TIME,
    C_CONFIG, C_GENERATION, C_RADIUS, C_Q_DELTA, C_DET, C_PATH_STEPS,
    C_STRIDE
};
enum ContactStatus { CONTINUED = 0, REACQUIRED_LOCAL = 1,
    REACQUIRED_GLOBAL = 2, FAILED = 3 };

// The unknown is an UNWRAPPED material coordinate. Only the field sampler
// wraps each band's FFT coordinates. Different band periods and a nonperiodic
// Coastal bake make wrapping the common q by a single band's L incorrect.
// Sample and cold are stack callbacks, with one pinned snapshot for the batch.
template<class Sample, class LightSample, class Cold>
void continue_contact(double wx, double wz, const double *previous,
        double lattice, double time, double version, double generation,
        Sample sample, LightSample light_sample, Cold cold, double *out) {
    std::fill(out, out + C_STRIDE, 0.0);
    out[C_STATUS] = FAILED;
    out[S_RESIDUAL] = std::numeric_limits<double>::infinity();
    out[C_WORLD_X] = wx; out[C_WORLD_Z] = wz;
    out[C_TIME] = time; out[C_CONFIG] = version; out[C_GENERATION] = generation;
    if (!std::isfinite(wx) || !std::isfinite(wz)) return;
    const bool history = previous && previous[S_VALID] > 0.5 &&
        std::isfinite(previous[C_QX]) && std::isfinite(previous[C_QZ]) &&
        std::isfinite(previous[C_WORLD_X]) && std::isfinite(previous[C_WORLD_Z]) &&
        time >= previous[C_TIME];
    int work = 0, steps = 0;
    const double cell_step = lattice * 0.5;
    double anchor_x = history ? previous[C_QX] : wx;
    double anchor_z = history ? previous[C_QZ] : wz;
    double predictor_x = anchor_x, predictor_z = anchor_z;
    double radius = lattice;
    double target_motion = 0.0;
    double orientation = history ? previous[C_DET] : 0.0;
    auto jacobian = [&](double x, double z, double *j) {
        // Use the final surface's existing 1 cm physical derivative contract
        // for local sheet tracking. The legacy cold/world 5 cm solver stays
        // unchanged. A 5 cm derivative can straddle BOTH sides of a narrow
        // Coastal fold and is unsuitable as its local continuation tangent.
        constexpr double e = 0.01;
        double p[S_STRIDE], m[S_STRIDE];
        light_sample(x + e, z, p); light_sample(x - e, z, m);
        j[0] = 1.0 + (p[S_DX] - m[S_DX]) / (2.0 * e);
        j[2] = (p[S_DZ] - m[S_DZ]) / (2.0 * e);
        light_sample(x, z + e, p); light_sample(x, z - e, m);
        j[1] = (p[S_DX] - m[S_DX]) / (2.0 * e);
        j[3] = 1.0 + (p[S_DZ] - m[S_DZ]) / (2.0 * e);
    };
    if (history) {
        double a[S_STRIDE], j[4]; sample(anchor_x, anchor_z, a);
        const double residual = std::hypot(anchor_x + a[S_DX] - wx, anchor_z + a[S_DZ] - wz);
        if (a[S_VALID] > 0.5 && a[S_JACOBIAN_DET] * orientation > 0.0 && residual <= POSITION_TOLERANCE_M) {
            std::copy(a, a + S_STRIDE, out);
            out[S_RESIDUAL] = residual; out[S_ITERATIONS] = 1;
            out[C_QX] = anchor_x; out[C_QZ] = anchor_z;
            out[C_STATUS] = CONTINUED; out[C_DET] = a[S_JACOBIAN_DET];
            out[C_RADIUS] = lattice; return;
        }
        jacobian(anchor_x, anchor_z, j);
        const double det = j[0] * j[3] - j[1] * j[2];
        const double rx = wx - anchor_x - a[S_DX];
        const double rz = wz - anchor_z - a[S_DZ];
        if (std::isfinite(det) && std::abs(det) >= 1e-6) {
            predictor_x += (j[3] * rx - j[1] * rz) / det;
            predictor_z += (-j[2] * rx + j[0] * rz) / det;
        }
        // Measured current surface change (including weather), target motion,
        // and a lattice cell establish the search radius; fast motion expands
        // it. Near a singularity the search is bounded by the local history,
        // and a failed continuation is explicitly a reacquisition.
        const double motion = std::hypot(wx - previous[C_WORLD_X], wz - previous[C_WORLD_Z]);
        target_motion = motion;
        radius = 2.0 * (std::hypot(predictor_x - anchor_x, predictor_z - anchor_z) + motion + lattice);
    }
    out[C_RADIUS] = radius;
    auto solve_local = [&](double x, double z, double *result, bool connected) {
        double a[S_STRIDE], j[4];
        const int limit = connected ? 12 + static_cast<int>(std::min(52.0, std::ceil(target_motion / cell_step))) : 12;
        for (int it = 0; it < limit; ++it) {
            ++work; sample(x, z, a);
            const double rx = x + a[S_DX] - wx, rz = z + a[S_DZ] - wz;
            const double residual = std::hypot(rx, rz);
            if (a[S_VALID] < 0.5 || !std::isfinite(residual)) return false;
            if (connected && a[S_JACOBIAN_DET] * orientation <= 0.0) return false;
            if (residual <= POSITION_TOLERANCE_M) {
                std::copy(a, a + S_STRIDE, result);
                result[S_RESIDUAL] = residual; result[C_QX] = x; result[C_QZ] = z;
                result[C_DET] = a[S_JACOBIAN_DET]; return true;
            }
            jacobian(x, z, j);
            const double det = j[0] * j[3] - j[1] * j[2];
            if (!std::isfinite(det) || std::abs(det) < 1e-6) return false;
            double dx = (j[3] * rx - j[1] * rz) / det;
            double dz = (-j[2] * rx + j[0] * rz) / det;
            const double length = std::hypot(dx, dz);
            if (!std::isfinite(length)) return false;
            // Trust steps traverse at most half the smallest active lattice
            // cell. A midpoint orientation test prevents crossing a fold and
            // silently calling the alternate sheet a continuation.
            double scale = length > cell_step ? cell_step / length : 1.0;
            bool accepted = false;
            for (int trial = 0; trial < 10; ++trial, scale *= 0.5) {
                const double tx = x - dx * scale, tz = z - dz * scale;
                if (std::hypot(tx - anchor_x, tz - anchor_z) > radius) continue;
                double b[S_STRIDE]; sample(tx, tz, b);
                if (std::hypot(tx + b[S_DX] - wx, tz + b[S_DZ] - wz) >= residual) continue;
                if (connected && b[S_JACOBIAN_DET] * orientation <= 0.0) continue;
                if (connected) {
                    double mid[S_STRIDE]; sample((tx + x) * 0.5, (tz + z) * 0.5, mid);
                    if (mid[S_JACOBIAN_DET] * orientation <= 0.0) continue;
                }
                x = tx; z = tz; ++steps; accepted = true; break;
            }
            if (!accepted) return false;
        }
        return false;
    };
    double chosen[C_STRIDE] = {};
    int status = FAILED;
    if (history && solve_local(anchor_x, anchor_z, chosen, true)) status = CONTINUED;
    if (history && status == FAILED) {
        // Fixed bounded candidates, ordered deterministically. Try prediction
        // and two concentric eight-direction rings, never a per-contact heap.
        constexpr double d = 0.7071067811865475244;
        constexpr double directions[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{d,d},{d,-d},{-d,d},{-d,-d}};
        double best = std::numeric_limits<double>::infinity();
        auto candidate = [&](double x, double z) {
            if (std::hypot(x - anchor_x, z - anchor_z) > radius) return;
            double r[C_STRIDE] = {};
            if (!solve_local(x, z, r, false)) return;
            const double score = std::hypot(r[C_QX] - anchor_x, r[C_QZ] - anchor_z) +
                0.25 * std::hypot(r[C_QX] - predictor_x, r[C_QZ] - predictor_z);
            if (score < best || (score == best && r[S_RESIDUAL] < chosen[S_RESIDUAL])) {
                best = score; std::copy(r, r + C_STRIDE, chosen); status = REACQUIRED_LOCAL;
            }
        };
        candidate(anchor_x, anchor_z);
        // An unchanged q minimizes |q-anchor| + .25*|q-predictor| globally
        // by the triangle inequality. No other seed can improve it. This is
        // common when only orientation changes through a weather singularity.
        if (status != REACQUIRED_LOCAL || chosen[C_QX] != anchor_x || chosen[C_QZ] != anchor_z) {
            candidate(predictor_x, predictor_z);
            for (double fraction : {0.25, 0.5}) for (const auto &dir : directions)
                candidate(anchor_x + radius * fraction * dir[0], anchor_z + radius * fraction * dir[1]);
        }
    }
    if (status == FAILED) {
        double r[S_STRIDE + 2] = {}; cold(wx, wz, r);
        work += static_cast<int>(r[S_ITERATIONS]);
        if (r[S_VALID] > 0.5 && std::isfinite(r[S_RESIDUAL])) {
            std::copy(r, r + S_STRIDE + 2, chosen);
            chosen[C_DET] = r[S_JACOBIAN_DET]; status = REACQUIRED_GLOBAL;
        } else {
            out[S_RESIDUAL] = r[S_RESIDUAL]; out[S_ITERATIONS] = work;
            return;
        }
    }
    std::copy(chosen, chosen + S_STRIDE + 2, out);
    out[C_STATUS] = status; out[C_DET] = chosen[C_DET];
    out[C_Q_DELTA] = history ? std::hypot(out[C_QX] - anchor_x, out[C_QZ] - anchor_z) : 0.0;
    out[C_PATH_STEPS] = steps; out[S_ITERATIONS] = work;
}
} // namespace oq
