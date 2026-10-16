# Ocean standalone clock correction — 2026-10-16

## Cause and correction

`OpenOceanFFT._process()` interpolates the authoritative physics wave clock.
Previously, only `CpuFftWaterProvider` contact preparation advanced that clock.
Instancing Ocean without a vehicle or contact consumer therefore left both wave
times at zero even though underwater, sun rays and caustics could still run.

`OpenOceanFFT._physics_process(delta)` now calls the existing clock advance
method. Its existing physics-tick guard also covers calls from CPU consumers,
so whichever runs first advances once. No provider, native binary, FFT math,
shader, scene parameter or vehicle implementation changed. Rendering alone
does not instantiate a CPU provider or construct a CPU physical field.

Ocean now evolves from initialization, including the interval before a vehicle
starts querying water. That fixes the standalone failure and intentionally
changes that previously frozen initial phase; a full trajectory started at a
different wave phase is not claimed to be bit-identical to the old startup.

## Validation

Godot 4.7.1 Windows, actual Forward+ rendering, fixed 60 Hz test input. Results
and original video frame samples are retained in
`temp/ocean_clock_fix_20261016/` (not distributed with the addon).

- `before.json`: reproduced the failure, zero wave-time advance during 45
  consumer-free ticks. Contact preparation was the only source of advancement.
- `after.json`: no failures. The same 45 ticks advance 0.75 seconds without
  creating a CPU provider. Then 12 consumer contexts produce 540 valid samples,
  with one shared CPU Lite construction per tick and no second clock advance.
  Disabled simulation, zero speed and 1.5x speed pass. Visual time advances.
- `clean_after.json`: identical assertions pass in the existing E1 clean
  installation, with no development integrator instantiated.
- `production_integration.json`: passes production scene readiness, water
  support, airborne/reentry, landing, horizontal water velocity, direct foam
  interactions and air/underwater/air transitions.
- `clean_vehicle.json`: the existing clean-install functional probe passes:
  native loading, configurable inputs, acceleration, two landings, recovery,
  spray (eight PNG frames), contact particles, nine camera controls and
  air/underwater/air. No development integrator or debug HUD is loaded. Zero
  native field failures. Jolt Physics and physics interpolation remain enabled.

No new performance benchmark or Steam Deck/Linux hardware validation was
performed for this GDScript-only correction. The DLL/SO are unchanged.

Re-run the focused regression with a real Forward+ renderer:

```text
Godot_v4.7.1-stable_win64_console.exe --path . --script res://validation/ocean_autonomous_clock_runtime.gd --audio-driver Dummy --fixed-fps 60 -- --result=<absolute-output.json>
```

## Updating an already copied addon

Stop the running game and replace only
`addons/ocean/fft/open_ocean_fft.gd` in the destination project with the corrected
file. Its UID and native binaries are unchanged. No Jet Ski update or scene
adjustment is required. `wave_speed_multiplier = 1` is normal playback and `0`
is the existing pause control.
