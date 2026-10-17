extends SceneTree
## Export completed validation only. Run headless after the GPU jobs finish.
var _manifest:Dictionary={"phase":"PHYS-GPU-1.3","status":"PARTIAL","files":[],"errors":[]}

func _initialize() -> void: call_deferred("_run")

func _read(name:String) -> Dictionary:
	var path:="res://.godot/"+name+".json"
	var parsed:Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		_manifest.errors.append("missing completed evidence "+path); return {}
	return parsed

func _put(path:String,bytes:PackedByteArray,plain_bytes:int,rows:int,plain_hash:String) -> void:
	var file:=FileAccess.open(path,FileAccess.WRITE)
	if file==null: _manifest.errors.append("cannot write "+path); return
	file.store_buffer(bytes); file.close()
	_manifest.files.append({"path":path.trim_prefix("res://"),"bytes":bytes.size(),"plain_bytes":plain_bytes,"rows":rows,"sha256":FileAccess.get_sha256(path),"plain_sha256":plain_hash})

func _put_json(path:String,data:Variant) -> void:
	var bytes:=JSON.stringify(data,"\t").to_utf8_buffer()
	_put(path,bytes,bytes.size(),0,_hash(bytes))

func _hash(bytes:PackedByteArray) -> String:
	var context:=HashingContext.new(); context.start(HashingContext.HASH_SHA256); context.update(bytes)
	return context.finish().hex_encode()

func _gzip_file(source:String,destination:String) -> void:
	var bytes:=FileAccess.get_file_as_bytes(source)
	if bytes.is_empty(): _manifest.errors.append("empty source "+source); return
	_put(destination,bytes.compress(FileAccess.COMPRESSION_GZIP),bytes.size(),0,FileAccess.get_sha256(source))

func _gzip_cases(source_name:String,prefix:String) -> int:
	var source:=FileAccess.open("res://.godot/"+source_name+".jsonl",FileAccess.READ)
	if source==null: _manifest.errors.append("missing full envelope case records"); return 0
	DirAccess.make_dir_recursive_absolute("res://validation/physics/gpu13_envelope")
	var bytes:=PackedByteArray(); var rows:=0; var part:=1; var total:=0
	while not source.eof_reached():
		var line:=source.get_line()
		if line.is_empty(): continue
		bytes.append_array((line+"\n").to_utf8_buffer()); rows+=1; total+=1
		if bytes.size()>=8*1024*1024:
			_put("res://validation/physics/gpu13_envelope/"+prefix+"-%03d.jsonl.gz"%part,bytes.compress(FileAccess.COMPRESSION_GZIP),bytes.size(),rows,_hash(bytes))
			bytes=PackedByteArray(); rows=0; part+=1
	if not bytes.is_empty():
		_put("res://validation/physics/gpu13_envelope/"+prefix+"-%03d.jsonl.gz"%part,bytes.compress(FileAccess.COMPRESSION_GZIP),bytes.size(),rows,_hash(bytes))
	source.close(); return total

func _run() -> void:
	var full:=_read("phys_gpu13_full")
	var envelope:=_read("phys_gpu13_envelope_replay")
	var old:=_read("phys_gpu13_old_replay")
	var current12:=_read("phys_gpu13_current12_replay")
	var ties:=_read("phys_gpu13_ties")
	var resource:=_read("phys_gpu13_resource_only")
	var lifecycle:=_read("phys_gpu13_lifecycle")
	var successful:=_read("phys_gpu13_success_bench")
	var attempted:=_read("phys_gpu13_bench_only")
	var reentry10:=_read("phys_gpu13_reentry10")
	var reentry10_envelope:=_read("phys_gpu13_reentry10_envelope")
	var legacy:=_read("phys_gpu1_matrix")
	_put_json("res://validation/physics/PHYS-GPU-1.3-MEASUREMENTS.json",{
		"phase":"PHYS-GPU-1.3","status":"PARTIAL","starting_head":"641c856",
		"full":full,"successful_handoff_benchmark":successful,
		"incorrect_handoff_benchmark":attempted,
		"envelope_totals":envelope.get("envelope_totals",{}),
		"envelope_checks":envelope.get("checks",[]),
		"envelope_source_hashes":envelope.get("source_hashes",{}),
		"current12_totals":current12.get("current12_totals",{}),
		"ties":ties,"resource":resource,"lifecycle":lifecycle,
		"reentry10":reentry10,"reentry10_envelope_totals":reentry10_envelope.get("envelope_totals",{}),
		"reentry10_envelope_checks":reentry10_envelope.get("checks",[]),
		"reentry10_envelope_source_hashes":reentry10_envelope.get("source_hashes",{})})
	_put_json("res://validation/physics/PHYS-GPU-1.3-OLD-RECLASSIFICATION.json",old)
	_put_json("res://validation/physics/PHYS-GPU-1.3-LEGACY-PARITY.json",legacy)
	_gzip_file("res://.godot/phys_gpu13_current12_replay.json","res://validation/physics/PHYS-GPU-1.3-CURRENT12-REPLAY.json.gz")
	_gzip_file("res://.godot/phys_gpu13_full_ledger.json","res://validation/physics/PHYS-GPU-1.3-CONTACT-LEDGER.json.gz")
	_gzip_file("res://.godot/phys_gpu13_reentry10_ledger.json","res://validation/physics/PHYS-GPU-1.3-REENTRY10-LEDGER.json.gz")
	_put_json("res://validation/physics/PHYS-GPU-1.3-ENVELOPE-EXAMPLES.json",envelope)
	_manifest["envelope_case_rows"]=_gzip_cases("phys_gpu13_envelope_cases","cases")
	_manifest["reentry10_envelope_case_rows"]=_gzip_cases("phys_gpu13_reentry10_envelope_cases","reentry10-cases")
	if _manifest.get("envelope_case_rows",-1)!=int(full.get("ledger_count",-2)):
		_manifest.errors.append("envelope case export does not cover the contact ledger")
	if _manifest.get("reentry10_envelope_case_rows",-1)!=int(reentry10.get("ledger_count",-2)):
		_manifest.errors.append("reentry10 envelope case export does not cover its contact ledger")
	_manifest["source_hashes"]=full.get("source_hashes",{})
	_manifest["export_source_hash"]=FileAccess.get_sha256("res://validation/physics/phys_gpu13_export.gd")
	_manifest["verifier_source_hash"]=FileAccess.get_sha256("res://validation/physics/phys_gpu13_verify.cjs")
	var file:=FileAccess.open("res://validation/physics/PHYS-GPU-1.3-EVIDENCE-MANIFEST.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(_manifest,"\t")); file.close()
	print("GPU13_EXPORT="+JSON.stringify({"files":_manifest.files.size(),"cases":_manifest.get("envelope_case_rows",0),"errors":_manifest.errors}))
	quit(0 if _manifest.errors.is_empty() else 1)
