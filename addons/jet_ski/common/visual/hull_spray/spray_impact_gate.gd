extends RefCounted
## Independent physical impact gate. No rendering, global RNG, or water queries.
var rng := RandomNumberGenerator.new()
var pending := Vector2(-1,-1)
var strength := Vector2.ZERO
var cooldown := Vector2.ZERO
var previous := Vector2.ZERO
var flow_wait := Vector2(0.03,0.10)
var last_emitted_side := 1
var armed := [true,true]
var elapsed := 0.0
var event_count := Vector2i.ZERO
var capture_events := false
var events: Array[Dictionary] = []

func step(delta: float, forward_speed: float, wet: Vector2, impact: Vector2,
		airborne: bool, settings: Resource) -> Vector2:
	elapsed += delta
	var fired := Vector2.ZERO
	for side in 2: cooldown[side]=maxf(cooldown[side]-delta,0.0)
	if airborne or not settings.sides_enabled or forward_speed<maxf(settings.speed_start,0.5):
		pending=Vector2(-1,-1)
		previous=Vector2.ZERO
		armed[0]=true
		armed[1]=true
		return fired
	var threshold: float=maxf(settings.impact_threshold,0.1)
	for side in 2:
		if wet[side]<0.05:
			pending[side]=-1
			armed[side]=true
		if impact[side]<threshold*0.4: armed[side]=true
	# Strongest side initiates the pair; the other can be weaker or absent.
	var leading := 0 if impact.x>=impact.y else 1
	for order in 2:
		var side := leading if order==0 else 1-leading
		if wet[side]<0.05 or cooldown[side]>0.0 or pending[side]>=0.0: continue
		if impact[side]<threshold: continue
		if not armed[side] and impact[side]-previous[side]<threshold*0.45: continue
		_schedule(side,clampf(impact[side]/(threshold*3.0),0.3,1.2),rng.randf_range(0.0,0.015),settings)
		var other := 1-side
		if wet[other]>0.05 and cooldown[other]<=0.0 and pending[other]<0.0 and rng.randf()<0.78:
			var response := clampf(impact[other]/maxf(impact[side],0.01),0.2,0.75)
			var delay_limit: float=maxf(settings.side_delay,0.04)
			_schedule(other,strength[side]*response*rng.randf_range(0.65,0.95),rng.randf_range(maxf(0.025,delay_limit*0.4),delay_limit),settings)
	previous=impact
	# Smaller water sheets recur during sustained forward contact. Wave impacts
	# remain the stronger accents; independent clocks avoid synchronized sides.
	for side in 2:
		flow_wait[side]-=delta
		if settings.sustained_rate_hz<=0.0 or wet[side]<0.05 or pending[side]>=0.0 or flow_wait[side]>0.0: continue
		var activity := smoothstep(settings.speed_start,settings.speed_start+10.0,forward_speed)
		var amount := lerpf(0.22,0.65,activity)*wet[side]
		pending[side]=rng.randf_range(0.0,0.025)
		strength[side]=amount*rng.randf_range(0.7,1.15)
		flow_wait[side]=rng.randf_range(0.8,1.35)/maxf(settings.sustained_rate_hz,0.01)
	var emitted_this_tick := false
	var first_side := 1-last_emitted_side
	for order in 2:
		var side := (first_side+order)%2
		if pending[side]<0.0: continue
		pending[side]-=delta
		if pending[side]>0.0: continue
		# Different delays can land on the same render tick. Keep the second
		# launch offset even at a lower frame rate.
		if emitted_this_tick:
			pending[side]=maxf(0.025,delta*1.1)
			continue
		pending[side]=-1.0
		fired[side]=strength[side]
		emitted_this_tick=true
		last_emitted_side=side
		event_count[side]+=1
		if capture_events: events.append({"time":elapsed,"side":side,"strength":strength[side]})
	return fired

func _schedule(side: int, amount: float, delay: float, settings: Resource) -> void:
	pending[side]=delay
	strength[side]=amount*rng.randf_range(0.8,1.15)
	cooldown[side]=settings.cooldown*rng.randf_range(0.8,1.4)
	armed[side]=false
