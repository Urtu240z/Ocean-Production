shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D crest_foam_long : repeat_enable, filter_linear;
uniform sampler2D crest_foam_mid : repeat_enable, filter_linear;
uniform sampler2D crest_foam_short : repeat_enable, filter_linear;
uniform sampler2D crest_breakup_texture : repeat_enable, filter_linear;
// P3 Surface Foam. All three textures are absent and never sampled while the
// system is OFF, preserving the approved P2 Crest Core path exactly.
uniform sampler2D surface_foam_field : repeat_enable, filter_linear;
uniform sampler2D surface_foam_topology : repeat_enable, filter_linear_mipmap;
uniform sampler2D surface_foam_mid_history : repeat_enable, filter_linear;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 short_fade_range_m = vec2(0.0, 55.0);
uniform vec2 mid_fade_range_m = vec2(96.0, 280.0);
uniform vec2 long_fade_range_m = vec2(768.0, 2500.0);
uniform vec2 camera_world_xz;
uniform vec3 deep_water_color = vec3(0.019474017, 0.0909042, 0.088472255);
uniform vec3 horizon_water_color = vec3(0.0075189536, 0.07750165, 0.04554274);
uniform int debug_view = 0;
uniform bool coastal_enabled = false;
uniform sampler2D coastal_field : repeat_disable, filter_linear;
uniform sampler2D coastal_metrics : repeat_disable, filter_linear;
uniform sampler2D coastal_phase : repeat_disable, filter_linear;
uniform sampler2D coastal_warp : repeat_disable, filter_linear;
uniform sampler2D coastal_jacobian : repeat_disable, filter_linear;
uniform vec2 coastal_origin = vec2(0.0);
uniform vec2 coastal_extent = vec2(1.0);
uniform vec2 coastal_warp_origin = vec2(0.0);
uniform vec2 coastal_warp_extent = vec2(1.0);
uniform float coastal_warp_detj_safe = 0.5;

// P2 Crest V3 Core. Surface Foam and Direct-J topology are intentionally absent.
uniform bool crest_foam_enabled = true;
uniform float crest_foam_intensity = 0.96;
uniform float crest_foam_contrast = 1.19;
uniform vec2 crest_foam_distance_fade_range_m = vec2(0.0, 5000.0);
uniform float crest_foam_detail_contribution = 0.35;
uniform float crest_foam_breakup_strength = 0.45;
uniform float crest_foam_breakup_world_size_m = 14.0;
uniform float crest_foam_edge_softness = 0.32;
uniform vec3 crest_foam_residual_color : source_color = vec3(1.84945);
uniform float crest_foam_residual_roughness = 0.88;
uniform float crest_foam_residual_specular = 0.18;
uniform bool crest_filigree_enabled = false;
uniform float crest_filigree_whitecap = 0.4;
uniform float crest_fresh_filigree_strength = 0.5;
uniform float crest_residual_filigree_strength = 0.62;
uniform float crest_filigree_contrast = 1.0;
uniform float crest_filigree_threshold = 0.0;
uniform bool surface_foam_enabled = false;
uniform float surface_foam_source_domain_m = 14.5;
uniform float surface_foam_field_domain_m = 88.0;
uniform float surface_foam_strength = 2.52;
uniform float surface_foam_threshold_visual = 0.11;
uniform vec2 surface_foam_distance_fade_range_m = vec2(200.0, 600.0);
uniform vec3 surface_foam_color : source_color = vec3(0.8954583, 0.9249786, 0.9149783);
uniform float surface_foam_roughness = 0.82;
uniform float surface_foam_specular = 0.37;
// V3 presentation: deterministic world-space deperiodization of the existing
// Direct-J topology/history. It is visual sampling only, never spectrum noise.
uniform bool surface_foam_stochastic_deperiodization_enabled = true;
uniform float surface_foam_stochastic_cell_size_m = 32.0;
uniform float surface_foam_ocean_coupling = 0.35;
// P4 injects its screen/depth declarations only in the runtime optics variant.
// Keeping this base material free of those hints makes Systems > Optics OFF real.
// P4_OPTICS_UNIFORMS
// P5 injects SSPR declarations only in a reflection-enabled material variant.
// P5_REFLECTIONS_UNIFORMS

