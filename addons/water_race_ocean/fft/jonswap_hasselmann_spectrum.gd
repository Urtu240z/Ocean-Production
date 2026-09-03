class_name JonswapHasselmannSpectrum
extends RefCounted
## Generador H0 determinista. Es la ruta espectral única de Production.

const UINT_MASK := 0xffffffff
const UINT_SCALE := 1.0 / 4294967296.0


static func build_h0_rgba32f(config: Resource, simulation_seed: int) -> PackedByteArray:
	assert(config.is_valid())
	var n: int = config.resolution
	var h0 := PackedVector2Array()
	h0.resize(n * n)
	var delta_k: float = TAU / config.domain_size_m
	var wind: Vector2 = config.wind_direction.normalized()
	var total_energy := 0.0
	for y in n:
		for x in n:
			var index: int = y * n + x
			var k: Vector2 = Vector2(float(x) - float(n) * 0.5, float(y) - float(n) * 0.5) * delta_k
			var k_length: float = k.length()
			if k_length <= 0.000001 or config.target_hs_m <= 0.0:
				h0[index] = Vector2.ZERO
				continue
			var wavelength: float = TAU / k_length
			var density := _jonswap_hasselmann_density(config, k_length, k.normalized(), wind)
			var amplitude: float = sqrt(maxf(density, 0.0) * 0.5) * delta_k * float(n * n) * _band_weight(wavelength, config)
			h0[index] = _gaussian_pair(simulation_seed, index) * amplitude
			total_energy += h0[index].length_squared()
	var measured := estimate_hs(h0, n)
	var scale: float = 0.0 if measured <= 0.0000001 else config.target_hs_m / measured
	for index in h0.size():
		h0[index] *= scale
	config.measured_hs_m = estimate_hs(h0, n)
	return _pack_h0(h0, n)


static func derive_cascade_seed(simulation_seed: int, cascade_id: StringName) -> int:
	var value := (simulation_seed & UINT_MASK) ^ 0x811c9dc5
	for byte in String(cascade_id).to_utf8_buffer():
		value = ((value ^ byte) * 0x01000193) & UINT_MASK
	return _hash_u32(value)


static func estimate_hs(h0: PackedVector2Array, resolution: int) -> float:
	var energy := 0.0
	for y in resolution:
		for x in resolution:
			var index := y * resolution + x
			var opposite := ((resolution - y) % resolution) * resolution + ((resolution - x) % resolution)
			var height := h0[index] + Vector2(h0[opposite].x, -h0[opposite].y)
			energy += height.length_squared()
	return 4.0 * sqrt(energy / pow(float(resolution), 4.0))


static func _jonswap_hasselmann_density(config: Resource, k_length: float, k_hat: Vector2, wind: Vector2) -> float:
	var g: float = config.gravity_mps2
	var omega: float = sqrt(g * k_length)
	var peak: float = 22.0 * pow(g * g / (maxf(config.wind_speed_mps, 0.1) * maxf(config.fetch_length_m, 1.0)), 1.0 / 3.0)
	if peak <= 0.000001:
		return 0.0
	var ratio: float = omega / peak
	var sigma: float = 0.07 if omega <= peak else 0.09
	var r: float = exp(-pow(omega - peak, 2.0) / (2.0 * sigma * sigma * peak * peak))
	var spectrum: float = config.jonswap_alpha * g * g / pow(omega, 5.0) * exp(-1.25 * pow(peak / omega, 4.0)) * pow(3.3, r)
	var direction_s: float = 6.97 * pow(ratio, 4.06) if omega <= peak else 9.77 * pow(ratio, -2.33 - 1.45 * (config.wind_speed_mps * peak / g - 1.17))
	var total_s: float = direction_s + 16.0 * tanh(peak / omega) * config.swell * config.swell
	var theta: float = absf(k_hat.angle_to(wind))
	var q: float = 0.5 / PI + total_s * (0.220636 + total_s * (-0.109 + total_s * 0.090)) if total_s < 0.4 else (0.5 * sqrt(total_s) + 0.0625 / sqrt(total_s)) / sqrt(PI)
	var hasselmann: float = q * pow(cos(theta * 0.5), 2.0 * total_s)
	var directional: float = lerpf(1.0 / TAU, hasselmann, 1.0 - clampf(config.jonswap_spread, 0.0, 1.0))
	var density: float = spectrum * directional * (g / (2.0 * omega) / k_length)
	return maxf(density * exp(-pow(1.0 - config.detail, 2.0) * k_length * k_length), 0.0)


static func _band_weight(wavelength: float, config: Resource) -> float:
	var width := maxf(config.transition_width_m, 0.0001)
	return smoothstep(config.min_wavelength_m - width, config.min_wavelength_m + width, wavelength) * (1.0 - smoothstep(config.max_wavelength_m - width, config.max_wavelength_m + width, wavelength))


static func _pack_h0(h0: PackedVector2Array, n: int) -> PackedByteArray:
	var packed := PackedFloat32Array()
	packed.resize(n * n * 4)
	for y in n:
		for x in n:
			var index := y * n + x
			var opposite := ((n - y) % n) * n + ((n - x) % n)
			var base := index * 4
			packed[base] = h0[index].x
			packed[base + 1] = h0[index].y
			packed[base + 2] = h0[opposite].x
			packed[base + 3] = -h0[opposite].y
	return packed.to_byte_array()


static func _gaussian_pair(seed: int, index: int) -> Vector2:
	var base := (seed & UINT_MASK) ^ ((index * 0x9e3779b9) & UINT_MASK)
	var u1 := maxf((float(_hash_u32(base ^ 0x68bc21eb)) + 0.5) * UINT_SCALE, 0.0000001)
	var u2 := (float(_hash_u32(base ^ 0x02e5be93)) + 0.5) * UINT_SCALE
	var radius := sqrt(-2.0 * log(u1))
	var angle := TAU * u2
	return Vector2(radius * cos(angle), radius * sin(angle))


static func _hash_u32(value: int) -> int:
	var x := value & UINT_MASK
	x = ((x ^ (x >> 16)) * 0x7feb352d) & UINT_MASK
	x = ((x ^ (x >> 15)) * 0x846ca68b) & UINT_MASK
	return (x ^ (x >> 16)) & UINT_MASK
