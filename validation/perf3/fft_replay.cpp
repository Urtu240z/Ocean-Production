#define NOMINMAX
#include <windows.h>
#include <intrin.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <vector>
#include "perf3_fft_probe.h"
#include "dynamic_ocean_fft_avx2.h"

struct Replay {
    oq::Perf3FftHeader h;
    std::vector<uint32_t> reverse;
    std::vector<double> re,im,rd,id;
    std::array<size_t,32> offsets{};
    std::vector<std::complex<double>> input,expected,work,scratch;
    void execute() {
        const int n=h.n;
        for(int y=0;y<n;++y)oq::inverse_fft_1d_avx2(work.data()+size_t(y)*n,n,reverse.data(),re.data(),im.data(),rd.data(),id.data(),offsets.data(),h.stages);
        constexpr int tile=16;
        for(int y0=0;y0<n;y0+=tile)for(int x0=0;x0<n;x0+=tile)
            for(int y=y0;y<std::min(y0+tile,n);++y)for(int x=x0;x<std::min(x0+tile,n);++x)
                scratch[size_t(x)*n+y]=work[size_t(y)*n+x];
        for(int y=0;y<n;++y)oq::inverse_fft_1d_avx2(scratch.data()+size_t(y)*n,n,reverse.data(),re.data(),im.data(),rd.data(),id.data(),offsets.data(),h.stages);
    }
    bool load(const std::filesystem::path &path) {
        std::ifstream f(path,std::ios::binary);if(!f.read(reinterpret_cast<char*>(&h),sizeof(h)))return false;
        if(h.magic!=0x3346514f || h.version!=1 || h.n<2 || h.n>128 || (h.n&(h.n-1)) || h.stages>7 ||
            (h.mxcsr_before&~0xffffu) || (h.mxcsr_before&0x1f80u)!=0x1f80u)return false;
        const size_t n=h.n,count=n*n;
        reverse.resize(n);re.resize(n-1);im.resize(n-1);rd.resize(2*(n-1));id.resize(2*(n-1));input.resize(count);expected.resize(count);work.resize(count);scratch.resize(count);
        auto read=[&](void *p,size_t bytes){return bool(f.read(reinterpret_cast<char*>(p),bytes));};
        if(!read(reverse.data(),n*4) || !read(re.data(),(n-1)*8) || !read(im.data(),(n-1)*8) ||
            !read(rd.data(),2*(n-1)*8) || !read(id.data(),2*(n-1)*8) || !read(offsets.data(),32*8) ||
            !read(input.data(),count*16) || !read(expected.data(),count*16))return false;
        if(f.peek()!=std::char_traits<char>::eof())return false;
        int bits=0;for(size_t k=n;k>1;k>>=1)++bits;
        if(h.stages!=uint32_t(bits))return false;
        for(auto v:reverse)if(v>=n)return false;
        for(uint32_t i=0;i<h.stages;++i)if(offsets[i]>(n-1)-(size_t(1)<<i))return false;
        return true;
    }
};
static uint64_t hash(const void *p,size_t bytes) {
    const auto *b=static_cast<const uint8_t*>(p);uint64_t h=14695981039346656037ull;
    for(size_t i=0;i<bytes;++i){h^=b[i];h*=1099511628211ull;}return h;
}
static bool avx2() {int r[4];__cpuid(r,1);if(!(r[2]&(1<<27)) || (_xgetbv(0)&6)!=6)return false;__cpuidex(r,7,0);return r[1]&(1<<5);}
static size_t subnormals(const std::vector<std::complex<double>> &v) {
    size_t count=0;const auto *b=reinterpret_cast<const uint64_t*>(v.data());
    for(size_t i=0;i<v.size()*2;++i)if((b[i]&0x7ff0000000000000ull)==0 && (b[i]&0x000fffffffffffffull))++count;
    return count;
}
static std::string run(Replay &r,bool cold,bool ftz,int iterations) {
    const auto original=_mm_getcsr();uint32_t control=r.h.mxcsr_before;
    if(ftz)control|=(1u<<15)|(1u<<6);
    _mm_setcsr(control);
    for(int warmup=0;warmup<32;++warmup){std::memcpy(r.work.data(),r.input.data(),r.input.size()*16);r.execute();}
    std::vector<double> times;std::vector<uint64_t> pressure(cold?4*1024*1024:0);volatile uint64_t witness=0;
    bool exact=true;double max_error=0;
    for(int iteration=0;iteration<iterations;++iteration) {
        if(cold)for(size_t i=0;i<pressure.size();i+=8){pressure[i]+=i+1;witness^=pressure[i];}
        std::memcpy(r.work.data(),r.input.data(),r.input.size()*16);
        const auto begin=std::chrono::steady_clock::now();r.execute();const auto end=std::chrono::steady_clock::now();
        times.push_back(std::chrono::duration<double,std::micro>(end-begin).count());
        exact=exact && std::memcmp(r.scratch.data(),r.expected.data(),r.expected.size()*16)==0;
        if(iteration==0)for(size_t i=0;i<r.expected.size();++i)max_error=std::max(max_error,std::abs(r.scratch[i]-r.expected[i]));
    }
    _mm_setcsr(original);std::sort(times.begin(),times.end());
    std::ostringstream out;out<<std::setprecision(12)<<"{\"mode\":\""<<(ftz?"offline_ftz_daz":cold?"cache_pressure_32MiB":"captured_control")
        <<"\",\"iterations\":"<<iterations<<",\"median_us\":"<<times[times.size()/2]<<",\"p95_us\":"<<times[size_t((times.size()-1)*.95)]
        <<",\"max_us\":"<<times.back()<<",\"bit_exact\":"<<(exact?"true":"false")<<",\"max_abs_error\":"<<max_error
        <<",\"output_fnv1a64\":\""<<std::hex<<hash(r.scratch.data(),r.scratch.size()*16)<<"\"}";
    (void)witness;return out.str();
}
int wmain(int argc,wchar_t **argv) {
    if(!avx2()){std::cerr<<"AVX2 unavailable\n";return 1;}
    if(argc<3){std::cerr<<"Usage: fft_replay snapshot.bin report.json [iterations]\n";return 1;}
    Replay r;if(!r.load(argv[1])){std::cerr<<"Invalid snapshot\n";return 1;}
    int iterations=argc>3?_wtoi(argv[3]):200;if(iterations<1 || iterations>100000)return 1;
    const auto captured=run(r,false,false,iterations);
    const auto pressure=run(r,true,false,iterations);
    const auto ftz=run(r,false,true,iterations);
    std::ostringstream out;out<<"{\"schema_version\":1,\"process_frame\":"<<r.h.frame<<",\"physics_tick\":"<<r.h.tick
        <<",\"band\":"<<r.h.band<<",\"pair\":"<<r.h.pair<<",\"resolution\":"<<r.h.n<<",\"captured_ifft_us\":"<<r.h.ifft_us
        <<",\"captured_mxcsr\":"<<r.h.mxcsr_before<<",\"captured_input_copy_us\":"<<r.h.input_copy_us
        <<",\"input_subnormal_components\":"<<subnormals(r.input)<<",\"input_fnv1a64\":\""<<std::hex<<hash(r.input.data(),r.input.size()*16)<<std::dec
        <<"\",\"notes\":\"same AVX2 kernel and captured twiddles; 32 warmups per mode; timed IFFT excludes input copy and cache pressure pass; copying input warms part of cache, this is not a guaranteed cold cache test; no affinity or priority changes; sequential timing differences are not causal proof; FTZ/DAZ modified only in this separate replay process\",\"runs\":["
        <<captured<<","<<pressure<<","<<ftz<<"]}";
    std::ofstream f(std::filesystem::path(argv[2]),std::ios::binary);f<<out.str();if(!f)return 1;
    std::cout<<"PERF3_REPLAY "<<out.str()<<"\n";
    return captured.find("\"bit_exact\":true")!=std::string::npos?0:2;
}
