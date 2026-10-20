
layout(location = 0) out vec2 waterline_mask;
layout(location = 1) out float ocean_depth;

void main() {
	// R is the actual raster face side. G explicitly distinguishes missing
	// coverage from a valid back-facing (underwater) surface.
	waterline_mask = vec2(gl_FrontFacing ? 1.0 : 0.0, 1.0);
	ocean_depth = gl_FragCoord.z;
}
