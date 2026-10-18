#include "../../addons/ocean/physics/native/ocean_query/src/hull_wave_core.h"
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <vector>

// Replays the study's fixed fixtures against the shipping analytic core.
// Compile separately; this executable is never linked into the extension.
int main(int argc,char **argv) {
    if(argc!=2) return 2;
    std::ifstream input(argv[1]); int cases=0; input>>cases;
    if(cases!=8) return 3;
    double error=0,checksum=0;
    std::cout<<std::setprecision(12)<<"{\"cases\":[";
    for(int ci=0;ci<cases;++ci) {
        int boats,dense,count;input>>boats>>dense>>count;
        oq::HullWaveCore core; core.clear(20.0);
        for(int i=0;i<count;++i) {
            std::array<double,23> row{};for(auto &v:row)input>>v;
            if(!core.append(row.data(),int64_t(row[18]))) return 4;
        }
        struct Point { double x,z;std::array<double,4> expected; };
        std::vector<Point> points;
        for(int boat=0;boat<boats;++boat) {
            int n;input>>n;
            for(int j=0;j<n;++j) {Point p;input>>p.x>>p.z;for(auto &v:p.expected)input>>v;points.push_back(p);}
        }
        if(!input) return 5;
        for(auto p:points) {
            auto v=core.sample(p.x,p.z);
            std::array<double,4> values{v.h,v.x,v.z,v.t};
            for(int j=0;j<4;++j)error=std::max(error,std::abs(values[j]-p.expected[j]));
        }
        std::vector<double> times;
        for(int trial=0;trial<208;++trial) {
            auto begin=std::chrono::steady_clock::now();
            for(auto p:points) {auto v=core.sample(p.x,p.z);checksum+=v.h+v.x+v.z+v.t;}
            if(trial>=16)times.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count());
        }
        std::sort(times.begin(),times.end());
        if(ci)std::cout<<',';
        std::cout<<"{\"boats\":"<<boats<<",\"dense\":"<<dense<<",\"median_ms\":"<<times[times.size()/2]<<",\"p95_ms\":"<<times[size_t(times.size()*.95)]<<'}';
    }
    std::cout<<"],\"max_reference_error\":"<<error<<",\"checksum\":"<<checksum<<"}\n";
    return error<0.0001?0:6;
}
