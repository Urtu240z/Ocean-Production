# PHYS-GPU-1.3 physical free-surface contract

The physical base-ocean surface is the upper envelope of Production LONG,
MID, SHORT and Coastal/shoaling at world XZ. Water exists below that selected
height for buoyancy. BreakerCarrier geometry is excluded. Contact Y affects
only signed depth: surface_y - contact_y. No force behavior is defined.

Physical mode 3 uses a 32-byte input: FP32 world XYZ plus padding at bytes
0/4/8/12; u32 mode/unused/vehicle/contact at 16/20/24/28. Mode 0 material,
mode 1 legacy inversion and mode 2 numerical branch validation keep their
existing layout. Each packet is homogeneous in persistent mode.

The control descriptor remains 32 bytes: stable slot, occupant generation,
action flags, reserved validation lane, then optional q hint and padding.
Normal physical q/history remains GPU resident. No oracle q is fed into
production packets. Explicit owned seeding is for validation, not a physical
authority.

Persistent state is 96 bytes: FP64 q at 0, FP64 target XZ at 16, owner identity
at 32, ocean epoch/sample configuration/status/validity at 48, velocity/time/determinant at 64,
and FP64 contact Y/selected surface Y at 80. Mode identity prevents a numerical
validation branch from being inherited as a physical sheet.

Rich physical output is 160 bytes. The original 96-byte rich sample and
32-byte persistent diagnostics are followed by two vec4s: selected surface Y,
contact Y, signed depth, previous selected Y; then current previous-candidate
Y, maximum candidate Y, height delta, ambiguity flag. Compact physical output
is 128 bytes. Packet generation/configuration remains in the existing rich
header and asynchronous request metadata.

Statuses are CONTINUED=1, COLD_ACQUIRED=3, FAILED=4, SHEET_HANDOFF=5. Numerical
mode 2 retains REACQUIRED_LOCAL=2 solely for the old branch regression. Physical
selection compares valid candidates by actual world Y. Warm selection preserves
the previous-sheet candidate within 2 mm of the maximum; cold ties use
lexicographic q among candidates within 2 mm of the maximum. Returned height
and 1 mm world-residual tolerance are never clamped by hysteresis.

Production contact inversion is bounded to five total solves of at most sixteen
iterations. A clearly ordinary warm primary uses one solve. Exceptional search
evaluates the bounded alternative candidates rather than accepting the first
Newton result. The PHYS-GPU-1.2 128-iteration and target-segmentation recovery
is removed from the production shader. Candidate discovery and ambiguity
detection must be measured against the validation-only root oracle; a bounded
search is not a completeness certificate. Wrong lower-sheet selections or
oracle-supported misses require PARTIAL, never a larger brute-force budget.

Reset, inactivity, teleport with RESET and occupant changes clear ownership. Retained q
can only accelerate reentry acquisition. Failure is explicitly invalid and
clears ownership. Async ring size three, coherent generation handling and
resource retirement remain unchanged.

The caller marks teleports with RESET. A large unmarked target jump is treated
as a possible sheet handoff, not evidence that the previous sheet survived.
Cold/reset acquisition does not infer ownership from a hint. Same-occupant
inactive state retains the last q across repeated inactive dispatches while
the validity bit clears ownership. Occupant generation resides at state byte 40.

Ambiguity evidence includes a 1 cm horizontal Jacobian determinant below 0.35,
absolute determinant above 4, Jacobian column length above 2, a Coastal mask
span above 0.05 combined with warp displacement above 0.5 m, primary failure,
or a corrected q outside the local continuation radius. Four alternative
seeds use world XZ and its local displacement direction and magnitude. These
local checks cannot certify that a disconnected higher sheet does not exist.

Validation mode 4 accepts separate XZ/seed packets, uses up to 48 fine Newton
iterations at a 1 micrometre residual, and never writes persistent contact
state. The wrapper rejects that mode and explicit physical OWNED_SEED controls
when validation telemetry is disabled. Dense discovery uses 802 deterministic
seeds plus any independently discovered roots. It establishes a strong set of
roots, not an exhaustive global topology proof.
