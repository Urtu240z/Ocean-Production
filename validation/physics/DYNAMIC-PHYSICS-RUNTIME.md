# Dynamic physics runtime contract

The direct spectral solver remains the oracle. The CPU FFT mirror supplies cheap
queries over complete LONG/MID/SHORT fields and the unchanged deterministic
Coastal bake. No gameplay forces are connected by this change.

## Snapshot ownership and time

- Three preallocated buffers: published, writer, spare. Readers acquire one
  immutable snapshot containing all bands, time, configuration version and H0.
- Render-thread spectrum readers retain the publisher atomically and read all
  metadata from that immutable snapshot. Shutdown detaches the publisher and
  joins the producer before clearing its builders; an already active reader can
  finish without accessing cleared core state.
- One build in flight and one latest-request mailbox. Intermediate requests are
  coalesced. No FIFO backlog or cancellation of every nearly finished build.
- A late completion is published if it advances the same coherent configuration.
  Age alone is not a reason to discard the freshest available progress.
- Build and ready/publication states are independent. A completed field slightly
  ahead of Production time may wait safely while the spare buffer builds the next
  latest target. At most two ready buffers can exist; publication picks the
  newest due field and releases older ready buffers. This is bounded ownership,
  not a FIFO of missed requests. No target beyond the caller's one-tick request
  is invented.
- Pause cancels future requests. Obsolete configurations, future canceled fields
  and regressing timestamps remain rejected.
- Call `advance_dynamic_async` once per physics tick with Production
  `Ocean.get_wave_time()`. The next target may be one deterministic tick ahead.
  Query methods return the published snapshot, whose actual time is explicit in
  `get_dynamic_snapshot_info`. They do not promise a time they have not built.
- Production advances its clock in `_process`. A process-wide hitch can cause a
  clock jump larger than one physics tick. Measure this separately from producer
  latency; recovery must jump to latest, not simulate every missed tick.

## Opt-in runtime weather

Use `addons/ocean/physics/dynamic_ocean_weather.gd` with an initialized native
mirror and its existing OpenOceanFFT node. The validation weather runner shows a
complete call sequence. Authoring setters and `Ocean.initialize()` retain their
existing behavior; consumers must use the runtime adapter for a live transition.

Initialize this runtime mirror through `set_production_spectrum` before
`start_dynamic_async_fields`. Generic spectral-array setters remain valid for
the oracle, but do not carry Production weather metadata. The adapter verifies
initial H0 bytes, resolution, domain, gravity, choppiness and wind metadata against the renderer
before starting its worker, rejecting an incompatible setup.

1. Build target configs with the Production wave profile, retaining the same seed
   and phase identity. `request(configs, parameters, duration)` takes private
   copies and returns a serial immediately.
2. One persistent worker prepares immutable H0 endpoints with the exact Production
   JONSWAP/Hasselmann equations. It never accesses a Node or RenderingDevice.
3. `poll(wave_time)` activates a ready transition. Native FFT builds interpolate
   float32 H0 and choppiness at their explicit requested simulation time. At the
   endpoints bytes are exact, avoiding cancellation from `a + (b-a)*1`.
   Each band's composition runs in its existing persistent FFT preparation job,
   directly before evolution. It does not serialize three full mode loops on
   the producer or add another job barrier. Inputs are immutable; each job
   writes only its own unpublished band arrays.
4. The existing renderer receives that same published H0 through its render-thread
   callback and existing H0 textures. All three bands update before dispatch.
   No GPU readback, scene reconstruction or texture reallocation is needed.
   Accessors keep the renderer's current `wave_time` separate from the retained
   H0's `spectrum_snapshot_time`; neither is substituted for the other.
5. Rapid pending requests coalesce. An active intentional ramp completes before
   the latest prepared destination is accepted, so its source cannot jump back to
   a stale state. This weather policy is separate from snapshot latest-wins.
6. Pausing Production time freezes the ramp. Call `shutdown()` explicitly before
   releasing the adapter; it joins the preparation thread.

Weather preparation is asynchronous but is not instantaneous. Its measured ready
latency and GPU upload cost must be reported separately from FFT freshness.
`call_on_render_thread` follows the configured Godot renderer thread model; with
a single renderer thread, upload work can execute on the caller. It is not a
guarantee of zero main-thread weather cost.

The runtime lattice (N, domain and gravity/dispersion) remains fixed. Weather can
change wind, direction, amplitude/Hs and choppiness continuously. Lattice changes
require an explicit mirror/renderer lifecycle restart, not a racing plan mutation.
Culling bounds grow conservatively through transitions, including the possible
cross-product of independently varying amplitude and choppiness.

## Oracle and velocity semantics

`set_production_spectrum` imports authoritative bytes and prepares the full direct
oracle. `prepare_production_spectrum` creates a private FFT-only weather endpoint;
it is not a prepared arbitrary-q direct oracle. Runtime transitions update the
mirror, not the live object's old direct spectrum. To validate a weather snapshot,
configure a separate direct object from `get_dynamic_snapshot_spectrum()`.

