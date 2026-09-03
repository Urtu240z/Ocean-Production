#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D packed_payload;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image2D jacobian_map;
layout(set = 0, binding = 2, std140) uniform Params { vec4 values; } params;
void main() { ivec2 c=ivec2(gl_GlobalInvocationID.xy); ivec2 s=imageSize(packed_payload); if(any(greaterThanEqual(c,s)))return; float q=((c.x+c.y)&1)==0?1.0:-1.0; vec4 p=imageLoad(packed_payload,c); float x=p.x*q*params.values.x, z=p.y*q*params.values.x, cross=p.z*q*params.values.x; float j=(1.0+x)*(1.0+z)-cross*cross; imageStore(jacobian_map,c,vec4((isnan(j)||isinf(j))?1.0:j,0,0,1)); }
