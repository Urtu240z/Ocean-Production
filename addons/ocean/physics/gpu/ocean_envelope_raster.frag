#version 450
layout(location=0) in vec4 seed;
layout(location=1) flat in uint tile_slot;
layout(location=0) out vec4 atlas_seed;
struct Tile { vec4 center_size; uvec4 stamp; uvec4 owner; vec4 atlas; };
layout(std430,set=1,binding=1) readonly buffer Tiles { Tile tiles[]; };
void main() {
    Tile tile=tiles[tile_slot]; int resolution=int(tile.atlas.x),axis=int(tile.atlas.y);
    ivec2 cell=ivec2(int(tile_slot)%axis,int(tile_slot)/axis);
    ivec2 pixel=ivec2(gl_FragCoord.xy)-cell*resolution;
    if(any(lessThan(pixel,ivec2(0)))||any(greaterThanEqual(pixel,ivec2(resolution)))) discard;
    atlas_seed=seed;
}
