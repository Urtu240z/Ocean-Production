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
// Persistent contacts are indexed by stable slot, not by packet ordering.
// Occupant generation prevents a recycled slot from inheriting another hull.
struct ContactState { dvec2 q; dvec2 target; uvec4 owner; uvec4 stamp; vec4 motion; };
layout(std430,set=0,binding=16) buffer ContactStates { ContactState contacts[]; };
struct Control { uvec4 lifetime; vec4 hint; };
layout(std430,set=0,binding=17) readonly buffer Controls { Control controls[]; };
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
bool finite2(dvec2 v) { return !any(isnan(v))&&!any(isinf(v)); }
double local_jacobian(dvec2 q,out dvec2 x,out dvec2 z) {
    double e=0.0001;
    x=(displacement(q+dvec2(e,0)).xz-displacement(q-dvec2(e,0)).xz)/(2.0*e)+dvec2(1,0);
    z=(displacement(q+dvec2(0,e)).xz-displacement(q-dvec2(0,e)).xz)/(2.0*e)+dvec2(0,1);
    return x.x*z.y-z.x*x.y;
}
// Radius and orientation are branch guards, not residual concessions. Never
// project/clamp a failed q into a valid result or cross a fold to lower residual.
bool solve(dvec2 target,inout dvec2 q,dvec2 anchor,double radius,double orientation,
           uint limit,out uint iterations,out uint reason) {
    reason=0u;
    for(iterations=0u;iterations<limit;iterations++) {
        dvec2 r=q+displacement(q).xz-target; double residual=length(r);
        if(!finite2(r)) { reason=1u; return false; }
        if(residual<=p.settings.w) return true;
        dvec2 x,z; double determinant=local_jacobian(q,x,z);
        if(abs(determinant)<1e-8) { reason=2u; return false; }
        if(orientation!=0.0&&determinant*orientation<=0.0) { reason=5u; return false; }
        dvec2 step=dvec2(z.y*r.x-z.x*r.y,-x.y*r.x+x.x*r.y)/determinant;
        bool accepted=false; double fraction=1.0;
        for(int trial=0;trial<12;trial++) {
            dvec2 candidate=q-step*fraction;
            bool guarded=radius>0.0&&length(candidate-anchor)>radius;
            if(!guarded&&orientation!=0.0) {
                dvec2 a,b;
                guarded=local_jacobian(candidate,a,b)*orientation<=0.0||local_jacobian((candidate+q)*0.5,a,b)*orientation<=0.0;
            }
            if(!guarded&&length(candidate+displacement(candidate).xz-target)<residual) { q=candidate; accepted=true; break; }
            fraction*=0.5;
        }
        if(!accepted) { reason=3u; return false; }
    }
    if(length(q+displacement(q).xz-target)<=p.settings.w) return true;
    reason=4u; return false;
}
void main() {
    uint i=gl_GlobalInvocationID.x; if(i>=p.metadata.x) return;
    Input input_value=queries[i]; dvec2 target=input_value.coordinates.xy;
    dvec2 q=input_value.identity.x==1u&&input_value.identity.y!=0u?input_value.coordinates.zw:target;
    uint iterations=0u, status=0u, reason=0u, solves=0u;
    bool persistent=input_value.identity.x==2u, owned=false, enabled=true;
    Control control; ContactState state; dvec2 previous=q; double radius=0.0, orientation=0.0;
    if(persistent) {
        control=controls[i]; state=contacts[control.lifetime.x];
        bool same=state.owner.x==input_value.identity.z&&state.owner.y==input_value.identity.w&&state.owner.z==control.lifetime.y&&state.stamp.x==p.metadata.w;
        enabled=(control.lifetime.z&1u)!=0u&&finite2(target);
        owned=same&&state.stamp.w!=0u&&(control.lifetime.z&2u)==0u;
        bool explicit_root=(control.lifetime.z&8u)!=0u;
        if(explicit_root) { owned=true; state.q=control.hint.xy; state.target=target; state.motion=vec4(0,0,p.scales_time.z,0); }
        previous=owned?state.q:target;
        q=previous;
        if(owned) {
            double dt=max(0.0,double(p.scales_time.z)-double(state.motion.z));
            dvec2 a,b; double jac=local_jacobian(q,a,b);
            // Motion in q is amplified by the inverse horizontal Jacobian.
            // A world-distance-only radius loses ordinary compressed crests.
            dvec2 r=target-(q+displacement(q).xz);
            dvec2 predicted=abs(jac)>1e-8?dvec2(b.y*r.x-b.x*r.y,-a.y*r.x+a.x*r.y)/jac:dvec2(0);
            radius=max(2.0*max(length(predicted),length(target-state.target))+2.0*(1.0+length(state.motion.xy))*dt
                       +2.0*length(displacement(q).xz)+2.0*length(q-state.target)+0.05,0.1);
            orientation=explicit_root?sign(jac):sign(state.motion.w);
        } else if((control.lifetime.z&4u)!=0u) q=same?state.q:dvec2(control.hint.xy);
        if(!finite2(target)) { q=dvec2(0); previous=q; }
        bool success=false;
        // Reserved control lane is accepted only with validation metrics on:
        // deterministic recovery-path timing, never a runtime quality fallback.
        if(enabled&&control.lifetime.w==0u) { solves++; success=solve(target,q,previous,radius,orientation,16u,iterations,reason); }
        uint total_iterations=iterations;
        status=owned?1u:3u; // CONTINUED / COLD_ACQUIRED
        if(enabled&&!success) {
            // Four cardinal seeds. Warm recovery stays within its local guard;
            // cold seeds are acquisition with no invented branch ownership.
            double seed_radius=owned?min(radius*0.5,0.25):clamp(length(displacement(target).xz)*0.5,0.25,1.5);
            dvec2 offsets[4]=dvec2[4](dvec2(1,0),dvec2(-1,0),dvec2(0,1),dvec2(0,-1));
            double nearest=1e30; dvec2 best=q;
            for(int seed=0;seed<4;seed++) {
                dvec2 candidate=(owned?previous:target)+offsets[seed]*seed_radius;
                uint count,why; solves++;
                if(solve(target,candidate,previous,radius,orientation,16u,count,why)) {
                    double distance=length(candidate-previous);
                    if(distance<nearest) { nearest=distance; best=candidate; success=true; }
                }
                total_iterations+=count;
            }
            if(success) { q=best; status=owned?2u:3u; reason=0u; }
        }
        iterations=total_iterations;
        if(!success) status=4u; // FAILED is always invalid, including inactive.
        if(!enabled) reason=finite2(target)?6u:1u;
    }
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
    double residual=input_value.identity.x!=0u?length(q+d.xz-target):0.0;
    double valid=finite3(d)&&finite3(v)&&finite3(normal)&&!any(isnan(q))&&!any(isinf(q))&&residual<=p.settings.w?1.0:0.0;
    if(persistent) {
        if(status==4u) valid=0.0;
        if(valid<0.5) status=4u;
        dvec2 a,b; double jac=local_jacobian(q,a,b);
        contacts[control.lifetime.x].q=valid>0.5?q:previous;
        contacts[control.lifetime.x].target=target;
        contacts[control.lifetime.x].owner=uvec4(input_value.identity.zw,control.lifetime.y,enabled?1u:0u);
        contacts[control.lifetime.x].stamp=uvec4(p.metadata.w,p.metadata.y,status,valid>0.5?1u:0u);
        contacts[control.lifetime.x].motion=vec4(v.x,v.z,p.scales_time.z,jac);
    }
    bool compact=p.scales_time.w>0.5; uint ordinary_stride=compact?4u:6u;
    uint base=i*(ordinary_stride+(persistent?2u:0u));
    words[base]=vec4(dvec4(q,residual,double(iterations)));
    words[base+1u]=vec4(dvec4(d,valid));
    if(compact) { words[base+2u]=vec4(dvec4(v,determinant)); words[base+3u]=vec4(dvec4(normal,valid)); }
    else {
        words[base+2u]=vec4(dvec4(q.x+d.x,p.domains_sea.w+d.y,q.y+d.z,determinant));
        words[base+3u]=vec4(dvec4(v,p.scales_time.z));
        words[base+4u]=vec4(dvec4(normal,valid));
        words[base+5u]=uintBitsToFloat(uvec4(p.metadata.y,p.metadata.z,input_value.identity.z,input_value.identity.w));
    }
    if(persistent) {
        words[base+ordinary_stride]=uintBitsToFloat(uvec4(status,solves,reason,owned?1u:0u));
        words[base+ordinary_stride+1u]=vec4(previous,length(q-previous),radius);
    }
}
