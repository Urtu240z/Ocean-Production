extends "res://addons/ocean/physics/water/cpu_fft_water_provider.gd"
## Counters and clocks exist only in this diagnostic fixture, never production.
var counts := PackedInt64Array()
var reference_comparison := false
const Reference = preload("res://validation/physics/perf_contact_reference_provider.gd")
const LABELS = ["validation_calls","validation_us","source_reads","source_us",
	"sample_calls","cached_reads","cache_misses","cached_read_excluding_validation_us",
	"disabled_comparison_calls","disabled_comparison_validation_us","prepare_calls","prepare_us",
	"batch_calls","batch_us","native_base_us","native_base_batches","native_base_contacts",
	"consumer_switches","consumer_switch_us"]

func _init() -> void:
	super()
	counts.resize(LABELS.size())

func snapshot() -> Dictionary:
	var result := {}
	for i in LABELS.size(): result[LABELS[i]] = counts[i]
	return result

func _is_water_source_current() -> bool:
	var start := Time.get_ticks_usec()
	var result := super()
	counts[0] += 1
	counts[1] += Time.get_ticks_usec()-start
	return result

func _read_ocean_source_state() -> Dictionary:
	var start := Time.get_ticks_usec()
	var result := super()
	counts[2] += 1
	counts[3] += Time.get_ticks_usec()-start
	return result

func sample_water(position: Vector3, output: WaterSample3D = null) -> WaterSample3D:
	var hit := _contact_cache_cursor < _contact_positions.size() and _contact_cache_cursor < _selected_contact_cache.size() and _same_xz(position,_contact_positions[_contact_cache_cursor])
	var validation_before := counts[1]
	var start := Time.get_ticks_usec()
	var result := super(position,output)
	counts[4] += 1
	if hit:
		counts[5] += 1
		counts[7] += Time.get_ticks_usec()-start-(counts[1]-validation_before)
	else: counts[6] += 1
	return result

func sample_comparison_water(position: Vector3, output: WaterSample3D = null) -> WaterSample3D:
	var validation_before := counts[1]
	var disabled := not compare_other_cpu_backend
	var result: WaterSample3D
	if reference_comparison:
		# This wrapper is diagnostic only. Reference fixture is used unwrapped in A.
		result = output.reset() if output != null else WaterSample3D.new()
		if not _is_water_source_current(): return result
		if not compare_other_cpu_backend:
			counts[8] += 1
			counts[9] += counts[1]-validation_before
			return result
		result = super(position,output)
	else: result = super(position,output)
	if disabled:
		counts[8] += 1
		counts[9] += counts[1]-validation_before
	return result

func prepare_water_queries(body: Transform3D, points: PackedVector3Array, extra: PackedVector3Array, delta: float) -> void:
	var start := Time.get_ticks_usec()
	super(body,points,extra,delta)
	counts[10] += 1
	counts[11] += Time.get_ticks_usec()-start

func sample_water_batch(points: PackedVector3Array, selected := -1, modes: PackedInt32Array = PackedInt32Array()) -> Array[WaterSample3D]:
	var native_before := contact_query_native_us
	var batches_before := contact_query_batch_count
	var positions_before := contact_query_count
	var start := Time.get_ticks_usec()
	var result := super(points,selected,modes)
	counts[12] += 1
	counts[13] += Time.get_ticks_usec()-start
	counts[14] += contact_query_native_us-native_before
	counts[15] += contact_query_batch_count-batches_before
	counts[16] += contact_query_count-positions_before
	return result

func select_consumer(consumer: RefCounted) -> void:
	var changed := consumer != _active_consumer
	var start := Time.get_ticks_usec()
	super(consumer)
	if changed:
		counts[17] += 1
		counts[18] += Time.get_ticks_usec()-start
