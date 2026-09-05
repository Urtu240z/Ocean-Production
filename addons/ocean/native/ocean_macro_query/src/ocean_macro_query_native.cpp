#include "ocean_macro_query_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <chrono>
#include <cmath>
#include <cstring>

using namespace godot;

namespace {
constexpr double TAU_D = 6.28318530717958647692;
}

void OceanMacroQueryNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("clear"), &OceanMacroQueryNative::clear);
	ClassDB::bind_method(D_METHOD("set_cascade_h0", "cascade_index", "resolution", "domain_m", "gravity_mps2", "h0_rgba32f"), &OceanMacroQueryNative::set_cascade_h0);
	ClassDB::bind_method(D_METHOD("is_ready"), &OceanMacroQueryNative::is_ready);
	ClassDB::bind_method(D_METHOD("sample_macro_height", "world_x", "world_z", "simulation_time"), &OceanMacroQueryNative::sample_macro_height);
	ClassDB::bind_method(D_METHOD("get_last_query_usec"), &OceanMacroQueryNative::get_last_query_usec);
	ClassDB::bind_method(D_METHOD("get_last_term_count"), &OceanMacroQueryNative::get_last_term_count);
}

void OceanMacroQueryNative::clear() {
	for (Cascade &cascade : cascades_) {
		cascade = Cascade{};
	}
	last_query_usec_ = 0;
	last_term_count_ = 0;
}

void OceanMacroQueryNative::set_cascade_h0(int cascade_index, int resolution, double domain_m, double gravity_mps2, const PackedByteArray &h0_rgba32f) {
	if (cascade_index < 0 || cascade_index >= static_cast<int>(cascades_.size())) {
		UtilityFunctions::push_error("Ocean macro query: invalid cascade index.");
		return;
	}
	Cascade next;
	next.resolution = resolution;
	next.domain_m = domain_m;
	next.gravity_mps2 = gravity_mps2;
	const size_t expected_bytes = static_cast<size_t>(resolution) * static_cast<size_t>(resolution) * 4 * sizeof(float);
	if (resolution <= 1 || domain_m <= 0.0 || h0_rgba32f.size() != static_cast<int64_t>(expected_bytes)) {
		UtilityFunctions::push_error("Ocean macro query: invalid H0 payload.");
		cascades_[cascade_index] = Cascade{};
		return;
	}
	next.h0.resize(expected_bytes / sizeof(float));
	std::memcpy(next.h0.data(), h0_rgba32f.ptr(), expected_bytes);
	cascades_[cascade_index] = std::move(next);
}

bool OceanMacroQueryNative::is_ready() const {
	return cascades_[0].valid() && cascades_[1].valid();
}

double OceanMacroQueryNative::evaluate_cascade_(const Cascade &cascade, double world_x, double world_z, double simulation_time) {
	const int n = cascade.resolution;
	const double delta_k = TAU_D / cascade.domain_m;
	const int half_n = n / 2;
	double sum = 0.0;
	for (int y = 0; y < n; ++y) {
		const double kz = static_cast<double>(y - half_n) * delta_k;
		for (int x = 0; x < n; ++x) {
			const int index = y * n + x;
			const int opposite = ((n - y) % n) * n + ((n - x) % n);
			// H(-k,t) is the conjugate of H(k,t), exactly as packed by the
			// shared H0 builder. Evaluate each Hermitian pair only once.
			if (index > opposite) {
				continue;
			}
			const double kx = static_cast<double>(x - half_n) * delta_k;
			const double omega = std::sqrt(cascade.gravity_mps2 * std::sqrt(kx * kx + kz * kz));
			const double phase = -omega * simulation_time;
			const double c = std::cos(phase);
			const double s = std::sin(phase);
			const size_t base = static_cast<size_t>(index * 4);
			// Same h(k,t) reconstruction as evolve_spectrum.glsl.
			const double height_re = cascade.h0[base] * c - cascade.h0[base + 1] * s + cascade.h0[base + 2] * c + cascade.h0[base + 3] * s;
			const double height_im = cascade.h0[base] * s + cascade.h0[base + 1] * c - cascade.h0[base + 2] * s + cascade.h0[base + 3] * c;
			const double spatial_phase = kx * world_x + kz * world_z;
			const double pair_scale = index == opposite ? 1.0 : 2.0;
			sum += pair_scale * (height_re * std::cos(spatial_phase) - height_im * std::sin(spatial_phase));
		}
	}
	return sum / static_cast<double>(n * n);
}

double OceanMacroQueryNative::sample_macro_height(double world_x, double world_z, double simulation_time) {
	if (!is_ready() || !std::isfinite(world_x) || !std::isfinite(world_z) || !std::isfinite(simulation_time)) {
		return 0.0;
	}
	const auto start = std::chrono::steady_clock::now();
	const double height = evaluate_cascade_(cascades_[0], world_x, world_z, simulation_time) + evaluate_cascade_(cascades_[1], world_x, world_z, simulation_time);
	last_query_usec_ = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count();
	last_term_count_ = static_cast<int64_t>(cascades_[0].resolution) * cascades_[0].resolution + static_cast<int64_t>(cascades_[1].resolution) * cascades_[1].resolution;
	return height;
}

int64_t OceanMacroQueryNative::get_last_query_usec() const {
	return last_query_usec_;
}

int64_t OceanMacroQueryNative::get_last_term_count() const {
	return last_term_count_;
}
