#include "hull_sparse_spectrum.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <numeric>

namespace oq {
namespace {
struct Group {
    size_t band, first, second, cost;
    std::array<double, 6> variance{};
    double score = 0.0;
    bool selected = false;
};

void copy_selected(const Cascade &source, const std::vector<size_t> &ids, Cascade &dest) {
    dest.inv_n2 = source.inv_n2; // Never renormalize the retained energy.
    dest.material_domain_m = source.material_domain_m;
    dest.material_resolution = source.material_resolution;
#define SELECT(member) dest.member.resize(ids.size()); for (size_t j = 0; j < ids.size(); ++j) dest.member[j] = source.member[ids[j]];
    SELECT(kx) SELECT(ky) SELECT(omega) SELECT(a1) SELECT(a2)
    SELECT(c11) SELECT(c12) SELECT(c21) SELECT(c22)
    SELECT(parity) SELECT(weight) SELECT(h0_re) SELECT(h0_im) SELECT(h0n_re) SELECT(h0n_im)
    SELECT(stencil_x_cos) SELECT(stencil_x_sin) SELECT(stencil_z_cos) SELECT(stencil_z_sin)
#undef SELECT
    // Irregular retained indices must not use the full-lattice phase recurrence.
    dest.regular_frequency_grid = false;
    dest.separable_frequency_grid = false;
}
}

bool HullSparseSpectrum::configure(const OceanQueryCore &source, const double *hull_xz,
                                  size_t points, size_t budget, size_t minimum_per_band,
                                  OceanQueryCore &destination) {
    configured = false;
    if (&source == &destination || source.cascades.size() != 3 || points < 3 || budget < 2) return false;
    double cx = 0.0, cz = 0.0, sx = 0.0, sz = 0.0;
    for (size_t j = 0; j < points; ++j) {
        if (!std::isfinite(hull_xz[2*j]) || !std::isfinite(hull_xz[2*j+1])) return false;
        cx += hull_xz[2*j]; cz += hull_xz[2*j+1];
    }
    cx /= points; cz /= points;
    for (size_t j = 0; j < points; ++j) { sx += std::abs(hull_xz[2*j]-cx); sz += std::abs(hull_xz[2*j+1]-cz); }
    if (sx == 0.0 || sz == 0.0) return false;
    std::vector<Group> groups;
    std::array<double, 6> total{};
    for (size_t b = 0; b < 3; ++b) {
        const auto &c = source.cascades[b];
        const size_t n = static_cast<size_t>(c.material_resolution);
        if (n < 2 || c.kx.size() != n*n) return false;
        for (size_t i = 0; i < n*n; ++i) {
            const size_t opposite = ((n-i/n)%n)*n + ((n-i%n)%n);
            if (opposite < i) continue;
            Group g{}; g.band = b; g.first = i; g.second = opposite; g.cost = i == opposite ? 1 : 2;
            // Average over 16 hull headings: ranking cannot silently depend on
            // one boat heading. Pitch/roll weights have unit L1 norm, as heave.
            std::array<double, 3> response{};
            for (int heading = 0; heading < 16; ++heading) {
                const double yaw = heading * (2.0*3.14159265358979323846/16.0);
                const double cy = std::cos(yaw), sy = std::sin(yaw);
                std::array<std::complex<double>, 3> r{};
                for (size_t j = 0; j < points; ++j) {
                    const double x = hull_xz[2*j]-cx, z = hull_xz[2*j+1]-cz;
                    const double phase = c.kx[i]*(cy*x-sy*z)+c.ky[i]*(sy*x+cy*z);
                    const std::complex<double> e(std::cos(phase), std::sin(phase));
                    r[0] += e/static_cast<double>(points);
                    r[1] += e*(z/sz); r[2] += e*(x/sx);
                }
                for (int a = 0; a < 3; ++a) response[a] += std::norm(r[a])/16.0;
            }
            double energy = 0.0;
            for (size_t row : {i, opposite}) {
                const double sig = c.parity[row]*c.weight[row]*c.inv_n2;
                energy += sig*sig*(c.h0_re[row]*c.h0_re[row]+c.h0_im[row]*c.h0_im[row]+c.h0n_re[row]*c.h0n_re[row]+c.h0n_im[row]*c.h0n_im[row]);
                if (i == opposite) break;
            }
            for (int a = 0; a < 3; ++a) {
                g.variance[a] = energy*response[a];
                g.variance[a+3] = g.variance[a]*c.omega[i]*c.omega[i];
            }
            for (int a = 0; a < 6; ++a) total[a] += g.variance[a];
            groups.push_back(g);
        }
    }
    for (auto &g : groups) for (int a = 0; a < 6; ++a) {
        if (total[a] > 0.0) g.score += g.variance[a]/total[a];
    }
    std::stable_sort(groups.begin(), groups.end(), [](const Group &a, const Group &b) { return a.score/a.cost > b.score/b.cost; });
    size_t remaining = budget;
    std::array<size_t, 3> selected_count{};
    if (minimum_per_band*3 > budget) return false;
    for (size_t b = 0; b < 3; ++b) for (auto &g : groups) {
        if (g.band != b || selected_count[b] >= minimum_per_band) continue;
        if (g.cost <= remaining) { g.selected = true; remaining -= g.cost; selected_count[b] += g.cost; }
    }
    for (auto &g : groups) if (!g.selected && g.cost <= remaining) { g.selected = true; remaining -= g.cost; }
    for (auto &ids : source_indices) ids.clear();
    std::array<double, 6> retained{};
    for (const auto &g : groups) if (g.selected) {
        source_indices[g.band].push_back(g.first);
        if (g.second != g.first) source_indices[g.band].push_back(g.second);
        for (int a = 0; a < 6; ++a) retained[a] += g.variance[a];
    }
    for (int a = 0; a < 6; ++a) retained_variance_fraction[a] = total[a] > 0.0 ? retained[a]/total[a] : 1.0;
    // An optimistic heave-only selection is an independent lower-bound
    // diagnostic; it ignores pitch, roll, velocity, and band quotas.
    std::stable_sort(groups.begin(), groups.end(), [](const Group &a, const Group &b) { return a.variance[0]/a.cost > b.variance[0]/b.cost; });
    double best = 0.0; remaining = budget;
    for (const auto &g : groups) if (g.cost <= remaining) { best += g.variance[0]; remaining -= g.cost; }
    best_heave_omitted_rms_fraction = total[0] > 0.0 ? std::sqrt(std::max(0.0, 1.0-best/total[0])) : 0.0;
    destination.clear(); destination.sea_level = source.sea_level;
    destination.coastal = source.coastal; // Configuration only; never per tick.
    destination.cascades.resize(3);
    for (size_t b = 0; b < 3; ++b) {
        auto &ids = source_indices[b]; std::sort(ids.begin(), ids.end());
        copy_selected(source.cascades[b], ids, destination.cascades[b]);
    }
    destination.finalize_spectrum();
    configured = true;
    return true;
}

bool HullSparseSpectrum::blend(const OceanQueryCore &from, const OceanQueryCore &to,
                              double alpha, OceanQueryCore &destination) const {
    if (!configured || !std::isfinite(alpha) || from.cascades.size() != 3 || to.cascades.size() != 3 || &destination == &from || &destination == &to) return false;
    alpha = std::clamp(alpha, 0.0, 1.0);
    // Validate before changing any band. Configurations must share the lattice.
    for (size_t b = 0; b < 3; ++b) {
        const auto &a = from.cascades[b]; const auto &z = to.cascades[b];
        if (a.material_resolution != z.material_resolution || a.material_domain_m != z.material_domain_m || a.kx.size() != z.kx.size()) return false;
        for (size_t i : source_indices[b]) if (i >= a.kx.size() || a.kx[i] != z.kx[i] || a.ky[i] != z.ky[i] || a.omega[i] != z.omega[i]) return false;
    }
    for (size_t b = 0; b < 3; ++b) {
        const auto &a = from.cascades[b]; const auto &z = to.cascades[b]; auto &d = destination.cascades[b];
        for (size_t j = 0; j < source_indices[b].size(); ++j) {
            const size_t i = source_indices[b][j];
#define BLEND(member) d.member[j] = a.member[i]+alpha*(z.member[i]-a.member[i]);
            BLEND(h0_re) BLEND(h0_im) BLEND(h0n_re) BLEND(h0n_im)
            BLEND(a1) BLEND(a2) BLEND(c11) BLEND(c12) BLEND(c21) BLEND(c22)
#undef BLEND
        }
    }
    destination.prepared_valid = false; destination.prepared_band_mask = 0; destination.breaker_prepared_valid = false;
    return true;
}
} // namespace oq