varying vec2 ocean_base_xz;
varying vec2 surface_foam_displacement_xz;

float fade_weight(float distance_m, vec2 range_m) { return 1.0 - smoothstep(range_m.x, range_m.y, distance_m); }
vec2 world_uv(vec2 world_xz, float domain_m) { return world_xz / domain_m + vec2(0.5); }
vec2 coastal_uv(vec2 world_xz, vec2 origin, vec2 extent) { return (world_xz - origin) / max(extent, vec2(0.001)); }
float coastal_confidence(vec4 warp) { return smoothstep(0.0, coastal_warp_detj_safe, warp.z) * warp.w; }

float crest_breakup_mask(vec2 base_xz) {
	float noise = texture(crest_breakup_texture, base_xz / crest_foam_breakup_world_size_m).r;
	float softness = clamp(crest_foam_edge_softness, 0.01, 0.49);
	float breakup = mix(0.25, 1.0, smoothstep(0.5 - softness, 0.5 + softness, noise));
	return mix(1.0, breakup, crest_foam_breakup_strength);
}

float surface_foam_stochastic_hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float surface_foam_stochastic_rotation_angle(vec2 lattice_vertex) {
	float index = floor(surface_foam_stochastic_hash12(lattice_vertex + vec2(17.0, 31.0)) * 8.0);
	if (index < 0.5) return 0.29670597;
	if (index < 1.5) return 0.71558499;
	if (index < 2.5) return 1.27409035;
	if (index < 3.5) return 1.90240888;
	if (index < 4.5) return 2.39110108;
	if (index < 5.5) return 2.84488668;
	if (index < 6.5) return 3.68264472;
	return 4.48549618;
}

float surface_foam_stochastic_scale(vec2 lattice_vertex) {
	return mix(0.91, 1.09, surface_foam_stochastic_hash12(lattice_vertex + vec2(89.0, 37.0)));
}

