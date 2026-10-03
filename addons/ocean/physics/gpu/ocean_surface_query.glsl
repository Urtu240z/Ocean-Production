#[compute]
#version 450
#extension GL_ARB_gpu_shader_fp64 : require
layout(local_size_x=64, local_size_y=1, local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D displacement_long;
layout(set=0,binding=1) uniform sampler2D displacement_mid;
layout(set=0,binding=2) uniform sampler2D displacement_short;
layout(set=0,binding=3) uniform sampler2D coastal_field;
layout(set=0,binding=4) uniform sampler2D coastal_warp;
layout(set=0,binding=5) uniform sampler2D velocity_long;
layout(set=0,binding=6) uniform sampler2D velocity_mid;
layout(set=0,binding=7) uniform sampler2D velocity_short;
layout(set=0,binding=8) uniform sampler2D spatial_b_long;
layout(set=0,binding=9) uniform sampler2D spatial_c_long;
layout(set=0,binding=10) uniform sampler2D spatial_b_mid;
layout(set=0,binding=11) uniform sampler2D spatial_c_mid;
layout(set=0,binding=12) uniform sampler2D spatial_b_short;
layout(set=0,binding=13) uniform sampler2D spatial_c_short;
// 32 bytes/contact: target.xz, previous_q.xz; mode,warm,vehicle,contact.
struct Input { vec4 coordinates; uvec4 identity; };
layout(std430,set=0,binding=14) readonly buffer Inputs { Input queries[]; };
layout(std430,set=0,binding=15) writeonly buffer Outputs { vec4 words[]; };
layout(push_constant,std430) uniform Params {
    vec4 domains_sea;
    vec4 field_rectangle;
    vec4 warp_rectangle;
    vec4 settings; // detj_safe, coastal_enabled, derivative_epsilon, tolerance
    vec4 scales_time; // horizontal scale, vertical scale, sample_time, compact
    uvec4 metadata; // count, request generation, config version, ocean epoch
} p;

ivec2 wrap(ivec2 v, ivec2 n) { return (v%n+n)%n; }
dvec4 fetch_value(sampler2D t, ivec2 v, bool periodic, bool signed_spatial) {
    ivec2 n=textureSize(t,0), c=periodic?wrap(v,n):clamp(v,ivec2(0),n-1);
    dvec4 value=texelFetch(t,c,0);
    if(signed_spatial) value*=(((c.x+c.y)&1)==0?1.0:-1.0)/double(n.x*n.y);
    return value;
}
dvec4 bilinear(sampler2D t, dvec2 uv, bool periodic, bool signed_spatial) {
    dvec2 pixel=(periodic?fract(uv):clamp(uv,dvec2(0),dvec2(1)))*dvec2(textureSize(t,0))-0.5;
    ivec2 lo=ivec2(floor(pixel)); dvec2 f=fract(pixel);
    return mix(mix(fetch_value(t,lo,periodic,signed_spatial),fetch_value(t,lo+ivec2(1,0),periodic,signed_spatial),f.x),
               mix(fetch_value(t,lo+ivec2(0,1),periodic,signed_spatial),fetch_value(t,lo+ivec2(1),periodic,signed_spatial),f.x),f.y);
}
dvec2 fft_uv(dvec2 q,double domain) { return q/domain+0.5; }
// Exact PHYS-OPT-2I one authored cell feather; no hardware sampler dependence.
double edge_weight(dvec2 uv) {
    dvec2 cells=min(uv,1.0-uv)*dvec2(textureSize(coastal_field,0)-ivec2(1));
    double t=clamp(min(cells.x,cells.y),0.0,1.0); return t*t*(3.0-2.0*t);
}
void surface(dvec2 q,out dvec3 d,out dvec3 v) {
    dvec2 ul=fft_uv(q,p.domains_sea.x), um=fft_uv(q,p.domains_sea.y), us=fft_uv(q,p.domains_sea.z);
    dvec3 dl=bilinear(displacement_long,ul,true,false).xyz;
    dvec3 vl=bilinear(velocity_long,ul,true,false).xyz;
    if(p.settings.y>0.5) {
        dvec2 uv=(q-p.field_rectangle.xy)/p.field_rectangle.zw;
        if(all(greaterThanEqual(uv,dvec2(0)))&&all(lessThanEqual(uv,dvec2(1)))) {
            dvec4 field=bilinear(coastal_field,uv,false,false);
            dvec4 warp_value=bilinear(coastal_warp,(q-p.warp_rectangle.xy)/p.warp_rectangle.zw,false,false);
            double confidence=field.a*smoothstep(0.0,p.settings.x,warp_value.z)*warp_value.w*edge_weight(uv);
            dvec2 uw=fft_uv(warp_value.xy,p.domains_sea.x);
            dl=mix(dl,bilinear(displacement_long,uw,true,false).xyz,confidence);
            vl=mix(vl,bilinear(velocity_long,uw,true,false).xyz,confidence);
            double shoal=mix(1.0,field.g,confidence); dl.y*=shoal; vl.y*=shoal;
        }
    }
    d=dl+bilinear(displacement_mid,um,true,false).xyz+bilinear(displacement_short,us,true,false).xyz;
    v=vl+bilinear(velocity_mid,um,true,false).xyz+bilinear(velocity_short,us,true,false).xyz;
    dvec3 scale=dvec3(p.scales_time.x,p.scales_time.y,p.scales_time.x); d*=scale; v*=scale;
}
dvec3 displacement(dvec2 q) { dvec3 d,v; surface(q,d,v); return d; }
void spectral_derivative(sampler2D b,sampler2D c,dvec2 q,double domain,out dvec3 dx,out dvec3 dz) {
    dvec4 bv=bilinear(b,fft_uv(q,domain),true,true), cv=bilinear(c,fft_uv(q,domain),true,true);
    dvec3 scale=dvec3(1.0,p.scales_time.y/p.scales_time.x,1.0);
    dx=dvec3(bv.z,bv.w,cv.z)*scale; dz=dvec3(cv.z,cv.y,cv.x)*scale;
}
void derivatives(dvec2 q,out dvec3 dx,out dvec3 dz) {
    if(p.settings.y>0.5) {
        double e=p.settings.z;
        dx=(displacement(q+dvec2(e,0))-displacement(q-dvec2(e,0)))/(2.0*e);
        dz=(displacement(q+dvec2(0,e))-displacement(q-dvec2(0,e)))/(2.0*e);
    } else {
        dvec3 ax,az,bx,bz,cx,cz;
        spectral_derivative(spatial_b_long,spatial_c_long,q,p.domains_sea.x,ax,az);
        spectral_derivative(spatial_b_mid,spatial_c_mid,q,p.domains_sea.y,bx,bz);
        spectral_derivative(spatial_b_short,spatial_c_short,q,p.domains_sea.z,cx,cz);
        dx=ax+bx+cx; dz=az+bz+cz;
    }
}
bool finite3(dvec3 v) { return !any(isnan(v))&&!any(isinf(v)); }
void main() {
    uint i=gl_GlobalInvocationID.x; if(i>=p.metadata.x) return;
    Input input_value=queries[i]; dvec2 target=input_value.coordinates.xy;
    dvec2 q=input_value.identity.x==1u&&input_value.identity.y!=0u?input_value.coordinates.zw:target;
    uint iterations=0u;
    if(input_value.identity.x==1u) {
        for(;iterations<12u;iterations++) {
            dvec2 r=q+displacement(q).xz-target; double residual=length(r);
            if(residual<=p.settings.w) break;
            // Resolve the LOCAL owned branch. A 5 cm stencil can span many
            // folds at authored mask transitions and hide the local gradient.
            double e=0.0001;
            dvec2 x=(displacement(q+dvec2(e,0)).xz-displacement(q-dvec2(e,0)).xz)/(2.0*e)+dvec2(1,0);
            dvec2 z=(displacement(q+dvec2(0,e)).xz-displacement(q-dvec2(0,e)).xz)/(2.0*e)+dvec2(0,1);
            double determinant=x.x*z.y-z.x*x.y; if(abs(determinant)<1e-6) break;
            dvec2 step=dvec2(z.y*r.x-z.x*r.y,-x.y*r.x+x.x*r.y)/determinant;
            bool accepted=false; double fraction=1.0;
            for(int trial=0;trial<10;trial++) {
                dvec2 candidate=q-step*fraction;
                if(length(candidate+displacement(candidate).xz-target)<residual) { q=candidate; accepted=true; break; }
                fraction*=0.5;
            }
            if(!accepted) break;
        }
    }
    dvec3 d,v,dx,dz; surface(q,d,v); derivatives(q,dx,dz);
    dvec3 tx=dx+dvec3(1,0,0),tz=dz+dvec3(0,0,1);
    double determinant=tx.x*tz.z-tz.x*tx.z;
    dvec3 normal=cross(tz,tx); normal=length(normal)>1e-12?normalize(normal):dvec3(0,1,0); if(normal.y<0.0) normal=-normal;
    double residual=input_value.identity.x==1u?length(q+d.xz-target):0.0;
    double valid=finite3(d)&&finite3(v)&&finite3(normal)&&!any(isnan(q))&&!any(isinf(q))&&residual<=p.settings.w?1.0:0.0;
    bool compact=p.scales_time.w>0.5; uint base=i*(compact?4u:6u);
    words[base]=vec4(dvec4(q,residual,double(iterations)));
    words[base+1u]=vec4(dvec4(d,valid));
    if(compact) { words[base+2u]=vec4(dvec4(v,determinant)); words[base+3u]=vec4(dvec4(normal,valid)); }
    else {
        words[base+2u]=vec4(dvec4(q.x+d.x,p.domains_sea.w+d.y,q.y+d.z,determinant));
        words[base+3u]=vec4(dvec4(v,p.scales_time.z));
        words[base+4u]=vec4(dvec4(normal,valid));
        words[base+5u]=uintBitsToFloat(uvec4(p.metadata.y,p.metadata.z,input_value.identity.z,input_value.identity.w));
    }
}
