extends SceneTree
const Gate := preload("res://addons/jet_ski/common/visual/hull_spray/spray_impact_gate.gd")
const Style := preload("res://addons/jet_ski/common/visual/hull_spray/hull_spray_style.gd")
func _initialize() -> void:
	var style := Style.new()
	seed(881)
	var expected_random := randi()
	seed(881)
	for scenario in ["rest","air","reverse","dry"]:
		var quiet := Gate.new()
		quiet.rng.seed=21
		for frame in 120:
			quiet.step(1.0/60.0,0.0 if scenario=="rest" else (-8.0 if scenario=="reverse" else 8.0),
				Vector2.ZERO if scenario=="dry" else Vector2.ONE,Vector2(6,6),scenario=="air",style)
		assert(quiet.event_count==Vector2i.ZERO,scenario)
	var gate := Gate.new()
	gate.rng.seed=1769
	gate.capture_events=true
	for frame in 420:
		var t := frame/60.0
		var energy := Vector2.ZERO
		for hit in [[0.5,5.0,1.7],[1.4,1.5,6.0],[2.8,4.0,2.2],[3.65,1.8,4.8],[5.1,6.0,3.5]]:
			if t>=hit[0] and t<hit[0]+0.18: energy=Vector2(hit[1],hit[2])
		gate.step(1.0/60.0,10.0,Vector2.ONE,energy,false,style)
	assert(gate.event_count.x>=3 and gate.event_count.y>=3)
	var simultaneous := 0
	var strengths := []
	for i in gate.events.size():
		strengths.append(gate.events[i].strength)
		for j in range(i+1,gate.events.size()):
			if gate.events[i].side!=gate.events[j].side and absf(gate.events[i].time-gate.events[j].time)<0.001: simultaneous+=1
	assert(simultaneous==0,"Sides fired in lockstep")
	assert(strengths.max()-strengths.min()>0.2)
	var one_side := Gate.new()
	one_side.rng.seed=21
	style.sustained_rate_hz=0.0
	for frame in 120: one_side.step(1.0/60.0,8.0,Vector2(1,0),Vector2(5,8),false,style)
	assert(one_side.event_count.x==1 and one_side.event_count.y==0,"Dry side fired or a sustained impact repeated")
	style.sustained_rate_hz=6.0
	var continuous := Gate.new()
	continuous.rng.seed=42
	continuous.capture_events=true
	for frame in 180: continuous.step(1.0/60.0,12.0,Vector2.ONE,Vector2.ZERO,false,style)
	assert(continuous.event_count.x>=10 and continuous.event_count.y>=10,"Sustained wet motion did not emit recurrent sheets")
	for i in range(1,continuous.events.size()):
		assert(continuous.events[i].time>continuous.events[i-1].time,"Sustained sides synchronized")
	var low_fps := Gate.new()
	low_fps.rng.seed=42
	for frame in 60: low_fps.step(1.0/12.0,12.0,Vector2.ONE,Vector2.ZERO,false,style)
	assert(low_fps.event_count.x>5 and low_fps.event_count.y>5,"A side was starved at low frame rate")
	assert(abs(low_fps.event_count.x-low_fps.event_count.y)<10)
	assert(randi()==expected_random,"Spray changed the global random stream")
	var pending := Gate.new()
	pending.rng.seed=1769
	pending.step(0.001,8.0,Vector2.ONE,Vector2(6,2),false,style)
	var count := pending.event_count
	for frame in 60: pending.step(1.0/60.0,8.0,Vector2.ONE,Vector2(6,6),true,style)
	assert(pending.event_count==count and pending.pending==Vector2(-1,-1))
	var result := {"passed":true,"events":gate.events,"counts":gate.event_count,"simultaneous":simultaneous,
		"quiet_modes":["rest","air","reverse","dry"],"one_wet_side":one_side.event_count,"global_rng_preserved":true}
	DirAccess.make_dir_recursive_absolute("res://temp/hull_spray")
	FileAccess.open("res://temp/hull_spray/impact_contract.json",FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
	print("HULL_SPRAY_IMPACT_PASS events=",gate.events.size()," simultaneous=",simultaneous)
	quit()
