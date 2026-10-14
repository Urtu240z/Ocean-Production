#define NOMINMAX
#include <windows.h>
#include <evntrace.h>
#include <evntcons.h>
#include <tdh.h>
#include <tlhelp32.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <thread>
#include <vector>

static const GUID provider = {0xa3d2398c,0x762f,0x4b16,{0xa8,0x9c,0x61,0x23,0x8e,0x64,0x17,0x02}};
static constexpr wchar_t session_name[] = L"OceanProduction.Perf2.AutoTrigger";
struct Handle {
    HANDLE value=nullptr;
    bool mutex=false;
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE){if(mutex)ReleaseMutex(value);CloseHandle(value);}}
};
// The named session belongs only to this component. Recover it only while its
// owner mutex is held and no legacy listener process is still alive.
template<class Start,class HasPeer,class Recover>
static ULONG start_recovering(Start start,HasPeer has_peer,Recover recover) {
    ULONG error=start();
    if(error!=ERROR_ALREADY_EXISTS || has_peer())return error;
    error=recover();
    if(error!=ERROR_SUCCESS && error!=ERROR_WMI_INSTANCE_NOT_FOUND)return error;
    return start();
}
static bool another_listener() {
    Handle snapshot;snapshot.value=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
    if(snapshot.value==INVALID_HANDLE_VALUE)return true; // fail closed
    wchar_t executable[MAX_PATH]{};
    if(!GetModuleFileNameW(nullptr,executable,MAX_PATH))return true;
    auto name=std::filesystem::path(executable).filename().wstring();
    PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);
    if(!Process32FirstW(snapshot.value,&entry))return true;
    do {
        if(entry.th32ProcessID!=GetCurrentProcessId() && !_wcsicmp(entry.szExeFile,name.c_str()))return true;
    }while(Process32NextW(snapshot.value,&entry));
    return GetLastError()!=ERROR_NO_MORE_FILES;
}
struct Frame { uint32_t pid=0,tid=0; uint64_t frame=0,begin=0,end=0,us=0; };
struct Gate {
    uint64_t threshold=50000,warmup=0; std::map<uint32_t,uint64_t> first;
    bool accept(const Frame &f) {
        if (!f.pid || !f.begin || f.end<=f.begin) return false;
        auto inserted=first.emplace(f.pid,f.end);
        return !inserted.second && f.end>=inserted.first->second &&
            f.end-inserted.first->second>=warmup && f.us>=threshold;
    }
};
static Gate gate;
static std::atomic<bool> done{false};
static HANDLE wake=nullptr;
static uint32_t only_pid=0;
static Frame selected;
static uint64_t observed_qpc=0,event_timestamp=0;
static uint64_t qpc() { LARGE_INTEGER v{}; QueryPerformanceCounter(&v); return v.QuadPart; }
static uint64_t frequency() { LARGE_INTEGER v{}; QueryPerformanceFrequency(&v); return v.QuadPart; }
static bool property(EVENT_RECORD *r,const wchar_t *name,uint64_t &value) {
    PROPERTY_DATA_DESCRIPTOR d{}; d.PropertyName=reinterpret_cast<ULONGLONG>(name);d.ArrayIndex=ULONG_MAX;
    return TdhGetProperty(r,0,nullptr,1,&d,sizeof(value),reinterpret_cast<PBYTE>(&value))==ERROR_SUCCESS;
}
static void WINAPI on_event(EVENT_RECORD *r) {
    if (done.load(std::memory_order_relaxed) || r->EventHeader.ProviderId!=provider ||
        (only_pid && r->EventHeader.ProcessId!=only_pid)) return;
    Frame f; f.pid=r->EventHeader.ProcessId; f.tid=r->EventHeader.ThreadId;
    // TDH uses the TraceLogging schema, rather than assuming binary offsets.
    if (!property(r,L"IntervalUs",f.us) || !property(r,L"ProcessFrame",f.frame) ||
        !property(r,L"BeginQpc",f.begin) || !property(r,L"EndQpc",f.end)) return;
    if (gate.accept(f)) {
        selected=f;observed_qpc=qpc();event_timestamp=r->EventHeader.TimeStamp.QuadPart;
        done.store(true,std::memory_order_release);SetEvent(wake);
    }
}
static bool write_file(const std::filesystem::path &path,const std::string &text) {
    auto temporary=path;temporary+=L".tmp";
    {std::ofstream f(temporary,std::ios::binary);if(!f)return false;f<<text;if(!f)return false;}
    return MoveFileExW(temporary.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0;
}
static int self_test() {
    Gate g;g.threshold=50000;g.warmup=100;
    if(g.accept({1,2,1,10,20,60000}))return 1; // first sample is startup
    if(g.accept({1,2,2,100,110,60000}))return 2; // warmup
    if(g.accept({1,2,3,110,120,49999}))return 3; // below threshold
    if(!g.accept({1,2,4,120,121,50000}))return 4;
    if(g.accept({2,2,1,120,130,100000}))return 5; // independent process warmup
    if(g.accept({1,2,5,130,130,100000}))return 6;
    int starts=0,recovers=0;
    auto start=[&](){return ++starts==1?ULONG(ERROR_ALREADY_EXISTS):ULONG(ERROR_SUCCESS);};
    auto recover=[&](){++recovers;return ULONG(ERROR_SUCCESS);};
    if(start_recovering(start,[]{return false;},recover)!=ERROR_SUCCESS || starts!=2 || recovers!=1)return 7;
    starts=recovers=0;
    if(start_recovering(start,[]{return true;},recover)!=ERROR_ALREADY_EXISTS || starts!=1 || recovers)return 8;
    starts=recovers=0;
    if(start_recovering([]{return ULONG(ERROR_ACCESS_DENIED);},[]{return false;},recover)!=ERROR_ACCESS_DENIED || recovers)return 9;
    starts=0;
    if(start_recovering(start,[]{return false;},[]{return ULONG(ERROR_ACCESS_DENIED);})!=ERROR_ACCESS_DENIED || starts!=1)return 10;
    std::cout<<"PERF2_AUTO_GATE PASS\n";return 0;
}
int wmain(int argc,wchar_t **argv) {
    std::filesystem::path output,ready,cancel,replay;
    uint32_t timeout_seconds=600,owner_pid=0;double warmup_seconds=5;
    for(int i=1;i<argc;++i) {
        std::wstring arg=argv[i];
        if(arg==L"--self-test")return self_test();
        if(i+1==argc){std::cerr<<"Missing argument\n";return 1;}
        auto value=argv[++i];
        try {
            if(arg==L"--output")output=value;
            else if(arg==L"--ready")ready=value;
            else if(arg==L"--cancel")cancel=value;
            else if(arg==L"--replay")replay=value;
            else if(arg==L"--pid")only_pid=std::stoul(value);
            else if(arg==L"--owner-pid")owner_pid=std::stoul(value);
            else if(arg==L"--threshold-ms")gate.threshold=uint64_t(std::stod(value)*1000);
            else if(arg==L"--warmup-seconds")warmup_seconds=std::stod(value);
            else if(arg==L"--timeout-seconds")timeout_seconds=std::stoul(value);
            else {std::cerr<<"Unknown option\n";return 1;}
        }catch(...){std::cerr<<"Invalid argument\n";return 1;}
    }
    if(output.empty() || !gate.threshold || warmup_seconds<0 || !timeout_seconds)return 1;
    Handle owner,session_mutex;
    if(replay.empty()) {
        if(owner_pid) {
            owner.value=OpenProcess(SYNCHRONIZE,FALSE,owner_pid);
            if(!owner.value || WaitForSingleObject(owner.value,0)!=WAIT_TIMEOUT){std::cerr<<"Launcher is no longer alive\n";return 1;}
        }
        session_mutex.value=CreateMutexW(nullptr,FALSE,L"Global\\OceanProduction.Perf2.AutoTrigger.Owner");
        if(!session_mutex.value){std::cerr<<"Listener owner mutex error "<<GetLastError()<<"\n";return 1;}
        DWORD acquired=WaitForSingleObject(session_mutex.value,0);
        if(acquired!=WAIT_OBJECT_0 && acquired!=WAIT_ABANDONED){std::cerr<<"Another automatic listener owns the session\n";return 1;}
        session_mutex.mutex=true;
    }
    gate.warmup=uint64_t(warmup_seconds*frequency());
    wake=CreateEventW(nullptr,TRUE,FALSE,nullptr);if(!wake)return 1;
    std::vector<uint8_t> storage(sizeof(EVENT_TRACE_PROPERTIES)+sizeof(session_name));
    auto props=reinterpret_cast<EVENT_TRACE_PROPERTIES*>(storage.data());
    props->Wnode.BufferSize=ULONG(storage.size());props->Wnode.Flags=WNODE_FLAG_TRACED_GUID;
    props->Wnode.ClientContext=1;props->LoggerNameOffset=sizeof(EVENT_TRACE_PROPERTIES);
    props->LogFileMode=EVENT_TRACE_REAL_TIME_MODE;props->BufferSize=64;
    props->MinimumBuffers=4;props->MaximumBuffers=16;props->FlushTimer=1;
    TRACEHANDLE control=0;
    auto stop_own=[&](){if(control){ControlTraceW(control,session_name,props,EVENT_TRACE_CONTROL_STOP);control=0;}};
    if(replay.empty()) {
        const auto initial_properties=storage;
        auto start=[&](){control=0;memcpy(props,initial_properties.data(),storage.size());return StartTraceW(&control,session_name,props);};
        ULONG error=start_recovering(start,another_listener,[&](){
            // Query/stop only our exact named real-time session, never WPR.
            auto old_storage=storage;
            auto old_props=reinterpret_cast<EVENT_TRACE_PROPERTIES*>(old_storage.data());
            ULONG status=ControlTraceW(0,session_name,old_props,EVENT_TRACE_CONTROL_QUERY);
            if(status!=ERROR_SUCCESS)return status;
            if(!(old_props->LogFileMode&EVENT_TRACE_REAL_TIME_MODE) ||
                (old_props->LogFileMode&EVENT_TRACE_SYSTEM_LOGGER_MODE))return ULONG(ERROR_INVALID_DATA);
            status=ControlTraceW(0,session_name,old_props,EVENT_TRACE_CONTROL_STOP);
            if(status==ERROR_SUCCESS)std::cout<<"Recovered orphaned automatic listener session; WPR untouched\n";
            return status;
        });
        if(error){std::cerr<<"StartTrace error "<<error<<(error==ERROR_ALREADY_EXISTS?" (another listener is still active)":error==ERROR_ACCESS_DENIED?" (Windows administrator permission required)":"")<<"\n";CloseHandle(wake);return 1;}
        const char event_name[]="FrameBoundary";
        std::vector<uint8_t> filter_storage(offsetof(EVENT_FILTER_EVENT_NAME,Names)+sizeof(event_name));
        auto filter=reinterpret_cast<EVENT_FILTER_EVENT_NAME*>(filter_storage.data());
        filter->Level=5;filter->FilterIn=TRUE;filter->NameCount=1;
        memcpy(filter->Names,event_name,sizeof(event_name));
        EVENT_FILTER_DESCRIPTOR desc{reinterpret_cast<ULONGLONG>(filter),ULONG(filter_storage.size()),EVENT_FILTER_TYPE_EVENT_NAME};
        ENABLE_TRACE_PARAMETERS params{};params.Version=ENABLE_TRACE_PARAMETERS_VERSION_2;
        params.EnableFilterDesc=&desc;params.FilterDescCount=1;
        error=EnableTraceEx2(control,&provider,EVENT_CONTROL_CODE_ENABLE_PROVIDER,5,0,0,0,&params);
        if(error){std::cerr<<"EnableTraceEx2 error "<<error<<"\n";stop_own();CloseHandle(wake);return 1;}
    }
    EVENT_TRACE_LOGFILEW log{};
    std::wstring replay_path=replay.wstring();
    if(replay.empty())log.LoggerName=const_cast<LPWSTR>(session_name);else log.LogFileName=replay_path.data();
    log.ProcessTraceMode=PROCESS_TRACE_MODE_EVENT_RECORD|PROCESS_TRACE_MODE_RAW_TIMESTAMP;
    if(replay.empty())log.ProcessTraceMode|=PROCESS_TRACE_MODE_REAL_TIME;
    log.EventRecordCallback=on_event;
    TRACEHANDLE reader=OpenTraceW(&log);
    if(reader==INVALID_PROCESSTRACE_HANDLE){std::cerr<<"OpenTrace error "<<GetLastError()<<"\n";stop_own();CloseHandle(wake);return 1;}
    std::atomic<bool> processing_finished{false};ULONG processing_result=0;
    std::thread consumer([&](){processing_result=ProcessTrace(&reader,1,nullptr,nullptr);processing_finished.store(true);SetEvent(wake);});
    if(!ready.empty() && !write_file(ready,"{\"ready\":true,\"listener_pid\":"+std::to_string(GetCurrentProcessId())+"}")) {
        stop_own();CloseTrace(reader);consumer.join();CloseHandle(wake);return 1;
    }
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(timeout_seconds);
    bool cancelled=false;
    while(WaitForSingleObject(wake,250)==WAIT_TIMEOUT) {
        if((owner.value && WaitForSingleObject(owner.value,0)!=WAIT_TIMEOUT) ||
            (!cancel.empty() && std::filesystem::exists(cancel)) || std::chrono::steady_clock::now()>=deadline){cancelled=true;break;}
    }
    // Remove only the session this process successfully created, never WPR's session.
    stop_own();CloseTrace(reader);consumer.join();CloseHandle(wake);
    if(!done.load(std::memory_order_acquire)) {
        std::cerr<<(cancelled?"Listener cancelled or timed out; no trigger\n":"Trace ended without a matching frame; status ")<<processing_result<<"\n";
        return cancelled?3:2;
    }
    std::ostringstream result;
    result<<"{\"schema_version\":1,\"source\":\""<<(replay.empty()?"realtime_etw":"offline_replay")
        <<"\",\"process_id\":"<<selected.pid<<",\"thread_id\":"<<selected.tid
        <<",\"process_frame\":"<<selected.frame<<",\"begin_qpc\":"<<selected.begin<<",\"end_qpc\":"<<selected.end
        <<",\"interval_us\":"<<selected.us<<",\"threshold_us\":"<<gate.threshold
        <<",\"observed_qpc\":"<<observed_qpc<<",\"event_timestamp_qpc\":"<<event_timestamp
        <<",\"qpc_frequency\":"<<frequency()<<"}";
    if(!write_file(output,result.str())){std::cerr<<"Cannot save trigger\n";return 1;}
    std::cout<<"PERF2_AUTO_TRIGGER frame="<<selected.frame<<" interval_ms="<<selected.us/1000.0<<" PID="<<selected.pid<<"\n";
    return 0;
}