PHYS-OPT-2G closes moving-weather velocity. The mirror's Vx/Vy/Vz are the total
time derivative of displacement at **fixed material-q**, with respect to
Production simulation time. The fixed-state direct oracle remains phase-only;
it is not an oracle for a moving weather envelope.

The unchanged authored ramp is `alpha = clamp((t-start)/duration, 0, 1)`.
There is no easing. Its derivative is `1/duration` strictly inside the ramp and
zero outside. Exact endpoint snapshots select the outside/fixed-state derivative.
The linear ramp has distinct one-sided velocity limits at start/end; a central
difference straddling an endpoint averages those limits. This is an authored
derivative discontinuity, not a velocity impulse introduced by the implementation.

The actual frequency evolution is `H = A*exp(-i*omega*t) + B*exp(+i*omega*t)`,
where B is the retained conjugate-negative H0 channel. Total height velocity is
`-i*omega*A*exp(-i*omega*t) + i*omega*B*exp(+i*omega*t)` plus
`A_dot*exp(-i*omega*t) + B_dot*exp(+i*omega*t)`.
Endpoint direction, Hs, common amplitude, band scaling and MID fill are already
embedded in A/B; no second scale or direction derivative is applied.

H0 mixing/upload still rounds to float32 at the existing operation boundary.
`A_dot/B_dot = (endpointB-endpointA)*alpha_dot` differentiates the authored linear
envelope. Literal float32 quantization is a staircase, without a useful classical
derivative at rounding jumps. Temporal finite differences of the **actual rounded
mirror displacement** verify total velocity, convergence and the small quantization
residual; no fake derivative of numerical quantization is used.

Horizontal spectra are `Dx=-i*a1*H`, `Dz=-i*a2*H`, with
`a1=-lambda*kx/|k|`, `a2=-lambda*kz/|k|`. Their velocities add
`-i*a1_dot*H` and `-i*a2_dot*H` to the phase+H0 terms. Choppiness does not multiply
height. Static Coastal coordinates/confidence/shoaling apply the same linear
blend to LONG velocities as to displacement. MID/SHORT stay at material-q.
All corrections reuse existing velocity spectra: **18 packed 2D IFFTs**.

Endpoint pointers, start/duration and configuration version belong to one
immutable build request. The producer prepares six double-precision endpoint
delta arrays per band only when that request's configuration version changes.
The arrays are preallocated at startup (9 MiB total at 3x256), remain immutable
while the synchronous band jobs borrow them, and add no main-thread work or
steady-state allocation. Snapshot metadata exposes `weather_alpha_dot`,
`weather_start_time`, `weather_duration` and per-band `choppiness_dot` alongside
the existing spectrum/time/version. Queries do not calculate envelope derivatives.
Pause freezes the snapshot and its stored intrinsic dD/d(simulation_time), including
velocity and metadata; the stored velocity is not dD/d(wall-clock) during pause.
See [PHYS-OPT-2G report](PHYS-OPT-2G-REPORT.md) for measured oracle/errors/cost.

## World inversion and folds

The mirror solves one material-q against the combined displacement. The 5 cm
Newton stencil and 1 mm position tolerance are unchanged. Residual backtracking
prevents full Newton steps from jumping across Coastal transitions and diverging.
No displacement, confidence or bake clamp was added.

On a failed cold start only, deterministic alternate seeds use the bound
`sum(max_band |D.xz|)` measured from the same immutable lattice snapshot. The
bilinear field and Coastal horizontal blend are convex, so a root lies inside
that radius. This bounded search adds no work to the FFT producer or successful
first attempts. Its iterations and cost remain observable. Warm starts keep the
local continuation attempt and report failure instead of jumping branches.

Coastal can create a folded horizontal mapping, particularly in storms. Negative
horizontal Jacobian means inversion is not globally unique. Validation reports
these points, all cold-start failures, nearby warm-start residuals and alternate
q recovery separately. A low residual alone does not prove branch identity.
Future consumers must inspect `valid`, `foldover`, residual and snapshot time, and
define branch continuation/rejection before buoyancy integration. This change
does not invent that gameplay policy or flatten the Production geometry.

## Reproduction

First run the tracked `setup_native_windows.ps1` bootstrap/build. Then:

```powershell
./validation/physics/run_dynamic_physics_validation.ps1 -GodotExe '<Godot 4.7.1 executable>'
```

Add `-IncludeDirectOracle` for the original PHYS-3 suite. Generated captures/logs
remain under ignored `.godot` (the original PHYS-3 report uses the temporary
directory). Source tests preserve the existing physics thresholds. The shared
`phys_native_build_contract.gd` guard must match the compiled native identifier.

## Pending closure

- Crest G / Spindrift clamp discrepancy.
- P3D.1 travelling phase after TIME-1 in an initialized Ocean/Carrier scene.
- P3E handoff after TIME-1 in an initialized Ocean/Carrier scene.
- TIME-1 audit instrumentation disposition: remove, move to validation/debug or
  retain intentionally.
