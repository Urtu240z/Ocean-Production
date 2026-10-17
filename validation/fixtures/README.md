# Portable production oracles

These frozen fixtures make the existing deterministic validators reproducible
from a clone. They are test inputs, not replacement production implementations.

- `production_d3/`: accepted D2/D3 provider, controller and vehicle oracle from
  `Water Race Backups/20261016_d3_jet_ski_validated`. The vehicle scene changes only
  its controller reference from the original absolute development path to
  `res://validation/fixtures/production_d3/oracle_controller.gd`. The scripts and
  every other scene value retain the accepted baseline values.
- `native_cpu_lite.bin`: exact E1 Windows reference, 645 time samples and 24
  points per batch. Source: `20261016_e1_linux_validated/native_fixture.bin`.
  The replay excludes timing counters, compares continuous fields at 1e-8 and
  requires exact repeat determinism and discrete flags.

Run with Godot 4.7.1 and the full project, using an absolute output path:

```text
Godot --path . --rendering-driver d3d12 --audio-driver Dummy --fixed-fps 60 --script res://validation/jet_ski_addon_regression.gd -- --fixtures=res://validation/fixtures/production_d3 --result=<absolute-output.json>
Godot --headless --path . --script res://validation/ocean_linux_native_runtime.gd -- --fixture=res://validation/fixtures/native_cpu_lite.bin --result=<absolute-output.json>
```

The second invocation supports Windows or Linux with the matching native binary.
The first requires Forward+ and Jolt Physics. `.gdignore` prevents the frozen
test scripts from being discovered as project scripts; validators load them
explicitly. These fixtures are not needed by either addon at runtime.
