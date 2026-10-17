# PHYS-GPU-1.2 CPU Contact API audit

Audited actual source at starting commit 4da4c7e: all 175 lines of
`addons/ocean/physics/native/ocean_query/src/dynamic_ocean_contact.h`;
`ocean_query_native.cpp` material sampling (344–447), legacy world/cold
(487–582), and Contact API wrapper/batch (639–685); persistent GPU solver
`ocean_surface_query.glsl` (96–188). CPU oracle source is unchanged.

Graph lookup/index/coverage failed with Transport closed; conclusions below
come from actual source, not graph completeness.

| Property | CPU Contact API | GPU PHYS-GPU-1.1 persistent solver |
| --- | --- | --- |
| Ownership | Caller owns complete 27-double row; VALID plus finite q/target and monotonic time enables history | GPU stable slot + vehicle/contact/occupant generation + ocean epoch + valid state |
| First seed | Previous q | Previous GPU q |
| Predictor | Current-snapshot Newton correction at anchor using 1 cm Jacobian; used during recovery | Same kind of current-snapshot inverse-J correction computes radius but is not tried as primary/recovery seed |
| Radius | 2*(prediction distance + target motion + smallest lattice); no hard cap | Inverse-J/target motion + prior horizontal velocity*dt + displacement terms; no hard cap |
| Jacobian | 1 cm displacement FD for local Newton, physical sample's 1 cm determinant for orientation | 0.1 mm local FD for Newton/orientation; physical output determinant remains 1 cm |
| Singularity | Reject nonfinite or abs(det)<1e-6 | Reject abs(det)<1e-8; nonfinite residual guard |
| Connected solve | 12 + min(52,ceil(target_motion/(lattice/2))) iterations | 16 iterations |
| Step limit | Newton step at most half smallest active FFT lattice cell | Backtracking of unrestricted Newton step, within radius |
| Line search | 10 strict-residual-descent trials | 12 strict-residual-descent trials |
| Orientation | Previous physical det sign required at start/candidate/midpoint only for connected solve | Previous local det sign required at start/candidate/midpoint for primary and every warm recovery seed |
| Local recovery | Anchor, predictor, two concentric rings x eight directions; each 12 iterations; orientation restriction removed | Four cardinal offsets min(radius/2,.25m); 16 iterations each; orientation restriction retained |
| Recovery score | distance from old q + .25*distance from predictor; residual tie-break | Distance from old q |
| Cold/global | Legacy cold solver, initial target then 32 broad deterministic alternate seeds; first valid result ends scan | Target/hint plus four cardinal seeds; no global scan |
| Status | CONTINUED=0, REACQUIRED_LOCAL=1, REACQUIRED_GLOBAL=2, FAILED=3 | CONTINUED=1, REACQUIRED_LOCAL=2, COLD_ACQUIRED=3, FAILED=4 |
| Periodicity | q unwrapped; per-band sampler wraps, Coastal bake does not | Same |
| Coastal | Final LONG warped/confidence blend and shoaling; MID/SHORT ordinary q; feather from imported bake | Same authoritative Production field/warp |
| Snapshot | Batch pins one native snapshot | Dispatch follows authoritative ocean work; per-query state updated on GPU |
| Validity | 1 mm residual; finite material sample, even with negative determinant | Same residual, explicit FAILED always invalid |

Important consequences:

1. The CPU primary still starts at previous q, not its predictor.
2. CPU REACQUIRED_LOCAL is explicitly not a connected-path certificate: the
   recovery solve removes the orientation restrictions. Its nearest/predictor
   score does not prove the candidate is the previously owned sheet.
3. CPU REACQUIRED_GLOBAL can select a different root after branch loss. A CPU
   valid result with that status must not be counted as preserved ownership.
4. Both implementations use determinant sign as a local guard, not a complete
   branch label. At singular or nonsmooth points it is insufficient to infer
   continuation or termination.
5. The CPU predictor is a current-snapshot residual correction. It is not the
   time-derivative predictor J^-1*(target velocity - water velocity); the CPU
   algorithm does not use previous water velocity.
6. Neither API defines highest-sheet semantics for cold multi-root XZ queries.
   The CPU global scan chooses its first valid discovered root, and GPU cold
   chooses the nearest discovered candidate to the target/anchor. Neither
   considers root height or the caller's intended sheet.
7. A row that satisfies the 1 mm contract near a fold need not be an exact
   mathematical root. Offline continuation must first establish a sufficiently
   accurate start root and identify its branch before diagnosing termination.
