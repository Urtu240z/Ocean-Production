#include "hull_buoyancy_geometry_native.h"
#include <godot_cpp/core/class_db.hpp>
#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;
namespace { constexpr double VOLUME_EPSILON = 0.000000001; constexpr int ROW = 10; }

void HullBuoyancyGeometryNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure_geometry", "vertices", "cell_offsets", "local_centers"), &HullBuoyancyGeometryNative::configure_geometry);
    ClassDB::bind_method(D_METHOD("integrate_cells", "transform", "surface_positions", "normals", "valid", "draft_offset"), &HullBuoyancyGeometryNative::integrate_cells);
}

bool HullBuoyancyGeometryNative::configure_geometry(const PackedVector3Array &vertices,
        const PackedInt32Array &offsets, const PackedVector3Array &centers) {
    cell_count_ = 0;
    vertices_ = PackedVector3Array();
    const auto n = centers.size();
    if (n < 1 || n > 12 || offsets.size() != n + 1 || offsets[0] != 0 || offsets[n] != vertices.size()) return false;
    for (int i = 0; i < n; ++i) {
        if (offsets[i + 1] <= offsets[i] || (offsets[i + 1] - offsets[i]) % 4 != 0 || !centers[i].is_finite()) return false;
    }
    for (int i = 0; i < vertices.size(); ++i) if (!vertices[i].is_finite()) return false;
    vertices_ = vertices;
    for (int i = 0; i <= n; ++i) offsets_[i] = offsets[i];
    for (int i = 0; i < n; ++i) centers_[i] = centers[i];
    cell_count_ = static_cast<int>(n);
    return true;
}

Vector4 HullBuoyancyGeometryNative::tetra_moment_(const Vector3 &a, const Vector3 &b,
        const Vector3 &c, const Vector3 &d) {
    // GDScript float is double; Vector3/Vector4 retain Godot real_t storage.
    // Keep every intermediate vector and the original addition order.
    const double volume = std::abs(static_cast<double>((b - a).dot((c - a).cross(d - a)))) / 6.0;
    const Vector3 first = (a + b + c + d) * static_cast<real_t>(volume * 0.25);
    return Vector4(first.x, first.y, first.z, static_cast<real_t>(volume));
}

Vector3 HullBuoyancyGeometryNative::intersection_(const Vector3 &a, const Vector3 &b,
        const Vector3 &normal, double plane_d) {
    const double depth_a = plane_d - static_cast<double>(normal.dot(a));
    const double depth_b = plane_d - static_cast<double>(normal.dot(b));
    return a.lerp(b, static_cast<real_t>(depth_a / (depth_a - depth_b)));
}

Vector4 HullBuoyancyGeometryNative::submerged_(const Vector3 &a, const Vector3 &b,
        const Vector3 &c, const Vector3 &d, const Vector3 &normal, double plane_d) {
    std::array<Vector3, 4> wet, dry;
    int w = 0, r = 0;
    const std::array<Vector3, 4> vertices{a, b, c, d};
    for (const auto &vertex : vertices) {
        if (static_cast<double>(normal.dot(vertex)) <= plane_d) wet[w++] = vertex;
        else dry[r++] = vertex;
    }
    switch (w) {
        case 0: return Vector4();
        case 4: return tetra_moment_(a, b, c, d);
        case 1: return tetra_moment_(wet[0], intersection_(wet[0], dry[0], normal, plane_d),
                intersection_(wet[0], dry[1], normal, plane_d), intersection_(wet[0], dry[2], normal, plane_d));
        case 3: return tetra_moment_(a, b, c, d) - tetra_moment_(dry[0],
                intersection_(dry[0], wet[0], normal, plane_d), intersection_(dry[0], wet[1], normal, plane_d),
                intersection_(dry[0], wet[2], normal, plane_d));
        case 2: {
            const Vector3 p = intersection_(wet[0], dry[0], normal, plane_d);
            const Vector3 q = intersection_(wet[0], dry[1], normal, plane_d);
            const Vector3 rr = intersection_(wet[1], dry[0], normal, plane_d);
            const Vector3 s = intersection_(wet[1], dry[1], normal, plane_d);
            return tetra_moment_(wet[0], p, q, wet[1]) + tetra_moment_(p, q, wet[1], rr) + tetra_moment_(q, wet[1], rr, s);
        }
    }
    return Vector4();
}

PackedFloat64Array HullBuoyancyGeometryNative::integrate_cells(const Transform3D &transform,
        const PackedVector3Array &surfaces, const PackedVector3Array &normals,
        const PackedByteArray &valid, double draft) {
    PackedFloat64Array result;
    if (!cell_count_ || surfaces.size() != cell_count_ || normals.size() != cell_count_ || valid.size() != cell_count_ || !std::isfinite(draft)) return result;
    result.resize(cell_count_ * ROW);
    result.fill(0.0);
    auto *out = result.ptrw();
    const auto *vertices = vertices_.ptr();
    for (int i = 0; i < cell_count_; ++i) {
        if (!valid[i] || !surfaces[i].is_finite() || !normals[i].is_finite() || normals[i].length_squared() < 0.000001) continue;
        const Vector3 normal = normals[i].normalized();
        // Intentionally preserve integrate_cell's per-cell transform operations.
        const Vector3 local_normal = transform.basis.transposed().xform(normal);
        const Vector3 local_surface = transform.affine_inverse().xform(surfaces[i]);
        const double raw_plane_d = static_cast<double>(local_normal.dot(local_surface));
        const double support_plane_d = raw_plane_d - static_cast<double>(normal.y) * draft;
        Vector4 moment;
        double depth = -std::numeric_limits<double>::infinity();
        const double denominator = std::max(static_cast<double>(normal.y), 0.05);
        for (int j = offsets_[i]; j < offsets_[i + 1]; ++j) {
            depth = std::max(depth, (raw_plane_d - static_cast<double>(local_normal.dot(vertices[j]))) / denominator);
        }
        for (int j = offsets_[i]; j < offsets_[i + 1]; j += 4) {
            moment += submerged_(vertices[j], vertices[j + 1], vertices[j + 2], vertices[j + 3], local_normal, support_plane_d);
        }
        Vector3 center = centers_[i];
        if (static_cast<double>(moment.w) > VOLUME_EPSILON) center = Vector3(moment.x, moment.y, moment.z) / moment.w;
        center = transform.xform(center);
        if (!center.is_finite() || !moment.is_finite() || !std::isfinite(depth)) continue;
        const int row = i * ROW;
        out[row] = 1.0; out[row + 1] = moment.w;
        out[row + 2] = center.x; out[row + 3] = center.y; out[row + 4] = center.z;
        out[row + 5] = depth;
        out[row + 6] = moment.x; out[row + 7] = moment.y; out[row + 8] = moment.z; out[row + 9] = moment.w;
    }
    return result;
}
