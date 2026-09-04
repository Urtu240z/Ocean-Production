#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D scene_color;
layout(set = 0, binding = 5) uniform sampler2D scene_depth;
layout(set = 0, binding = 1, std430) readonly buffer CandidateBuffer { uint candidates[]; };
layout(set = 0, binding = 2, rgba16f) uniform image2D reflection_output;
layout(set = 0, binding = 4, r16f) uniform image2D reflection_depth_output;
layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inverse_projection; mat4 inverse_view; mat4 view_projection;
	vec4 source_size; vec4 destination_size; vec4 ocean_level;
} params;
const uint INVALID = 0u;
const float HOLE_FILL_ALPHA = 0.35;
void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy); ivec2 extent = ivec2(params.destination_size.xy);
	if (any(greaterThanEqual(pixel, extent))) return;
	uint payload = candidates[uint(pixel.y * extent.x + pixel.x)]; float alpha = 1.0;
	if (payload == INVALID) {
		uint best = INVALID; int best_distance = 99;
		for (int y=-1;y<=1;y++) for (int x=-1;x<=1;x++) { ivec2 n=pixel+ivec2(x,y); if (x==0&&y==0||any(lessThan(n,ivec2(0)))||any(greaterThanEqual(n,extent))) continue; uint p=candidates[uint(n.y*extent.x+n.x)]; int d=abs(x)+abs(y); if (p!=INVALID&&(d<best_distance||(d==best_distance&&p>best))){best=p;best_distance=d;} }
		if (best == INVALID) { imageStore(reflection_output,pixel,vec4(0.0)); imageStore(reflection_depth_output,pixel,vec4(0.0)); return; }
		payload=best; alpha=HOLE_FILL_ALPHA;
	}
	uint coordinates=payload-1u; ivec2 source_pixel=ivec2(int(coordinates&0xffffu),int((coordinates>>16u)&0xffffu));
	ivec2 source_extent=ivec2(params.source_size.xy);
	if (any(greaterThanEqual(source_pixel,source_extent))) {imageStore(reflection_output,pixel,vec4(0.0));imageStore(reflection_depth_output,pixel,vec4(0.0));return;}
	float depth=texelFetch(scene_depth,source_pixel,0).r;
	if (!(depth>0.000001)||depth>1.000001) {imageStore(reflection_output,pixel,vec4(0.0));imageStore(reflection_depth_output,pixel,vec4(0.0));return;}
	vec2 uv=(vec2(source_pixel)+0.5)/params.source_size.xy; vec3 color=texture(scene_color,uv).rgb;
	if (any(isnan(color))||any(isinf(color))) {imageStore(reflection_output,pixel,vec4(0.0));imageStore(reflection_depth_output,pixel,vec4(0.0));return;}
	imageStore(reflection_output,pixel,vec4(color,alpha));
	vec4 view_position=params.inverse_projection*vec4(uv*2.0-1.0,depth,1.0); if(abs(view_position.w)<=0.000001){imageStore(reflection_depth_output,pixel,vec4(0.0));return;} view_position/=view_position.w;
	vec4 world_position=params.inverse_view*vec4(view_position.xyz,1.0); if(abs(world_position.w)<=0.000001){imageStore(reflection_depth_output,pixel,vec4(0.0));return;} world_position/=world_position.w; world_position.y=2.0*params.ocean_level.x-world_position.y;
	vec4 clip=params.view_projection*world_position; if(abs(clip.w)<=0.000001){imageStore(reflection_depth_output,pixel,vec4(0.0));return;}
	imageStore(reflection_depth_output,pixel,vec4(clamp(clip.z/clip.w,0.0,1.0),0.0,0.0,0.0));
}
