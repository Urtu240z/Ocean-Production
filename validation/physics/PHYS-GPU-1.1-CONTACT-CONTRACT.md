# Persistent GPU contact contract

The world-query authority and interpolation are unchanged from PHYS-GPU-1. The
new opt-in `pack_contacts` / `submit_contacts` API adds an independent GPU-owned
history for each stable slot. Legacy 32-byte material/world packets remain valid.

## Identity and lifetime

Descriptors contain `slot` (0..1023), `vehicle_id`, `contact_id`, occupant
`generation`, `active`, and optional `reset`, `retain_hint`, `hint_q`,
`owned_seed`. A packet may reference a slot only once; duplicate/out-of-capacity
slots are rejected before dispatch to prevent storage races.

The caller must increment occupant generation on slot/vehicle reuse. Removal is
an explicit inactive descriptor for the removed contacts. Teleport or deliberate
history invalidation uses `reset=true`; absence from a packet is not deactivation.
An ocean epoch change automatically makes existing ownership unusable. Weather
configuration changes do not reset contact ownership.

`owned_seed` initializes a known branch for validation/import of an established
root. Ordinary activation does not set it. `hint_q` or `retain_hint` is non-owned
acquisition history. For the same occupant, the GPU-retained q takes priority as
the hint, avoiding a CPU round trip. Invalid input coordinates fail that contact,
not its structurally valid neighbours.

## State ABI and results

One persistent storage buffer has capacity 1024, explicitly zero-initialized.
The std430 state stride is 80 bytes:

| Member | Contents |
| --- | --- |
| dvec2 q | owned/last good material q, FP64 |
| dvec2 target | prior world target |
| uvec4 owner | vehicle, contact, occupant generation, active |
| uvec4 stamp | ocean epoch, last dispatch generation, status, valid |
| vec4 motion | previous horizontal water velocity, sampled time, local Jacobian |

Each ring slot adds a 32-byte/contact control buffer: slot, occupant generation,
action flags, validation-only reserved lane, and an optional hint. Existing input
is still 32 bytes/contact. Rich persistent output is 128 bytes/contact; compact
is 96. The original 96/64-byte legacy outputs are unchanged.

Persistent output appends status, number of Newton solves, termination reason,
whether the solve started with ownership, previous q, q delta and local radius.
Coordinates in diagnostic/readback records are FP32; internal owned q is FP64.
Status 1=CONTINUED, 2=REACQUIRED_LOCAL, 3=COLD_ACQUIRED, 4=FAILED. FAILED always has
validity zero and clears ownership. No best-invalid candidate becomes valid.

Inactive contacts return FAILED/reason 6, preserve a non-owned hint, and do not
churn acquisition. Cold policy ignores the hint; hint policy can reuse it without
pretending that airborne history owns a branch. A new occupant cannot use a prior
occupant's hint even if it requests hint retention.

## Bounded solver

The primary seed for a valid owned contact is the GPU state q. It never depends
on which CPU result was consumed. The solver has 16 Newton iterations and 12
backtracking trials, a 0.0001 m local derivative stencil, and the unchanged 1 mm
world residual acceptance. Newton candidates must remain inside the local
radius and preserve the owned local Jacobian orientation at candidate/midpoint.

The radius accounts for inverse-Jacobian amplification of the current residual,
world target motion, water velocity/time delta, current sampled displacement and
prior horizontal displacement. It has a 0.1 m minimum, no arbitrary four-metre
ceiling. This bounds a finite seed search, not a projection/clamp of q or ocean
geometry. It is a local guard, not a mathematical proof of branch uniqueness.

On primary failure, four deterministic cardinal seeds are tried. Warm seed
radius is min(local radius/2, 0.25 m); warm candidates retain radius/orientation
guards. Among valid candidates, the closest q to the owned q wins, not the lowest
residual or global q ordering. Cold seed radius is clamp(|D(target).xz|/2,
0.25 m, 1.5 m), with no invented ownership. Maximum five solves/contact; no
global root enumerator or CPU fallback is called.

Reasons: 1 nonfinite input/residual; 2 singular local Jacobian; 3 no accepted
guarded descent step; 4 iteration limit; 5 owned orientation changed; 6 inactive.
These are numerical termination facts, not proof that no physical root exists.

## Ordering, resources and validation

All contacts share one dispatch with 64 invocations/workgroup. Authoritative band
dispatches precede the query on the global RenderingDevice; subsequent query
dispatches read the previous GPU state writes. Readback callbacks never write
contact state. Three result slots, one pending/latest mailbox and one completed
mailbox retain PHYS-GPU-1 async semantics. No sync, blocking readback, CPU ocean
query or extra ocean transform is added to production.

At capacity: three input/control/output triplets plus one 80 KiB state buffer,
10 storage buffers / 656 KiB total. Count changes do not allocate new buffers.
Retirement frees them only after all outstanding callbacks drain. Ocean/Coastal
textures remain borrowed. Shader reload requires query retirement/recreation;
live shader replacement is not certified by this phase.

Validation metrics enable a bounded 32-packet completion capture, drained by the
harness. It records every coherent persistent completion, including packets
superseded by ordinary latest consumption. An overflow counter prevents a false
claim of complete failure accounting. Normal runtime has no such capture queue.
Detailed timestamp/trace arrays retain the existing 16,384-entry cap.

The reserved control lane can bypass the primary solve ONLY when validation
metrics are enabled, to measure four-seed local recovery separately. Ordinary
runtime rejects that reserved lane. This timing probe does not relax validity,
branch guards or residual tolerance and is not counted as natural recovery.
