# PHYS-GPU-1.3 — physical free-surface contract

**PARTIAL. NOT READY FOR PHYS-GPU-2.** Starting HEAD: `641c856bf3681ca243fcadfa3682851e5d0aec50`, branch `wip/phys-gpu-1`. Tested on Intel i7-5820K / GTX 970 / Godot 4.7.1 / Forward+ / D3D12. These are non-target development measurements.

The supplied highest-Y decision is implemented in candidate selection, XYZ input and signed depth. The bounded search cannot reliably discover that surface: it returns valid lower candidates and explicitly misses reference-supported targets. Successful exceptional dispatches average about 4 ms, and the full 16×16 stress dispatch reaches 23.895 ms. Neither physical correctness nor exceptional cost closes. This is not evidence that the highest-Y contract is impossible; no new acceleration architecture was built.

## Physical contract

The buoyancy free surface is the greatest world Y among valid roots of `world_xz = q + displacement_xz(q)` in Production LONG + MID + SHORT + Coastal/shoaling, including the existing feather. Water exists below that upper envelope. Trapped air/underside pockets are excluded by the supplied gameplay contract. **BreakerCarrier P5/P6 is excluded.** Contact Y chooses no root; it only supplies `signed_depth = surface_y - contact_y`, positive below water. No buoyancy, damping, drag, force or torque is calculated.

Warm q is a seed, not immutable authority. Valid candidates are compared by actual world Y. The warm primary is retained within **0.002 m** of the highest discovered candidate; cold ties in that band choose lexicographic q. Hysteresis changes identity selection only: no height clamp, geometry modification, determinant-sign sheet rule or residual relaxation. Production residual remains **1 mm**, internal FP64 policy unchanged.

The implementation establishes the highest **discovered** candidate, not a certificate that no higher undiscovered sheet exists. Consequently a valid production flag alone does not establish a physically valid buoyancy surface. The failures below prohibit using this phase as a completed physical query for PHYS-GPU-2.

## Exact ABI and persistent ownership

All offsets are bytes; XYZ/vector output components are FP32, IDs/flags u32. Legacy material mode 0, legacy world mode 1 and numerical persistent mode 2 retain their interfaces. Physical persistent mode is 3. Validation-only fine inversion is mode 4 and does not write persistent state. Persistent packets are homogeneous by mode.

| Physical input, stride 32 | Layout |
|---|---|
| 0 / 4 / 8 / 12 | world X / Y / Z / padding |
| 16 / 20 / 24 / 28 | mode / unused / vehicle ID / contact ID |

Control stride 32: slot at 0, occupant generation at 4, flags at 8, reserved validation lane at 12, optional hint q X/Z at 16/20, padding at 24/28. Teleport callers send RESET. Explicit physical OWNED_SEED and mode 4 are rejected when validation telemetry is disabled.

| GPU persistent state, stride 96 | Layout |
|---|---|
| 0 / 8 | FP64 selected q X/Z |
| 16 / 24 | FP64 previous target X/Z |
| 32 / 36 / 40 / 44 | vehicle / contact / occupant generation / mode |
| 48 / 52 / 56 / 60 | ocean epoch / previous sample config / status / validity |
| 64 / 68 / 72 / 76 | FP32 velocity X/Z / sample time / determinant |
| 80 / 88 | FP64 previous contact Y / selected surface Y |

Previous target XYZ therefore occupies XZ at 16/24 and Y at 80. No root list is stored. Identity, mode, epoch and generation prevent stale inheritance; previous time/config support coherent continuation.

| Rich physical output, stride 160 | Layout |
|---|---|
| 0 / 4 / 8 / 12 | selected q X/Z / residual / iterations |
| 16 / 20 / 24 / 28 | displacement XYZ / validity |
| 32 / 36 / 40 / 44 | selected world XYZ / determinant |
| 48 / 52 / 56 / 60 | velocity XYZ / sample time |
| 64 / 68 / 72 / 76 | normal XYZ / validity |
| 80 / 84 / 88 / 92 | request generation / config / vehicle / contact |
| 96 / 100 / 104 / 108 | status / solve count / reason / prior ownership |
| 112 / 116 / 120 / 124 | previous q X/Z / q delta / continuity radius |
| 128 / 132 / 136 / 140 | surface Y / contact Y / signed depth / previous selected Y |
| 144 / 148 / 152 / 156 | current primary candidate Y / maximum candidate Y / Y delta / ambiguity |

Compact physical stride is 128: q/residual/iterations and displacement/validity at 0–28, velocity/determinant at 32–44, normal/validity at 48–60, persistent diagnostics at 64–92, physical Y/depth diagnostics at 96–124. Generation/config remains in coherent async request metadata. Rich and compact signed-depth paths were both tested.

