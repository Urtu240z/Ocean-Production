#include "../addons/ocean/physics/native/ocean_query/src/perf1_telemetry.h"
#include <cassert>
#include <iostream>
#include <memory>
#include <thread>

int main() {
    auto journal = std::make_unique<oq::Perf1Journal>();
    for (int tick = 0; tick < 2300; ++tick) {
        oq::Perf1Build row;
        row.context.physics_tick = tick; row.context.process_frame = tick / 3;
        row.wall_us = tick == 240 ? 9001 : 1000;
        journal->tick(tick, tick / 3, tick / 3);
        journal->push(row);
    }
    auto snapshot = journal->snapshot();
    assert(snapshot.recent.size() == oq::Perf1Journal::CAPACITY);
    assert(snapshot.overwritten == 252 && snapshot.sequence == 2300);
    assert(snapshot.windows.size() == 1);
    const auto &window = snapshot.windows[0];
    assert(window.trigger == 241 && window.remaining == 0 && window.count == 33);
    assert(window.rows[0].context.physics_tick == 224);
    assert(window.rows[32].context.physics_tick == 256);
    assert(snapshot.frames[1].steps == 3);
    assert(journal->snapshot().windows.empty()); // Complete windows drained once.
    for (int tick = 0; tick < 80; ++tick) { oq::Perf1Build row; row.wall_us = 9001; journal->push(row); }
    snapshot = journal->snapshot();
    assert(snapshot.windows.size() == 32 && snapshot.dropped_windows == 48);
    journal->enabled = false;
    journal->push({});
    assert(journal->snapshot().sequence == 2380);
    journal->enabled = true;
    { oq::Perf1Scope scope(*journal, true, 0); std::this_thread::sleep_for(std::chrono::milliseconds(20)); }
    snapshot = journal->snapshot();
    assert(snapshot.recent.back().wall_us > 8000);
#ifdef _WIN32
    assert(snapshot.recent.back().thread_cpu_us >= 0 && snapshot.recent.back().thread_cycles >= 0);
#endif
    std::cout << "PERF1_RING PASS: pre/post, wrap, overflow, drain, disabled, Windows clocks; sleep wall_us="
              << snapshot.recent.back().wall_us << " thread_cpu_us=" << snapshot.recent.back().thread_cpu_us << '\n';
}
