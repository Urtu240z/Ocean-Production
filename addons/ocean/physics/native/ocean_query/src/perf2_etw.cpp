#include "perf2_telemetry.h"
#ifdef _WIN32
#include <TraceLoggingProvider.h>
#include <mutex>
TRACELOGGING_DEFINE_PROVIDER(g_perf2_provider, "OceanProduction.Perf2",
    (0xa3d2398c, 0x762f, 0x4b16, 0xa8, 0x9c, 0x61, 0x23, 0x8e, 0x64, 0x17, 0x02));
static bool g_perf2_registered = false;
#endif
namespace oq {
void perf2_etw_initialize() {
#ifdef _WIN32
    static std::once_flag once; std::call_once(once, [] { g_perf2_registered = TraceLoggingRegister(g_perf2_provider) == ERROR_SUCCESS; });
#endif
}
void perf2_etw_shutdown() {
#ifdef _WIN32
    if (g_perf2_registered) { TraceLoggingUnregister(g_perf2_provider); g_perf2_registered = false; }
#endif
}
bool perf2_etw_enabled() {
#ifdef _WIN32
    return TraceLoggingProviderEnabled(g_perf2_provider, 0, 0);
#else
    return false;
#endif
}
void perf2_etw_span(int stage, int64_t frame, int64_t tick, uint64_t start_qpc,
        uint64_t end_qpc, uint64_t duration_us, uint64_t calls) {
#ifdef _WIN32
    if (!perf2_etw_enabled()) return;
    TraceLoggingWrite(g_perf2_provider, "StageSpan", TraceLoggingInt32(stage, "Stage"),
        TraceLoggingInt64(frame, "ProcessFrame"), TraceLoggingInt64(tick, "PhysicsTick"),
        TraceLoggingUInt64(start_qpc, "StartQpc"), TraceLoggingUInt64(end_qpc, "EndQpc"),
        TraceLoggingUInt64(duration_us, "DurationUs"), TraceLoggingUInt64(calls, "Calls"));
#endif
}
void perf2_etw_frame(int64_t frame, uint64_t begin_qpc, uint64_t end_qpc, uint64_t interval_us, bool hitch) {
#ifdef _WIN32
    if (!perf2_etw_enabled()) return;
    TraceLoggingWrite(g_perf2_provider, "FrameBoundary", TraceLoggingInt64(frame, "ProcessFrame"),
        TraceLoggingUInt64(begin_qpc, "BeginQpc"), TraceLoggingUInt64(end_qpc, "EndQpc"),
        TraceLoggingUInt64(interval_us, "IntervalUs"), TraceLoggingBool(hitch, "Hitch"));
#endif
}
}
