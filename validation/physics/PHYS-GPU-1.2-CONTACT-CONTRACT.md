# PHYS-GPU-1.2 contact inversion contract

The PHYS-GPU-1.1 packet, result, state, generation and async contracts remain
unchanged: 1 mm acceptance; GPU-owned q; 1,024 stable slots; 80 bytes/state;
three fixed readback slots; FAILED is invalid and clears ownership. The retained
q after failure is only a hint. Cold acquisition has no inherited ownership.

The ordinary primary is still one 16-iteration solve with a 0.1 mm local
Jacobian stencil and 12 strict-descent backtracks. A primary success performs
no additional solve. Physical normals and reported determinant keep their
existing 1 cm derivative convention.

After an enabled owned primary fails, two exceptional attempts start from
the unchanged previous q, before the existing four cardinal recovery seeds.
Each has at most 128 iterations and 16 backtracks; Newton steps are clipped
to half the smallest active FFT cell (0.072265625 m for the validated bands).
The first uses the ordinary 0.1 mm stencil; the second uses 1 micrometre.
Both retain the existing radius and prior orientation guard at the current
q, trial q and midpoint. abs(detJ)<1e-8 still rejects division. The iteration
and line-search bounds also limit work for ill-conditioned, stalled contacts.
If both corrections fail, two then four fixed-current-field target segments
are tried. Each restarts from the owned anchor, interpolates from its current
mapped world position to the requested target, and uses the same guarded fine
128-iteration solve at every segment. Partial segment results are never
published. Every segment retains the original orientation, radius and anchor.
Maximum solves are thirteen for an owned failure and five for cold acquisition.
The reserved forced-recovery validation lane bypasses all new corrections so
its historical four-cardinal benchmark remains comparable.

The fine stencil repairs averaging across moving Coastal interpolation kinks
observed in replay. It is an exceptional numerical correction, not a relaxed
residual or a claim that determinant sign defines a physical sheet. A successful
exceptional attempt reports REACQUIRED_LOCAL. That status is a candidate result;
it is not a certificate of continuous ownership through time.
The legacy residual acceptance precedes the Jacobian test at a solve's starting
point. A within-tolerance approximate point is accepted without establishing
an exact root or testing its orientation there; this is another reason the
guard cannot be treated as a complete ownership certificate.

No time predictor or historical FFT substeps are introduced. Target segmentation
is a fixed-snapshot correction homotopy, not physical-time reconstruction. Offline velocity
prediction used a reconstructed full previous Jacobian. Runtime state stores
only its determinant, not four previous Jacobian entries. The predictor helped
and hurt tested cases. Current-field orientation guards can still reject an
otherwise surviving time-connected branch when the old anchor lies on the
opposite side of a moving caustic. Globally removing that guard is not justified.

Runtime FAILED is not relabeled TERMINATED from a Newton failure. Offline
bilinear enumeration can establish sampled local pair loss for reconstructed
open-water cases; it does not establish every runtime failure's physical cause.
Until an independently validated sheet policy exists, termination remains an
explicit invalid result and a subsequent query uses the existing cold/hint path.
No force behavior is defined here.

Cold multi-root XZ acquisition remains physically unresolved. The renderer
contains several material-q sheets with different heights. The query does not
specify an intended Y intersection, a ray direction, or a highest-sheet rule.
Nearest/first-valid root ordering alone cannot supply that missing contract.
No height policy is invented in this phase.

Validation captures the executed predecessor time, target, q, physical det,
velocity, configuration, weather alpha, spectrum time and GPU time for new
failed contacts. This ledger is diagnostic only and never enters normal query
packets. Its q values are FP32 serialized outputs; internal state remains FP64.
