#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector4.hpp>
#include <array>

namespace godot {
// Per-hull geometry only. No scene, water provider, forces, threads or FFT state.
class HullBuoyancyGeometryNative : public RefCounted {
    GDCLASS(HullBuoyancyGeometryNative, RefCounted);
    PackedVector3Array vertices_;
    std::array<int32_t, 13> offsets_{};
    std::array<Vector3, 12> centers_{};
    int cell_count_ = 0;
    bool profiling_ = false;
    std::array<int64_t, 3> profile_ns_{};
    static Vector4 tetra_moment_(const Vector3 &, const Vector3 &, const Vector3 &, const Vector3 &);
    static Vector3 intersection_(const Vector3 &, const Vector3 &, const Vector3 &, double);
    static Vector4 submerged_(const Vector3 &, const Vector3 &, const Vector3 &, const Vector3 &, const Vector3 &, double);
protected:
    static void _bind_methods();
public:
    // Geometry is uploaded once; PackedArray COW retains an immutable snapshot.
    bool configure_geometry(const PackedVector3Array &, const PackedInt32Array &, const PackedVector3Array &);
    // Per cell: valid, volume, world center xyz, max depth, local first moment xyzw.
    PackedFloat64Array integrate_cells(const Transform3D &, const PackedVector3Array &,
            const PackedVector3Array &, const PackedByteArray &, double);
    void set_profiling_enabled(bool enabled) { profiling_ = enabled; }
    PackedInt64Array get_last_profile() const;
};
}
