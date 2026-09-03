#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(set=0,binding=0) uniform sampler2D jacobian_map;
layout(set=0,binding=1) uniform sampler2D previous_field;
layout(rg16f,set=0,binding=2) uniform restrict writeonly image2D next_field;
layout(set=0,binding=3,std140) uniform Params { vec4 foam; vec4 timing; vec4 spatial; } params;
const float TAU=6.28318530718;
vec2 warp(vec2 p){ float a=max(params.spatial.z,0.0),d=max(params.spatial.x,.001); return .5*a*vec2(sin(p.x*TAU/d+.37)+sin(2.*p.y*TAU/d+1.11),cos(p.y*TAU/d+.71)+cos(3.*p.x*TAU/d+2.07)); }
float source(vec2 p){ return clamp(max(0.,params.foam.x-textureLod(jacobian_map,p,0.).r)*max(params.foam.y,0.),0.,1.); }
float target(float s,float selectivity){ return s*smoothstep(selectivity,selectivity+max(params.timing.w,.001),s); }
void main(){ ivec2 c=ivec2(gl_GlobalInvocationID.xy),size=imageSize(next_field);if(any(greaterThanEqual(c,size)))return;vec2 uv=(vec2(c)+.5)/vec2(size),p=(uv-.5)*params.spatial.x,w=warp(p);float a=source((p+w)/max(params.spatial.y,.001));mat2 r=mat2(vec2(.7986355,-.601815),vec2(.601815,.7986355));float b=source((p+r*(w*1.19)+vec2(2.37,-1.41))/max(params.spatial.y,.001));float sel=smoothstep(.42,.58,.5+.5*sin(p.x*TAU/params.spatial.x+.83)*cos(2.*p.y*TAU/params.spatial.x+1.47));float birth=mix(target(a,params.foam.z),target(b,params.foam.z),sel),sustain=mix(target(a,max(params.foam.z-.12,0.)),target(b,max(params.foam.z-.12,0.)),sel);float previous=textureLod(previous_field,uv,0.).r;if(isnan(previous)||isinf(previous))previous=0.;float desired=previous>.001?sustain:birth;float rate=desired>previous?1./max(params.timing.y,.001):1./max(params.timing.z,.001);float next=mix(previous,desired,1.-exp(-rate*max(params.timing.x,0.)));imageStore(next_field,c,vec4(clamp(next,0.,1.),birth,0.,1.)); }
