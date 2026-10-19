#include "phys_weather_velocity_native_fixture.h"
#include "dynamic_ocean_lite_async.h"
#include <cstring>
#include <atomic>
#include <iomanip>
#include <stdexcept>

using Field = oq::DynamicOceanPhysicsField;
using Publisher = oq::DynamicOceanLiteAsync;
static void require(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }

static void compare(const Field &a, const Field &b, uint64_t &checks) {
    const auto &x = a.lite_packed_field(), &y = b.lite_packed_field();
    require(x.size() == y.size() && std::memcmp(x.data(), y.data(), x.size()*sizeof(x[0])) == 0, "packed height/velocity mismatch");
    for (int i = 0; i < 16; ++i) {
        double av[7]{}, bv[7]{};
        const double px = i*17.13-127.0, pz = i*-11.79+89.0;
        require(a.sample_lite_surface(px,pz,1.5,av,1) && b.sample_lite_surface(px,pz,1.5,bv,1), "surface missing");
        require(a.sample_lite_horizontal_displacement(px,pz,av+5,av+6,1) &&
                b.sample_lite_horizontal_displacement(px,pz,bv+5,bv+6,1), "displacement missing");
        require(std::memcmp(av,bv,sizeof(av)) == 0, "cubic height/normal/velocity/displacement mismatch");
        checks += 7;
    }
}

static void parity(int workers, bool avx2) {
    require(Field::acquire_lite_workers(workers), "worker lease");
    require(Field::set_worker_count(6) == workers, "worker cap bypass");
    require(!Field::acquire_lite_workers(workers == 3 ? 4 : 3), "conflicting worker mode accepted");
    std::array<std::array<Field,3>,3> baseline, builders;
    std::array<std::unique_ptr<Publisher>,3> publishers;
    for (int state = 0; state < 3; ++state) {
        const auto source = spectrum(400.0 + state*200.0, 0.8 + state*0.3);
        for (int band = 0; band < 3; ++band) {
            const double minimum_wavelength = state == 0 ? 1.0 : 0.0;
            require(baseline[state][band].configure_lite(source[band],128,minimum_wavelength), "baseline configure");
            require(builders[state][band].configure_lite(source[band],128,minimum_wavelength), "async configure");
        }
        publishers[state] = std::make_unique<Publisher>(std::move(builders[state]), avx2);
    }
    uint64_t checks = 0, rebases = 0;
    double times[3] = {0,0,0};
    double rates[3] = {1.0,0.71,1.3};
    std::atomic<bool> stop{false}, reader_ok{true};
    Publisher::SnapshotPtr pinned;
    std::thread reader;
    struct ReaderGuard {
        std::atomic<bool> &stop;
        std::thread &reader;
        ~ReaderGuard() { stop.store(true); if (reader.joinable()) reader.join(); }
    } reader_guard{stop,reader};
    for (uint64_t tick = 0; tick < 1060; ++tick) {
        if (tick == 450) rates[1] = 0.9;
        for (int state = 0; state < 3; ++state) {
            if (tick != 0 && tick != 100) times[state] += rates[state]/60.0;
            if (tick == 200) times[state] = 0.5;
            if (tick == 400) times[state] += 1.0;
            require(publishers[state]->request({tick,1,1,times[state]}), "request");
        }
        for (int state = 0; state < 3; ++state) {
            auto snapshot = publishers[state]->consume({tick,1,1,times[state]});
            require(snapshot && snapshot->valid && snapshot->key.tick == tick && snapshot->key.time == times[state], "stale snapshot");
            for (int band = 0; band < 3; ++band) {
                require(baseline[state][band].build_lite(times[state],avx2), "baseline build");
                compare(baseline[state][band],snapshot->bands[band],checks);
                if (baseline[state][band].profile().phase_reason == 4) ++rebases;
            }
            if (tick == 0 && state == 0) {
                pinned = snapshot;
                double original[5]{};
                require(pinned->bands[0].sample_lite_surface(7.13,-9.7,0,original,1), "pinned initial sample");
                reader = std::thread([&, original = std::array<double,5>{original[0],original[1],original[2],original[3],original[4]}] {
                    while (!stop.load()) {
                        double current[5]{};
                        if (!pinned->bands[0].sample_lite_surface(7.13,-9.7,0,current,1) ||
                            std::memcmp(current,original.data(),sizeof(current)) != 0) reader_ok.store(false);
                        std::this_thread::yield();
                    }
                });
            }
        }
        for (int state = 0; state < 3; ++state)
            require(publishers[state]->request({tick+1,1,1,times[state]+rates[state]/60.0}), "prediction");
    }
    stop.store(true); reader.join(); require(reader_ok.load(), "retained snapshot overwritten");
    require(rebases > 0, "phase rebase not exercised");
    for (int state = 0; state < 3; ++state) {
        // Hot rollback must retire the unconsumed prediction and preserve the
        // accepted phase, including the periodic rebase counter.
        std::array<Field,3> restored;
        publishers[state]->release_builders(restored);
        for (int band = 0; band < 3; ++band) {
            const double next = times[state]+rates[state]/60.0;
            require(restored[band].build_lite(next,avx2) && baseline[state][band].build_lite(next,avx2), "rollback build");
            compare(baseline[state][band],restored[band],checks);
        }
    }
    const auto occupancy = Field::worker_stats();
    require(occupancy[6] <= static_cast<uint64_t>(workers), "oversubscription");
    for (int i = 0; i < workers; ++i) require(occupancy[i] > 0, "idle worker");
    std::cout << "PASS workers=" << workers << " avx2=" << avx2 << " exact_values=" << checks
              << " rebases=" << rebases << " peak_jobs=" << occupancy[6] << " jobs=";
    for (int i=0;i<workers;++i) std::cout << occupancy[i] << ',';
    std::cout << '\n';
    publishers = {};
    double retained[5]{};
    require(pinned->bands[0].sample_lite_surface(7.13,-9.7,0,retained,1), "lease lost during shutdown");
    pinned.reset(); Field::release_lite_workers();
}

