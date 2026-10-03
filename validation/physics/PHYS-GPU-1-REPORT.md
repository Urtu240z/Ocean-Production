# PHYS-GPU-1 — GPU surface query and asynchronous readback proof

**PHYS-GPU-1: PASS for the development correctness/architecture proof.** This is not final target performance acceptance or gameplay force integration. Warm inversion and controlled folded continuation pass. The adversarial moving-world stress has **18,665 explicit invalid inversions / 569,464 consumed world contacts (3.277%)**. These must remain explicit failures; they are not silently accepted water samples. Cold/re-entry policy and sustained contact robustness remain work before forces.

## Starting source and scope

- Source branch: `origin/wip/phys-opt-2`.
- Source commit: `df4f5eca68c1d5918cd6bfd4e6f6cfb08c1260e7`, clean and equal to fetched remote at task start.
- New branch: `wip/phys-gpu-1`.
- Core milestone: `ad252dd` — Add batched GPU ocean queries with asynchronous readback ring.
- Validation milestone: “Validate GPU ocean parity, inversion and 10k asynchronous delivery”; its hash is the report-containing commit in `git log wip/phys-gpu-1`.
- Push destination: `origin/wip/phys-gpu-1`; publication and local/remote equality are checked after the report commit.
- `wip/phys-opt-2` stays at the starting commit and is not pushed. No master merge, PHYS-GPU-2, PHYS-4, force model, or RigidBody3D edits.

Actual environment on 2026-10-03: Intel(R) Core(TM) i7-5820K CPU @ 3.30GHz, NVIDIA GeForce GTX 970, Godot `4.7.1.stable.official.a13da4feb`, `forward_plus`, `d3d12`, frame queue 2. **All timings are NON-TARGET DEVELOPMENT data.** i7-13650HX / RTX 4070 Laptop remains unmeasured.

## Authoritative GPU resources

See [resource contract](PHYS-GPU-1-RESOURCE-CONTRACT.md) for the source audit and equations.

| Band | Resolution | Domain m | Displacement | Existing spatial intermediates |
| --- | --- | --- | --- | --- |
| LONG | 256 x 256 | 512 | RGBA32F: dx,height,dz,det | three RGBA32F complex images, double buffered |
| MID | 256 x 256 | 137 | same | same |
| SHORT | 256 x 256 | 37 | same | same |

H0 is RGBA32F: H0(k).xy and conjugate H0(-k).zw. Normals are RGBA16F. The original pipeline had no velocity texture. This change derives analytic velocity from the SAME evolution and packs it into previously unused imaginary spatial lanes (height+i*vy, dx+i*vx, dz+i*vz); dxx+i*slopeX and dzz+i*slopeZ similarly retain analytic open normals. Real displacement/Jacobian lanes remain intact. Assembly writes one RGBA32F velocity texture per band. **No added FFT pass, independent spectrum or CPU mirror upload.** Three previous-H0 textures supply the existing weather interpolation derivative; together with velocity textures this adds about 6 MiB at these resolutions. Those textures are allocated with the solver; query velocity stores are opt-in.

Coastal Field and Warp are the borrowed Production RIDs, RGBA32F 353 x 354, origin (-168.2814,-1217.282), extent (1408,1412) m. Field.g is shoaling and .a validity. Warp.xy is LONG sampling coordinate, .z detJ and .w validity; detj_safe=0.5. The exact 2I one-authored-cell (4 m) smoothstep edge feather multiplies the same confidence. LONG mixes open and warped samples and applies the same height shoaling; MID and SHORT sample material q. Physics has no camera fade.

Band UV=q/effective_domain+0.5. Manual bilinear evaluates uv*N-0.5 with positive periodic wrapping, preserving the established L/2-L/(2N) offset. Coastal clamp/rectangle rules match the physical contract. Query arithmetic is **FP64 over the actual FP32 textures**. A first FP32 prototype amplified mask interpolation rounding into 1.2 mm/s velocity and 1.45 degree normal error; FP64 removed that discrepancy without changing CPU tolerances. The shader requires GPU FP64 support. Capability fallback and target throughput are not yet established.

