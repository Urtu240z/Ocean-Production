#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0) uniform sampler2D jacobian_map;
layout(rg16f,set=0,binding=1) uniform writeonly image2D topology_map;
layout(set=0,binding=2,std140) uniform Params { vec4 values; } params;
void main(){ivec2 c=ivec2(gl_GlobalInvocationID.xy),s=imageSize(topology_map);if(any(greaterThanEqual(c,s)))return;float j=textureLod(jacobian_map,(vec2(c)+.5)/vec2(s),0.).r;if(isnan(j)||isinf(j))j=1.;imageStore(topology_map,c,vec4(max(0.,params.values.x-j),max(0.,params.values.y-j),0.,1.));}
