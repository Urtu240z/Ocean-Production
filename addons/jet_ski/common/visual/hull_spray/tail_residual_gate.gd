extends RefCounted
## Finite water retained after intake loses contact. Visual only, no physics/query.
var rng := RandomNumberGenerator.new()
var charge := 0.0
var remaining := 0.0
var wait := 0.0
var pulse_age := 0.0
var pulse_length := 0.0
var pulse_strength := 0.0
var was_driven_wet := false

func step(delta: float, driven_wet: bool, enabled: bool, duration: float, strength: float) -> float:
	if not enabled or duration<=0.0:
		charge=0.0
		remaining=0.0
		was_driven_wet=false
		return 0.0
	if driven_wet:
		charge=minf(1.0,charge+delta*5.0)
		remaining=0.0
		was_driven_wet=true
		return 0.0
	if was_driven_wet:
		remaining=duration*charge
		wait=rng.randf_range(0.015,0.045)
		pulse_length=0.0
		was_driven_wet=false
	remaining=maxf(0.0,remaining-delta)
	if remaining<=0.0:
		charge=0.0
		return 0.0
	wait-=delta
	if wait<=0.0:
		pulse_age=0.0
		pulse_length=rng.randf_range(0.045,0.085)
		pulse_strength=rng.randf_range(0.45,1.0)
		wait=pulse_length+rng.randf_range(0.035,0.095)
	pulse_age+=delta
	var fade := remaining/maxf(duration,0.001)
	return sin(clampf(pulse_age/maxf(pulse_length,0.001),0.0,1.0)*PI)*pulse_strength*fade*fade*strength
