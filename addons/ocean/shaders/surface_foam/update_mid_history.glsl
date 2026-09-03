#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0) uniform sampler2D displacement_mid;
layout(set=0,binding=1) uniform sampler2D previous_history;
layout(r16f,set=0,binding=2) uniform restrict writeonly image2D next_history;
layout(push_constant,std430) uniform Params { vec4 timing; vec4 fold; } params;
void main(){ivec2 c=ivec2(gl_GlobalInvocationID.xy),s=imageSize(next_history);if(any(greaterThanEqual(c,s)))return;float j=texelFetch(displacement_mid,c,0).a;if(isnan(j)||isinf(j))j=1.;float target=smoothstep(params.fold.x,max(params.fold.y,params.fold.x+.001),max(0.,1.-j));float old=texelFetch(previous_history,c,0).r;if(isnan(old)||isinf(old))old=0.;float rate=target>old?1./max(params.timing.y,.001):1./max(params.timing.z,.001);imageStore(next_history,c,vec4(mix(old,target,1.-exp(-rate*max(params.timing.x,0.))),0,0,1));}
