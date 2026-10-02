#pragma once
#include <godot_cpp/variant/dictionary.hpp>
#include <cstdint>
namespace godot {
// Exact equation port of jonswap_hasselmann_spectrum.gd, including its
// float32 Vector2/lattice storage boundaries. Optional weather producer only.
Dictionary build_production_h0(const Dictionary &config, uint32_t seed);
}
