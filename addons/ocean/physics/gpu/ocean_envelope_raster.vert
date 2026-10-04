#version 450
#extension GL_ARB_gpu_shader_fp64 : require
// @OCEAN_AUTHORITY@
// @ENVELOPE_SHARED@
layout(location=0) in vec2 grid;
layout(location=0) out vec4 seed;
layout(location=1) flat out uint tile_slot;
void main() {
    tile_slot=uint(gl_InstanceIndex); Tile tile=tiles[tile_slot];
    if(tile.owner.x==0u) { seed=vec4(0); gl_Position=vec4(2,2,2,1); return; }
    vec3 bound=coverage_bound();
    dvec2 q=dvec2(tile.center_size.xy)+dvec2(grid)*dvec2(tile.center_size.zw+2.0*bound.xz);
    dvec3 d,v; surface(q,d,v);
    dvec2 local=(q+d.xz-dvec2(tile.center_size.xy))/dvec2(tile.center_size.zw);
    uint axis=uint(tile.atlas.y); uvec2 cell=uvec2(tile_slot%axis,tile_slot/axis);
    dvec2 atlas_uv=(local+0.5+dvec2(cell))/double(axis);
    double vertical=double(bound.y)+1.0;
    // Explicit positive depth: highest Y wins GREATER_OR_EQUAL, clear=0.
    gl_Position=vec4(vec2(atlas_uv*2.0-1.0),float((d.y+vertical)/(2.0*vertical)),1.0);
    seed=vec4(q.x,q.y,double(p.domains_sea.w)+d.y,1.0);
}