Consumer statuses: CONTINUED=1, COLD_ACQUIRED=3, FAILED=4, SHEET_HANDOFF=5. Mode 2 alone retains numerical REACQUIRED_LOCAL=2. Physical reasons distinguish higher candidate replacement (8), unavailable/jumping primary (7), and no acquired candidate (9). A FAILED result is invalid and clears ownership. These reasons infer continuation locally; they do **not** prove topological root termination. A valid lower-sheet result violates the physical status meaning even if its inversion residual passes.

Inactive/reset/teleport/occupant change clears ownership. Same-occupant q may persist only as a hint across repeated inactive dispatches. The wrapper carries lifetime invalidations through the coalescing mailbox until an actual dispatch includes them. Two bounded CPU maps hold submitted identity and invalidation revision for at most 1,024 slots; they contain no q or readback feedback. This fixes a one-tick inactive packet being coalesced away and accidentally preserving ownership. Newer invalidations survive preparation of an older packet.

## Production search and limits

An ordinary contact uses **one solve**, at most 16 Newton iterations. Ambiguity triggers are primary failure; 1 cm Jacobian determinant below 0.35, absolute determinant above 4 or column length above 2; Coastal mask span above 0.05 **combined with** warp displacement above 0.5 m; correction outside a local continuity radius; or explicit validation seed/diagnostic controls. Coastal membership alone is not a trigger.

Exceptional acquisition has **five total solves × 16 iterations = 80 maximum Newton iterations/contact**. Each solve has bounded backtracking (up to 12 trials). Primary ordinary derivatives use the existing stencil; alternative solves use a 1 μm derivative stencil while retaining the 1 mm production residual. Fine derivatives increase exceptional cost despite the lower iteration cap. No production exhaustive rings/grid, target segmentation, 13-solve/1,104-iteration recovery or CPU inversion feedback remains.

Let `D` be displacement at target XZ, direction its horizontal direction, and radius its horizontal magnitude clamped to 0.25–1.5 m. Warm alternatives are target, target−D.xz, target−direction×radius and target+direction×radius. Cold alternatives are target−D.xz, target+perpendicular(direction)×radius, target−direction×radius and target+direction×radius; the primary is the cold seed/hint. All valid candidates enter Y comparison. A local movement/velocity radius is used for status inference, not determinant-orientation ownership rejection.

These local triggers cannot exclude a disconnected higher root. The five seeds also cannot discover all sheets. The measured wrong results demonstrate both limitations; no budget was increased to manufacture PASS.

## Reference method and coverage

Every captured ambiguous production result, every authored-fold result, every invalid result and periodic ordinary samples enter the contact ledger, including executed completions superseded before CPU consumption. Validation capture is bounded to 32 packets and reports zero dropped captures. Predecessors are taken from actual executed GPU completions, not CPU-consumed history. Coalesced submissions are not falsely counted as executed contact updates.

For each captured target, the reference uses **802 deterministic seeds** around target and predecessor anchors: two 17×17 grids at 0.25 m spacing plus seven 16-point rings, with supplied discovered/current roots added. Mode 4 evaluates the same authoritative GPU fields, at most 48 fine iterations and a **1 μm residual**, without persistent-state writes. Accepted roots record q, residual, world XYZ, determinant, normal and distance from previous q. Solver acceptance/residual is evaluated internally in FP64 before the FP32 output ABI; rounded recorded q is not a claim that replaying those two FP32 coordinates reproduces a 1 μm residual without correction. Root clustering requires both q separation below 0.1 mm and Y difference below 0.5 mm; thin roots are retained. Cluster counts are discovery counts, not certified exact topological multiplicities. The archive verifier checks serialization, reported residuals, required fields, identity, budgets and history; it does not independently re-solve GPU geometry.

The strongest discovered root defines reference maximum Y. Within the 2 mm band, warm membership is compared with the owned candidate and cold ordering is deterministic. The archived records retain the full root set and production result. This is strong bounded discovery, **not a mathematically exhaustive global certificate**. No claim of PASS rests on reference completeness. A single discovered higher valid root suffices to refute a lower returned surface; no roots found would not prove absence.

Weather/config/time/transition alpha are captured and reconstructed coherently for replay. Historical PHYS-GPU-1.2 texture bytes were not archived; endpoint reconstructions are not byte-identical playback of those old GPU textures. Main stress references likewise reconstruct the recorded coherent configuration and time rather than storing every texture snapshot. This provenance and 1 mm production-vs-1 μm reference residual difference limit ancestry and sheet-identity claims near caustics.

