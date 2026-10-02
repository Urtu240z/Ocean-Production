// Matched producer-only A/B harness: compile against checkpoint and current
// native sources. No rendering/oracle/query work inside the timed build loop.
#include "phys_weather_velocity_native_fixture.h"
#include <vector>

int main(int argc, char **argv) {
    const bool moving_weather = argc > 1 && std::string(argv[1]) == "weather";
    oq::DynamicOceanPhysicsField::set_worker_count(5);
    const auto a = spectrum(400.0, 0.8), b = spectrum(950.0, 2.0);
    std::array<oq::DynamicOceanPhysicsField, 3> fields;
    if (!initialize(fields, a, true)) return 1;
    oq::DynamicOceanAsyncPublisher publisher(fields, a, 0.0, 0, 1, true);
    if (moving_weather) publisher.transition_configuration(
        oq::DynamicOceanAsyncPublisher::prepare_spectrum(a),
        oq::DynamicOceanAsyncPublisher::prepare_spectrum(b), 1.0, 30.0, 2);
    std::vector<double> builds, prep, evolution, frequency;
    for (int tick = 0; tick < 720; ++tick) {
        const double time = 2.0 + tick / 60.0;
        auto s = await_field(publisher, time, moving_weather ? 2 : 1);
        if (!s) return 2;
        const auto profile = publisher.stats();
        if (tick < 120) continue;
        builds.push_back(profile.last_build_duration_us / 1000.0);
        prep.push_back(profile.last_batch_profile.prepare_barrier_us / 1000.0);
        double longest_evolve = 0.0, longest_frequency = 0.0;
        for (const auto &band : profile.last_band_profile) {
            longest_evolve = std::max(longest_evolve, band.evolve_us / 1000.0);
            longest_frequency = std::max(longest_frequency, band.frequency_prepare_us / 1000.0);
        }
        evolution.push_back(longest_evolve); frequency.push_back(longest_frequency);
    }
    publisher.shutdown();
    const auto print = [](const char *name, std::vector<double> samples) {
        double sum = 0.0; for (double value : samples) sum += value;
        std::sort(samples.begin(), samples.end());
        std::cout << name << " mean=" << sum / samples.size() << " p95=" << samples[569]
            << " p99=" << samples[593] << " max=" << samples.back() << '\n';
    };
    std::cout << "weather=" << moving_weather << " measured=600 warmup=120 workers=5 N=256x3 IFFTs=18\n";
    print("build_ms", builds); print("prepare_ms", prep);
    print("evolve_ms", evolution); print("frequency_ms", frequency);
    return 0;
}
