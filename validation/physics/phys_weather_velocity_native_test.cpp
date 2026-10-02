#include "phys_weather_velocity_native_fixture.h"

int main() {
    oq::DynamicOceanPhysicsField::set_worker_count(5);
    const auto a = spectrum(400.0, 0.8), b = spectrum(950.0, 2.0);
    std::array<oq::DynamicOceanPhysicsField, 3> scalar_fields, simd_fields;
    if (!initialize(scalar_fields, a, false) || !initialize(simd_fields, a, true)) return 1;
    oq::DynamicOceanAsyncPublisher scalar(scalar_fields, a, 0.0, 0, 1, false);
    oq::DynamicOceanAsyncPublisher simd(simd_fields, a, 0.0, 0, 1, true);
    auto source = oq::DynamicOceanAsyncPublisher::prepare_spectrum(a);
    auto target = oq::DynamicOceanAsyncPublisher::prepare_spectrum(b);
    double maximum = 0.0;
    size_t compared = 0;
    // Exact endpoints, intermediate envelope, phase rebase, reversed weather.
    for (int test = 0; test < 6; ++test) {
        const uint64_t version = 2 + test;
        const double start = 10.0 + test * 12.0;
        const double alpha = test % 3 == 0 ? 0.0 : test % 3 == 1 ? 0.5 : 1.0;
        scalar.transition_configuration(test < 3 ? source : target, test < 3 ? target : source, start, 3.0, version);
        simd.transition_configuration(test < 3 ? source : target, test < 3 ? target : source, start, 3.0, version);
        auto x = await_field(scalar, start + alpha * 3.0, version);
        auto y = await_field(simd, start + alpha * 3.0, version);
        if (!x || !y || x->weather_alpha != y->weather_alpha) return 2;
        for (int band = 0; band < 3; ++band) {
            if (x->production_h0[band] != y->production_h0[band]) return 3;
            for (int j = 0; j < 256; ++j) {
                double xv[12], yv[12];
                const auto &bx = x->bands[band]; const auto &by = y->bands[band];
                oq::DynamicOceanPhysicsField::sample_material_q_packed_from(bx.packed_fields, 256, bx.domain_m,
                    j * 13.37 - 700.0, j * -7.31 + 350.0, xv);
                oq::DynamicOceanPhysicsField::sample_material_q_packed_from(by.packed_fields, 256, by.domain_m,
                    j * 13.37 - 700.0, j * -7.31 + 350.0, yv);
                for (int field = 0; field < 12; ++field) {
                    maximum = std::max(maximum, std::abs(xv[field] - yv[field])); ++compared;
                }
            }
        }
    }
    scalar.shutdown(); simd.shutdown();
    std::cout << "scalar_avx_fields=" << compared << " max_error=" << maximum << '\n';
    return maximum <= 1e-9 ? 0 : 4;
}