The completed main corpus has **118,531 cases**, including **all 111,814 ambiguous results** and **all 110,864 fold observations**. Reference roots exist in every case: **744,152 discovered root clusters**, maximum **34/target**, zero empty reference sets. Production returns **33,017 valid results more than 2 mm below the discovered maximum** and **1,145 explicit failures while an envelope exists**. The hard zero-wrong-sheet gate fails.

Ownership split: 1,273 ownerless cases have 334 wrong-lower results and 559 misses; 117,258 warm cases have 32,683 wrong-lower results and 586 misses. All 117,258 owned ledger rows have a valid actual executed predecessor, with zero previous-q mismatches (0.1 mm comparison) and zero previous-Y mismatches (0.01 mm comparison). This verifies captured history, not physical sheet authority.

There are **8,294 envelope-matching handoff endpoints** and **312 apparent false-handoff flags** where reason 8 is reported even though current primary Y remains within 2 mm of reference maximum. Endpoint agreement does not prove prior-sheet termination; the false-handoff flag likewise does not certify topology. Separate diagnostics find **606 valid results above the reference maximum by more than 2 mm**, **860 valid outputs with no matched fine reference root**, and **222 below-maximum results with q within 2 cm of the maximum root**. These categories overlap and are not added together. The 1 mm production residual can produce height uncertainty near a caustic; those outputs are not automatically classified as correct upper surfaces.

The main corpus partitions into **83,756 reference-matching envelope endpoints**, 33,017 wrong-lower outputs, 1,145 invalid misses and **613 other valid unmatched outputs**. Of the wrong-lower outputs, **29,080 were flagged ambiguous and 3,937 were not**. All 111,814 flagged ambiguous cases were checked. Non-ambiguous lower results demonstrate false confidence in the fast-path detector, independently of five-seed acquisition failures.

The conservative wrong-lower metric means a valid returned Y is more than 2 mm below a discovered reference maximum. Some records can represent height error on the same nearby branch rather than a uniquely identified distinct sheet. Both violate the physical surface comparison. Valid outputs above the reference/no matched fine root are separately reported, not silently called correct.

## Old failure reclassification

The union of the PHYS-GPU-1.2 ROOT/CONNECTED/LATERAL study collections contains **80 unique historical cases**. All were replayed, retaining their previous evidence. Conditional fine temporal paths and the existing lateral root-pair studies yield:

| Classification | Cases |
|---|---:|
| Tracked prior root survives and is upper at reconstructed endpoint | 6 |
| Tracked prior root survives; another root is higher at endpoint | 14 |
| Previous local pair terminated; replacement envelope exists | 7 |
| Insufficient temporal ancestry evidence | 53 |
| No valid reference root discovered | 0 |

All 80 have a discovered endpoint envelope. The survival/upper labels describe the reconstructed current endpoint relative to tracked prior q; they do not prove that an old numerical owner was already the physical upper envelope in the preceding snapshot. Production returns 67 valid results, including 47 handoff statuses; **36 valid results are below the reference** and **13 explicitly fail despite an envelope**. These endpoint statuses do not certify all 47 as legitimate physical handoffs.

The separate actual PHYS-GPU-1.2 final failure corpus was also replayed **exhaustively: 2,565/2,565** (946 cold, 1,619 warm). Reference envelopes exist for all 2,565, with **13,797 discovered clusters**, maximum 25/target. Production has **1,125 wrong-lower results and 769 explicit reference-supported misses**. A strict nearby CPU endpoint correction finds 7 near-prior upper endpoints, 1 near-prior lower endpoint and no nearby endpoint in 1,611 warm cases. That absence does not prove termination; without the old texture sequence all 1,619 warm histories retain insufficient ancestry evidence. Cold cases have no previous owner. This exhaustive endpoint corpus and the 80 stronger historical studies answer different questions and are not conflated.

## Original lateral seven

All **7/7** are physically classified as local pair loss with another discovered upper-envelope root: **zero unresolved endpoint envelopes**. Production finds a handoff in **5/7** and explicitly fails acquisition in **2/7**. Semantic classification is not a claim of seven successful production handoffs. Old Y is the conditionally reconstructed prior-root height, not an archived texture-byte measurement.

