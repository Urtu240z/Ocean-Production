extends RefCounted
## PHYS-1 bridge: consumes Production's final GPU-upload H0 verbatim. It does
## not generate a spectrum or random values.

const NativeScript := "OceanQueryNative"

static func configure_long(native_query: Object, snapshot: Dictionary, sea_level: float) -> Dictionary:
	native_query.clear()
	native_query.set_sea_level(sea_level)
	var configured := _configure_band(native_query, snapshot, 0)
	if not bool(configured.get("ok", false)):
		return configured
	native_query.finalize_spectrum()
	return configured


static func configure_bands(native_query: Object, snapshots: Array[Dictionary], sea_level: float,
							active_mask := 7) -> Dictionary:
	if snapshots.size() != 3:
		return {"ok": false, "error": "Expected LONG, MID and SHORT Production snapshots."}
	native_query.clear()
	native_query.set_sea_level(sea_level)
	var configured: Array[Dictionary] = []
	for band_index in 3:
		if (active_mask & (1 << band_index)) == 0:
			continue
		var result := _configure_band(native_query, snapshots[band_index], band_index)
		if not bool(result.get("ok", false)):
			return result
		configured.append(result)
	native_query.finalize_spectrum()
	return {"ok": configured.size() == _bit_count(active_mask), "bands": configured,
		"active_mask": active_mask, "source": "retained final Production H0 uploads"}


