#pragma once

#include "ocean_query_core.h"

namespace oq {

// Experimental subset of the authoritative lattice, never a replacement ocean.
// Budgets count lattice rows (a conjugate pair normally consumes two rows).
class HullSparseSpectrum {
public:
    std::array<std::vector<size_t>, 3> source_indices;
    std::array<double, 6> retained_variance_fraction{};
    double best_heave_omitted_rms_fraction = 1.0;
    bool configured = false;

    bool configure(const OceanQueryCore &source, const double *hull_xz, size_t points,
                   size_t budget, size_t minimum_per_band, OceanQueryCore &destination);
    // Fixed mode identities; only endpoint H0 and geometric coefficients blend.
    // No random generation, phase reset, allocation, or large bake copy here.
    bool blend(const OceanQueryCore &from, const OceanQueryCore &to, double alpha,
               OceanQueryCore &destination) const;
};

} // namespace oq