| Original ordinal | Old selected Y (m) | Replacement envelope Y (m) | New q X/Z (m) | Signed ΔY (m) | Production |
|---|---:|---:|---|---:|---|
| 1028 | 2.070601468 | 2.017362356 | −302.487548828, −1368.981689453 | −0.053239112 | HANDOFF |
| 1029 | 2.080710967 | 1.844279766 | −301.995025635, −1370.119628906 | −0.236431201 | FAILED |
| 1030 | 2.085195881 | 1.940847635 | −301.748657227, −1369.523559570 | −0.144348246 | FAILED |
| 1031 | 2.079049021 | 2.027424335 | −301.537658691, −1368.962402344 | −0.051624685 | HANDOFF |
| 1032 | 2.070822478 | 2.133550167 | −301.074676514, −1368.088378906 | +0.062727690 | HANDOFF |
| 2521 | 1.899809156 | 1.401758194 | −302.726257324, −1371.069702148 | −0.498050962 | HANDOFF |
| 2522 | 1.738399517 | 1.783868194 | −302.073944092, −1369.995483398 | +0.045468677 | HANDOFF |

## Authored fold, cold acquisition and ordinary regression

The original trajectory XZ poses/layouts remain unchanged; physical contacts add Y. Across the eight short layouts and both main long runs, there are **1,381,104 active executed contact observations**. Fold accounts for **110,864**: 99,635 CONTINUED, 9,441 HANDOFF, 645 COLD_ACQUIRED and 1,143 FAILED. All fold observations enter the reference ledger; envelopes exist for all 110,864, with **33,017 wrong-lower selections and 1,143 reference-supported misses**. The two remaining main-corpus misses are lateral.

Cold fold has **1,204 ownerless attempts** and a reference envelope in every one: 645 numerically valid acquisitions, **308 reference-matching envelope endpoints**, **334 wrong-lower selections**, **559 explicit failures** and three other valid unmatched outputs. Numerically acquired does not mean physically correct.

| Scenario | Active observations | CONTINUED | HANDOFF | COLD | FAILED |
|---|---:|---:|---:|---:|---:|
| Stationary | 163,064 | 161,381 | 1,543 | 140 | 0 |
| Slow | 156,344 | 156,014 | 218 | 112 | 0 |
| Fast | 114,696 | 114,389 | 227 | 80 | 0 |
| Acceleration | 114,696 | 114,097 | 519 | 80 | 0 |
| Turning | 112,776 | 112,636 | 68 | 72 | 0 |
| Lateral | 112,776 | 112,475 | 225 | 74 | 2 |
| Crest | 110,864 | 110,800 | 0 | 64 | 0 |
| Coastal interior | 110,864 | 110,373 | 427 | 64 | 0 |
| Coastal boundary | 110,864 | 110,631 | 169 | 64 | 0 |
| Wrap | 41,648 | 41,542 | 74 | 32 | 0 |
| Combined translation/rotation | 41,648 | 41,548 | 68 | 32 | 0 |
| Reentry cold trajectory | 40,000 | 39,421 | 19 | 560 | 0 |
| Reentry hint trajectory | 40,000 | 39,432 | 8 | 560 | 0 |

Ordinary scenarios retain zero explicit failures except lateral (2). However zero unnecessary ordinary handoffs is **not established**: the local continuity-radius heuristic reports handoffs in stationary/slow/interior and other ordinary scenarios, even when a single reference cluster is discovered (**3,503 non-fold handoff endpoints** have one discovered root). Endpoint envelope agreement cannot turn an unproven ancestry change into a legitimate handoff. This ordinary status regression remains open and contributes to PARTIAL. Covered ordinary cases have zero wrong-lower results; their full active observations are not all exhaustively referenced.

| Inactive duration | Main cold / retained-hint observed first logical returns | Stale prior ownership | Explicit failures |
|---|---|---:|---:|
| 1 tick | 80 / 80 | 0 | 0 |
| 5 ticks | 32 / 32 | 0 | 0 |
| 30 ticks | 64 / 64 | 0 | 0 |

These counts include short and long 16×16 layouts. Coalescing skips some first logical activation submissions; they are not counted as executed reentry queries. Main reference coverage includes 224 cold-reentry-scenario and 113 retained-hint-scenario cases, with zero wrong-lower results or misses in those covered cases. Only 14 of the specifically marked first logical reentry returns (five-tick duration) entered that original reference ledger; it did not directly reference all 352 observed first returns. This gap is stated rather than treating ordinary validity as a reference proof.

Supplemental 10×8 captures the **first actually executed cold return after every inactive interval**, including a coalesced initial activation submission: **96 / 88 / 88** results for 1 / 5 / 30 ticks (272 total), **all COLD_ACQUIRED, prior ownership false, zero explicit failures**. All **272/272 match the discovered reference envelope**, with zero wrong-lower results or misses at every duration. The wider stationary-reentry cohort has 1,067 referenced cases and likewise zero wrong/miss results. Reentry ownership clearing is established in these tests; reliable fold-envelope acquisition remains unclosed.

