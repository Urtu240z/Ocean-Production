#pragma once

#include <algorithm>

namespace oq {
// Authored cell spacing is extent/(resolution-1), not hardware sampler spacing.
// PHYS-OPT-2I: measured smallest successful width, mirrored by shader/GDScript.
constexpr double COASTAL_COVERAGE_FEATHER_TEXELS = 1.0;

inline double coastal_coverage_edge_weight(double u, double v, int width, int height,
        double feather_texels = COASTAL_COVERAGE_FEATHER_TEXELS) {
    if (u < 0.0 || v < 0.0 || u > 1.0 || v > 1.0 || width < 2 || height < 2) return 0.0;
    if (feather_texels <= 0.0) return 1.0; // Explicit old-contract diagnostic only.
    const double cells = std::min(std::min(u, 1.0 - u) * (width - 1),
                                  std::min(v, 1.0 - v) * (height - 1));
    const double t = std::max(0.0, std::min(1.0, cells / feather_texels));
    return t * t * (3.0 - 2.0 * t);
}
} // namespace oq
