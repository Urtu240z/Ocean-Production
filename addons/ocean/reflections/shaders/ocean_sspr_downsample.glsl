#[compute]
#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D source_mip;
layout(rgba16f,set=0,binding=1) uniform writeonly image2D destination_mip;
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);ivec2 size=imageSize(destination_mip);if(any(greaterThanEqual(p,size)))return;ivec2 source_size=textureSize(source_mip,0);ivec2 base=p*2;ivec2 max_p=source_size-1;vec4 a=texelFetch(source_mip,min(base,max_p),0);vec4 b=texelFetch(source_mip,min(base+ivec2(1,0),max_p),0);vec4 c=texelFetch(source_mip,min(base+ivec2(0,1),max_p),0);vec4 d=texelFetch(source_mip,min(base+ivec2(1,1),max_p),0);float coverage=a.a+b.a+c.a+d.a;vec3 color=coverage>0.0001?(a.rgb*a.a+b.rgb*b.a+c.rgb*c.a+d.rgb*d.a)/coverage:vec3(0.0);imageStore(destination_mip,p,vec4(color,coverage*0.25));}