## Hysteresis and handoff chatter

The dedicated equal-height crossing searches 41 authored timestamps and starts with two roots only **0.100970 mm** apart in Y. Sixty updates per sheet (120 total) produce **one handoff, zero immediate reversals, zero wrong-lower results**. Both finish on the same higher sheet. No height clamping is used.

Across the full main trajectories, the raw counters are **13,006 handoff statuses**, **118 immediate reversals** and **16 handoffs/slot/second maximum**. The reversal metric compares successive handoff q positions; it is a diagnostic pattern, not proof that every reversal is numerical noise. An independent case-scoped analysis of serialized q/time counts 116 reversal patterns and **28 overlapping repeated-toggle windows**: consecutive handoffs less than 0.1 s apart return within 2 cm of the previous handoff's old q, twice consecutively. The two-count live/serialized discrepancy is retained; exact equivalence at those strict floating-point cutoffs is not established. Global zero numerical chatter is **not established**; the dedicated near-tie test alone cannot close the broad trajectory gate. All old/new q, Y and reason diagnostics remain in the case archive.

## Signed depth and controlled two-root regression

Open ocean and Coastal each have six above/at/below probes across rich/compact output. Expected depths −0.10/0/+0.10 m agree to **0.0077501 mm** (open) and **0.017333 mm** (Coastal). Input Y leaves q/selected surface unchanged. Fold cold acquisition and lower-owned handoff each have six probes; **all twelve use the wrong lower surface**, about **318.236 mm** below the reference. A point 10 cm below the true upper surface can therefore be wrongly reported about 0.218 m above the selected lower surface. The arithmetic formula error is only **9.313×10⁻⁹ m**; physical depth is nevertheless incorrect because sheet discovery failed.

Six supplemental probes through the **successful higher-sheet handoff** fixture return HANDOFF/reason 8 on both rich and compact paths, with zero wrong-lower selections. Above/at/below depths are −0.0999994054 / +0.0000006153 / +0.1000006422 m, maximum error **0.000642240 mm**. Thus signed-depth arithmetic works when selection is correct; it does not repair a wrongly selected lower sheet.

The old **NUMERICAL** two-root regression remains separate: **360 updates, zero GPU failures, zero branch jumps**, minimum root separation 0.343925476 m. CPU ContactOracle has zero failures/mismatches; legacy CPU world inversion retains 137 diagnostic failures. This does not authorize a lower physical sheet.

The new **PHYSICAL** controlled run has 360 updates, zero explicit failures, 358 CONTINUED and 2 HANDOFF statuses, but **3 wrong-lower results** at the first three updates of the lower-seeded contact. At XZ (393.4588, −992.3107), time 2.25, dense discovery finds seven roots and upper Y **0.112039998 m**; the returned lower surface is −0.2061959 m. It reaches the upper candidate at update 3. Preserving two numerical roots therefore passes while physical initial selection fails.

## Full layout matrix and long stress

Each short layout has 240 physics submissions. Contacts per hull include 4, 8 and 16. GPU cost is complete dispatch, not divided by contacts.

| Vehicles × contacts | Active observations | FAILED | HANDOFF | Executed / coalesced | GPU mean / p95 / max (ms) |
|---|---:|---:|---:|---:|---|
| 1×4 | 960 | 0 | 0 | 240 / 0 | 0.182449 / 0.221440 / 0.268032 |
| 1×8 | 1,920 | 0 | 0 | 240 / 0 | 0.183870 / 0.222208 / 0.264192 |
| 1×16 | 3,840 | 0 | 0 | 240 / 0 | 0.187840 / 0.221952 / 0.264192 |
| 4×8 | 7,680 | 0 | 0 | 240 / 0 | 0.232071 / 0.267008 / 0.268544 |
| 6×8 | 11,472 | 0 | 0 | 239 / 1 | 0.221474 / 0.242688 / 0.263680 |
| 10×8 | 16,000 | 10 | 92 | 200 / 40 | 8.897742 / 11.109376 / 13.163520 |
| 10×16 | 16,640 | 14 | 157 | 104 / 136 | 11.658700 / 14.460928 / 16.049408 |
| 16×16 | 15,328 | 10 | 133 | 60 / 180 | 13.659533 / 18.761216 / 21.055232 |