vec2 surface_foam_stochastic_rotate(vec2 p, float angle) {
	float c = cos(angle); float s = sin(angle);
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

vec2 surface_foam_stochastic_transform_delta(vec2 delta, vec2 lattice_vertex) {
	delta *= surface_foam_stochastic_scale(lattice_vertex);
	delta = surface_foam_stochastic_rotate(delta, surface_foam_stochastic_rotation_angle(lattice_vertex));
	if (surface_foam_stochastic_hash12(lattice_vertex + vec2(47.0, 11.0)) > 0.5) delta.x *= -1.0;
	return delta;
}

vec2 surface_foam_lattice_vertex_world(vec2 lattice_vertex) {
	float cell_m = max(surface_foam_stochastic_cell_size_m, 0.001);
	return vec2((lattice_vertex.x + 0.5 * lattice_vertex.y) * cell_m, lattice_vertex.y * (0.8660254037844386 * cell_m));
}

vec2 surface_foam_stochastic_sample_position(vec2 world_xz, vec2 lattice_vertex, float domain_m) {
	vec2 vertex_world = surface_foam_lattice_vertex_world(lattice_vertex);
	vec2 transformed = surface_foam_stochastic_rotate((world_xz - vertex_world) * surface_foam_stochastic_scale(lattice_vertex), surface_foam_stochastic_rotation_angle(lattice_vertex));
	if (surface_foam_stochastic_hash12(lattice_vertex + vec2(47.0, 11.0)) > 0.5) transformed.x = -transformed.x;
	vec2 phase = vec2(surface_foam_stochastic_hash12(lattice_vertex + vec2(7.0, 53.0)), surface_foam_stochastic_hash12(lattice_vertex + vec2(71.0, 19.0))) * domain_m;
	return vertex_world + transformed + phase;
}

void surface_foam_stochastic_triangle(vec2 world_xz, out vec2 v0, out vec2 v1, out vec2 v2, out vec3 weights) {
	float cell_m = max(surface_foam_stochastic_cell_size_m, 0.001);
	vec2 lattice = vec2(world_xz.x / cell_m - world_xz.y / (1.7320508075688772 * cell_m), world_xz.y / (0.8660254037844386 * cell_m));
	vec2 cell = floor(lattice); vec2 f = fract(lattice);
	if (f.x + f.y <= 1.0) {
		v0 = cell; v1 = cell + vec2(1.0, 0.0); v2 = cell + vec2(0.0, 1.0);
		weights = vec3(1.0 - f.x - f.y, f.x, f.y);
	} else {
		v0 = cell + vec2(1.0, 1.0); v1 = cell + vec2(0.0, 1.0); v2 = cell + vec2(1.0, 0.0);
		weights = vec3(f.x + f.y - 1.0, 1.0 - f.x, 1.0 - f.y);
	}
	weights = weights * weights * (3.0 - 2.0 * weights);
	weights /= max(weights.x + weights.y + weights.z, 0.00001);
}

vec2 surface_foam_topology_at(vec2 sample_position, vec2 world_dx, vec2 world_dy) {
	vec2 uv = world_uv(sample_position, surface_foam_source_domain_m);
	return textureGrad(surface_foam_topology, uv, world_dx / surface_foam_source_domain_m * 0.5, world_dy / surface_foam_source_domain_m * 0.5).rg;
}

void surface_foam_shared_direct_topologies(vec2 world_xz, out float surface_raw, out float crest_raw) {
	if (!surface_foam_stochastic_deperiodization_enabled) {
		vec2 topology = surface_foam_topology_at(world_xz, dFdx(world_xz), dFdy(world_xz));
		surface_raw = topology.r; crest_raw = topology.g; return;
	}
	vec2 v0; vec2 v1; vec2 v2; vec3 weights;
	surface_foam_stochastic_triangle(world_xz, v0, v1, v2, weights);
	vec2 dx = dFdx(world_xz); vec2 dy = dFdy(world_xz);
	vec2 t0 = surface_foam_topology_at(surface_foam_stochastic_sample_position(world_xz, v0, surface_foam_source_domain_m), surface_foam_stochastic_transform_delta(dx, v0), surface_foam_stochastic_transform_delta(dy, v0));
	vec2 t1 = surface_foam_topology_at(surface_foam_stochastic_sample_position(world_xz, v1, surface_foam_source_domain_m), surface_foam_stochastic_transform_delta(dx, v1), surface_foam_stochastic_transform_delta(dy, v1));
	vec2 t2 = surface_foam_topology_at(surface_foam_stochastic_sample_position(world_xz, v2, surface_foam_source_domain_m), surface_foam_stochastic_transform_delta(dx, v2), surface_foam_stochastic_transform_delta(dy, v2));
	vec2 topology = t0 * weights.x + t1 * weights.y + t2 * weights.z;
	surface_raw = topology.r; crest_raw = topology.g;
}

vec2 surface_foam_stochastic_field_unweighted(vec2 world_xz) {
	vec2 v0; vec2 v1; vec2 v2; vec3 weights;
	surface_foam_stochastic_triangle(world_xz, v0, v1, v2, weights);
	vec2 f0 = textureLod(surface_foam_field, world_uv(surface_foam_stochastic_sample_position(world_xz, v0, surface_foam_field_domain_m), surface_foam_field_domain_m), 0.0).rg;
	vec2 f1 = textureLod(surface_foam_field, world_uv(surface_foam_stochastic_sample_position(world_xz, v1, surface_foam_field_domain_m), surface_foam_field_domain_m), 0.0).rg;
	vec2 f2 = textureLod(surface_foam_field, world_uv(surface_foam_stochastic_sample_position(world_xz, v2, surface_foam_field_domain_m), surface_foam_field_domain_m), 0.0).rg;
	return f0 * weights.x + f1 * weights.y + f2 * weights.z;
}

vec2 pixel_ocean_surface_foam_field_unweighted(vec2 world_xz) {
	return surface_foam_stochastic_deperiodization_enabled ? surface_foam_stochastic_field_unweighted(world_xz) : textureLod(surface_foam_field, world_uv(world_xz, surface_foam_field_domain_m), 0.0).rg;
}

float surface_foam_macro_from_topology(float raw_topology, float history_envelope) {
	float persistent_gate = smoothstep(0.015, 0.32, history_envelope);
	return clamp(raw_topology * 2.05 * mix(0.46, 1.0, persistent_gate), 0.0, 1.0);
}

float crest_filigree_source_from_macro(float crest_macro) {
	return pow(smoothstep(crest_filigree_threshold, max(1.0, crest_filigree_threshold + 0.001), clamp(crest_macro, 0.0, 1.0)), 1.0 / max(crest_filigree_contrast, 0.1));
}

void vertex() {
	vec2 world_xz = MODEL_MATRIX[3].xz + VERTEX.xz;
	ocean_base_xz = world_xz;
	float distance_m = distance(world_xz, camera_world_xz);
	float long_weight = fade_weight(distance_m, long_fade_range_m);
	float mid_weight = fade_weight(distance_m, mid_fade_range_m);
	float short_weight = fade_weight(distance_m, short_fade_range_m);
	vec3 long_displacement = texture(displacement_long, world_uv(world_xz, domain_long_m)).xyz;
	if (coastal_enabled) {
		vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent);
		if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
			vec4 field = texture(coastal_field, coast_uv);
			vec4 warp = texture(coastal_warp, clamp(coastal_uv(world_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));
			float confidence = field.a * coastal_confidence(warp);
			long_displacement = mix(long_displacement, texture(displacement_long, world_uv(warp.xy, domain_long_m)).xyz, confidence);
			long_displacement.y *= mix(1.0, field.g, confidence);
		}
	}
	vec3 surface_displacement = long_displacement * long_weight + texture(displacement_mid, world_uv(world_xz, domain_mid_m)).xyz * mid_weight + texture(displacement_short, world_uv(world_xz, domain_short_m)).xyz * short_weight;
	surface_foam_displacement_xz = surface_displacement.xz;
	VERTEX += surface_displacement;
}

