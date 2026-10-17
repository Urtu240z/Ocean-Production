# PHYS-OPT-2C — asynchronous CPU FFT snapshots

Status: **PARTIAL** on the i7-5820K / GTX 970. The asynchronous publication path
keeps the main-thread wait small and publishes coherent snapshots, but the old-PC
worker build does not consistently meet a one-physics-tick deadline.

## Implementation

- Startup creates one valid field synchronously from the current native cascade
  state, then starts one persistent producer thread.
- The producer schedules the existing persistent FFT worker pool. Its immutable
  configuration owns copies of the FFT inputs and carries a monotonically updated
  configuration version.
- Two spatial snapshots are allocated. Queries hold an immutable shared snapshot;
  the producer writes only the inactive snapshot after its readers release it.
  Publication uses an atomic shared-pointer swap; it does not copy the field arrays
  on the physics thread. FFT scratch remains in the three persistent builders.
- Each completed snapshot contains LONG, MID, and SHORT with shared simulation
  time, tick id, configuration version, generation, and timestamps. Query entry
  points acquire one snapshot and use it for the whole query, including Coastal
  sampling and inversion.
- `advance_dynamic_async` accepts the caller's Production Ocean time and the next
  requested time. It does not read a clock or wait for a worker. A paused time
  keeps the matching snapshot current; an obsolete/future configuration result is
  discarded. No GPU readback is used.

## Old-PC run

The native DLL loaded under Godot 4.7.1 with D3D12 on the GTX 970. The PHYS-OPT-2A
synchronous FFT/oracle suite ran before the asynchronous suite. The async matrix
ran 600 ticks for each worker/load combination (4, 5, and 6 workers; 0, 2, and
4 ms of main-thread CPU contention), followed by 3,600 ticks at five workers and
60-tick windows at 0.5x, 1x, 2x, and 3x. Querying continued during worker builds.

| Workers | Added main-thread load | Missed deadlines / 600 | Published | Main wait mean / p95 | Query mean / p95 |
|---:|---:|---:|---:|---:|---:|
| 4 | 0 ms | 26 | 558 | 3.22 / 6 µs | 0.030 / 0.047 ms |
| 4 | 2 ms | 34 | 325 | 3.17 / 6 µs | 0.027 / 0.043 ms |
| 4 | 4 ms | 7 | 334 | 3.64 / 6 µs | 0.027 / 0.043 ms |
| 5 | 0 ms | 2 | 591 | 3.47 / 6 µs | 0.031 / 0.048 ms |
| 5 | 2 ms | 51 | 309 | 2.83 / 6 µs | 0.027 / 0.057 ms |
| 5 | 4 ms | 49 | 476 | 3.37 / 6 µs | 0.031 / 0.044 ms |
| 6 | 0 ms | 37 | 560 | 2.76 / 5 µs | 0.034 / 0.046 ms |
| 6 | 2 ms | 42 | 310 | 2.98 / 6 µs | 0.032 / 0.057 ms |
| 6 | 4 ms | 54 | 562 | 3.32 / 6 µs | 0.031 / 0.044 ms |

Five workers had the fewest misses without added load and were selected for the
sustained run. Over 3,600 ticks it published 3,261 snapshots from 3,494 scheduled
requests, with 209 missed deadlines (5.8%), 2,946 current-time-ready ticks, and a
maximum field age of 7 ticks (p95 1 tick). Queries remained coherent across all
three bands; there were no mixed-band-time observations or invalid query results.
The query mean was 0.0311 ms and p95 0.046 ms. Main-thread wait was 3.20 µs mean
and 6 µs p95 (30 µs maximum).

Across the complete run, worker build time averaged 13.31 ms (119,707,024 µs over
8,992 builds) and peaked at 29.022 ms. This explains the missed one-tick deadlines.
The maximum recorded age across all windows was 32 ticks; it is reported rather
than hidden. The 0.5x/1x/2x/3x windows ran using `Ocean.get_wave_time()` as the
input authority; those windows had 2, 2, 5, and 9 missed deadlines respectively.
The 0x pause held Production time at 157.640690116094 s and the published field
at 157.640690116 s across 30 physics ticks; the 120-tick resume window published
110 of 117 requests with 3 deadline misses.

The synchronous prototype reports 6 paired inverse transforms per band (18 total
per snapshot). Its 12 real spatial outputs per band are retained in each field.
For N=256 and 12 double fields, one full three-band snapshot occupies 18 MiB;
the two published/inactive spatial buffers therefore occupy about 36 MiB, in
addition to persistent FFT scratch and spectral configuration. No field copy is
performed during publication.

## Gate and remaining work

Correctness and concurrency smoke checks passed: Production time is caller-owned,
pause/resume worked, all three bands shared a snapshot time/version, and queries
continued while the worker ran. Main-thread wait and query cost were low. The
one-tick freshness target did **not** pass: deadlines were missed and the selected
worker's sustained field age reached 9 ticks. Therefore this remains PARTIAL and
is not ready for gameplay integration. The code does not change FFT quality,
disable a band, or introduce a static field.

An incremental relink attempt after the runtime run returned `Access denied`
while a Godot process had the existing DLL open. The diagnostic-only
`last_build_us` change was removed; the retained source/API matches the tested
24-field stats interface. Per-window build averages use differences in cumulative
counters; per-window build percentiles were not captured.

No commit or push was made. No weather-transition feature or jetski integration
was added in this phase.