static void scalar_control() {
    const auto source = spectrum(600.0,1.3);
    std::array<Field,3> scalar, avx;
    for (int band=0;band<3;++band) {
        require(scalar[band].configure_lite(source[band],128) && avx[band].configure_lite(source[band],128), "control configure");
    }
    double maximum = 0.0, time = 0.0;
    uint64_t values = 0;
    for (int tick=0;tick<610;++tick) {
        time += 1.0/60.0;
        for (int band=0;band<3;++band) {
            require(scalar[band].build_lite(time,false) && avx[band].build_lite(time,true), "control build");
            const auto &a = scalar[band].lite_packed_field(), &b = avx[band].lite_packed_field();
            for (size_t i=0;i<a.size();++i) { maximum = std::max(maximum,std::abs(a[i]-b[i])); values += 2; }
        }
    }
    std::cout << std::setprecision(17) << "SCALAR_AVX2 values=" << values << " max_complex_error=" << maximum << '\n';
    require(maximum <= 1e-9,"scalar/AVX2 unexpected difference");
}

static void sparse_history_control(bool avx2) {
    require(Field::acquire_lite_workers(3),"sparse worker lease");
    const auto source = spectrum(600.0,1.3);
    std::array<Field,3> sparse, builders;
    for (int band=0;band<3;++band) {
        require(sparse[band].configure_lite(source[band],128) && builders[band].configure_lite(source[band],128),"sparse configure");
    }
    std::array<double,7> maximum{};
    uint64_t float_mismatches = 0, compared = 0;
    {
        Publisher publisher(std::move(builders),avx2);
        double time = 0.0;
        for (uint64_t tick=0;tick<1060;++tick) {
            time += 1.0/60.0;
            auto snapshot = publisher.consume({tick,1,1,time});
            require(bool(snapshot),"sparse snapshot");
            const bool queried = tick < 10 || (tick >= 210 && tick < 230) || (tick >= 500 && tick < 520) || tick >= 1000;
            if (!queried) continue;
            for (int band=0;band<3;++band) {
                require(sparse[band].build_lite(time,avx2),"sparse baseline");
                for (int point=0;point<64;++point) {
                    const double x=point*17.13-200.0,z=point*-11.79+100.0;
                    double a[7]{},b[7]{};
                    require(sparse[band].sample_lite_surface(x,z,0,a,1) && snapshot->bands[band].sample_lite_surface(x,z,0,b,1),"sparse sample");
                    require(sparse[band].sample_lite_horizontal_displacement(x,z,a+5,a+6,1) && snapshot->bands[band].sample_lite_horizontal_displacement(x,z,b+5,b+6,1),"sparse displacement");
                    for(int value=0;value<7;++value) {
                        maximum[value]=std::max(maximum[value],std::abs(a[value]-b[value]));
                        const float af=static_cast<float>(a[value]),bf=static_cast<float>(b[value]);
                        if(std::memcmp(&af,&bf,sizeof(float))) ++float_mismatches;
                        ++compared;
                    }
                }
            }
        }
    }
    std::cout << std::setprecision(17) << "SPARSE_HISTORY avx2=" << avx2 << " values=" << compared << " float_mismatches=" << float_mismatches << " maximum_h_vy_nx_ny_nz_dx_dz=";
    for(double error:maximum) { std::cout << error << ','; require(error<=1e-9,"unexpected sparse-history error"); }
    std::cout << '\n';
    Field::release_lite_workers();
}

int main() {
    try {
        oq::OceanQueryCore core;
        parity(3,false); parity(4,false);
        if (core.avx2_supported()) { parity(3,true); parity(4,true); scalar_control(); sparse_history_control(true); }
        else std::cout << "AVX2 unavailable: skipped\n";
        return 0;
    } catch(const std::exception &e) { std::cerr << "FAIL " << e.what() << '\n'; return 1; }
}
