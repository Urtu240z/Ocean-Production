extends "res://validation/physics/phys_gpu11_runner.gd"
## PHYS-GPU-1.2 validation ledger. Captured history never enters runtime packets.
var _ledger:Dictionary={}

func _trajectory(vehicles:int,contacts:int,ticks:int,long_run:bool) -> void:
	_ledger.clear()
	await super._trajectory(vehicles,contacts,ticks,long_run)

func _observe(result:Dictionary,pauses:Array) -> void:
	if result.is_empty() or not _inbox.has(result.generation): return
	var contexts:Array=_inbox[result.generation]
	var enriched:Array=[]
	for i in int(result.count):
		var context:Dictionary=contexts[i]; var row:=_decode(result,i)
		var key:int=context.slot
		var prior:Dictionary=_ledger.get(key,{})
		if context.active and not row.valid:
			var history:Dictionary={"available":false,"reason":"no matching captured valid predecessor"}
			if row.owned and not prior.is_empty() and prior.q==row.previous and prior.generation<result.generation:
				history={"available":true,"generation":prior.generation,"time":prior.time,
					"target":[prior.target.x,prior.target.y],"q":[prior.q.x,prior.q.y],
					"weather_alpha":prior.alpha,"config":prior.config,"physical_det":prior.det,
					"water_velocity":[prior.velocity.x,prior.velocity.y,prior.velocity.z],
					"elapsed":result.sample_time-prior.time,
					"target_motion":context.target.distance_to(prior.target)}
			enriched.append(history)
		if context.active and row.valid:
			_ledger[key]={"generation":result.generation,"time":result.sample_time,"target":context.target,
				"q":row.q,"alpha":result.weather_alpha,"config":result.config_version,"det":row.det,"velocity":row.velocity}
		else: _ledger.erase(key)
	var begin:=_records.size()
	super._observe(result,pauses)
	for i in enriched.size(): _records[begin+i]["captured_history"]=enriched[i]

func _save() -> void:
	_proof["phase"]="PHYS-GPU-1.2"
	_proof["starting_head"]="4da4c7e"
	var suffix:String="resource" if OS.get_cmdline_user_args().has("--resource-only") else "focused" if OS.get_cmdline_user_args().has("--focused-only") else "full"
	var file:=FileAccess.open("res://.godot/phys_gpu12_"+suffix+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(_proof)); file.close()
