extends "res://validation/physics/phys_branch_continuity_runner.gd"
## Add exceptional recovery timings without changing the authoritative checks.
func _cost_distribution(values: Array) -> Dictionary:
	if values.is_empty(): return {"count":0,"mean":null,"p95":null,"p99":null,"max":null}
	var sorted := values.duplicate(); sorted.sort(); var sum := 0.0
	for v in sorted: sum += float(v)
	return {"count":sorted.size(),"mean":sum/sorted.size(),"p95":sorted[int((sorted.size()-1)*0.95)],
		"p99":sorted[int((sorted.size()-1)*0.99)],"max":sorted.back()}

func _local_probe(native: Object, roots: Dictionary) -> Dictionary:
	var report := super._local_probe(native,roots)
	var timings: Array = []; var others: Array = []; var q := _vec(roots.a); var w := _vec(roots.target)
	for row in report.cases:
		if int(row.status)!=1: continue
		var state := _state_at(native,q+Vector2(float(row.seed_offset),0),w); state[DET]=roots.det_a
		for i in 100:
			var at := Time.get_ticks_usec()
			var result: PackedFloat64Array = native.call("sample_dynamic_contact",w.x,w.y,state)
			var elapsed := (Time.get_ticks_usec()-at)/1000.0
			if int(result[STATUS])==1: timings.append(elapsed)
			else: others.append({"status":result[STATUS],"ms":elapsed})
	report.local_reacquisition_ms=_cost_distribution(timings); report.unexpected_statuses=others
	return report

func _lifecycle(native: Object, roots: Dictionary) -> Dictionary:
	var report := super._lifecycle(native,roots)
	var w := _vec(roots.target); var values: Array = []; var bad := 0
	for i in 100:
		var at := Time.get_ticks_usec()
		var result: PackedFloat64Array = native.call("sample_dynamic_contact",w.x,w.y,PackedFloat64Array())
		values.append((Time.get_ticks_usec()-at)/1000.0)
		if result[0]==0 or int(result[STATUS])!=2: bad+=1
	report.global_reacquisition_ms=_cost_distribution(values); report.global_bad=bad
	report.passed=bool(report.passed) and bad==0
	return report
