# Boundary tsunami

Instance `res://addons/ocean/events/boundary_tsunami.tscn` in the level.
Assign **Ocean** and **Target** (the Jet Ski root). Set **Boundary Radius M**.
Move this node to the centre of the playable map, or assign a separate
**Boundary Center** Marker3D. Detection uses horizontal world metres, ignoring Y.

The defaults are a 1000 m boundary and a 60 m wave, spawned 220 m outside the
target. **Wave Height M**, **Front/Back Width M**, **Wave Speed Mps**, **Spawn
Distance M**, rise/fade times and the impact impulses are editable.

On crossing the limit, a circular crest forms outside the target and contracts
towards the map centre. Its closing speed stays above the target's measured
inward escape speed. It has a configurable catch deadline (12 seconds by default),
and an entire ring cannot be evaded by driving sideways. Returning inside the
boundary after activation does not cancel the incident. Swept crossing checks
handle fast movement and long physics frames. The centre is fixed for that incident.

The event adds the same giant-wave height, slopes and vertical water velocity to
the visible ocean, CPU contacts, underwater sensor and waterline raster, after
the normal FFT/local-sea mixing. It includes a leading trough and a white crest.
Clipmap culling bounds include its full height. This is a scripted gameplay wave,
not a fourth FFT or a coastal shallow-water tsunami simulation.

At impact, `target_caught(target,direction)` is emitted. Jet Ski implements the
optional `request_boundary_tsunami_wipeout` adapter. If the host already provides
its own wipeout system it receives the standard `boundary_tsunami` context.
The standalone addon otherwise creates a small fallback: lock controls, tumble
the vehicle, and recover after four seconds. It does not add rider ragdoll physics
or change normal driving/ejection behaviour.

For a predictable safe return, assign **Recovery Point** to a Marker3D on safe
water. Otherwise the controller remembers the last target position inside the
rearm margin, uses a valid original spawn, or falls back to a point inside the
circle. That final fallback does not test land/building collisions; an explicit
marker is recommended in levels containing islands or docks.

Recovery/manual reset clears the incident. It rearms when the target is inside
**Boundary Radius M − Rearm Margin M** and no longer in wipeout. One controller
is supported per Ocean. Custom targets can connect `target_caught` to their own
game-over/recovery logic; Ocean has no dependency on the Jet Ski addon.

No boundary is active just by installing the addon: instantiate and configure
the controller in the desired level. Existing scenes and saved sea settings are
not changed. This implementation is in Ocean Production; it has not been copied
to Test Add-ons.

Validation: `tsunami_boundary_check.gd`, `tsunami_render_check.gd` and
`tsunami_jet_ski_check.gd` under `validation/`.
