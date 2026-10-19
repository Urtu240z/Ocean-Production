# Local sea performance audit — phase 2
Parent: phase 1 instrumentation commit `66a92b0`.

Synchronization now runs once per physics tick in runtime. Explicit area/property/structure invalidation permits another synchronization in the same tick. Editor remains pollable. Stable area ordering, shapes and inverse transforms are reused; cached child transforms/shape dimensions are checked once per tick because CollisionShape3D exposes no general transform-changed signal. Area setters notify hosts. SceneTree structure changes invalidate the cache; shutdown disconnects the signal.

Each slot gathers the union of positively affected contact indices, samples that subset, and maps results to original indices. Weights retain Float64 precision; feather gradients and ordered height/slope/VY composition are unchanged. Position/index/weight/native bridge input buffers are reused. Null local resources now retire/free the old generation and remove the slot.

Validation: 1,120 DIRECT/DISPLACED reference comparisons, max HEIGHT/NORMAL/VY/signed_depth error 0. Additional assertions pass: 100 getters in one tick cause one synchronization; an outside contact is omitted from the native subset; same-tick explicit property changes update; slot change releases unused state; null resource retires its generation; RenderingDevice confirms old textures are actually freed after render-thread completion; resource restoration and hot wind changes rebuild correctly. RID.is_valid alone is insufficient to establish native ownership of a saved RID identifier.

Same reverse matrix, 180 warmup physics ticks, at least 300 measured ticks and 240 frames. Counts become **1 synchronization/tick** at 1/4/6 boats. Stable layouts do not rebuild in the measured interval. All raw component distributions and per-frame/per-tick counts are attached in JSON.

| Boats | Case | Sync p50 ms/tick before → after | WALL p50/p95 ms before → after |
|---|---|---:|---:|
| 6 | two_separate | 5.207 → 0.616 | 168.652 / 194.894 → 33.152 / 64.052 |
| 6 | two_same | 2.840 → 0.399 | 101.131 / 141.671 → 17.825 / 33.340 |
| 6 | one_inside | 2.757 → 0.388 | 64.894 / 114.344 → 17.104 / 32.190 |
| 6 | one_outside | 2.793 → 0.387 | 17.080 / 33.436 → 14.345 / 16.342 |
| 6 | none | 0.120 → 0.032 | 13.003 / 14.100 → 11.977 / 14.448 |
| 4 | two_separate | 3.690 → 0.678 | 48.675 / 78.277 → 15.422 / 17.141 |
| 4 | two_same | 2.117 → 0.430 | 15.093 / 17.336 → 12.865 / 14.854 |
| 4 | one_inside | 2.122 → 0.417 | 15.428 / 17.907 → 3.638 / 13.811 |
| 4 | one_outside | 1.998 → 0.396 | 3.248 / 12.965 → 3.130 / 10.745 |
| 4 | none | 0.093 → 0.032 | 2.411 / 9.684 → 2.491 / 9.873 |
| 1 | two_separate | 1.444 → 0.669 | 2.429 / 9.432 → 2.805 / 9.499 |
| 1 | two_same | 0.841 → 0.371 | 2.029 / 7.525 → 2.055 / 7.043 |
| 1 | one_inside | 0.872 → 0.397 | 1.840 / 7.488 → 1.982 / 7.241 |
| 1 | one_outside | 0.837 → 0.393 | 1.501 / 5.718 → 1.818 / 5.565 |
| 1 | none | 0.045 → 0.034 | 1.443 / 4.911 → 1.579 / 5.108 |

WALL has substantial scheduler/load/wave-phase/vehicle-VFX variability. Some one-boat frame intervals are worse despite lower synchronization cost. This phase changes no shader, FFT resolution or water formulas; it does **not** establish an across-the-board FPS improvement. The measured causal reduction is the repeated CPU synchronization work (13→1 calls/tick with six boats), plus subset contact querying verified separately. Physics catch-up makes overloaded frame latency nonlinear. No user resource/scene settings or vehicle physics changed.
