#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <array>
#include <cstdint>
#include <vector>

namespace godot {

// Minimal point evaluator for the same centered H0 layout consumed by the
// Production FFT. It deliberately exposes only the P6 LONG+MID macro height.
class OceanMacroQueryNative : public RefCounted {
	GDCLASS(OceanMacroQueryNative, RefCounted)

	struct Cascade {
		int resolution = 0;
		double domain_m = 0.0;
		double gravity_mps2 = 9.81;
		std::vector<float> h0;
		bool valid() const { return resolution > 1 && domain_m > 0.0 && h0.size() == static_cast<size_t>(resolution * resolution * 4); }
	};

	std::array<Cascade, 2> cascades_;
	int64_t last_query_usec_ = 0;
	int64_t last_term_count_ = 0;

	static void _bind_methods();
	static double evaluate_cascade_(const Cascade &cascade, double world_x, double world_z, double simulation_time);

public:
	void clear();
	void set_cascade_h0(int cascade_index, int resolution, double domain_m, double gravity_mps2, const PackedByteArray &h0_rgba32f);
	bool is_ready() const;
	double sample_macro_height(double world_x, double world_z, double simulation_time);
	int64_t get_last_query_usec() const;
	int64_t get_last_term_count() const;
};

} // namespace godot