The existing weather publisher still uploads immutable native H0 state before the three render-thread band dispatches. This phase does not remove that existing dependency; queries themselves never run CPU ocean evaluation. Query time/config are captured after this upload and after all three band dispatches on the global device.

## Query and ring architecture

Shader: `addons/ocean/physics/gpu/ocean_surface_query.glsl`; owner/API: `ocean_surface_query.gd`. One invocation/contact, workgroup size 64, **one dispatch ceil(count/64) for the complete contact packet**, capacity 1,024, verified through 256. Vehicle/contact counts are configurable and never assume four contacts.

- Input 32 B/contact: material q or world target XZ, previous q, mode, warm-valid, vehicle index and contact index.
- Rich output 96 B/contact: q, residual, iterations, displacement, validity, final world XYZ, determinant, velocity XYZ, sampled GPU time, normal, generation/config and vehicle/contact IDs.
- Compact output 64 B/contact: q/residual/iterations, displacement/validity, velocity/determinant, normal/validity. Identity and generation/time/config use the immutable packet header and input ordering; compact contacts do not redundantly echo GPU IDs.
- World inversion: bounded 12 Newton iterations, up to ten line-search steps, local 0.0001 m derivative stencil and unchanged 0.001 m residual acceptance. A warm q owns the local branch; there is no global canonical/root enumeration runtime.
- Three persistent slots, each with input/output buffer; six buffers, about 384 KiB at capacity/rich stride. A busy slot is not overwritten. Only one latest pending packet and one latest completed coherent packet are retained.
- API: actual installed ClassDB confirms `RenderingDevice.buffer_get_data_async(buffer, callback, offset, size)`; live callbacks succeeded on the global device. [Official API reference](https://docs.godotengine.org/en/4.4/classes/class_renderingdevice.html#class-renderingdevice-method-buffer-get-data-async) describes frame-queue-dependent delivery.
- **Global GPU sync in production: NO.** New runtime contains no `rd.sync()`, blocking `buffer_get_data()`, local device or `rd.submit()`. Deterministic new tests also use asynchronous results. The preserved legacy oracle has its own clearly separated validation readback.
- Submit/consume are mutex-protected. Render-thread callbacks retain a RefCounted lifetime token rather than a freed Ocean Node. Retiring waits for outstanding callbacks before freeing owned buffers/sets/pipeline. Borrowed ocean/Coastal textures are never freed here; already-invalid uniform sets are checked before destruction.
- Result packet retains generation, ocean epoch, sampled CPU and quantized GPU time, spectrum time, config version, weather alpha and surface configuration. Rich callbacks verify GPU generation/config/time. Consumer can reject expected epoch/config mismatches. Latest completed results may supersede older coherent results; no wrong-generation result is relabeled.
- Detailed metrics, GPU timestamps and trace are validation opt-in, bounded at 16,384 records (timestamp bookkeeping 32); default runtime does not accumulate a history.

`target_time` is accepted by the submission interface, but a finite time incompatible with the dispatched field is explicitly rejected. NAN requests the next authoritative current field. These textures represent only current rendered time; PHYS-GPU-1 does not duplicate their FFT. A future N+1 shared water time can schedule the single authority at a known predicted time; pose prediction/latency compensation belongs to PHYS-GPU-3.

## Material-q parity

Primary oracle: unchanged native Dynamic CPU FFT Mirror, exact same H0, time, weather and Coastal bake. **6,912 samples**: 256 locations x 27 packets, 135 regional/state rows. Current/calm/storm/direction at 0.36, 2.25, 16.89 s; calm->storm, storm->calm and storm->direction at 10, 10.3, 11.5, 12.7, 13 s of a 3 s transition. Open/interior/all four rectangle boundaries/internal masks/wraps are sampled.

Absolute errors below. Quantiles use nearest-rank over the actual samples, not an average of packet percentiles. Full regional/weather mean/RMS/p95/p99/max for every component are retained in [measurements](PHYS-GPU-1-MEASUREMENTS.json). Existing CPU oracle budgets/implementation are unchanged.

| Quantity | Unit | mean | rms | p95 | p99 | max |
| --- | --- | --- | --- | --- | --- | --- |
| det | unitless | 0.0000157735 | 0.0000661918 | 0.0000672022 | 0.000301337 | 0.00158135 |
| dx | m | 0.00000509756 | 0.00000746722 | 0.0000166263 | 0.0000248793 | 0.0000442134 |
| dy | m | 0.00000384658 | 0.00000505883 | 0.0000103576 | 0.0000150033 | 0.0000225197 |
| dz | m | 0.00000486481 | 0.00000717849 | 0.0000160284 | 0.0000231584 | 0.0000384263 |
| normal_deg | degrees | 0.00391124 | 0.00884885 | 0.0197823 | 0.0197823 | 0.0279765 |
| vx | m/s | 0.00000418063 | 0.00000618993 | 0.0000137768 | 0.0000217129 | 0.0000315163 |
| vy | m/s | 0.00000337511 | 0.00000444285 | 0.00000923083 | 0.0000126569 | 0.0000204636 |
| vz | m/s | 0.00000426416 | 0.00000645939 | 0.0000144414 | 0.0000222902 | 0.0000376710 |

Float32 dot-product angular quantization contributes the approximately 0.01978 degree reporting floor. Determinant errors concentrate at sharp confidence/mask derivatives; max 0.001581 is a derivative representation difference, not displacement error.

| Scope | Samples | max displacement m | max velocity m/s | mean normal deg | p95 normal deg | p99 normal deg | max normal deg | max det error |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| region/boundary | 1377 | 0.0000275795 | 0.0000276035 | 0.00375903 | 0.0197823 | 0.0197823 | 0.0279765 | 0.0000229673 |
| region/interior | 1377 | 0.0000442134 | 0.0000376710 | 0.00386903 | 0.0197823 | 0.0197823 | 0.0279765 | 0.0000221651 |
| region/mask | 1377 | 0.0000426853 | 0.0000315251 | 0.00411326 | 0.0197823 | 0.0197823 | 0.0279765 | 0.00158135 |
| region/open | 1404 | 0.0000288966 | 0.0000356750 | 0.00394036 | 0.0197823 | 0.0197823 | 0.0279765 | 0.0000289074 |
| region/wrap | 1377 | 0.0000347530 | 0.0000262702 | 0.00387396 | 0.0197823 | 0.0197823 | 0.0279765 | 0.0000234535 |
| weather/calm | 768 | 0.00000839452 | 0.00000658761 | 0.00391267 | 0.0197823 | 0.0197823 | 0.0279765 | 0.0000600127 |
| weather/calm_to_storm | 1280 | 0.0000347530 | 0.0000316182 | 0.00450114 | 0.0197823 | 0.0197823 | 0.0279765 | 0.000628865 |
| weather/current | 768 | 0.0000426853 | 0.0000311988 | 0.00406539 | 0.0197823 | 0.0197823 | 0.0279765 | 0.00116356 |
| weather/direction | 768 | 0.0000442134 | 0.0000315163 | 0.00393217 | 0.0197823 | 0.0197823 | 0.0279765 | 0.00158135 |
| weather/storm | 768 | 0.0000384263 | 0.0000356750 | 0.00366392 | 0.0197823 | 0.0197823 | 0.0279765 | 0.00102388 |
| weather/storm_to_calm | 1280 | 0.0000288553 | 0.0000376710 | 0.00391760 | 0.0197823 | 0.0197823 | 0.0279765 | 0.00103310 |
| weather/storm_to_direction | 1280 | 0.0000342589 | 0.0000376710 | 0.00335748 | 0.0197823 | 0.0197823 | 0.0279765 | 0.00108611 |

A selective regression wrapper reruns the original lattice, DirectSpectral, Coastal, periodic and clock tests without editing their source. LONG/MID/SHORT lattice displacement maxima are 0.0000218918, 0.00000158928, 3.26357e-7 m. Continuous DirectSpectral vs discrete bilinear off-grid maxima are 0.0323372 m displacement and 0.0746312 m/s velocity: these compare different continuous/discrete representations and are not GPU-vs-Mirror errors.

The original legacy runner exits at its stale `snapshot_info.size()==5` startup guard; the unchanged starting native API returns six values. A new wrapper verifies the current six-value immutable snapshot and retains the other original tests. **The old asynchronous CPU scheduling matrix was not rerun successfully and is not claimed PASS.** Native CPU source, adapter and original runner have an empty diff against the starting branch.

## World inversion and branch ownership

3,072 controlled warm targets come from known material q, with warm guesses offset (+0.001,-0.001) m. GPU failures: **0**. Maximum world residual 0.000998640 m; maximum recovered-q error 0.00497766 m. Near singular/folded mappings, q error can exceed the accepted world residual; it does not justify loosening that residual.

CPU/GPU validity mismatches: **87**, all at internal-mask samples: CPU failed while GPU passed. One CPU-vs-GPU root difference exceeded 0.01 m (max 0.019739 m); GPU stayed near the known source q. CPU retains its wider 0.05 m solver stencil; the local GPU stencil avoids crossing sharp mask folds. This is distinct from an owned-branch failure.

134 negative-determinant cases have **zero controlled owned-branch mismatches**. A validation-only multi-seed search found five valid roots for one world target, then continued two independently after a (0.002,0.002) m target shift. Both stayed valid and distinct, final separation 0.343499 m. No global root enumerator exists in runtime.

| Scope | Count | mean q error m | RMS q error m | p95 q error m | p99 q error m | max q error m | max residual m | GPU failures | CPU validity mismatch | CPU branch mismatch | owned branch mismatch |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| all | 3072 | 0.0000464984 | 0.000237219 | 0.000122070 | 0.00140281 | 0.00497766 | 0.000998640 | 0 | 87 | 1 | 0 |
| folded | 134 | 0.000283699 | 0.000543917 | 0.00140281 | 0.00177422 | 0.00230650 | 0.000981035 | 0 | 50 | 0 | 0 |
| region/boundary | 612 | 0.0000243243 | 0.000144696 | 0.000122070 | 0.000492081 | 0.00140281 | 0.000988351 | 0 | 0 | 0 | 0 |
| region/interior | 612 | 0.0000167426 | 0.000127362 | 0.0000610352 | 0.000122308 | 0.00140281 | 0.000993073 | 0 | 0 | 0 | 0 |
| region/mask | 612 | 0.000161198 | 0.000470703 | 0.00138107 | 0.00177422 | 0.00497766 | 0.000996998 | 0 | 87 | 1 | 0 |
| region/open | 624 | 0.0000220120 | 0.000140609 | 0.000122070 | 0.000123020 | 0.00140281 | 0.000998640 | 0 | 0 | 0 | 0 |
| region/wrap | 612 | 0.00000869566 | 0.0000599093 | 0.0000305176 | 0.000122070 | 0.00140281 | 0.000933056 | 0 | 0 | 0 | 0 |
| unfolded | 2938 | 0.0000356799 | 0.000212946 | 0.000122070 | 0.00140281 | 0.00497766 | 0.000998640 | 0 | 37 | 1 | 0 |
| weather/calm | 768 | 0.0000317505 | 0.000194470 | 0.0000610352 | 0.00138107 | 0.00160210 | 0.000996998 | 0 | 5 | 0 | 0 |
| weather/current | 768 | 0.0000671322 | 0.000272636 | 0.000220065 | 0.00140281 | 0.00140281 | 0.000998640 | 0 | 28 | 0 | 0 |
| weather/direction | 768 | 0.0000373329 | 0.000192065 | 0.000122070 | 0.00138107 | 0.00284076 | 0.000965607 | 0 | 21 | 1 | 0 |
| weather/storm | 768 | 0.0000497779 | 0.000275777 | 0.000123020 | 0.00140281 | 0.00497766 | 0.000991078 | 0 | 33 | 0 | 0 |

These controlled tests establish warm local continuation, not universal cold/re-entry convergence. The long stress changes target/time/counts and uses returned-q history where available; its explicit failure rate remains 3.27764%. Those failures were not classified by region in the long-run capture. They must not be attributed exclusively to masks without evidence. An earlier fixed-initial-guess development run had 23,110 invalid contacts; the returned-q run reduced but did not eliminate them.

## Batch scaling and payload

12 repetitions per material/world x rich/compact x batch. GPU timestamps bracket only query compute. CPU submit/dispatch/consume include enabled validation bookkeeping; consume can include empty polling. World timing uses mixed targets/initial guesses with divergent solves, not an ideal steady warm hull. All times below are NON-TARGET.

| Mode | Payload/contact B | Contacts | GPU mean us | GPU p95 us | CPU submit mean us | CPU dispatch mean us | CPU consume mean us | Payload B | callback mean ms | callback p95 ms | callback p99 ms | callback max ms | consume max ticks |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| material | 96 | 4 | 137.920 | 143.104 | 12.2500 | 102.750 | 7.62500 | 384 | 9.83233 | 10.3690 | 10.3690 | 10.3690 | 2 |
| material | 96 | 8 | 137.408 | 138.496 | 16.5833 | 130.417 | 7.75000 | 768 | 9.82017 | 10.2010 | 10.2010 | 10.2010 | 1 |
| material | 96 | 32 | 140.885 | 142.080 | 10.5833 | 97.0833 | 5.91667 | 3072 | 9.84033 | 10.0840 | 10.0840 | 10.0840 | 1 |
| material | 96 | 64 | 139.947 | 142.336 | 14.4167 | 134.500 | 8.45833 | 6144 | 9.84725 | 10.1720 | 10.1720 | 10.1720 | 1 |
| material | 96 | 80 | 135.061 | 139.520 | 10.5833 | 93.5000 | 7.41667 | 7680 | 10.0323 | 10.5160 | 10.5160 | 10.5160 | 1 |
| material | 96 | 128 | 136.640 | 138.240 | 14.5000 | 121.417 | 7.58333 | 12288 | 9.97317 | 10.7010 | 10.7010 | 10.7010 | 1 |
| material | 96 | 160 | 135.552 | 136.960 | 13.2500 | 122.167 | 8.45833 | 15360 | 9.91375 | 10.6750 | 10.6750 | 10.6750 | 1 |
| material | 96 | 256 | 136.768 | 137.472 | 12.9167 | 114.167 | 7.70833 | 24576 | 9.73833 | 9.98000 | 9.98000 | 9.98000 | 1 |
| material | 64 | 4 | 138.133 | 141.056 | 9.58333 | 86.0000 | 7.33333 | 256 | 10.1047 | 10.5980 | 10.5980 | 10.5980 | 1 |
| material | 64 | 8 | 137.472 | 138.752 | 12.2500 | 119.000 | 8.58333 | 512 | 10.0787 | 10.5320 | 10.5320 | 10.5320 | 1 |
| material | 64 | 32 | 141.525 | 145.408 | 16.5833 | 128.500 | 8.70833 | 2048 | 9.94183 | 10.2370 | 10.2370 | 10.2370 | 1 |
| material | 64 | 64 | 139.797 | 140.544 | 13.0000 | 113.583 | 9.25000 | 4096 | 9.97733 | 10.5310 | 10.5310 | 10.5310 | 1 |
| material | 64 | 80 | 135.232 | 139.520 | 11.9167 | 116.417 | 8.95833 | 5120 | 10.1638 | 10.9230 | 10.9230 | 10.9230 | 1 |
| material | 64 | 128 | 136.597 | 141.312 | 11.6667 | 102.167 | 7.95833 | 8192 | 9.94675 | 10.2680 | 10.2680 | 10.2680 | 1 |
| material | 64 | 160 | 135.232 | 136.704 | 11.5000 | 106.417 | 8.37500 | 10240 | 9.99675 | 10.1610 | 10.1610 | 10.1610 | 1 |
| material | 64 | 256 | 136.661 | 137.216 | 14.0833 | 123.917 | 8.41667 | 16384 | 9.81333 | 10.3970 | 10.3970 | 10.3970 | 1 |
| world | 96 | 4 | 342.549 | 363.520 | 14.4167 | 126.083 | 8.08333 | 384 | 10.2488 | 10.6790 | 10.6790 | 10.6790 | 1 |
| world | 96 | 8 | 1010.77 | 1071.10 | 12.4167 | 120.583 | 9.79167 | 768 | 10.9689 | 11.4090 | 11.4090 | 11.4090 | 1 |
| world | 96 | 32 | 1385.37 | 1416.45 | 13.5833 | 113.750 | 7.83333 | 3072 | 11.3175 | 11.5550 | 11.5550 | 11.5550 | 1 |
| world | 96 | 64 | 1928.45 | 1982.46 | 16.2500 | 136.500 | 10.7917 | 6144 | 11.7598 | 12.1440 | 12.1440 | 12.1440 | 1 |
| world | 96 | 80 | 1974.10 | 1979.14 | 13.1667 | 115.583 | 9.00000 | 7680 | 11.9280 | 12.3990 | 12.3990 | 12.3990 | 1 |
| world | 96 | 128 | 1976.21 | 1979.90 | 15.7500 | 138.083 | 8.87500 | 12288 | 11.6545 | 12.2230 | 12.2230 | 12.2230 | 1 |
| world | 96 | 160 | 1974.12 | 1978.62 | 12.9167 | 121.667 | 8.45833 | 15360 | 11.5753 | 12.0880 | 12.0880 | 12.0880 | 1 |
| world | 96 | 256 | 1978.03 | 1990.40 | 12.7500 | 119.250 | 8.83333 | 24576 | 11.5984 | 12.0490 | 12.0490 | 12.0490 | 1 |
| world | 64 | 4 | 494.763 | 1965.82 | 12.2500 | 104.500 | 8.25000 | 256 | 10.1910 | 10.6740 | 10.6740 | 10.6740 | 1 |
| world | 64 | 8 | 1010.11 | 1072.13 | 13.7500 | 115.750 | 9.50000 | 512 | 10.9732 | 11.3240 | 11.3240 | 11.3240 | 1 |
| world | 64 | 32 | 1384.98 | 1415.42 | 15.5833 | 126.583 | 9.50000 | 2048 | 11.3120 | 11.6940 | 11.6940 | 11.6940 | 1 |
| world | 64 | 64 | 1926.06 | 1979.65 | 12.4167 | 116.167 | 7.79167 | 4096 | 11.9947 | 12.2620 | 12.2620 | 12.2620 | 1 |
| world | 64 | 80 | 1971.33 | 1975.04 | 13.1667 | 110.500 | 8.12500 | 5120 | 11.9003 | 12.3000 | 12.3000 | 12.3000 | 1 |
| world | 64 | 128 | 1974.17 | 1981.18 | 11.6667 | 107.333 | 7.95833 | 8192 | 11.7726 | 12.2850 | 12.2850 | 12.2850 | 1 |
| world | 64 | 160 | 1974.76 | 1985.54 | 11.5833 | 109.167 | 7.79167 | 10240 | 11.7795 | 12.2540 | 12.2540 | 12.2540 | 1 |
| world | 64 | 256 | 1974.78 | 1984.77 | 10.6667 | 101.250 | 7.95833 | 16384 | 11.7636 | 12.4130 | 12.4130 | 12.4130 | 1 |

The material dispatch floor is approximately 0.135–0.141 ms and world cost approaches 1.97–1.98 ms for 80–256 contacts. Measured scaling is not linear: low occupancy/dispatch floor and world divergence dominate this GTX 970 layout. The work is per contact, and FFT passes remain constant. No unmeasured occupancy percentage or cooperative-workgroup speedup is claimed.

Existing three-band ocean compute measured 2.49924 ms (packing off) vs 2.47155 ms (on), 40 frames per configuration after eight warmups. The negative difference is run-order/clock/noise, **not evidence that the extra velocity work is free**. No extra transform is structurally required; additional evolution arithmetic/velocity writes remain part of existing ocean work. Query cost above is incremental and is not the full ocean FFT.

| Vehicles / contacts | Rich B | Compact B |
| --- | --- | --- |
| 1 x 8 | 768 | 512 |
| 10 x 8 = 80 | 7,680 | 5,120 |
| 16 x 16 = 256 | 24,576 | 16,384 |

At 60 Hz the 256-contact rich return is about 1.47 MB/s, compact 0.98 MB/s. Small payload bandwidth is not the dominant measured cost. Rich vehicle/contact IDs and compact immutable ordering support a future force/torque grouping pass without replacing the query layout.

## Asynchronous delivery and 10k stress

Overall capture includes deterministic/batch requests and 10k stress: 10,423 submitted, 10,415 dispatched/completed, eight pending packets coalesced, 10,409 consumed, six completed results superseded under latest-result semantics. No wrong-generation/config corruption; errors and mismatches both zero.

| Delivery metric | Count | Mean | p50 | p95 | p99 | Max |
| --- | --- | --- | --- | --- | --- | --- |
| latency_ms | 10415 | 8.03644 | 7.68800 | 9.88300 | 11.6940 | 33.7210 |
| latency_ticks | 10409 | 0.987030 | 1.00000 | 1.00000 | 1.00000 | 3.00000 |

Milliseconds are submission->callback; ticks are submission->consume, not callback->consume. Final capture includes 2+ tick cases (max three). An earlier development capture reached four ticks. No one-tick deadline is guaranteed. Matrix-only rerun callback max was 15.722 ms and max one tick; it is a different workload, not a replacement for the long stress tail.

Stress alone: **10,000 submissions / 9,992 dispatches / 9,992 completions / eight coalesced**, 166.824405 s at 60 Hz, changing all requested batch sizes and rich/compact/world/material modes. Max in flight two, pending at drain zero, six buffers throughout. Explicit invalid world inversions 18,665; generation mismatches/readback errors zero. After shutdown, owned buffers and in-flight count zero.

Trace captures submission time/tick, requested time, actual dispatch generation/time, sampled state, callback time/tick and consume tick for every submitted generation; coalesced packets are explicitly marked. Full local header trace remains `.godot/phys_gpu1_trace.json`, reproducible and ignored rather than committing 10k redundant records. NAN target_time serializes null; actual requested/dispatch sampled times are stored separately.

Instrumented process static memory grew from 145,656,875 to 193,877,251 B by tick 9,000 because validation retains bounded timing/trace records. This is **not a flat-memory claim**. The production ring/queues stay fixed. With default telemetry off, four retire/reinitialize cycles measured 124,076,881 -> 124,082,333 B (5,452 B drift), zero metric/trace records, zero buffers/in-flight after each shutdown. Each cycle retired with an outstanding readback and coalesced 31 of 32 pending submissions; no callback corruption/invalid RID error occurred.

## Weather, pause and renderer coexistence

Calm, storm, both amplitude transitions and direction transition pass the same material matrix. Weather metadata is captured after the existing shared publication; stress observed configs 1,2,3 without mixing packet generations. During pause, 180 observed results all sampled 66.6666666666642 s; resume continued Production simulation time, not wall-clock query time.

The actual Production Ocean scene rendered throughout live D3D12 tests. Camera/light and active Coastal bake were present; breakers, Crest foam and surface foam were disabled to isolate the physical surface. The saved viewport was visually inspected: no corrupt ocean texture observed. No attributable shader/D3D12 runtime errors or native crash occurred in successful GPU test runs. This is not a video-based flicker audit or full visual-feature coexistence certification. Full breaker/Crest coexistence and shader hot-reload under pending readbacks remain untested; shader/ocean ownership changes should retire/recreate the query, as scene reload does.

Unrelated sandbox startup warnings: root certificate-store access and MCP registry writes to read-only AppData. An initial headless attempt crashed during denied user-log rotation before GPU queries; subsequent tests use explicit workspace `--log-file` paths. These are disclosed rather than counted as GPU-query integrity failures.

## Verification, files and reproduction

Live runners exited zero: full 10k proof, final matrix-only scope capture, four-cycle lifetime/folded continuation, and selective preserved-oracle regression wrapper. `git diff --check` passes. Graph coverage reports partial GLSL parsing and metadata changes; flagged source lines and relevant actual source were read. Conclusions about resource ordering and blocking calls come from actual source/live results rather than graph absence.

Files changed:
- `addons/ocean/fft/gpu_resource_generation.gd`: immutable runtime publisher identity/state.
- `addons/ocean/fft/gpu_stockham_fft.gd`: velocity/previous-H0 resources, packing metadata, opt-in timestamps.
- `addons/ocean/fft/open_ocean_fft.gd`: opt-in query lifecycle and dispatch after three bands.
- `addons/ocean/shaders/fft/evolve_spectrum.glsl`, `assemble_maps.glsl`: existing-transform velocity/slope packing and assembly.
- `addons/ocean/physics/gpu/ocean_surface_query.gd`, `.gd.uid`, `ocean_surface_query.glsl`, `.glsl.import`: query shader, owner and Godot import identity.
- `validation/physics/phys_gpu1_runner.gd`, `phys_gpu1_lifecycle_runner.gd`, `phys_gpu1_oracle_regression.gd`: validation.
- This report, `PHYS-GPU-1-RESOURCE-CONTRACT.md`, `PHYS-GPU-1-MEASUREMENTS.json`: audit/evidence.

Run with the real renderer, **not --headless** (dummy device), from repository root:

```powershell
& 'C:\Users\Eric\Desktop\Godot_v4.7.1-stable_win64_console.exe' --path . --log-file .godot/phys_gpu1_final.log --script validation/physics/phys_gpu1_runner.gd
& 'C:\Users\Eric\Desktop\Godot_v4.7.1-stable_win64_console.exe' --path . --log-file .godot/phys_gpu1_matrix_final.log --script validation/physics/phys_gpu1_runner.gd -- --matrix-only
& 'C:\Users\Eric\Desktop\Godot_v4.7.1-stable_win64_console.exe' --path . --log-file .godot/phys_gpu1_lifecycle.log --script validation/physics/phys_gpu1_lifecycle_runner.gd
& 'C:\Users\Eric\Desktop\Godot_v4.7.1-stable_win64_console.exe' --path . --log-file .godot/phys_gpu1_oracle_lattice.log --script validation/physics/phys_gpu1_oracle_regression.gd
```

Machine-readable measurements preserve full regional/weather component distributions, regional/folded world distributions, all 32 batch distributions, latency, memory trend, lifecycle and selective-oracle evidence. Local raw results/trace/viewport are under `.godot`; a rerun regenerates them. Worktree is checked clean after committing/pushing this report and runners.

## Architectural conclusion and preserved roadmap

The authoritative GPU query path is suitable to continue toward Production: it consumes the rendered three-band/Coastal authority, supports many contacts in one dispatch and returns asynchronously with bounded resources. No blocker requiring duplicated FFT or per-tick full-device sync was found. This PASS is scoped to the requested proof: **explicit local-inversion failures, target FP64/performance, late-result policy and full-feature reload/coexistence remain limitations**. It is not approval to consume invalid samples or lower physical accuracy.

CPU FFT Mirror and DirectSpectral remain validated oracle/reference systems and are no longer the preferred Production runtime direction pending this GPU proof/target follow-up. Existing PHYS-3/2G/2H/2I/2J machinery is preserved.

Unrelated pending items remain open:
- Crest G / Spindrift clamp discrepancy.
- P3D.1 travelling phase after TIME-1 in an initialized Ocean/Carrier.
- P3E handoff after TIME-1 in an initialized Ocean/Carrier.
- TIME-1 instrumentation disposition.

Next planned phases, **not started**: PHYS-GPU-2 per-contact buoyancy/damping/drag and per-vehicle force/torque reduction, then PHYS-GPU-3 predicted N+1 pose/time and latency compensation. Resolve/define invalid-contact and cold/re-entry handling before using the outputs for final forces. Target laptop measurements must separately establish performance.
