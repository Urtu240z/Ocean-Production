#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D spatial_a;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D spatial_b;
layout(rgba32f, set = 0, binding = 2) uniform restrict readonly image2D spatial_c;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D displacement_map;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D normal_map;
layout(push_constant, std430) uniform Params { vec4 values; } params;
ivec2 wrap_coord(ivec2 coord, ivec2 size) { return ivec2((coord.x + size.x) % size.x, (coord.y + size.y) % size.y); }
vec3 displacement_at(ivec2 coord, ivec2 size) { ivec2 wrapped = wrap_coord(coord, size); float checkerboard = ((wrapped.x + wrapped.y) & 1) == 0 ? 1.0 : -1.0; vec4 a = imageLoad(spatial_a, wrapped); vec4 b = imageLoad(spatial_b, wrapped); return vec3(a.z, a.x, b.x) * (checkerboard * params.values.y); }
void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy); ivec2 size = imageSize(spatial_a); if (any(greaterThanEqual(coord, size))) return;
	vec3 displacement = displacement_at(coord, size); float inverse_two_dx = 0.5 / params.values.z;
	vec3 derivative_x = vec3(1.0, 0.0, 0.0) + (displacement_at(coord + ivec2(1,0), size) - displacement_at(coord - ivec2(1,0), size)) * inverse_two_dx;
	vec3 derivative_z = vec3(0.0, 0.0, 1.0) + (displacement_at(coord + ivec2(0,1), size) - displacement_at(coord - ivec2(0,1), size)) * inverse_two_dx;
	float checkerboard = ((coord.x + coord.y) & 1) == 0 ? 1.0 : -1.0; float scale = checkerboard * params.values.y; vec4 b = imageLoad(spatial_b, coord); vec4 c = imageLoad(spatial_c, coord);
	float jacobian = (1.0 + b.z * scale) * (1.0 + c.x * scale) - c.z * c.z * scale * scale; vec3 normal = normalize(cross(derivative_z, derivative_x));
	if (any(isnan(displacement)) || any(isinf(displacement)) || any(isnan(normal)) || any(isinf(normal))) { displacement = vec3(0.0); normal = vec3(0.0, 1.0, 0.0); jacobian = 1.0; }
	imageStore(displacement_map, coord, vec4(displacement, jacobian)); imageStore(normal_map, coord, vec4(normal, 1.0));
}