| Main long stress | 10×8 | 16×16 |
|---|---:|---:|
| Physics submissions | 10,000 | 10,000 |
| Executed dispatches | 8,244 | 2,543 |
| Coalesced submissions | 1,756 | 7,457 |
| Active executed observations | 659,520 | 647,744 |
| CONTINUED | 653,469 | 638,106 |
| HANDOFF | 5,217 | 7,407 |
| COLD_ACQUIRED | 298 | 1,656 |
| FAILED | 536 | 575 |
| GPU mean / p95 / max (ms) | 9.007370 / 11.920640 / 19.459328 | 15.694978 / 20.220928 / 23.894784 |
| Async latency mean / p95 / max (ms) | 32.485 / 42.877 / 77.374 | 69.464 / 86.363 / 176.223 |
| Maximum total Newton iterations observed | 72 | 76 |

Every ambiguous result and fold observation from both main long runs is covered by the reference archive. The 10×8 long cohort has **69,883 reference cases, 17,767 wrong-lower results and 536 misses**; 16×16 has **44,320 reference cases, 13,982 wrong-lower results and 575 misses**. Short-cohort wrong/miss counts are 448/10 (10×8), 498/14 (10×16), 322/10 (16×16), and zero for the five smaller layouts. These are separate cohorts, not unique-world-target counts.

Both long runs exercise six current/weather configurations, transitions, direction/choppiness changes, authored folds and pause/resume. Sample time stays at 83.33333333333 s during ticks 5,000–5,200 (spread below 10⁻⁸ s). Original 16×16 includes 1/5/30-tick reentry. The original 10×8 fixture has only vehicles 0–9; reentry was on vehicles 12/13, so supplemental 10×8 overlays activation/deactivation on stationary vehicle 0 without changing its XZ trajectory.

The supplemental 10×8 run completes **10,000 submissions, 7,838 dispatches, 2,162 coalesced**, with 624,304 active contact observations: 618,151 CONTINUED, 5,084 HANDOFF, 565 COLD_ACQUIRED, 504 FAILED. GPU mean/p95/max **9.009330 / 11.906048 / 16.442368 ms**; latency **32.875 / 45.317 / 74.333 ms**. Maximum total iterations is 71. It captures **66,822 reference cases**, including every one of its **62,350 ambiguous results**, every fold result and all 272 actually executed reentry returns.

Supplemental reference discovery finds **424,343 clusters**, maximum 34/target, and an envelope in all 66,822 cases. It has **49,013 reference-matching envelope endpoints**, **16,973 wrong-lower results**, **504 misses** and 332 other valid unmatched outputs. Wrong results split into 14,421 flagged ambiguous and **2,552 not flagged ambiguous**. Fold contributes 62,704 cases, all 16,973 wrong results and 503 misses; lateral contributes the remaining miss. Ownerless fold attempts are 511: 228 valid acquisitions (104 envelope matches and 124 wrong results), 283 explicit failures. Supplemental handoff endpoints include 3,350 envelope matches and 173 apparent false-handoff flags; raw chatter is 5,084 handoff statuses, 83 immediate reversals and 15/slot/second maximum.

Across the two separate captured corpora, all **185,353 cases** and **1,168,495 discovered clusters** are archived: **49,990 wrong-lower results and 1,649 explicit reference-supported misses**. These count executed test updates, including repeated targets and pause updates, not unique world positions. They are not added to the older-failure and controlled-fixture cohorts.

These 15–24 ms query stalls remain **despite** the enforced 80-iteration cap. The performance gate fails; general FFT was not optimized to offset them.

| Required gate | Result |
|---|---|
| Highest-Y volume rule, XYZ ABI, signed-depth arithmetic | Implemented; discovery remains incomplete |
| Zero wrong lower surfaces in every referenced ambiguous result | **FAIL: 33,017 in the main corpus** |
| Reliable cold fold acquisition | **FAIL: 334 wrong results and 559 misses** |
| Seven old lateral endpoint envelopes classified | 7/7 classified; production acquisition succeeds 5/7 |
| Zero unnecessary ordinary handoff / global numerical chatter | **Unclosed**, with ordinary handoff flags and reversal patterns |
| ≤5 solves, ≤16 iterations/solve, ≤80 total | Source cap and measured budget checks pass |
| Focused and legacy surface parity without tolerance/FP64 changes | Pass |
| Ordinary 80/256 mean ≤0.45 ms | Pass |
| Exceptional mean ≤2 ms, p95 ≤4 ms; no 15–40 ms stalls | **FAIL** |
| Async generation, bounded resources, tested retirement/ownership clearing | Observed checks pass |
| READY FOR PHYS-GPU-2 | **NO** |

## CPU/GPU parity and performance gates

The focused **1,280-sample** matrix completes with zero GPU invalid results. Maximum vector displacement error **0.03304936 mm**, vector velocity error **0.05147157 mm/s**, normal **0.027976455°**, world residual **0.85094897 mm**. Gates remain 1 mm / 1 mm/s / 0.5° / 1 mm.

