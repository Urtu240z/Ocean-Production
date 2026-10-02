#include "production_spectrum.h"
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <algorithm>
#include <cmath>
#include <vector>

namespace godot {
namespace {
constexpr double PI = 3.1415926535897932384626433832795;
constexpr double TAU = 2.0 * PI;
uint32_t hash_u32(uint32_t x) {
    x = (x ^ (x >> 16)) * 0x7feb352dU;
    x = (x ^ (x >> 15)) * 0x846ca68bU;
    return x ^ (x >> 16);
}
Vector2 gaussian(uint32_t seed, uint32_t index) {
    const uint32_t base = seed ^ (index * 0x9e3779b9U);
    const double u1 = std::max((hash_u32(base ^ 0x68bc21ebU) + 0.5) / 4294967296.0, 0.0000001);
    const double u2 = (hash_u32(base ^ 0x02e5be93U) + 0.5) / 4294967296.0;
    const double radius = std::sqrt(-2.0 * std::log(u1));
    return Vector2(radius * std::cos(TAU * u2), radius * std::sin(TAU * u2));
}
double smooth(double from, double to, double value) {
    const double t = std::max(0.0, std::min(1.0, (value - from) / (to - from)));
    return t * t * (3.0 - 2.0 * t);
}
}

Dictionary build_production_h0(const Dictionary &c, uint32_t seed) {
    const int n = c.get("resolution", 0);
    const double domain = c.get("domain_size_m", 0.0);
    if (n < 2 || n > 4096 || (n & (n - 1)) || !std::isfinite(domain) || domain <= 0.0) return {};
    const double g = c.get("gravity_mps2", 9.81);
    const double wind_speed = c.get("wind_speed_mps", 0.0);
    const double fetch = c.get("fetch_length_m", 1000.0);
    const double wavelength_scale = c.get("dominant_wavelength_scale", 1.0);
    const double alpha = c.get("jonswap_alpha", 0.0081);
    const double spread = c.get("jonswap_spread", 0.2);
    const double swell = c.get("swell", 0.5);
    const double detail = c.get("detail", 1.0);
    const double min_wave = c.get("min_wavelength_m", 4.0);
    const double max_wave = c.get("max_wavelength_m", 20.0);
    const double width = std::max(0.0001, static_cast<double>(c.get("transition_width_m", 0.75)));
    const Vector2 direction = c.get("wind_direction", Vector2(1, 0));
    const Vector2 wind = direction.normalized();
    for (double v : {g, wind_speed, fetch, wavelength_scale, alpha, spread, swell, detail, min_wave, max_wave, width})
        if (!std::isfinite(v)) return {};
    if (g <= 0.0 || wind_speed < 0.0 || max_wave < min_wave) return {};
    const double dk = TAU / domain;
    double peak = 22.0 * std::pow(g * g / (std::max(wind_speed, 0.1) * std::max(fetch, 1.0)), 1.0 / 3.0);
    peak /= std::sqrt(std::max(wavelength_scale, 0.0001));
    std::vector<Vector2> h0(static_cast<size_t>(n) * n);
    for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
        const size_t i = static_cast<size_t>(y) * n + x;
        const Vector2 k = Vector2(x - n * 0.5, y - n * 0.5) * dk;
        const double length = k.length();
        if (length <= 0.000001 || peak <= 0.000001) continue;
        const double omega = std::sqrt(g * length);
        const double ratio = omega / peak;
        const double sigma = omega <= peak ? 0.07 : 0.09;
        const double r = std::exp(-std::pow(omega - peak, 2.0) / (2.0 * sigma * sigma * peak * peak));
        const double spectrum = alpha * g * g / std::pow(omega, 5.0) *
            std::exp(-1.25 * std::pow(peak / omega, 4.0)) * std::pow(3.3, r);
        const double direction_s = omega <= peak ? 6.97 * std::pow(ratio, 4.06) :
            9.77 * std::pow(ratio, -2.33 - 1.45 * (wind_speed * peak / g - 1.17));
        const double total_s = direction_s + 16.0 * std::tanh(peak / omega) * swell * swell;
        const double theta = std::abs(static_cast<double>(k.normalized().angle_to(wind)));
        const double q = total_s < 0.4 ? 0.5 / PI + total_s * (0.220636 + total_s * (-0.109 + total_s * 0.090)) :
            (0.5 * std::sqrt(total_s) + 0.0625 / std::sqrt(total_s)) / std::sqrt(PI);
        const double hasselmann = q * std::pow(std::cos(theta * 0.5), 2.0 * total_s);
        const double mix = 1.0 - std::max(0.0, std::min(1.0, spread));
        const double directional = (1.0 / TAU) + (hasselmann - 1.0 / TAU) * mix;
        const double density = std::max(spectrum * directional * (g / (2.0 * omega) / length) *
            std::exp(-std::pow(1.0 - detail, 2.0) * length * length), 0.0);
        const double wavelength = TAU / length;
        const double weight = smooth(min_wave - width, min_wave + width, wavelength) *
            (1.0 - smooth(max_wave - width, max_wave + width, wavelength));
        const double amplitude = std::sqrt(density * 0.5) * dk * static_cast<double>(n * n) * weight;
        h0[i] = gaussian(seed, static_cast<uint32_t>(i)) * amplitude;
    }
    double energy = 0.0;
    for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
        const size_t i = static_cast<size_t>(y) * n + x;
        const auto opposite = h0[static_cast<size_t>((n - y) % n) * n + (n - x) % n];
        const Vector2 height = h0[i] + Vector2(opposite.x, -opposite.y);
        energy += height.length_squared();
    }
    const double measured = 4.0 * std::sqrt(energy / std::pow(static_cast<double>(n), 4.0));
    if (measured <= 0.0000001) for (auto &value : h0) value = Vector2();
    PackedFloat32Array packed; packed.resize(static_cast<int64_t>(n) * n * 4);
    auto *out = packed.ptrw();
    for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
        const size_t i = static_cast<size_t>(y) * n + x;
        const auto opposite = h0[static_cast<size_t>((n - y) % n) * n + (n - x) % n];
        out[4 * i] = h0[i].x; out[4 * i + 1] = h0[i].y;
        out[4 * i + 2] = opposite.x; out[4 * i + 3] = -opposite.y;
    }
    Dictionary result;
    result["h0_rgba32f"] = packed.to_byte_array();
    result["measured_hs_m"] = measured > 0.0000001 ? measured : 0.0;
    return result;
}
}
