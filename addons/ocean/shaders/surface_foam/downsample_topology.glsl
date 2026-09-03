#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0) uniform sampler2D source_mip;
layout(rg16f,set=0,binding=1) uniform writeonly image2D destination_mip;
void main(){ivec2 c=ivec2(gl_GlobalInvocationID.xy),d=imageSize(destination_mip);if(any(greaterThanEqual(c,d)))return;ivec2 ss=textureSize(source_mip,0),b=c*2,m=max(ss-ivec2(1),ivec2(0));vec2 v=(texelFetch(source_mip,min(b,m),0).rg+texelFetch(source_mip,min(b+ivec2(1,0),m),0).rg+texelFetch(source_mip,min(b+ivec2(0,1),m),0).rg+texelFetch(source_mip,min(b+ivec2(1),m),0).rg)*.25;imageStore(destination_mip,c,vec4(v,0,1));}
