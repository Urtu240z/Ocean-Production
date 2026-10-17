#include "../../addons/ocean/physics/native/ocean_query/src/perf2_telemetry.h"
#include <cassert>
#include <iostream>
#include <memory>
int main() {
    auto journal = std::make_unique<oq::Perf2Journal>();
    uint64_t qpc = 1000000;
    for (int frame = 0; frame < 2300; ++frame) {
        qpc += frame == 60 ? 63210 : 5000;
        for (int tick = 0; tick < 4; ++tick) journal->stage(frame, oq::NATIVE_BUILD, 5500, 1);
        journal->boundary(frame, frame, qpc, 1000000, 25000);
        journal->stage(frame, oq::CONTROLLER, 47470, 4); // Late callback must be retained.
        journal->stage(frame, oq::TETRA_LOOP, 8370, 1008);
    }
    auto result = journal->snapshot();
    assert(result.windows.size() == 1 && result.windows[0].complete);
    const auto &window = result.windows[0];
    assert(window.trigger == 60 && window.count == 65 && window.remaining == 0);
    assert(window.frames.front().frame == 28 && window.frames[64].frame == 92);
    const auto &hitch = window.frames[32];
    assert(hitch.interval_us == 63210 && hitch.stage_us[oq::NATIVE_BUILD] == 22000);
    assert(hitch.stage_calls[oq::NATIVE_BUILD] == 4 && hitch.stage_us[oq::CONTROLLER] == 47470);
    assert(hitch.stage_calls[oq::TETRA_LOOP] == 1008);
    assert(journal->snapshot().windows.empty());
    for (int frame = 2300; frame < 2340; ++frame) {
        qpc += 63000; journal->boundary(frame, frame, qpc, 1000000, 25000);
    }
    result = journal->snapshot(); assert(result.windows.size() == 16 && result.dropped == 24);
    std::cout << "PERF2_FRAME_RING PASS: 63 ms frame with four 5.5 ms builds; pre/post, late spans, wrap, overflow\n";
}