The legacy **6,912-material-sample / 27-snapshot** matrix was rerun. Max displacement component errors X/Y/Z are 0.044213376 / 0.022519666 / 0.038426275 mm (conservative vector bound 0.0628 mm); velocity component errors 0.031516287 / 0.020463607 / 0.037670969 mm/s (bound 0.0533 mm/s). Normal maximum 0.027976455°, 3,072 world inversions max residual 0.998640084 mm, zero GPU world failures/owned branch mismatches. One legacy CPU branch mismatch and 87 CPU-validity mismatches remain recorded diagnostics. Surface parity passes without tolerance relaxation or FP64 conversion.

Ordinary benchmarks contain 24 measured complete packets per size; every contact uses one solve. First packets include cold startup, subsequent packets are warm. Performance gates pass for ordinary batches:

| Complete dispatch | Mean (ms) | p95 (ms) | Max (ms) |
|---|---:|---:|---:|
| 80 ordinary | 0.176661 | 0.172800 | 0.303616 |
| 256 ordinary | 0.161408 | 0.173824 | 0.304640 |
| One reference-validated higher-sheet handoff | 4.158901 | 4.571392 | 4.968704 |
| 79 ordinary + 1 validated handoff | 4.007659 | 4.019456 | 4.024832 |
| 255 ordinary + 1 validated handoff | 4.033760 | 4.057088 | 4.059136 |

The successful handoff fixture is old case 2519, config 6/time 133.6667, reference max Y 1.1322489 m with eleven discovered roots, reason 8. Each size has 24 valid higher-sheet replacements and zero wrong-lower results. Mixed-batch ordinary contacts are verified one-solve contacts (zero non-primary ordinary solves). Desired exceptional mean ≤2 ms and p95 ≤4 ms **fail**. The maximum complete physical query dispatch is **23.894784 ms** in full stress.

An additional controlled lower-seed fixture measures **attempted but incorrect** handoffs: one contact mean/p95 5.339744/5.911808 ms; 79+1 5.270229/5.276928 ms; 255+1 5.304256/5.320448 ms. Each has 24 wrong-lower results. Uniform exceptional 80/256 batches mean 5.434730/5.448736 ms with 1,920/6,144 wrong results. These timings are retained as failure evidence, never presented as successful physical handoff cost.

## Async, resources and lifetime

Production uses the global RenderingDevice and existing renderer scheduling. **No production rd.sync(), no blocking buffer_get_data(), no CPU q/history feedback.** Async buffer readback, latest coherent generation semantics and ring capacity **3** remain. Main run maximum in flight is 2; zero generation mismatches, callback errors, target-time rejections or validation-capture drops. Per-contact invalidity remains explicit. Validation-only GPU enumeration never writes persistent history.

The ten storage buffers include one persistent state buffer. Allocated GPU query footprint is **768 KiB** versus previous 656 KiB, due to required XYZ/depth/state diagnostics; no root lists or extra production queue. Scene reload/retirement is tested in four cycles, each with 32 submissions, 31 coalesced and one retired in-flight request. Every cycle ends with zero buffers, zero in-flight, zero mismatches/errors. Static memory is 141,354,790 → 141,359,954 bytes across cycles (5,164-byte drift), no growing query RID count.

Telemetry-off 16×16 stress has **10,000 submissions, 8,264 dispatches, 1,736 coalesced**, zero metric/trace/capture arrays, zero errors/mismatches and bounded ten buffers/one state. After initial setup, tick 1,000 memory is 156,314,921 bytes and tick 9,000 is 156,338,261 (23,340-byte drift); this is bounded observed production memory, not a claim that all process allocations are constant. Final shutdown has zero buffers, in-flight, submitted-identity slots and pending invalidations. Telemetry-on stress intentionally retains a large validation ledger and grows CPU memory; that archive growth is not attributed to a production resource leak.

Identity tests cover initial cold, ordinary continuation, coalesced inactive/reset/occupant changes, 1/5/30-tick retained hints, reset/generation/vehicle/contact reuse and marked teleport. All ownership-clearing cases return without prior ownership, ordinary valid acquisitions remain reference-supported, and NaN contact Y is invalid. Production-mode validation seeds are rejected. Final main reentry returns have zero stale ownership for both cold and retained hints. No stale state/callback/RID leak was observed in these tests.

## Reproduction, artifacts and Git

