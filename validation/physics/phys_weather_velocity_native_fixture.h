#pragma once
// Shared full-resolution fixture for native correctness and producer A/B tests.
#include "dynamic_ocean_async.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <thread>

static std::array<oq::Cascade, 3> spectrum(double gain, double chop) {
    std::array<oq::Cascade, 3> result;
    constexpr int n = 256;
    const double domains[3] = {512.0, 137.0, 37.0};
    for (int band = 0; band < 3; ++band) {
        auto &c = result[band];
        c.material_resolution = n; c.material_domain_m = domains[band];
        c.production_choppiness = chop; c.inv_n2 = 1.0 / (n * n);
        for (auto *v : {&c.kx, &c.ky, &c.omega, &c.a1, &c.a2, &c.c11, &c.c12,
                       &c.c21, &c.c22, &c.parity, &c.weight, &c.h0_re, &c.h0_im, &c.h0n_re, &c.h0n_im})
            v->resize(n * n);
        for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
            const size_t i = y * n + x;
            const double kx = (x - n / 2) * 6.283185307179586 / domains[band];
            const double kz = (y - n / 2) * 6.283185307179586 / domains[band];
            const double k = std::hypot(kx, kz);
            c.kx[i] = kx; c.ky[i] = kz; c.omega[i] = std::sqrt(9.81 * k);
            c.a1[i] = k > 0.0 ? -chop * kx / k : 0.0;
            c.a2[i] = k > 0.0 ? -chop * kz / k : 0.0;
            c.c11[i] = c.a1[i] * kx; c.c12[i] = c.a1[i] * kz;
            c.c21[i] = c.a2[i] * kx; c.c22[i] = c.a2[i] * kz;
            c.parity[i] = (x + y) % 2 ? -1.0 : 1.0; c.weight[i] = 1.0;
            c.h0_re[i] = static_cast<float>(gain * std::sin(i * 0.17 + band) / (1.0 + k * k));
            c.h0_im[i] = static_cast<float>(gain * std::cos(i * 0.31 + band) / (1.0 + k * k));
            c.h0n_re[i] = static_cast<float>(gain * std::cos(i * 0.11 + band) / (1.0 + k * k));
            c.h0n_im[i] = static_cast<float>(gain * std::sin(i * 0.23 + band) / (1.0 + k * k));
        }
    }
    return result;
}

static bool initialize(std::array<oq::DynamicOceanPhysicsField, 3> &fields,
                       const std::array<oq::Cascade, 3> &c, bool avx) {
    std::array<oq::DynamicOceanPhysicsField *, 3> builders{&fields[0], &fields[1], &fields[2]};
    std::array<const oq::Cascade *, 3> bands{&c[0], &c[1], &c[2]};
    return oq::DynamicOceanPhysicsField::build_all(builders, bands, 0.0, avx);
}

static oq::DynamicOceanAsyncPublisher::SnapshotPtr await_field(
        oq::DynamicOceanAsyncPublisher &publisher, double time, uint64_t version) {
    for (int i = 0; i < 1000; ++i) {
        publisher.advance(1, time, time, 1.0 / 60.0);
        auto s = publisher.acquire_snapshot();
        if (s && s->valid && s->configuration_version == version && s->simulation_time == time) return s;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return {};
}
