#pragma once
// Finite hull-wave packets, independent of FFT fields and render resources.
// Row ABI matches hull_wave_state.gd; returned derivatives are in world metres.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace oq {
struct HullWaveValue { double h=0, x=0, z=0, t=0; };
struct HullWavePacket {
    std::array<double,18> p{};
    int64_t owner=0;
    double frequency=0, inv_sigma2=0, ex=0, ez=0;
};
class HullWaveCore {
    struct Contribution : HullWaveValue { double w=0, wx=0, wz=0; };
    std::array<HullWavePacket,128> packets_{};
    size_t count_=0;
    double clock_=0;
    static double unit(double x) { return std::clamp(x,0.0,1.0); }
    static double smooth(double x) { x=unit(x); return x*x*(3-2*x); }
    static double smooth_d(double x) { x=unit(x); return 6*x*(1-x); }
    Contribution packet(const HullWavePacket &v, double x, double z,
                        int64_t consumer, double cx, double cz, double own_seconds, double own_radius) const {
        const auto &p=v.p;
        Contribution out;
        const double dx=x-p[0], dz=z-p[1];
        double age=clock_-p[10], gx=0,gz=0,agx=0,agz=0,aw=1,awx=0,awz=0;
        double sw=1,swx=0,swz=0,swt=0,dist=0;
        if(p[17]>.5) {
            const double radius=std::hypot(dx,dz);
            dist=radius-p[5]*age; gx=dx/std::max(radius,.001); gz=dz/std::max(radius,.001);
        } else {
            const double along=dx*p[2]+dz*p[3], across=-dx*p[3]+dz*p[2];
            age-=along*p[13]; agx=-p[2]*p[13]; agz=-p[3]*p[13];
            const double lateral=std::sqrt(across*across+.0625);
            dist=lateral-(p[14]+p[5]*age);
            gx=-p[3]*across/lateral-p[5]*agx; gz=p[2]*across/lateral-p[5]*agz;
            const double edge=std::min(std::max(p[16],.1),p[9]);
            const double a=unit((std::abs(along)-p[9]+edge)/edge);
            aw=1-smooth(a);
            const double d=-smooth_d(a)/edge*((along>0)-(along<0));
            awx=p[2]*d; awz=p[3]*d;
            const double inv=std::max(p[13],.0001), birth_edge=std::max(p[16],.1);
            const double path=((clock_-p[15])-age)/inv;
            if(path<=0) return out;
            const double b=path/birth_edge, a_birth=age/inv/birth_edge;
            const double pw=smooth(b), bw=smooth(a_birth);
            const double pd=smooth_d(b)/birth_edge, bd=smooth_d(a_birth)/birth_edge;
            sw=bw*pw; swx=p[2]*(bw*pd-bd*pw); swz=p[3]*(bw*pd-bd*pw); swt=bd/inv*pw;
        }
        if(age<=0 || age>=p[8] || std::abs(dist)>p[6]*3.5 || aw<=0) return out;
        const double envelope=std::exp(-dist*dist*.5*v.inv_sigma2);
        const double rise=std::min(std::max(p[11],.05),p[8]*.8);
        const double fade=std::min(std::max(p[12],.05),p[8]-rise);
        const double r=age/rise, f=(age-p[8]+fade)/fade;
        const double rising=smooth(r), falling=1-smooth(f), decay=std::exp(-age/p[8]);
        const double temporal=rising*falling*decay;
        const double td=decay*(smooth_d(r)/rise*falling-rising*smooth_d(f)/fade-rising*falling/p[8]);
        const double oscillation=std::cos(dist*v.frequency);
        const double h=p[4]*temporal*envelope*oscillation;
        const double derivative=p[4]*temporal*envelope*(-v.frequency*std::sin(dist*v.frequency)-dist*v.inv_sigma2*oscillation);
        const double th=p[4]*envelope*oscillation*td;
        double height=h*sw, sx=(derivative*gx+th*agx)*sw+h*swx;
        double sz=(derivative*gz+th*agz)*sw+h*swz, ht=(th-p[5]*derivative)*sw+h*swt;
        // Only recent self-generated water close to this consumer is attenuated.
        // Old own wakes remain tangible on a later crossing. Include mask derivatives.
        if(consumer!=0 && consumer==v.owner && own_seconds>0 && own_radius>0) {
            const double rx=x-cx,rz=z-cz, radius=std::hypot(rx,rz);
            const double a=smooth(age/own_seconds), b=smooth(radius/own_radius);
            const double ad=smooth_d(age/own_seconds)/own_seconds;
            const double bd=smooth_d(radius/own_radius)/own_radius;
            const double weight=1-(1-a)*(1-b), scale=(1-a)*bd/std::max(radius,.001);
            sx=sx*weight+height*(ad*agx*(1-b)+scale*rx);
            sz=sz*weight+height*(ad*agz*(1-b)+scale*rz);
            ht=ht*weight+height*ad*(1-b); height*=weight;
        }
        out.h=height*aw; out.x=sx*aw+height*awx; out.z=sz*aw+height*awz;
        out.t=ht*aw; out.w=aw; out.wx=awx; out.wz=awz;
        return out;
    }
public:
    void clear(double clock) { count_=0; clock_=clock; }
    bool append(const double *row, int64_t owner) {
        if(count_>=packets_.size()) return false;
        for(int j=0;j<18;++j) if(!std::isfinite(row[j])) return false;
        if(row[6]<=0 || row[7]<=0 || row[8]<=0 || row[9]<=0 || row[5]<0 || row[13]<0) return false;
        auto &v=packets_[count_++]; std::copy(row,row+18,v.p.begin()); v.owner=owner;
        v.frequency=6.2831853/std::max(row[7],.1); v.inv_sigma2=1/(row[6]*row[6]);
        const double radius=row[5]*std::clamp(clock_-row[10]+row[9]*row[13],0.0,row[8])+row[6]*3.5+row[14];
        v.ex=row[17]>.5?radius:std::abs(row[2])*row[9]+std::abs(row[3])*radius;
        v.ez=row[17]>.5?radius:std::abs(row[3])*row[9]+std::abs(row[2])*radius;
        return true;
    }
    HullWaveValue sample(double x, double z, int64_t consumer=0, double cx=0, double cz=0,
                         double own_seconds=0, double own_radius=0, double cap=0) const {
        HullWaveValue total;
        std::array<int64_t,128> owners{}; std::array<Contribution,128> groups{}; size_t n=0;
        for(size_t i=0;i<count_;++i) {
            const auto &p=packets_[i];
            if(std::abs(x-p.p[0])>p.ex || std::abs(z-p.p[1])>p.ez) continue;
            auto v=packet(p,x,z,consumer,cx,cz,own_seconds,own_radius);
            if(p.p[17]>.5) {total.h+=v.h; total.x+=v.x; total.z+=v.z; total.t+=v.t; continue;}
            size_t g=0; while(g<n && owners[g]!=p.owner)++g;
            if(g==n) owners[n++]=p.owner;
            auto &s=groups[g]; s.h+=v.h; s.x+=v.x; s.z+=v.z; s.t+=v.t; s.w+=v.w; s.wx+=v.wx; s.wz+=v.wz;
        }
        for(size_t g=0;g<n;++g) {
            const auto &s=groups[g]; if(s.w<=.0001) continue;
            const double h=s.h/s.w, c=smooth(s.w/.15), cg=smooth_d(s.w/.15)/.15;
            total.h+=h*c; total.x+=(s.x-h*s.wx)/s.w*c+h*cg*s.wx;
            total.z+=(s.z-h*s.wz)/s.w*c+h*cg*s.wz; total.t+=s.t/s.w*c;
        }
        if(cap>0 && std::abs(total.h)>cap*.75) {
            const double tail=std::exp(-(std::abs(total.h)-cap*.75)/(cap*.25));
            total.h=std::copysign(cap*.75+cap*.25*(1-tail),total.h);
            total.x*=tail; total.z*=tail; total.t*=tail;
        }
        return total;
    }
};
} // namespace oq