Primary modified source: `addons/ocean/physics/gpu/ocean_surface_query.glsl` and `.gd`. Added contact contract, `phys_gpu13_runner.gd`, `phys_gpu13_export.gd`, read-only `phys_gpu13_verify.cjs`, this report, measurements, legacy parity, old reclassification, compressed full contact/current-failure ledgers and all per-case root archives under `validation/physics/gpu13_envelope/`. Earlier PHYS-GPU-1.2 evidence is preserved.

`PHYS-GPU-1.3-EVIDENCE-MANIFEST.json` lists compressed/plain SHA-256, byte counts and row counts for every exported evidence file. `PHYS-GPU-1.3-ENVELOPE-EXAMPLES.json` retains the first 2,048 main failing examples and aggregate totals; it is **not** the complete case corpus. Every case/root is in **62 main and 36 supplemental numbered JSONL gzip parts**. Export and independent read-only verification both finish with **zero errors**. All **105 evidence files**, totaling **224,696,842 bytes** (about 214.3 MiB), pass checksum, decompression, size and row checks. Largest file is **27,635,449 bytes**; no evidence file exceeds 100 MiB. Production shader/wrapper and export/verifier source hashes match. Required reference fields, reported fine residuals, coherent packet identity, ≤5/80 production budgets and all executed-predecessor comparisons pass archive checks. These checks validate the evidence, not physical PASS.

The tested production shader hash is `a7608f750628550e877b7e004d53f0f4eaebb2dd05b44d758f12fa6aeb5280ba`; wrapper hash `343c2e55e5297fa59bbebcf1f81e98c63f7c8fbd26efb04aad01ee41a773b58b`. Main runner hash at launch was `76c03763397b7efb2f2dabb8cff9b63b815e291a6cd774ae6efe05bcba4bc77a`; subsequent harness extensions add supplemental depth/reentry capture and clarify diagnostic logging, without changing those tested production sources. Each later proof retains its launch hashes.

Run GPU jobs sequentially on the real Forward+/D3D12 device, never headless. From this repository:

```powershell
$validationExe = 'C:\Users\Eric\Desktop\Godot_v4.7.1-stable_win64_console.exe'
& $validationExe --path . --log-file .godot/phys_gpu13_full_engine.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu13_runner.gd -- --full
# Repeat sequentially with: --envelope-replay, --old-replay,
# --current12-replay, --ties, --bench-only, --success-bench,
# --resource-only, --lifecycle, --reentry10, --reentry10-envelope.
& $validationExe --path . --log-file .godot/phys_gpu13_legacy_engine.log --rendering-method forward_plus --rendering-driver d3d12 --script res://validation/physics/phys_gpu1_runner.gd -- --matrix-only
& $validationExe --headless --path . --log-file .godot/phys_gpu13_export_engine.log --script res://validation/physics/phys_gpu13_export.gd
node validation/physics/phys_gpu13_verify.cjs
```

Envelope replay follows its completed ledger-producing stress job. Headless is used only for import/export. Test exits and empty `checks` arrays indicate completed protocol checks, **not physical PASS**. Earlier progress lines labeled `failures=0` read the inherited numerical collector, not the physical failure bins; the final harness labels this counter `protocol_checks`. Physical failure/wrong-sheet totals above remain explicit. Earlier startup log-rotation failures and a fixed harness `previous_q` key error are excluded from final metrics. Task-owned stalled processes were identified by exact command line before termination; the user's existing editor remained untouched.

Structural inspection used the installed codebase-memory skill with coverage checks; stale/partial index coverage was resolved by direct source inspection of reported missing ranges. The graph is an aid, not a completeness certificate.

Implementation commit: `b247abb` — Define physical GPU free-surface sheet selection. Lifetime fix: `3334f06` — Clear GPU contact ownership across coalesced lifecycle packets. Validation/report commit: the commit containing this file, subject **Validate upper-envelope ocean contact contract**; resolve its exact hash with `git log -1 --format=%H -- validation/physics/PHYS-GPU-1.3-REPORT.md`. Publication is restricted to **origin/wip/phys-gpu-1**. Delivery checks verify successful publication, identical local/remote branch HEAD, a clean worktree and unchanged protected local refs. No other branch is pushed.

Protected refs at start: `wip/phys-opt-2 = df4f5eca68c1d5918cd6bfd4e6f6cfb08c1260e7`, `master = fe6df4d4ce8dcafe05d176f1f312eaa4c9332dbf`. Neither is modified or merged.

**Architectural status: NOT READY FOR PHYS-GPU-2.** Highest-Y semantics are decided, but bounded discovery, physical status ancestry, broad chatter and exceptional dispatch cost remain unclosed. No PHYS-GPU-2, PHYS-GPU-3 or PHYS-4 work was started. No force fallback or new envelope acceleration structure was introduced.
