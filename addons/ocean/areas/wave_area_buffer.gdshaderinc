// Include wave_area_math.gdshaderinc before this block.
struct WaveAreaRecord {
	mat4 inverse_frame;
	vec4 shape;
	vec4 blend;
	vec4 settings;
	vec4 wind;
	vec4 meta;
	vec4 groups;
	vec4 components0[32];
	vec4 components1[32];
};
layout(std430, set = 0, binding = WAVE_AREA_BINDING) readonly buffer WaveAreaBuffer {
	vec4 wave_area_header;
	WaveAreaRecord wave_area_records[8];
};
float wave_areas_height(vec2 p, float base_height) {
	float value = base_height;
	for (int i = 0; i < int(wave_area_header.x); i++) {
		float w = wave_area_weight(vec3(p.x, wave_area_header.z, p.y), wave_area_records[i].inverse_frame, wave_area_records[i].shape, wave_area_records[i].blend) * wave_area_records[i].meta.z;
		if (w > 0.0) {
			vec4 local = vec4(0.0);
			for (int j = 0; j < int(wave_area_records[i].meta.x); j++) {
				local += wave_area_component(p,wave_area_records[i].components0[j],wave_area_records[i].components1[j],wave_area_header.y);
			}
			local = wave_area_group(p,local,wave_area_records[i].groups,wave_area_records[i].wind.w,wave_area_header.y);
			value = mix(value,local.x,w);
		}
	}
	return value;
}