void fragment() {
	vec2 world_xz = ocean_base_xz;
	float distance_m = distance(world_xz, camera_world_xz);
	float long_weight = fade_weight(distance_m, long_fade_range_m);
	float mid_weight = fade_weight(distance_m, mid_fade_range_m);
	float short_weight = fade_weight(distance_m, short_fade_range_m);
	vec3 long_normal = texture(normal_long, world_uv(world_xz, domain_long_m)).xyz;
	if (coastal_enabled) {
		vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent);
		if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
			vec4 field = texture(coastal_field, coast_uv);
			vec4 warp = texture(coastal_warp, clamp(coastal_uv(world_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));
			long_normal = mix(long_normal, texture(normal_long, world_uv(warp.xy, domain_long_m)).xyz, field.a * coastal_confidence(warp));
		}
	}
	// FFT normals are reconstructed in ocean/world axes. Godot's fragment NORMAL
	// is view-space, so keep the physical and presentation coordinates explicit.
	vec3 shading_normal_world = normalize(long_normal * long_weight
		+ texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz * mid_weight
		+ texture(normal_short, world_uv(world_xz, domain_short_m)).xyz * short_weight);
	vec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);
	NORMAL = visual_normal;
	ALBEDO = mix(deep_water_color, horizon_water_color, smoothstep(200.0, 2500.0, distance_m));
	ROUGHNESS = 0.08; METALLIC = 0.0; SPECULAR = 0.9;
	// P4_OPTICS_FRAGMENT
	vec2 surface_foam_world_xz = ocean_base_xz + surface_foam_displacement_xz * clamp(surface_foam_ocean_coupling, 0.0, 1.0);
	float surface_raw = 0.0; float crest_raw = 0.0; vec2 surface_field = vec2(0.0);
	if (surface_foam_enabled || crest_filigree_enabled) {
		surface_foam_shared_direct_topologies(ocean_base_xz, surface_raw, crest_raw);
		surface_field = pixel_ocean_surface_foam_field_unweighted(surface_foam_world_xz);
	}
	if (crest_foam_enabled) {
		float long_foam = texture(crest_foam_long, world_uv(world_xz, domain_long_m)).r * long_weight;
		float mid_detail = texture(crest_foam_mid, world_uv(world_xz, domain_mid_m)).r * mid_weight * crest_foam_detail_contribution * 0.55;
		float short_detail = texture(crest_foam_short, world_uv(world_xz, domain_short_m)).r * short_weight * crest_foam_detail_contribution * 0.30;
		float detail = 1.0 - (1.0 - mid_detail) * (1.0 - short_detail);
		float raw_foam = 1.0 - (1.0 - clamp(long_foam, 0.0, 1.0)) * (1.0 - detail);
		float shaped = pow(smoothstep(0.0, 1.0, raw_foam), 1.0 / max(crest_foam_contrast, 0.1));
		float distance_fade = 1.0 - smoothstep(crest_foam_distance_fade_range_m.x, max(crest_foam_distance_fade_range_m.y, crest_foam_distance_fade_range_m.x + 0.001), distance_m);
		float crest = clamp(shaped * crest_foam_intensity * crest_breakup_mask(world_xz) * distance_fade, 0.0, 1.0);
		if (crest_filigree_enabled) {
			float filigree = crest_filigree_source_from_macro(surface_foam_macro_from_topology(crest_raw, surface_field.r));
			// The P2 mask remains the physical support; Direct-J only erodes it.
			crest *= mix(1.0, filigree, crest_residual_filigree_strength);
		}
		ALBEDO = mix(ALBEDO, crest_foam_residual_color, crest);
		ROUGHNESS = mix(ROUGHNESS, crest_foam_residual_roughness, crest);
		SPECULAR = mix(SPECULAR, crest_foam_residual_specular, crest);
	}
	if (surface_foam_enabled) {
		float macro = surface_foam_macro_from_topology(surface_raw, surface_field.r);
		float threshold = clamp(surface_foam_threshold_visual, 0.0, 0.999);
		float shaped = smoothstep(threshold, 1.0, macro);
		float mid_eligibility = texture(surface_foam_mid_history, world_uv(world_xz, domain_mid_m)).r;
		float surface_foam_camera_distance = distance(surface_foam_world_xz, camera_world_xz);
		float fade = 1.0 - smoothstep(surface_foam_distance_fade_range_m.x, max(surface_foam_distance_fade_range_m.y, surface_foam_distance_fade_range_m.x + 0.001), surface_foam_camera_distance);
		float mask = min(clamp(shaped * surface_foam_strength, 0.0, 1.0), clamp(macro * surface_foam_strength * fade, 0.0, 1.0));
		mask *= mid_eligibility;
		ALBEDO = mix(ALBEDO, surface_foam_color, mask);
		ROUGHNESS = mix(ROUGHNESS, surface_foam_roughness, mask);
		SPECULAR = mix(SPECULAR, surface_foam_specular, mask);
	}
	// P5_REFLECTIONS_FRAGMENT
	if (debug_view == 1) ALBEDO = NORMAL * 0.5 + 0.5;
}