static func configure_coastal(native_query: Object, snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty() or not bool(snapshot.get("active", false)):
		native_query.clear_coastal()
		return {"ok": false, "active": false, "error": "No active authoritative Coastal CPU bake snapshot."}
	var field_resolution: Vector2i = snapshot.get("field_resolution", Vector2i.ZERO)
	var warp_resolution: Vector2i = snapshot.get("warp_resolution", Vector2i.ZERO)
	var field_count := field_resolution.x * field_resolution.y
	var warp_count := warp_resolution.x * warp_resolution.y
	var shoaling: PackedFloat32Array = snapshot.get("shoaling", PackedFloat32Array())
	var field_valid: PackedByteArray = snapshot.get("field_valid", PackedByteArray())
	var warp_x: PackedFloat32Array = snapshot.get("warp_x", PackedFloat32Array())
	var warp_z: PackedFloat32Array = snapshot.get("warp_z", PackedFloat32Array())
	var warp_det_j: PackedFloat32Array = snapshot.get("warp_det_j", PackedFloat32Array())
	var warp_valid: PackedByteArray = snapshot.get("warp_valid", PackedByteArray())
	if field_resolution.x < 2 or field_resolution.y < 2 or warp_resolution.x < 2 or warp_resolution.y < 2 \
			or shoaling.size() != field_count or field_valid.size() != field_count \
			or warp_x.size() != warp_count or warp_z.size() != warp_count \
			or warp_det_j.size() != warp_count or warp_valid.size() != warp_count:
		native_query.clear_coastal()
		return {"ok": false, "active": false, "error": "Coastal bake arrays do not match their declared dimensions."}
	var field_origin: Vector2 = snapshot["field_origin"]
	var field_extent: Vector2 = snapshot["field_extent"]
	var warp_origin: Vector2 = snapshot["warp_origin"]
	var warp_extent: Vector2 = snapshot["warp_extent"]
	native_query.set_coastal_runtime(
		field_origin.x, field_origin.y, field_extent.x, field_extent.y,
		field_resolution.x, field_resolution.y, shoaling, field_valid,
		warp_origin.x, warp_origin.y, warp_extent.x, warp_extent.y,
		warp_resolution.x, warp_resolution.y, warp_x, warp_z, warp_det_j,
		warp_valid, float(snapshot.get("detj_safe", 0.5)))
	return {
		"ok": true, "active": true, "generation": int(snapshot.get("generation", 0)),
		"field_resolution": field_resolution, "field_origin": field_origin,
		"field_extent": field_extent, "warp_resolution": warp_resolution,
		"warp_origin": warp_origin, "warp_extent": warp_extent,
		"detj_safe": float(snapshot.get("detj_safe", 0.5)),
		"source": "same CPU bake arrays used by active Production ImageTextures",
	}


static func _configure_band(native_query: Object, snapshot: Dictionary, cascade_index: int) -> Dictionary:
	var n := int(snapshot.get("resolution", 0))
	var domain_m := float(snapshot.get("domain_size_m", 0.0))
	var gravity := float(snapshot.get("gravity_mps2", 0.0))
	var choppiness := float(snapshot.get("choppiness", 0.0))
	var packed: PackedFloat32Array = snapshot.get("h0_rgba32f", PackedByteArray()).to_float32_array()
	if n < 2 or domain_m <= 0.0 or gravity <= 0.0 or packed.size() != n * n * 4:
		return {"ok": false, "error": "Invalid final Production H0 snapshot for band %s." % snapshot.get("band", cascade_index)}
	var count := n * n
	var kx := PackedFloat64Array(); kx.resize(count)
	var ky := PackedFloat64Array(); ky.resize(count)
	var omega := PackedFloat64Array(); omega.resize(count)
	var a1 := PackedFloat64Array(); a1.resize(count)
	var a2 := PackedFloat64Array(); a2.resize(count)
	var c11 := PackedFloat64Array(); c11.resize(count)
	var c12 := PackedFloat64Array(); c12.resize(count)
	var c21 := PackedFloat64Array(); c21.resize(count)
	var c22 := PackedFloat64Array(); c22.resize(count)
	var parity := PackedFloat64Array(); parity.resize(count)
	var weight := PackedFloat64Array(); weight.resize(count)
	var h0_re := PackedFloat64Array(); h0_re.resize(count)
	var h0_im := PackedFloat64Array(); h0_im.resize(count)
	var h0n_re := PackedFloat64Array(); h0n_re.resize(count)
	var h0n_im := PackedFloat64Array(); h0n_im.resize(count)
	var delta_k := TAU / domain_m
	for y in n:
		for x in n:
			var i := y * n + x
			var k := Vector2(float(x) - float(n) * 0.5, float(y) - float(n) * 0.5) * delta_k
			var k_length := k.length()
			var ax := -choppiness * k.x / k_length if k_length > 0.000001 else 0.0
			var az := -choppiness * k.y / k_length if k_length > 0.000001 else 0.0
			# The Production texture index i represents FFT-q=i*L/N. Rotate
			# both retained H0 terms by exp(i*k*L/2) as PHYS-1 already proved.
			var origin_phase := -1.0 if ((x + y - n) & 1) != 0 else 1.0
			var base := i * 4
			kx[i] = k.x; ky[i] = k.y
			omega[i] = sqrt(gravity * k_length)
			a1[i] = ax; a2[i] = az
			c11[i] = ax * k.x; c12[i] = ax * k.y
			c21[i] = az * k.x; c22[i] = az * k.y
			parity[i] = -1.0 if ((x + y) & 1) != 0 else 1.0
			weight[i] = 1.0
			h0_re[i] = packed[base] * origin_phase
			h0_im[i] = packed[base + 1] * origin_phase
			h0n_re[i] = packed[base + 2] * origin_phase
			h0n_im[i] = packed[base + 3] * origin_phase

	native_query.set_cascade_data(cascade_index, 1.0 / float(count), kx, ky, omega,
		a1, a2, c11, c12, c21, c22, parity, weight,
		h0_re, h0_im, h0n_re, h0n_im)
	native_query.set_cascade_material_q_contract(cascade_index, domain_m, n)
	var texel_size := domain_m / float(n)
	return {
		"ok": true, "band": String(snapshot.get("band", "")), "cascade_index": cascade_index,
		"resolution": n, "domain_size_m": domain_m, "texel_size_m": texel_size,
		"material_to_fft_offset_m": domain_m * 0.5 - texel_size * 0.5,
		"choppiness": choppiness, "gravity_mps2": gravity,
		"effective_amplitude_scale": float(snapshot.get("effective_amplitude_scale", 1.0)),
		"mode_count": count, "h0_bytes": int(snapshot["h0_rgba32f"].size()),
		"h0_source": snapshot.get("h0_source", "Production retained final H0"),
		"production_h0_retained_bytes": int(snapshot["h0_rgba32f"].size()),
		"wave_time": float(snapshot.get("wave_time", 0.0)),
	}


static func _bit_count(value: int) -> int:
	var remaining := value
	var count := 0
	while remaining != 0:
		count += remaining & 1
		remaining = remaining >> 1
	return count
